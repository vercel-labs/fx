const std = @import("std");
const contracts = @import("contracts.zig");

const max_calls = 1024;

// The caller owns the returned arrays and releases them with Plan.deinit.
// Calls retain input order. Borrowed strings must stay alive and unchanged.
pub fn build_plan(
    alloc: std.mem.Allocator,
    calls: []const contracts.LogicalCall,
    mode: contracts.Mode,
) (std.mem.Allocator.Error || error{ DuplicateLogicalId, TooManyCalls })!contracts.Plan {
    if (calls.len > max_calls) return error.TooManyCalls;
    for (calls, 0..) |call, index| {
        for (calls[0..index]) |earlier| {
            if (call.request.id == earlier.request.id) return error.DuplicateLogicalId;
        }
    }

    const logical_calls = try alloc.alloc(contracts.PlannedCall, calls.len);
    errdefer alloc.free(logical_calls);
    var groups: std.ArrayList(contracts.PhysicalGroup) = .empty;
    defer groups.deinit(alloc);
    try groups.ensureTotalCapacity(alloc, calls.len);

    for (calls, 0..) |call, index| {
        const status = admission_status(call);
        logical_calls[index] = .{
            .call = call,
            .status = status,
            .physical_group = null,
        };
        if (status != .admitted) continue;

        var existing_group: ?usize = null;
        if (mode == .enabled and call.request.effect == .snapshot_read) {
            for (groups.items, 0..) |group, group_index| {
                const representative = logical_calls[group.representative].call.request;
                if (compatible(call.request, representative)) {
                    existing_group = group_index;
                    break;
                }
            }
        }
        if (existing_group) |group_index| {
            logical_calls[index].physical_group = group_index;
            groups.items[group_index].consumer_count += 1;
        } else {
            const group_index = groups.items.len;
            groups.appendAssumeCapacity(.{
                .id = group_index,
                .representative = index,
                .consumer_count = 1,
            });
            logical_calls[index].physical_group = group_index;
        }
    }

    return .{
        .logical_calls = logical_calls,
        .groups = try groups.toOwnedSlice(alloc),
    };
}

fn admission_status(call: contracts.LogicalCall) contracts.AdmissionStatus {
    const admitted = switch (call.admission) {
        .denied => return .denied,
        .admitted => |host_admission| host_admission,
    };
    if (!exact_binding(call.request, admitted.binding)) return .binding_mismatch;
    if (!same_authority(call.request.authority, admitted.current_authority)) return .stale_authority;
    if (call.request.effect == .snapshot_read) {
        const requested_snapshot = call.request.snapshot orelse return .uncertified_snapshot;
        const certified_snapshot = admitted.immutable_snapshot orelse return .uncertified_snapshot;
        if (!same_snapshot(requested_snapshot, certified_snapshot)) return .uncertified_snapshot;
    }
    return .admitted;
}

fn exact_binding(a: contracts.CallBinding, b: contracts.CallBinding) bool {
    return a.id == b.id and
        same_bytes(a.agent_id, b.agent_id) and
        compatible_fields(a, b);
}

fn compatible(a: contracts.CallBinding, b: contracts.CallBinding) bool {
    return a.effect == .snapshot_read and b.effect == .snapshot_read and compatible_fields(a, b);
}

// Logical identity is deliberately excluded from physical equivalence.
fn compatible_fields(a: contracts.CallBinding, b: contracts.CallBinding) bool {
    return same_bytes(a.principal_domain, b.principal_domain) and
        same_bytes(a.task_id, b.task_id) and
        same_bytes(a.tool_id, b.tool_id) and
        a.effect == b.effect and
        same_optional_snapshot(a.snapshot, b.snapshot) and
        same_bytes(a.args.path, b.args.path) and
        a.args.window.offset == b.args.window.offset and
        a.args.window.length == b.args.window.length and
        same_bytes(a.args.options, b.args.options) and
        same_bytes(a.result.schema_id, b.result.schema_id) and
        a.result.version == b.result.version and
        a.result.encoding == b.result.encoding and
        a.output_budget == b.output_budget and
        same_authority(a.authority, b.authority);
}

fn same_authority(a: contracts.Authority, b: contracts.Authority) bool {
    return same_bytes(a.partition, b.partition) and a.epoch == b.epoch and a.generation == b.generation;
}

fn same_optional_snapshot(a: ?contracts.SnapshotIdentity, b: ?contracts.SnapshotIdentity) bool {
    if (a) |snapshot_a| {
        return if (b) |snapshot_b| same_snapshot(snapshot_a, snapshot_b) else false;
    }
    return b == null;
}

fn same_snapshot(a: contracts.SnapshotIdentity, b: contracts.SnapshotIdentity) bool {
    return same_bytes(a.id, b.id) and same_bytes(a.version, b.version);
}

fn same_bytes(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fixture(id: u64, agent_id: []const u8) contracts.LogicalCall {
    const request: contracts.CallBinding = .{
        .id = id,
        .agent_id = agent_id,
        .principal_domain = "operator",
        .task_id = "task-1",
        .tool_id = "embedded-content-reader",
        .effect = .snapshot_read,
        .snapshot = .{ .id = "snapshot-1", .version = "content-v1" },
        .args = .{ .path = "fixture.txt", .window = .{ .offset = 0, .length = 8 }, .options = "raw" },
        .result = .{ .schema_id = "content", .version = 1, .encoding = .bytes },
        .output_budget = 64,
        .authority = .{ .partition = "operator-read", .epoch = 2, .generation = 3 },
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

test "two agents in the same domain share certified reads only when enabled" {
    const calls = [_]contracts.LogicalCall{ fixture(1, "agent-a"), fixture(2, "agent-b") };
    var enabled = try build_plan(std.testing.allocator, &calls, .enabled);
    defer enabled.deinit(std.testing.allocator);
    var disabled = try build_plan(std.testing.allocator, &calls, .disabled);
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), enabled.groups.len);
    try std.testing.expectEqual(@as(usize, 2), disabled.groups.len);
    try std.testing.expectEqual(@as(usize, 2), enabled.logical_calls.len);
    try std.testing.expectEqual(@as(usize, 2), enabled.groups[0].consumer_count);
    try std.testing.expectEqualStrings("agent-a", enabled.logical_calls[0].call.request.agent_id);
    try std.testing.expectEqualStrings("agent-b", enabled.logical_calls[1].call.request.agent_id);
    try std.testing.expectEqual(@as(?usize, 0), enabled.logical_calls[0].physical_group);
    try std.testing.expectEqual(@as(?usize, 0), enabled.logical_calls[1].physical_group);
}

test "denied consumers retain logical identity and never enter physical groups" {
    var denied = fixture(2, "agent-b");
    denied.admission = .denied;
    const calls = [_]contracts.LogicalCall{ denied, fixture(1, "agent-a"), fixture(3, "agent-c") };
    inline for (.{ contracts.Mode.disabled, contracts.Mode.enabled }) |mode| {
        var plan = try build_plan(std.testing.allocator, &calls, mode);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 3), plan.logical_calls.len);
        try std.testing.expectEqual(contracts.AdmissionStatus.denied, plan.logical_calls[0].status);
        try std.testing.expectEqual(@as(?usize, null), plan.logical_calls[0].physical_group);
        for (plan.groups) |group| try std.testing.expect(group.representative != 0);
        try std.testing.expectEqual(@as(u64, 2), plan.logical_calls[0].call.request.id);
    }
}

test "host generation and epoch changes reject stale authority" {
    inline for (.{ "epoch", "generation" }) |field| {
        var stale = fixture(1, "agent-a");
        @field(stale.admission.admitted.current_authority, field) += 1;
        var plan = try build_plan(std.testing.allocator, &.{stale}, .enabled);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(contracts.AdmissionStatus.stale_authority, plan.logical_calls[0].status);
        try std.testing.expectEqual(@as(usize, 0), plan.groups.len);
    }
}

test "admission binds the exact request including logical agent and arguments" {
    inline for (0..4) |change| {
        var changed = fixture(1, "agent-a");
        switch (change) {
            0 => changed.request.id = 9,
            1 => changed.request.agent_id = "agent-b",
            2 => changed.request.args.path = "other.txt",
            3 => changed.request.args.window.offset = 1,
            else => unreachable,
        }
        var plan = try build_plan(std.testing.allocator, &.{changed}, .enabled);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(contracts.AdmissionStatus.binding_mismatch, plan.logical_calls[0].status);
        try std.testing.expectEqual(@as(usize, 0), plan.groups.len);
    }
}

test "snapshot reads need an exact host certificate independent of tool names" {
    inline for (0..3) |change| {
        var uncertified = fixture(1, "agent-a");
        switch (change) {
            0 => uncertified.admission.admitted.immutable_snapshot = null,
            1 => uncertified.admission.admitted.immutable_snapshot.?.version = "content-v2",
            2 => {
                uncertified.request.snapshot = null;
                uncertified.admission.admitted.binding = uncertified.request;
            },
            else => unreachable,
        }
        var plan = try build_plan(std.testing.allocator, &.{uncertified}, .enabled);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(contracts.AdmissionStatus.uncertified_snapshot, plan.logical_calls[0].status);
        try std.testing.expectEqual(@as(usize, 0), plan.groups.len);
    }
}

test "different snapshots contracts authorities domains tasks and options prevent sharing" {
    inline for (0..16) |change| {
        const first = fixture(1, "agent-a");
        var request = fixture(2, "agent-b").request;
        switch (change) {
            0 => request.snapshot.?.id = "snapshot-2",
            1 => request.snapshot.?.version = "content-v2",
            2 => request.result.schema_id = "other-schema",
            3 => request.result.version = 2,
            4 => request.result.encoding = .utf8,
            5 => request.authority.partition = "other-grant",
            6 => request.authority.epoch += 1,
            7 => request.authority.generation += 1,
            8 => request.principal_domain = "other-operator",
            9 => request.task_id = "other-task",
            10 => request.args.options = "with-header",
            11 => request.args.path = "other.txt",
            12 => request.args.window.offset = 1,
            13 => request.args.window.length = 4,
            14 => request.output_budget = 32,
            15 => request.tool_id = "other-reader",
            else => unreachable,
        }
        const calls = [_]contracts.LogicalCall{ first, admit(request) };
        var plan = try build_plan(std.testing.allocator, &calls, .enabled);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), plan.groups.len);
        try std.testing.expectEqual(contracts.AdmissionStatus.admitted, plan.logical_calls[1].status);
    }
}

test "mutable reads mutations external effects and opaque calls remain separate" {
    inline for (.{ contracts.Effect.mutable_read, contracts.Effect.mutation, contracts.Effect.external, contracts.Effect.opaque_exec }) |effect| {
        var first = fixture(1, "agent-a").request;
        var second = fixture(2, "agent-b").request;
        first.effect = effect;
        second.effect = effect;
        const calls = [_]contracts.LogicalCall{ admit(first), admit(second) };
        var plan = try build_plan(std.testing.allocator, &calls, .enabled);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), plan.groups.len);
    }
}

test "duplicate logical IDs are rejected even across agents or admission outcomes" {
    var second = fixture(1, "agent-b");
    second.admission = .denied;
    const calls = [_]contracts.LogicalCall{ fixture(1, "agent-a"), second };
    try std.testing.expectError(error.DuplicateLogicalId, build_plan(std.testing.allocator, &calls, .enabled));
}

test "empty input is valid and the bounded planner rejects excess calls" {
    var empty = try build_plan(std.testing.allocator, &.{}, .enabled);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.logical_calls.len);
    try std.testing.expectEqual(@as(usize, 0), empty.groups.len);
    const calls: [max_calls + 1]contracts.LogicalCall = undefined;
    try std.testing.expectError(error.TooManyCalls, build_plan(std.testing.allocator, &calls, .enabled));
}

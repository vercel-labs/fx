const std = @import("std");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session_child_store = @import("../session/session_child_store.zig");
const types = @import("../shared/types.zig");
const communication = @import("communication.zig");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;
const schema_version: u64 = 6;
const base64_delivery_schema_version: u64 = 5;
const previous_capacity_schema_version: u64 = 4;
const pre_capacity_schema_version: u64 = 3;
const process_epoch_schema_version: u64 = 2;
const legacy_schema_version: u64 = 1;
pub const max_record_bytes: usize = 512 * 1024;
pub const mutation_reserve_bytes: usize = 64 * 1024;
pub const max_canonical_record_bytes: usize =
    max_record_bytes - mutation_reserve_bytes;
pub const metadata_budget_bytes: usize = 32 * 1024;
pub const retained_delivery_budget_bytes: usize =
    communication.max_retained_delivery_canonical_bytes;
pub const subsequent_mutation_budget_bytes: usize =
    communication.max_retained_delivery_canonical_bytes;
const record_file = "communication.json";
const lock_file = "subagent-control.lock";
const lock_deadline_ms: u64 = 2000;

const WireRecord = struct {
    schema_version: u64,
    ledger: communication.Ledger,
};

const WireMessageV5 = struct {
    encoding: []u8,
    data: []u8,
};

const WireDeliveryPayloadV5 = union(communication.DeliveryKind) {
    message: WireMessageV5,
    milestone: []u8,
    terminal: domain.State,
    interval: struct {
        state: domain.State,
        coalesced_ticks: u32,
    },
    approval: []u8,
    tool_activity: communication.ToolActivity,
};

const WireDeliveryV5 = struct {
    sequence: u64,
    revision: u64,
    id: []u8,
    source_id: []u8,
    target_id: []u8,
    work_id: ?[]u8 = null,
    operation_id: ?[]u8 = null,
    timestamp_ms: i64,
    payload: WireDeliveryPayloadV5,
};

const WireLedgerV5 = struct {
    session_id: []u8,
    capacity_version: u64 = 0,
    generation: u64 = 0,
    next_sequence: u64 = 1,
    deliveries: []WireDeliveryV5,
    cursors: []communication.ConsumerCursor,
    retention_targets: ?[]communication.RetentionTarget = null,
    work_notifications: []communication.WorkNotification,
    approvals: []communication.Approval,
    parent_turn_evicted_through: u64 = 0,
    authority_generation: u64 = 0,
    authority_grants: []types.PermissionGrant,
    legacy_operation_replay_closed: bool = false,
    model_replay_floor: u64 = 0,
    human_replay_floor: u64 = 0,
    model_epoch_high: u64 = 0,
    human_epoch_high: u64 = 0,
};

const WireRecordV5 = struct {
    schema_version: u64,
    ledger: WireLedgerV5,
};

const WirePermissionGrantV6 = struct {
    tool_name: []u8,
    target_path: WireMessageV5,
};

const WireApprovalV6 = struct {
    id: []u8,
    kind: communication.ApprovalKind,
    child_id: []u8,
    root_id: []u8,
    work_id: ?[]u8,
    relationship: ?communication.RelationshipApproval = null,
    prepared_fingerprint: [32]u8,
    identity_fingerprint: [32]u8,
    label: []u8,
    explanation: ?[]u8,
    command: ?WireMessageV5 = null,
    file: ?permission_request.FileApprovalRequest = null,
    grants: []WirePermissionGrantV6,
    status: communication.ApprovalStatus,
    created_at_ms: i64,
    resolved_at_ms: ?i64 = null,
    resolved_revision: ?u64 = null,
};

const WireLedgerV6 = struct {
    session_id: []u8,
    capacity_version: u64 = 0,
    generation: u64 = 0,
    next_sequence: u64 = 1,
    deliveries: []WireDeliveryV5,
    cursors: []communication.ConsumerCursor,
    retention_targets: ?[]communication.RetentionTarget = null,
    work_notifications: []communication.WorkNotification,
    approvals: []WireApprovalV6,
    parent_turn_evicted_through: u64 = 0,
    authority_generation: u64 = 0,
    authority_grants: []WirePermissionGrantV6,
    legacy_operation_replay_closed: bool = false,
    model_replay_floor: u64 = 0,
    human_replay_floor: u64 = 0,
    model_epoch_high: u64 = 0,
    human_epoch_high: u64 = 0,
};

const WireRecordV6 = struct {
    schema_version: u64,
    ledger: WireLedgerV6,
};

comptime {
    // 224 KiB live state + 32 KiB metadata + one retained and one subsequent
    // 96 KiB delivery fit below 448 KiB, leaving 64 KiB below the file cap.
    if (communication.max_irreducible_canonical_bytes +
        metadata_budget_bytes +
        retained_delivery_budget_bytes +
        subsequent_mutation_budget_bytes >
        max_canonical_record_bytes)
    {
        @compileError("communication capacity budgets exceed the canonical record envelope");
    }
}

pub const LoadError = error{
    OutOfMemory,
    CommunicationNotFound,
    InvalidCommunicationRecord,
    UnsupportedCommunicationSchema,
    CommunicationRecordTooLarge,
    CommunicationPathUnsafe,
    PrivateStatePermissionsUnsupported,
    CommunicationStoreFailed,
};

pub const SaveError = error{
    OutOfMemory,
    CommunicationIdentityMismatch,
    InvalidCommunicationRecord,
    CommunicationCapacityExceeded,
    CommunicationRecordTooLarge,
    CommunicationPathUnsafe,
    PrivateStatePermissionsUnsupported,
    CommunicationCommitIndeterminate,
    CommunicationStoreFailed,
};

pub const LockError = error{
    OutOfMemory,
    CommunicationLockBusy,
    CommunicationLockUnsupported,
    CommunicationPathUnsafe,
    PrivateStatePermissionsUnsupported,
    CommunicationStoreFailed,
};

pub const Store = struct {
    capability: *session_child_store.SessionChildCapability,
    expected_session_id: []const u8,

    pub fn acquireLock(self: Store) LockError!io_mod.TimedAdvisoryLock {
        return self.capability.acquireTimedAdvisoryLock(
            .subagent_control,
            lock_file,
            lock_deadline_ms,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LockBusy => error.CommunicationLockBusy,
            error.LockUnsupported => error.CommunicationLockUnsupported,
            error.SessionPathUnsafe => error.CommunicationPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            else => error.CommunicationStoreFailed,
        };
    }

    /// Returns an owned ledger, or null when no communication record exists.
    pub fn loadOptional(self: Store, alloc: Allocator) LoadError!?communication.Ledger {
        var file = self.capability.openFileReadOnly(
            alloc,
            .subagent_control,
            record_file,
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.CommunicationPathUnsafe,
            error.PrivateStatePermissionsUnsupported => return error.PrivateStatePermissionsUnsupported,
            else => return error.CommunicationStoreFailed,
        };
        defer file.deinit();
        const bytes = file.readToEnd(alloc, max_record_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.CommunicationRecordTooLarge,
            else => return error.CommunicationStoreFailed,
        };
        defer alloc.free(bytes);
        var ledger = try decode(alloc, bytes);
        errdefer ledger.deinit(alloc);
        if (!std.mem.eql(u8, ledger.session_id, self.expected_session_id)) {
            return error.InvalidCommunicationRecord;
        }
        return ledger;
    }

    /// Returns an owned ledger; caller frees it with `Ledger.deinit`.
    pub fn load(self: Store, alloc: Allocator) LoadError!communication.Ledger {
        return (try self.loadOptional(alloc)) orelse error.CommunicationNotFound;
    }

    pub fn save(self: Store, alloc: Allocator, ledger: communication.Ledger) SaveError!void {
        if (!std.mem.eql(u8, ledger.session_id, self.expected_session_id)) {
            return error.CommunicationIdentityMismatch;
        }
        communication.validateLedger(ledger) catch
            return error.InvalidCommunicationRecord;
        const bytes = encode(alloc, ledger) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CommunicationCapacityExceeded => error.CommunicationCapacityExceeded,
            error.CommunicationRecordTooLarge => error.CommunicationRecordTooLarge,
        };
        defer alloc.free(bytes);
        var entry = self.capability.atomicReplace(
            alloc,
            .subagent_control,
            record_file,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.CommunicationPathUnsafe,
            error.PrivateStatePermissionsUnsupported => return error.PrivateStatePermissionsUnsupported,
            error.SessionChildCommitIndeterminate => return error.CommunicationCommitIndeterminate,
            else => return error.CommunicationStoreFailed,
        };
        entry.deinit(alloc);
    }
};

const EncodeError = error{
    OutOfMemory,
    CommunicationCapacityExceeded,
    CommunicationRecordTooLarge,
};

fn encode(alloc: Allocator, ledger: communication.Ledger) EncodeError![]u8 {
    return encodeLimit(alloc, ledger, max_record_bytes);
}

fn encodeLimit(
    alloc: Allocator,
    ledger: communication.Ledger,
    byte_limit: usize,
) EncodeError![]u8 {
    var retained = ledger.clone(alloc) catch return error.OutOfMemory;
    defer retained.deinit(alloc);
    communication.compactStoppedWorkNotifications(alloc, &retained) catch
        return error.OutOfMemory;
    var approvals_compacted = false;
    while (true) {
        if (retained.capacity_version == 0 and
            communication.capacityContractSatisfied(retained))
        {
            retained.capacity_version = communication.capacity_contract_version;
            const migrated = try encodeCanonical(alloc, retained);
            if (migrated.len <= @min(byte_limit, max_canonical_record_bytes)) {
                return migrated;
            }
            alloc.free(migrated);
            retained.capacity_version = 0;
        }
        const capacity_bound =
            retained.capacity_version == communication.capacity_contract_version;
        const canonical_limit = if (capacity_bound)
            @min(byte_limit, max_canonical_record_bytes)
        else
            byte_limit;
        const bytes = try encodeCanonical(alloc, retained);
        if (bytes.len <= canonical_limit) return bytes;
        alloc.free(bytes);
        if (!approvals_compacted) {
            approvals_compacted = true;
            if (try communication.compactResolvedApprovals(alloc, &retained)) {
                continue;
            }
        }
        if (retained.deliveries.len <= 1) {
            return if (capacity_bound)
                error.CommunicationCapacityExceeded
            else
                error.CommunicationRecordTooLarge;
        }
        _ = communication.evictOldestDelivery(alloc, &retained) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CapacityExceeded => error.CommunicationCapacityExceeded,
            else => error.CommunicationRecordTooLarge,
        };
    }
}

fn encodeCanonical(alloc: Allocator, ledger: communication.Ledger) error{OutOfMemory}![]u8 {
    return encodeWireCanonical(
        alloc,
        if (ledger.capacity_version == communication.capacity_contract_version)
            schema_version
        else
            pre_capacity_schema_version,
        ledger,
    );
}

fn encodeWireCanonical(
    alloc: Allocator,
    version: u64,
    ledger: communication.Ledger,
) error{OutOfMemory}![]u8 {
    if (version == schema_version) {
        return encodeWireCanonicalV6(alloc, ledger);
    }
    if (version == base64_delivery_schema_version) {
        return encodeWireCanonicalV5(alloc, ledger);
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(WireRecord{
        .schema_version = version,
        .ledger = ledger,
    }, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn encodeWireCanonicalV6(
    alloc: Allocator,
    ledger: communication.Ledger,
) error{OutOfMemory}![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deliveries = try arena.alloc(WireDeliveryV5, ledger.deliveries.len);
    for (ledger.deliveries, deliveries) |delivery, *wire| {
        wire.* = .{
            .sequence = delivery.sequence,
            .revision = delivery.revision,
            .id = delivery.id,
            .source_id = delivery.source_id,
            .target_id = delivery.target_id,
            .work_id = delivery.work_id,
            .operation_id = delivery.operation_id,
            .timestamp_ms = delivery.timestamp_ms,
            .payload = switch (delivery.payload) {
                .message => |content| .{ .message = try encodeWireTextV6(
                    arena,
                    content,
                ) },
                .milestone => |value| .{ .milestone = value },
                .terminal => |value| .{ .terminal = value },
                .interval => |value| .{ .interval = .{
                    .state = value.state,
                    .coalesced_ticks = value.coalesced_ticks,
                } },
                .approval => |value| .{ .approval = value },
                .tool_activity => |value| .{ .tool_activity = value },
            },
        };
    }
    const approvals = try arena.alloc(WireApprovalV6, ledger.approvals.len);
    for (ledger.approvals, approvals) |approval, *wire| {
        wire.* = .{
            .id = approval.id,
            .kind = approval.kind,
            .child_id = approval.child_id,
            .root_id = approval.root_id,
            .work_id = approval.work_id,
            .relationship = approval.relationship,
            .prepared_fingerprint = approval.prepared_fingerprint,
            .identity_fingerprint = approval.identity_fingerprint,
            .label = approval.label,
            .explanation = approval.explanation,
            .command = if (approval.command) |command|
                try encodeWireTextV6(arena, command)
            else
                null,
            .file = approval.file,
            .grants = try encodeWireGrantsV6(arena, approval.grants),
            .status = approval.status,
            .created_at_ms = approval.created_at_ms,
            .resolved_at_ms = approval.resolved_at_ms,
            .resolved_revision = approval.resolved_revision,
        };
    }
    const authority_grants = try encodeWireGrantsV6(
        arena,
        ledger.authority_grants,
    );
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(WireRecordV6{
        .schema_version = schema_version,
        .ledger = .{
            .session_id = ledger.session_id,
            .capacity_version = ledger.capacity_version,
            .generation = ledger.generation,
            .next_sequence = ledger.next_sequence,
            .deliveries = deliveries,
            .cursors = ledger.cursors,
            .retention_targets = ledger.retention_targets,
            .work_notifications = ledger.work_notifications,
            .approvals = approvals,
            .parent_turn_evicted_through = ledger.parent_turn_evicted_through,
            .authority_generation = ledger.authority_generation,
            .authority_grants = authority_grants,
            .legacy_operation_replay_closed = ledger.legacy_operation_replay_closed,
            .model_replay_floor = ledger.model_replay_floor,
            .human_replay_floor = ledger.human_replay_floor,
            .model_epoch_high = ledger.model_epoch_high,
            .human_epoch_high = ledger.human_epoch_high,
        },
    }, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn encodeWireGrantsV6(
    arena: Allocator,
    grants: []const types.PermissionGrant,
) error{OutOfMemory}![]WirePermissionGrantV6 {
    const encoded = try arena.alloc(WirePermissionGrantV6, grants.len);
    for (grants, encoded) |grant, *wire| {
        wire.* = .{
            .tool_name = grant.tool_name,
            .target_path = try encodeWireTextV6(arena, grant.target_path),
        };
    }
    return encoded;
}

fn encodeWireTextV6(
    arena: Allocator,
    content: []const u8,
) error{OutOfMemory}!WireMessageV5 {
    const encoded = try arena.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(content.len),
    );
    _ = std.base64.standard.Encoder.encode(encoded, content);
    return .{
        .encoding = @constCast("base64"),
        .data = encoded,
    };
}

fn encodeWireCanonicalV5(
    alloc: Allocator,
    ledger: communication.Ledger,
) error{OutOfMemory}![]u8 {
    const deliveries = try alloc.alloc(WireDeliveryV5, ledger.deliveries.len);
    defer alloc.free(deliveries);
    var encoded_messages: std.ArrayList([]u8) = .empty;
    defer {
        for (encoded_messages.items) |message| alloc.free(message);
        encoded_messages.deinit(alloc);
    }
    for (ledger.deliveries, 0..) |delivery, index| {
        deliveries[index] = .{
            .sequence = delivery.sequence,
            .revision = delivery.revision,
            .id = delivery.id,
            .source_id = delivery.source_id,
            .target_id = delivery.target_id,
            .work_id = delivery.work_id,
            .operation_id = delivery.operation_id,
            .timestamp_ms = delivery.timestamp_ms,
            .payload = switch (delivery.payload) {
                .message => |content| blk: {
                    const encoded = try alloc.alloc(
                        u8,
                        std.base64.standard.Encoder.calcSize(content.len),
                    );
                    errdefer alloc.free(encoded);
                    _ = std.base64.standard.Encoder.encode(
                        encoded,
                        content,
                    );
                    try encoded_messages.append(alloc, encoded);
                    break :blk .{ .message = .{
                        .encoding = @constCast("base64"),
                        .data = encoded,
                    } };
                },
                .milestone => |value| .{ .milestone = value },
                .terminal => |value| .{ .terminal = value },
                .interval => |value| .{ .interval = .{
                    .state = value.state,
                    .coalesced_ticks = value.coalesced_ticks,
                } },
                .approval => |value| .{ .approval = value },
                .tool_activity => |value| .{ .tool_activity = value },
            },
        };
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(WireRecordV5{
        .schema_version = base64_delivery_schema_version,
        .ledger = .{
            .session_id = ledger.session_id,
            .capacity_version = ledger.capacity_version,
            .generation = ledger.generation,
            .next_sequence = ledger.next_sequence,
            .deliveries = deliveries,
            .cursors = ledger.cursors,
            .retention_targets = ledger.retention_targets,
            .work_notifications = ledger.work_notifications,
            .approvals = ledger.approvals,
            .parent_turn_evicted_through = ledger.parent_turn_evicted_through,
            .authority_generation = ledger.authority_generation,
            .authority_grants = ledger.authority_grants,
            .legacy_operation_replay_closed = ledger.legacy_operation_replay_closed,
            .model_replay_floor = ledger.model_replay_floor,
            .human_replay_floor = ledger.human_replay_floor,
            .model_epoch_high = ledger.model_epoch_high,
            .human_epoch_high = ledger.human_epoch_high,
        },
    }, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn decode(alloc: Allocator, bytes: []const u8) LoadError!communication.Ledger {
    if (bytes.len > max_record_bytes) return error.CommunicationRecordTooLarge;
    var header = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommunicationRecord,
    };
    defer header.deinit();
    const header_object = switch (header.value) {
        .object => |object| object,
        else => return error.InvalidCommunicationRecord,
    };
    const version_value = header_object.get("schema_version") orelse
        return error.InvalidCommunicationRecord;
    const version = switch (version_value) {
        .integer => |value| std.math.cast(u64, value) orelse
            return error.InvalidCommunicationRecord,
        else => return error.InvalidCommunicationRecord,
    };
    if (version != schema_version and
        version != base64_delivery_schema_version and
        version != previous_capacity_schema_version and
        version != pre_capacity_schema_version and
        version != process_epoch_schema_version and version != legacy_schema_version)
    {
        return error.UnsupportedCommunicationSchema;
    }
    if (version == schema_version) return decodeV6(alloc, bytes);
    if (version == base64_delivery_schema_version) return decodeV5(alloc, bytes);
    var parsed = std.json.parseFromSlice(WireRecord, alloc, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommunicationRecord,
    };
    defer parsed.deinit();
    if (version == process_epoch_schema_version or
        version == legacy_schema_version)
    {
        parsed.value.ledger.legacy_operation_replay_closed = true;
        parsed.value.ledger.model_replay_floor = 0;
        parsed.value.ledger.human_replay_floor = 0;
        parsed.value.ledger.model_epoch_high = 0;
        parsed.value.ledger.human_epoch_high = 0;
    }
    if (version == legacy_schema_version) {
        for (parsed.value.ledger.approvals) |*approval| {
            if (approval.status != .pending and approval.resolved_revision == null) {
                approval.resolved_revision = parsed.value.ledger.generation;
            }
        }
    }
    parsed.value.ledger.capacity_version = 0;
    communication.validateLedger(parsed.value.ledger) catch
        return error.InvalidCommunicationRecord;
    if (communication.capacityContractSatisfied(parsed.value.ledger)) {
        parsed.value.ledger.capacity_version =
            communication.capacity_contract_version;
        const migrated_bytes = canonicalWireByteCount(
            alloc,
            schema_version,
            parsed.value.ledger,
        ) catch return error.OutOfMemory;
        if (migrated_bytes > max_canonical_record_bytes) {
            parsed.value.ledger.capacity_version = 0;
        }
    }
    return parsed.value.ledger.clone(alloc) catch return error.OutOfMemory;
}

fn decodeV6(
    alloc: Allocator,
    bytes: []const u8,
) LoadError!communication.Ledger {
    var parsed = std.json.parseFromSlice(WireRecordV6, alloc, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommunicationRecord,
    };
    defer parsed.deinit();
    if (parsed.value.schema_version != schema_version or
        parsed.value.ledger.capacity_version !=
            communication.capacity_contract_version)
    {
        return error.InvalidCommunicationRecord;
    }
    const deliveries = try decodeV5Deliveries(
        alloc,
        parsed.value.ledger.deliveries,
    );
    defer freeBorrowedV5Deliveries(alloc, deliveries);
    const approvals = try decodeApprovalsV6(
        alloc,
        parsed.value.ledger.approvals,
    );
    defer freeBorrowedApprovalsV6(alloc, approvals);
    const authority_grants = try decodeWireGrantsV6(
        alloc,
        parsed.value.ledger.authority_grants,
    );
    defer freeBorrowedWireGrantsV6(alloc, authority_grants);
    const wire = parsed.value.ledger;
    const borrowed = communication.Ledger{
        .session_id = wire.session_id,
        .capacity_version = wire.capacity_version,
        .generation = wire.generation,
        .next_sequence = wire.next_sequence,
        .deliveries = deliveries,
        .cursors = wire.cursors,
        .retention_targets = wire.retention_targets,
        .work_notifications = wire.work_notifications,
        .approvals = approvals,
        .parent_turn_evicted_through = wire.parent_turn_evicted_through,
        .authority_generation = wire.authority_generation,
        .authority_grants = authority_grants,
        .legacy_operation_replay_closed = wire.legacy_operation_replay_closed,
        .model_replay_floor = wire.model_replay_floor,
        .human_replay_floor = wire.human_replay_floor,
        .model_epoch_high = wire.model_epoch_high,
        .human_epoch_high = wire.human_epoch_high,
    };
    communication.validateLedger(borrowed) catch
        return error.InvalidCommunicationRecord;
    const canonical_bytes = canonicalWireByteCount(
        alloc,
        schema_version,
        borrowed,
    ) catch return error.OutOfMemory;
    if (canonical_bytes > max_canonical_record_bytes) {
        return error.InvalidCommunicationRecord;
    }
    return borrowed.clone(alloc) catch return error.OutOfMemory;
}

fn decodeV5(
    alloc: Allocator,
    bytes: []const u8,
) LoadError!communication.Ledger {
    var parsed = std.json.parseFromSlice(WireRecordV5, alloc, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommunicationRecord,
    };
    defer parsed.deinit();
    if (parsed.value.schema_version != base64_delivery_schema_version or
        parsed.value.ledger.capacity_version !=
            communication.capacity_contract_version)
    {
        return error.InvalidCommunicationRecord;
    }
    const deliveries = try decodeV5Deliveries(
        alloc,
        parsed.value.ledger.deliveries,
    );
    defer freeBorrowedV5Deliveries(alloc, deliveries);
    const wire = parsed.value.ledger;
    var borrowed = communication.Ledger{
        .session_id = wire.session_id,
        .capacity_version = 0,
        .generation = wire.generation,
        .next_sequence = wire.next_sequence,
        .deliveries = deliveries,
        .cursors = wire.cursors,
        .retention_targets = wire.retention_targets,
        .work_notifications = wire.work_notifications,
        .approvals = wire.approvals,
        .parent_turn_evicted_through = wire.parent_turn_evicted_through,
        .authority_generation = wire.authority_generation,
        .authority_grants = wire.authority_grants,
        .legacy_operation_replay_closed = wire.legacy_operation_replay_closed,
        .model_replay_floor = wire.model_replay_floor,
        .human_replay_floor = wire.human_replay_floor,
        .model_epoch_high = wire.model_epoch_high,
        .human_epoch_high = wire.human_epoch_high,
    };
    communication.validateLedger(borrowed) catch
        return error.InvalidCommunicationRecord;
    if (communication.capacityContractSatisfied(borrowed)) {
        borrowed.capacity_version = communication.capacity_contract_version;
        const canonical_bytes = canonicalWireByteCount(
            alloc,
            schema_version,
            borrowed,
        ) catch return error.OutOfMemory;
        if (canonical_bytes > max_canonical_record_bytes) {
            borrowed.capacity_version = 0;
        }
    }
    return borrowed.clone(alloc) catch return error.OutOfMemory;
}

fn decodeApprovalsV6(
    alloc: Allocator,
    approvals: []const WireApprovalV6,
) LoadError![]communication.Approval {
    const decoded = try alloc.alloc(communication.Approval, approvals.len);
    var built: usize = 0;
    errdefer {
        for (decoded[0..built]) |approval| {
            if (approval.command) |command| alloc.free(command);
            freeBorrowedWireGrantsV6(alloc, approval.grants);
        }
        alloc.free(decoded);
    }
    for (approvals) |approval| {
        const command = if (approval.command) |command|
            try decodeCanonicalMessage(alloc, command)
        else
            null;
        const grants = decodeWireGrantsV6(alloc, approval.grants) catch |err| {
            if (command) |value| alloc.free(value);
            return err;
        };
        decoded[built] = .{
            .id = approval.id,
            .kind = approval.kind,
            .child_id = approval.child_id,
            .root_id = approval.root_id,
            .work_id = approval.work_id,
            .relationship = approval.relationship,
            .prepared_fingerprint = approval.prepared_fingerprint,
            .identity_fingerprint = approval.identity_fingerprint,
            .label = approval.label,
            .explanation = approval.explanation,
            .command = command,
            .file = approval.file,
            .grants = grants,
            .status = approval.status,
            .created_at_ms = approval.created_at_ms,
            .resolved_at_ms = approval.resolved_at_ms,
            .resolved_revision = approval.resolved_revision,
        };
        built += 1;
    }
    return decoded;
}

fn decodeWireGrantsV6(
    alloc: Allocator,
    grants: []const WirePermissionGrantV6,
) LoadError![]types.PermissionGrant {
    const decoded = try alloc.alloc(types.PermissionGrant, grants.len);
    var built: usize = 0;
    errdefer {
        for (decoded[0..built]) |grant| alloc.free(grant.target_path);
        alloc.free(decoded);
    }
    for (grants) |grant| {
        decoded[built] = .{
            .tool_name = grant.tool_name,
            .target_path = try decodeCanonicalMessage(alloc, grant.target_path),
        };
        built += 1;
    }
    return decoded;
}

fn freeBorrowedApprovalsV6(
    alloc: Allocator,
    approvals: []communication.Approval,
) void {
    for (approvals) |approval| {
        if (approval.command) |command| alloc.free(command);
        freeBorrowedWireGrantsV6(alloc, approval.grants);
    }
    alloc.free(approvals);
}

fn freeBorrowedWireGrantsV6(
    alloc: Allocator,
    grants: []types.PermissionGrant,
) void {
    for (grants) |grant| alloc.free(grant.target_path);
    alloc.free(grants);
}

fn decodeV5Deliveries(
    alloc: Allocator,
    deliveries: []const WireDeliveryV5,
) LoadError![]communication.Delivery {
    const decoded = try alloc.alloc(communication.Delivery, deliveries.len);
    var built: usize = 0;
    errdefer {
        for (decoded[0..built]) |delivery| {
            if (delivery.payload == .message) {
                alloc.free(delivery.payload.message);
            }
        }
        alloc.free(decoded);
    }
    for (deliveries) |delivery| {
        decoded[built] = .{
            .sequence = delivery.sequence,
            .revision = delivery.revision,
            .id = delivery.id,
            .source_id = delivery.source_id,
            .target_id = delivery.target_id,
            .work_id = delivery.work_id,
            .operation_id = delivery.operation_id,
            .timestamp_ms = delivery.timestamp_ms,
            .payload = switch (delivery.payload) {
                .message => |message| .{ .message = try decodeCanonicalMessage(
                    alloc,
                    message,
                ) },
                .milestone => |value| .{ .milestone = value },
                .terminal => |value| .{ .terminal = value },
                .interval => |value| .{ .interval = .{
                    .state = value.state,
                    .coalesced_ticks = value.coalesced_ticks,
                } },
                .approval => |value| .{ .approval = value },
                .tool_activity => |value| .{ .tool_activity = value },
            },
        };
        built += 1;
    }
    return decoded;
}

fn decodeCanonicalMessage(
    alloc: Allocator,
    message: WireMessageV5,
) LoadError![]u8 {
    if (!std.mem.eql(u8, message.encoding, "base64")) {
        return error.InvalidCommunicationRecord;
    }
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(
        message.data,
    ) catch return error.InvalidCommunicationRecord;
    const decoded = try alloc.alloc(u8, decoded_len);
    errdefer alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, message.data) catch
        return error.InvalidCommunicationRecord;
    const canonical = try alloc.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(decoded.len),
    );
    defer alloc.free(canonical);
    const encoded = std.base64.standard.Encoder.encode(canonical, decoded);
    if (!std.mem.eql(u8, encoded, message.data)) {
        return error.InvalidCommunicationRecord;
    }
    return decoded;
}

fn freeBorrowedV5Deliveries(
    alloc: Allocator,
    deliveries: []communication.Delivery,
) void {
    for (deliveries) |delivery| {
        if (delivery.payload == .message) alloc.free(delivery.payload.message);
    }
    alloc.free(deliveries);
}

fn canonicalWireByteCount(
    alloc: Allocator,
    version: u64,
    ledger: communication.Ledger,
) error{OutOfMemory}!usize {
    const bytes = try encodeWireCanonical(alloc, version, ledger);
    defer alloc.free(bytes);
    return bytes.len;
}

test "communication codec rejects malformed oversized and unknown version records" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidCommunicationRecord,
        decode(alloc, "{"),
    );
    try std.testing.expectError(
        error.UnsupportedCommunicationSchema,
        decode(alloc, "{\"schema_version\":99,\"ledger\":{}}"),
    );
    const oversized = try alloc.alloc(u8, max_record_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.CommunicationRecordTooLarge,
        decode(alloc, oversized),
    );
}

test "communication codec round trips owned durable state" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    _ = try communication.appendDelivery(alloc, &ledger, .{
        .id = "11111111111111111111111111111111",
        .source_id = "child",
        .target_id = "parent",
        .timestamp_ms = 1,
        .payload = .{ .message = "hello" },
    });
    try communication.acknowledgeTarget(alloc, &ledger, "human", "parent", 1);
    ledger.cursors[0].stale = true;
    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    var restored = try decode(alloc, bytes);
    defer restored.deinit(alloc);
    try std.testing.expectEqualStrings("child", restored.session_id);
    try std.testing.expectEqual(@as(usize, 1), restored.deliveries.len);
    try std.testing.expectEqual(@as(usize, 1), restored.cursors.len);
    try std.testing.expect(restored.cursors[0].stale);
    try std.testing.expectEqualStrings("hello", restored.deliveries[0].payload.message);
    restored.deliveries[0].payload.message[0] = 'H';
    try std.testing.expectEqualStrings("hello", ledger.deliveries[0].payload.message);
}

test "schema v6 persists near-limit captured command approvals" {
    const command_environment = @import("../execution/command_environment.zig");
    const terminal_contracts = @import("../terminal/contracts.zig");
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const command = try arena.alloc(u8, terminal_contracts.max_command_bytes);
    @memset(command, 0x01);
    command[0] = '#';
    command[command.len - 1] = '\n';
    const environments = [_]command_environment.Environment{
        .legacy,
        .{ .clean = "/bin/zsh" },
        .{ .user = "/bin/zsh" },
    };

    for (environments) |environment| {
        const approval_command = try command_environment.formatApprovalCommand(
            arena,
            environment,
            command,
        );
        const command_identity = try command_environment.permissionCommandIdentity(
            arena,
            environment,
            command,
        );
        const grant_target = try std.fmt.allocPrint(
            arena,
            "/tmp/workspace::{s}",
            .{command_identity},
        );
        const grants = [_]types.PermissionGrant{.{
            .tool_name = @constCast("bash"),
            .target_path = grant_target,
        }};

        var approval_ledger = try communication.Ledger.init(alloc, "child");
        defer approval_ledger.deinit(alloc);
        _ = try communication.registerApproval(alloc, &approval_ledger, .{
            .id = "near-limit-command",
            .kind = .tool,
            .child_id = "child",
            .root_id = "root",
            .work_id = "work",
            .prepared_fingerprint = [_]u8{11} ** 32,
            .label = "captured command",
            .explanation = null,
            .command = approval_command,
            .grants = &grants,
            .created_at_ms = 1,
        });
        const approval_bytes = try encode(alloc, approval_ledger);
        defer alloc.free(approval_bytes);
        try std.testing.expect(approval_bytes.len <= max_canonical_record_bytes);
        try std.testing.expect(
            std.mem.indexOf(u8, approval_bytes, "\"schema_version\":6") != null,
        );
        var restored_approval = try decode(alloc, approval_bytes);
        defer restored_approval.deinit(alloc);
        try std.testing.expectEqualStrings(
            approval_command,
            restored_approval.approvals[0].command.?,
        );
        try std.testing.expectEqualStrings(
            grant_target,
            restored_approval.approvals[0].grants[0].target_path,
        );

        var authority_ledger = try communication.Ledger.init(alloc, "root");
        defer authority_ledger.deinit(alloc);
        try std.testing.expect(try communication.applyAlwaysGrants(
            alloc,
            &authority_ledger,
            &grants,
        ));
        const authority_bytes = try encode(alloc, authority_ledger);
        defer alloc.free(authority_bytes);
        try std.testing.expect(authority_bytes.len <= max_canonical_record_bytes);
        var restored_authority = try decode(alloc, authority_bytes);
        defer restored_authority.deinit(alloc);
        try std.testing.expectEqualStrings(
            grant_target,
            restored_authority.authority_grants[0].target_path,
        );
    }
}

test "schema v6 rejects a malformed later grant without leaking partial state" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    const grants = [_]types.PermissionGrant{
        .{
            .tool_name = @constCast("read_file"),
            .target_path = @constCast("/tmp/first-valid-target"),
        },
        .{
            .tool_name = @constCast("write_file"),
            .target_path = @constCast("/tmp/second-invalid-target"),
        },
    };
    _ = try communication.registerApproval(alloc, &ledger, .{
        .id = "partial-decode",
        .kind = .tool,
        .child_id = "child",
        .root_id = "root",
        .work_id = "work",
        .prepared_fingerprint = [_]u8{12} ** 32,
        .label = "partial decode",
        .explanation = null,
        .command = "printf command",
        .grants = &grants,
        .created_at_ms = 1,
    });
    const encoded = try encode(alloc, ledger);
    defer alloc.free(encoded);
    var second_target: [64]u8 = undefined;
    const target_data = std.base64.standard.Encoder.encode(
        &second_target,
        grants[1].target_path,
    );
    const needle = try std.fmt.allocPrint(
        alloc,
        "\"data\":\"{s}\"",
        .{target_data},
    );
    defer alloc.free(needle);
    const malformed = try std.mem.replaceOwned(
        u8,
        alloc,
        encoded,
        needle,
        "\"data\":\"%%%\"",
    );
    defer alloc.free(malformed);
    try std.testing.expect(malformed.len < encoded.len);
    try std.testing.expectError(
        error.InvalidCommunicationRecord,
        decode(alloc, malformed),
    );
}

test "schema v6 file approval projection round trips as independent owned state" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    const grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("write_file"),
        .target_path = @constCast("/tmp/workspace/**"),
    }};
    _ = try communication.registerApproval(alloc, &ledger, .{
        .id = "file-round-trip",
        .kind = .tool,
        .child_id = "child",
        .root_id = "root",
        .work_id = "work",
        .prepared_fingerprint = [_]u8{4} ** 32,
        .label = "file_mutation",
        .explanation = "review the file change",
        .file = .{
            .kind = .write,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &.{.{ .op = .addition, .new_line = 1, .text = "hello" }},
                .additions = 1,
                .deletions = 0,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
        .grants = &grants,
        .created_at_ms = 1,
    });

    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    var restored = try decode(alloc, bytes);
    defer restored.deinit(alloc);

    const original = ledger.approvals[0].file.?;
    const decoded = restored.approvals[0].file.?;
    try std.testing.expectEqualStrings("note.txt", decoded.preview.path);
    try std.testing.expectEqualStrings("hello", decoded.preview.lines[0].text);
    try std.testing.expect(decoded.scope == .workspace_files);
    try std.testing.expect(original.preview.path.ptr != decoded.preview.path.ptr);
    try std.testing.expect(original.preview.lines.ptr != decoded.preview.lines.ptr);
    try std.testing.expectEqualStrings(
        grants[0].target_path,
        restored.approvals[0].grants[0].target_path,
    );
}

test "schema v5 approvals without file projection remain compatible" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    const grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("bash"),
        .target_path = @constCast("/tmp/legacy-target"),
    }};
    _ = try communication.registerApproval(alloc, &ledger, .{
        .id = "legacy-generic-approval",
        .kind = .tool,
        .child_id = "child",
        .root_id = "root",
        .work_id = "work",
        .prepared_fingerprint = [_]u8{5} ** 32,
        .label = "terminal.exec printf ok",
        .explanation = null,
        .command = "printf legacy",
        .grants = &grants,
        .created_at_ms = 1,
    });
    ledger.capacity_version = communication.capacity_contract_version;
    const current = try encodeWireCanonical(
        alloc,
        base64_delivery_schema_version,
        ledger,
    );
    defer alloc.free(current);
    try std.testing.expect(std.mem.find(u8, current, "\"file\":null,") != null);
    const legacy = try std.mem.replaceOwned(
        u8,
        alloc,
        current,
        "\"file\":null,",
        "",
    );
    defer alloc.free(legacy);

    var restored = try decode(alloc, legacy);
    defer restored.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), restored.approvals.len);
    try std.testing.expect(restored.approvals[0].file == null);
    try std.testing.expectEqualStrings(
        "legacy-generic-approval",
        restored.approvals[0].id,
    );
    try std.testing.expectEqualStrings(
        "printf legacy",
        restored.approvals[0].command.?,
    );
    try std.testing.expectEqualStrings(
        "/tmp/legacy-target",
        restored.approvals[0].grants[0].target_path,
    );
}

test "schema v6 bounds a worst-escaped full message within the record equation" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    const content = try alloc.alloc(u8, domain.max_message_bytes);
    defer alloc.free(content);
    @memset(content, 0x1f);
    var operation_id: [domain.max_operation_id_bytes]u8 = undefined;
    for (&operation_id, 0..) |*byte, index| {
        byte.* = if (index % 2 == 0) '"' else '\\';
    }
    var source_id: [255]u8 = undefined;
    @memset(&source_id, 's');
    var target_id: [255]u8 = undefined;
    @memset(&target_id, 't');
    _ = try communication.appendDelivery(alloc, &ledger, .{
        .id = &operation_id,
        .source_id = &source_id,
        .target_id = &target_id,
        .work_id = &operation_id,
        .operation_id = &operation_id,
        .timestamp_ms = std.math.minInt(i64),
        .payload = .{ .message = content },
    });
    const delivery_bytes = communication.canonicalDeliveryWireBytes(
        ledger.deliveries[0],
    ).?;
    try std.testing.expectEqual(@as(usize, 88_848), delivery_bytes);
    try std.testing.expect(
        delivery_bytes <= communication.max_retained_delivery_canonical_bytes,
    );
    try std.testing.expectEqual(
        max_canonical_record_bytes,
        communication.max_irreducible_canonical_bytes +
            metadata_budget_bytes +
            retained_delivery_budget_bytes +
            subsequent_mutation_budget_bytes,
    );
    try std.testing.expectEqual(
        max_record_bytes,
        max_canonical_record_bytes + mutation_reserve_bytes,
    );

    const bytes = try encodeCanonical(alloc, ledger);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len <= max_canonical_record_bytes);
    try std.testing.expect(
        std.mem.indexOf(u8, bytes, "\"encoding\":\"base64\"") != null,
    );
    var restored = try decode(alloc, bytes);
    defer restored.deinit(alloc);
    try std.testing.expectEqualSlices(
        u8,
        content,
        restored.deliveries[0].payload.message,
    );
}

test "canonical byte retention keeps valid delivery traffic encodable" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    const content = try alloc.alloc(u8, 12 * 1024);
    defer alloc.free(content);
    @memset(content, 'x');

    for (0..50) |index| {
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "byte-fill-{d}", .{index});
        _ = try communication.appendDelivery(alloc, &ledger, .{
            .id = id,
            .source_id = "child",
            .target_id = "parent",
            .timestamp_ms = @intCast(index),
            .payload = .{ .message = content },
        });
    }

    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len <= max_record_bytes);
    var restored = try decode(alloc, bytes);
    defer restored.deinit(alloc);
    try std.testing.expect(restored.deliveries.len < 50);
    try std.testing.expect(restored.deliveries.len != 0);
}

const CapacityTestGrants = struct {
    grants: []types.PermissionGrant,
    tool_bytes: []u8,
    target_bytes: []u8,

    fn init(
        alloc: Allocator,
        count: usize,
        item_bytes: usize,
    ) !CapacityTestGrants {
        const grants = try alloc.alloc(types.PermissionGrant, count);
        errdefer alloc.free(grants);
        const tool_bytes = try alloc.alloc(u8, count * item_bytes);
        errdefer alloc.free(tool_bytes);
        const target_bytes = try alloc.alloc(u8, count * item_bytes);
        errdefer alloc.free(target_bytes);
        for (grants, 0..) |*grant, index| {
            const tool = tool_bytes[index * item_bytes ..][0..item_bytes];
            const target = target_bytes[index * item_bytes ..][0..item_bytes];
            @memset(tool, 't');
            @memset(target, 'p');
            tool[0] = @intCast('A' + index % 26);
            tool[1] = @intCast('A' + index / 26);
            target[0] = @intCast('a' + index % 26);
            target[1] = @intCast('a' + index / 26);
            grant.* = .{
                .tool_name = tool,
                .target_path = target,
            };
        }
        return .{
            .grants = grants,
            .tool_bytes = tool_bytes,
            .target_bytes = target_bytes,
        };
    }

    fn deinit(self: *CapacityTestGrants, alloc: Allocator) void {
        alloc.free(self.grants);
        alloc.free(self.tool_bytes);
        alloc.free(self.target_bytes);
        self.* = undefined;
    }
};

fn capacityTestNotificationPolicy(alloc: Allocator) !domain.NotificationPolicy {
    var names: [domain.max_milestones][]const u8 = undefined;
    var storage: [domain.max_milestones][domain.max_name_bytes]u8 = undefined;
    for (&storage, 0..) |*name, index| {
        @memset(name, '"');
        name[0] = @intCast('A' + index);
        names[index] = name;
    }
    return domain.validateNotificationPolicy(alloc, .{
        .milestones = &names,
        .report_interval_ms = 1,
    });
}

fn smallCapacityTestNotificationPolicy(
    alloc: Allocator,
) !domain.NotificationPolicy {
    return domain.validateNotificationPolicy(alloc, .{
        .report_interval_ms = 1,
    });
}

fn registerCapacityTestApproval(
    alloc: Allocator,
    ledger: *communication.Ledger,
    id: []const u8,
    grants: []const types.PermissionGrant,
) !void {
    var label: [domain.max_admission_item_bytes]u8 = undefined;
    @memset(&label, 'l');
    var explanation: [256]u8 = undefined;
    @memset(&explanation, 'e');
    _ = try communication.registerApproval(alloc, ledger, .{
        .id = id,
        .kind = .tool,
        .child_id = "child",
        .root_id = "root",
        .work_id = "work",
        .prepared_fingerprint = [_]u8{7} ** 32,
        .label = &label,
        .explanation = &explanation,
        .grants = grants,
        .created_at_ms = 1,
    });
}

test "valid active notification policies cannot exceed the communication record" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    var policy = try capacityTestNotificationPolicy(alloc);
    defer policy.deinit(alloc);

    var rejected = false;
    for (0..140) |index| {
        var work_id_buffer: [64]u8 = undefined;
        const work_id = try std.fmt.bufPrint(
            &work_id_buffer,
            "capacity-policy-{d}",
            .{index},
        );
        const before = try encodeCanonical(alloc, ledger);
        defer alloc.free(before);
        communication.upsertWorkNotification(
            alloc,
            &ledger,
            work_id,
            policy,
            @intCast(index),
        ) catch |err| switch (err) {
            error.CapacityExceeded => {
                const after = try encodeCanonical(alloc, ledger);
                defer alloc.free(after);
                try std.testing.expectEqualStrings(before, after);
                rejected = true;
                break;
            },
            else => return err,
        };
    }

    try std.testing.expect(rejected);
    try communication.validateLedger(ledger);
    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len <= max_canonical_record_bytes);
}

test "irreducible collection count budgets reject only the next admission" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    var policy = try smallCapacityTestNotificationPolicy(alloc);
    defer policy.deinit(alloc);

    for (0..communication.max_active_work_notifications) |index| {
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "count-work-{d}", .{index});
        try communication.upsertWorkNotification(
            alloc,
            &ledger,
            id,
            policy,
            @intCast(index),
        );
    }
    try std.testing.expectError(
        error.CapacityExceeded,
        communication.upsertWorkNotification(
            alloc,
            &ledger,
            "count-work-overflow",
            policy,
            9,
        ),
    );

    for (0..communication.max_live_approvals) |index| {
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(
            &id_buffer,
            "count-approval-{d}",
            .{index},
        );
        _ = try communication.registerApproval(alloc, &ledger, .{
            .id = id,
            .kind = .tool,
            .child_id = "child",
            .root_id = "root",
            .work_id = "work",
            .prepared_fingerprint = [_]u8{5} ** 32,
            .label = "approve",
            .explanation = null,
            .grants = &.{},
            .created_at_ms = @intCast(index),
        });
    }
    const approval_generation = ledger.generation;
    try std.testing.expectError(
        error.CapacityExceeded,
        communication.registerApproval(alloc, &ledger, .{
            .id = "count-approval-overflow",
            .kind = .tool,
            .child_id = "child",
            .root_id = "root",
            .work_id = "work",
            .prepared_fingerprint = [_]u8{6} ** 32,
            .label = "approve",
            .explanation = null,
            .grants = &.{},
            .created_at_ms = 65,
        }),
    );
    try std.testing.expectEqual(approval_generation, ledger.generation);

    var grants = try CapacityTestGrants.init(
        alloc,
        communication.max_authority_grants,
        8,
    );
    defer grants.deinit(alloc);
    try std.testing.expect(
        try communication.applyAlwaysGrants(alloc, &ledger, grants.grants),
    );
    const authority_generation = ledger.authority_generation;
    try std.testing.expectError(
        error.CapacityExceeded,
        communication.applyAlwaysGrants(alloc, &ledger, &.{.{
            .tool_name = @constCast("overflow-tool"),
            .target_path = @constCast("overflow-target"),
        }}),
    );
    try std.testing.expectEqual(authority_generation, ledger.authority_generation);

    const usage = communication.canonicalBudgetUsage(ledger).?;
    try std.testing.expectEqual(
        communication.max_active_work_notifications,
        usage.active_work_count,
    );
    try std.testing.expectEqual(
        communication.max_live_approvals,
        usage.live_approval_count,
    );
    try std.testing.expectEqual(
        communication.max_authority_grants,
        usage.authority_grant_count,
    );
    try communication.validateLedger(ledger);
    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len <= max_canonical_record_bytes);
}

test "valid pending approval payloads cannot exceed the communication record" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    var grants = try CapacityTestGrants.init(
        alloc,
        24,
        domain.max_admission_item_bytes,
    );
    defer grants.deinit(alloc);

    const before = try encodeCanonical(alloc, ledger);
    defer alloc.free(before);
    try std.testing.expectError(
        error.CapacityExceeded,
        registerCapacityTestApproval(
            alloc,
            &ledger,
            "capacity-approval",
            grants.grants,
        ),
    );
    const after = try encodeCanonical(alloc, ledger);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(usize, 0), ledger.approvals.len);
}

test "valid effective authority grants cannot exceed the communication record" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "root");
    defer ledger.deinit(alloc);
    var grants = try CapacityTestGrants.init(
        alloc,
        80,
        domain.max_admission_item_bytes,
    );
    defer grants.deinit(alloc);

    const before = try encodeCanonical(alloc, ledger);
    defer alloc.free(before);
    try std.testing.expectError(
        error.CapacityExceeded,
        communication.applyAlwaysGrants(
            alloc,
            &ledger,
            grants.grants,
        ),
    );
    const after = try encodeCanonical(alloc, ledger);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(usize, 0), ledger.authority_grants.len);
}

test "oversized canonical delivery admission has zero partial effects" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    const payload = try alloc.alloc(u8, 40 * 1024);
    defer alloc.free(payload);
    @memset(payload, 0x1f);
    const before = try encodeCanonical(alloc, ledger);
    defer alloc.free(before);

    try std.testing.expectError(
        error.CapacityExceeded,
        communication.appendDelivery(alloc, &ledger, .{
            .id = "canonical-delivery-overflow",
            .source_id = "child",
            .target_id = "root",
            .timestamp_ms = 1,
            .payload = .{ .approval = payload },
        }),
    );
    const after = try encodeCanonical(alloc, ledger);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(usize, 0), ledger.deliveries.len);
    try std.testing.expectEqual(@as(u64, 0), ledger.generation);
    try std.testing.expectEqual(@as(u64, 1), ledger.next_sequence);
}

test "valid mixed irreducible state cannot exceed the communication record" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    var policy = try capacityTestNotificationPolicy(alloc);
    defer policy.deinit(alloc);
    for (0..5) |index| {
        var work_id_buffer: [64]u8 = undefined;
        const work_id = try std.fmt.bufPrint(
            &work_id_buffer,
            "mixed-policy-{d}",
            .{index},
        );
        try communication.upsertWorkNotification(
            alloc,
            &ledger,
            work_id,
            policy,
            @intCast(index),
        );
    }
    var approval_grants = try CapacityTestGrants.init(
        alloc,
        12,
        domain.max_admission_item_bytes,
    );
    defer approval_grants.deinit(alloc);
    try registerCapacityTestApproval(
        alloc,
        &ledger,
        "mixed-approval",
        approval_grants.grants,
    );
    for (0..communication.max_consumers) |index| {
        var consumer_buffer: [64]u8 = undefined;
        const consumer = try std.fmt.bufPrint(
            &consumer_buffer,
            "mixed-consumer-{d}",
            .{index},
        );
        try communication.acknowledgeTarget(
            alloc,
            &ledger,
            consumer,
            "root",
            0,
        );
    }
    var authority_grants = try CapacityTestGrants.init(
        alloc,
        32,
        domain.max_admission_item_bytes,
    );
    defer authority_grants.deinit(alloc);
    var rejected = false;
    for (authority_grants.grants) |grant| {
        const before = try encodeCanonical(alloc, ledger);
        defer alloc.free(before);
        const changed = communication.applyAlwaysGrants(
            alloc,
            &ledger,
            &.{grant},
        ) catch |err| switch (err) {
            error.CapacityExceeded => {
                const usage = communication.canonicalBudgetUsage(ledger).?;
                try std.testing.expect(
                    usage.authority_grant_bytes <
                        communication.max_authority_grant_bytes,
                );
                const after = try encodeCanonical(alloc, ledger);
                defer alloc.free(after);
                try std.testing.expectEqualStrings(before, after);
                rejected = true;
                break;
            },
            else => return err,
        };
        try std.testing.expect(changed);
    }
    try std.testing.expect(rejected);
    const grant_count = ledger.authority_grants.len;
    try std.testing.expect(grant_count != 0);
    const first_grant = ledger.authority_grants[0];
    const tools = [_][]const u8{first_grant.tool_name};
    try std.testing.expectEqual(
        communication.ToolAuthorityDecision.allow,
        try communication.decideToolAuthority(
            alloc,
            .{
                .generation = ledger.authority_generation,
                .root_id = "root",
                .tools = &tools,
                .integrations = &.{},
                .rules = .{ .rules = &.{} },
                .grants = ledger.authority_grants,
            },
            "/tmp",
            first_grant.tool_name,
            first_grant.target_path,
            .none,
        ),
    );
    try std.testing.expectEqual(
        communication.PollDecision{ .emit = 1 },
        try communication.pollNotification(
            &ledger.work_notifications[0],
            .running,
            1,
        ),
    );
    try std.testing.expect(communication.applyTerminalStop(
        &ledger.work_notifications[0],
        .completed,
    ));
    try communication.compactStoppedWorkNotifications(alloc, &ledger);
    const approval = communication.findApproval(
        ledger.approvals,
        "mixed-approval",
    ).?;
    const approval_revision = ledger.generation + 1;
    try communication.applyApprovalDecision(
        approval,
        .deny,
        2,
        approval_revision,
    );
    ledger.generation = approval_revision;
    _ = try communication.appendDelivery(alloc, &ledger, .{
        .id = "mixed-ledger-remains-writable",
        .source_id = "child",
        .target_id = "root",
        .timestamp_ms = 2,
        .payload = .{ .message = "still writable" },
    });
    _ = try communication.registerApproval(alloc, &ledger, .{
        .id = "mixed-next-approval",
        .kind = .tool,
        .child_id = "child",
        .root_id = "root",
        .work_id = "work",
        .prepared_fingerprint = [_]u8{8} ** 32,
        .label = "next approval",
        .explanation = null,
        .grants = &.{},
        .created_at_ms = 3,
    });
    try std.testing.expect(try communication.compactResolvedApprovals(
        alloc,
        &ledger,
    ));
    try std.testing.expect(
        communication.findApproval(ledger.approvals, "mixed-approval") == null,
    );
    try std.testing.expectEqual(grant_count, ledger.authority_grants.len);
    for (ledger.authority_grants, authority_grants.grants[0..grant_count]) |
        retained,
        original,
    | {
        try std.testing.expectEqualStrings(original.tool_name, retained.tool_name);
        try std.testing.expectEqualStrings(original.target_path, retained.target_path);
    }
    var page = try communication.pageForTarget(
        alloc,
        ledger,
        "mixed-consumer-0",
        "root",
        null,
        1,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.deliveries.len);
    try communication.acknowledgeTarget(
        alloc,
        &ledger,
        "mixed-consumer-0",
        "root",
        page.through_sequence,
    );
    try communication.validateLedger(ledger);
    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len <= max_canonical_record_bytes);
    var restored = try decode(alloc, bytes);
    defer restored.deinit(alloc);
    try std.testing.expectEqual(grant_count, restored.authority_grants.len);
    for (restored.authority_grants, ledger.authority_grants) |actual, expected| {
        try std.testing.expectEqualStrings(expected.tool_name, actual.tool_name);
        try std.testing.expectEqualStrings(expected.target_path, actual.target_path);
    }
}

test "terminal and resolved cycles remain writable beyond retained bounds" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    var policy = try smallCapacityTestNotificationPolicy(alloc);
    defer policy.deinit(alloc);

    for (0..512) |index| {
        var work_buffer: [64]u8 = undefined;
        const work_id = try std.fmt.bufPrint(
            &work_buffer,
            "cycle-work-{d}",
            .{index},
        );
        try communication.upsertWorkNotification(
            alloc,
            &ledger,
            work_id,
            policy,
            @intCast(index),
        );
        try std.testing.expect(communication.stopWorkNotification(
            &ledger.work_notifications[0],
        ));
        try communication.compactStoppedWorkNotifications(alloc, &ledger);

        var approval_buffer: [64]u8 = undefined;
        const approval_id = try std.fmt.bufPrint(
            &approval_buffer,
            "cycle-approval-{d}",
            .{index},
        );
        _ = try communication.registerApproval(alloc, &ledger, .{
            .id = approval_id,
            .kind = .tool,
            .child_id = "child",
            .root_id = "root",
            .work_id = "work",
            .prepared_fingerprint = [_]u8{9} ** 32,
            .label = "approve",
            .explanation = null,
            .grants = &.{},
            .created_at_ms = @intCast(index),
        });
        const revision = ledger.generation + 1;
        try communication.applyApprovalDecision(
            &ledger.approvals[ledger.approvals.len - 1],
            .deny,
            @intCast(index),
            revision,
        );
        ledger.generation = revision;
        var delivery_buffer: [64]u8 = undefined;
        const delivery_id = try std.fmt.bufPrint(
            &delivery_buffer,
            "cycle-delivery-{d}",
            .{index},
        );
        _ = try communication.appendDelivery(alloc, &ledger, .{
            .id = delivery_id,
            .source_id = "child",
            .target_id = "root",
            .timestamp_ms = @intCast(index),
            .payload = .{ .message = "cycle remains writable" },
        });
        _ = try communication.compactResolvedApprovals(alloc, &ledger);

        if (index % 64 == 0) {
            try communication.validateLedger(ledger);
            const checkpoint = try encode(alloc, ledger);
            defer alloc.free(checkpoint);
            try std.testing.expect(checkpoint.len <= max_canonical_record_bytes);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), ledger.work_notifications.len);
    try std.testing.expectEqual(@as(usize, 0), ledger.approvals.len);
    try communication.validateLedger(ledger);
}

test "schema v1 non-empty cursor without retention fields remains compatible" {
    const alloc = std.testing.allocator;
    const encoded =
        \\{"schema_version":1,"ledger":{"session_id":"child","generation":2,"next_sequence":2,"deliveries":[{"sequence":1,"revision":1,"id":"delivery","source_id":"child","target_id":"parent","work_id":null,"operation_id":null,"timestamp_ms":1,"payload":{"message":"hello"}}],"cursors":[{"consumer_id":"human","target_id":"parent","projection":"human","acknowledged_sequence":1}],"work_notifications":[],"approvals":[],"parent_turn_evicted_through":0,"authority_generation":0,"authority_grants":[]}}
    ;
    var restored = try decode(alloc, encoded);
    defer restored.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), restored.cursors.len);
    try std.testing.expectEqual(@as(u64, 1), restored.cursors[0].acknowledged_sequence);
    try std.testing.expect(!restored.cursors[0].stale);
    try std.testing.expect(restored.retention_targets == null);
    try std.testing.expect(restored.legacy_operation_replay_closed);
}

test "schema v4 messages migrate to schema v6 canonical encoding" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    ledger.capacity_version = 1;
    _ = try communication.appendDelivery(alloc, &ledger, .{
        .id = "schema-v4-message",
        .source_id = "child",
        .target_id = "parent",
        .timestamp_ms = 1,
        .payload = .{ .message = "quotes \" slashes \\ and unicode 🦎" },
    });
    const legacy = try encodeWireCanonical(
        alloc,
        previous_capacity_schema_version,
        ledger,
    );
    defer alloc.free(legacy);
    var migrated = try decode(alloc, legacy);
    defer migrated.deinit(alloc);
    try std.testing.expectEqual(
        communication.capacity_contract_version,
        migrated.capacity_version,
    );
    try std.testing.expectEqualStrings(
        "quotes \" slashes \\ and unicode 🦎",
        migrated.deliveries[0].payload.message,
    );
    const current = try encode(alloc, migrated);
    defer alloc.free(current);
    try std.testing.expect(
        std.mem.indexOf(u8, current, "\"schema_version\":6") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, current, "\"encoding\":\"base64\"") != null,
    );
}

test "schema v2 process epochs cannot seed manager delivery authority" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    ledger.legacy_operation_replay_closed = true;
    ledger.model_replay_floor = 900;
    ledger.human_replay_floor = 700;
    ledger.model_epoch_high = 999;
    ledger.human_epoch_high = 777;
    const current = try encodeCanonical(alloc, ledger);
    defer alloc.free(current);
    const legacy = try std.mem.replaceOwned(
        u8,
        alloc,
        current,
        "\"schema_version\":6",
        "\"schema_version\":2",
    );
    defer alloc.free(legacy);
    var migrated = try decode(alloc, legacy);
    defer migrated.deinit(alloc);
    try std.testing.expect(migrated.legacy_operation_replay_closed);
    try std.testing.expectEqual(@as(u64, 0), migrated.model_replay_floor);
    try std.testing.expectEqual(@as(u64, 0), migrated.human_replay_floor);
    try std.testing.expectEqual(@as(u64, 0), migrated.model_epoch_high);
    try std.testing.expectEqual(@as(u64, 0), migrated.human_epoch_high);
}

test "schema v1 resolved approvals receive a deterministic migration revision" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    _ = try communication.registerApproval(alloc, &ledger, .{
        .id = "approval",
        .kind = .tool,
        .child_id = "child",
        .root_id = "root",
        .work_id = "work",
        .prepared_fingerprint = [_]u8{3} ** 32,
        .label = "tool action",
        .explanation = null,
        .grants = &.{},
        .created_at_ms = 1,
    });
    const revision = ledger.generation + 1;
    try communication.applyApprovalDecision(
        &ledger.approvals[0],
        .deny,
        2,
        revision,
    );
    ledger.generation = revision;
    const current = try encodeCanonical(alloc, ledger);
    defer alloc.free(current);
    const versioned = try std.mem.replaceOwned(
        u8,
        alloc,
        current,
        "\"schema_version\":6",
        "\"schema_version\":1",
    );
    defer alloc.free(versioned);
    const without_revision = try std.mem.replaceOwned(
        u8,
        alloc,
        versioned,
        ",\"resolved_revision\":2",
        "",
    );
    defer alloc.free(without_revision);
    const legacy = try std.mem.replaceOwned(
        u8,
        alloc,
        without_revision,
        ",\"legacy_operation_replay_closed\":false,\"model_replay_floor\":0,\"human_replay_floor\":0,\"model_epoch_high\":0,\"human_epoch_high\":0",
        "",
    );
    defer alloc.free(legacy);
    try std.testing.expect(legacy.len < current.len);

    var restored = try decode(alloc, legacy);
    defer restored.deinit(alloc);
    try std.testing.expect(restored.legacy_operation_replay_closed);
    try std.testing.expectEqual(
        @as(?u64, revision),
        restored.approvals[0].resolved_revision,
    );
}

test "legacy over-budget records load and migrate only after safe reduction" {
    const alloc = std.testing.allocator;
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    var policy = try smallCapacityTestNotificationPolicy(alloc);
    defer policy.deinit(alloc);
    for (0..communication.max_active_work_notifications) |index| {
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "legacy-work-{d}", .{index});
        try communication.upsertWorkNotification(
            alloc,
            &ledger,
            id,
            policy,
            @intCast(index),
        );
    }
    ledger.capacity_version = 0;
    ledger.work_notifications = try alloc.realloc(
        ledger.work_notifications,
        ledger.work_notifications.len + 1,
    );
    ledger.work_notifications[ledger.work_notifications.len - 1] = .{
        .work_id = try alloc.dupe(u8, "legacy-work-over-budget"),
        .policy = try policy.clone(alloc),
        .started_at_ms = 9,
        .next_due_ms = 10,
    };
    try communication.validateLedger(ledger);

    const legacy = try encodeWireCanonical(
        alloc,
        pre_capacity_schema_version,
        ledger,
    );
    defer alloc.free(legacy);
    var restored = try decode(alloc, legacy);
    defer restored.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 0), restored.capacity_version);
    try std.testing.expectEqual(
        communication.max_active_work_notifications + 1,
        restored.work_notifications.len,
    );

    ledger.capacity_version = communication.capacity_contract_version;
    const invalid_current = try encodeWireCanonical(
        alloc,
        schema_version,
        ledger,
    );
    defer alloc.free(invalid_current);
    try std.testing.expectError(
        error.InvalidCommunicationRecord,
        decode(alloc, invalid_current),
    );

    try std.testing.expect(communication.stopWorkNotification(
        &restored.work_notifications[restored.work_notifications.len - 1],
    ));
    const migrated = try encode(alloc, restored);
    defer alloc.free(migrated);
    try std.testing.expect(
        std.mem.indexOf(u8, migrated, "\"schema_version\":6") != null,
    );
    var current = try decode(alloc, migrated);
    defer current.deinit(alloc);
    try std.testing.expectEqual(
        communication.capacity_contract_version,
        current.capacity_version,
    );
    try std.testing.expectEqual(
        communication.max_active_work_notifications,
        current.work_notifications.len,
    );
}

test "approval persistence keeps prepared action identity without command content" {
    const alloc = std.testing.allocator;
    const secret_command = "deploy --token=not-for-projection";
    const prepared = communication.preparedRequestFingerprint(.{
        .id = 17,
        .label = "deploy",
        .command = secret_command,
    });
    const same_action = communication.preparedRequestFingerprint(.{
        .id = 99,
        .label = "deploy",
        .command = secret_command,
    });
    const changed_action = communication.preparedRequestFingerprint(.{
        .id = 17,
        .label = "deploy",
        .command = "deploy --environment=staging",
    });
    try std.testing.expectEqualSlices(u8, &prepared, &same_action);
    try std.testing.expect(!std.mem.eql(u8, &prepared, &changed_action));

    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    try std.testing.expectEqual(
        communication.RegisterApprovalResult.registered,
        try communication.registerApproval(alloc, &ledger, .{
            .id = "approval-prepared",
            .kind = .tool,
            .child_id = "child",
            .root_id = "root",
            .work_id = "work",
            .prepared_fingerprint = prepared,
            .label = "deploy",
            .explanation = "prepared action requires approval",
            .grants = &.{},
            .created_at_ms = 1,
        }),
    );
    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, secret_command) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "prepared action requires approval") != null);
}

test "redacted tool activity survives restart with ordered bounded query" {
    const alloc = std.testing.allocator;
    const secret_arguments = "{\"token\":\"must-not-persist\"}";
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    _ = try communication.appendDelivery(alloc, &ledger, .{
        .id = "activity-started",
        .source_id = "child",
        .target_id = "parent",
        .work_id = "work",
        .timestamp_ms = 1,
        .payload = .{ .tool_activity = .{
            .tool_name = "read_file",
            .phase = .started,
        } },
    });
    _ = try communication.appendDelivery(alloc, &ledger, .{
        .id = "activity-succeeded",
        .source_id = "child",
        .target_id = "parent",
        .work_id = "work",
        .timestamp_ms = 2,
        .payload = .{ .tool_activity = .{
            .tool_name = "read_file",
            .phase = .succeeded,
        } },
    });
    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, secret_arguments) == null);

    var restarted = try decode(alloc, bytes);
    defer restarted.deinit(alloc);
    var first = try communication.pageForTarget(
        alloc,
        restarted,
        "manager-ui",
        "parent",
        null,
        1,
    );
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), first.deliveries.len);
    try std.testing.expectEqual(communication.ToolActivityPhase.started, first.deliveries[0].payload.tool_activity.phase);
    try std.testing.expect(first.has_more);
    try communication.acknowledgeTarget(
        alloc,
        &restarted,
        "manager-ui",
        "parent",
        first.through_sequence,
    );
    try std.testing.expectError(
        error.StaleCursor,
        communication.pageForTarget(
            alloc,
            restarted,
            "manager-ui",
            "parent",
            first.generation,
            1,
        ),
    );
    var second = try communication.pageForTarget(
        alloc,
        restarted,
        "manager-ui",
        "parent",
        null,
        1,
    );
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), second.deliveries.len);
    try std.testing.expectEqual(communication.ToolActivityPhase.succeeded, second.deliveries[0].payload.tool_activity.phase);
}

fn checkCommunicationCodecAllocationFailures(alloc: Allocator) !void {
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    _ = try communication.appendDelivery(alloc, &ledger, .{
        .id = "delivery",
        .source_id = "child",
        .target_id = "parent",
        .timestamp_ms = 1,
        .payload = .{ .message = "hello" },
    });
    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    var restored = try decode(alloc, bytes);
    defer restored.deinit(alloc);
}

test "communication codec cleans every failing allocation path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCommunicationCodecAllocationFailures,
        .{},
    );
}

fn checkCommunicationCompactionAllocationFailures(alloc: Allocator) !void {
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    inline for (.{ "first", "second", "third" }, 0..) |id, index| {
        _ = try communication.appendDelivery(alloc, &ledger, .{
            .id = id,
            .source_id = "child",
            .target_id = "parent",
            .timestamp_ms = index,
            .payload = .{ .message = "hello" },
        });
    }
    const raw = try encodeCanonical(alloc, ledger);
    defer alloc.free(raw);
    const bytes = try encodeLimit(alloc, ledger, raw.len - 1);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len < raw.len);
}

test "communication compaction cleans every failing allocation path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCommunicationCompactionAllocationFailures,
        .{},
    );
}

fn checkCapacityMutationAllocationFailures(alloc: Allocator) !void {
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    var policy = try smallCapacityTestNotificationPolicy(alloc);
    defer policy.deinit(alloc);
    try communication.upsertWorkNotification(
        alloc,
        &ledger,
        "allocation-work",
        policy,
        1,
    );
    const grants = [_]types.PermissionGrant{
        .{
            .tool_name = @constCast("tool-a"),
            .target_path = @constCast("target-a"),
        },
        .{
            .tool_name = @constCast("tool-b"),
            .target_path = @constCast("target-b"),
        },
        .{
            .tool_name = @constCast("tool-c"),
            .target_path = @constCast("target-c"),
        },
    };
    _ = try communication.registerApproval(alloc, &ledger, .{
        .id = "allocation-approval",
        .kind = .tool,
        .child_id = "child",
        .root_id = "root",
        .work_id = "work",
        .prepared_fingerprint = [_]u8{4} ** 32,
        .label = "approve",
        .explanation = "allocation sweep",
        .grants = &grants,
        .created_at_ms = 1,
    });
    try std.testing.expect(
        try communication.applyAlwaysGrants(alloc, &ledger, &grants),
    );
    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
}

test "capacity mutations clean every failing allocation path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCapacityMutationAllocationFailures,
        .{},
    );
}

test "communication decoder handles fuzzed bytes" {
    try std.testing.fuzz({}, fuzzCommunicationRecord, .{ .corpus = &.{
        "{\"schema_version\":1,\"ledger\":{\"session_id\":\"child\",\"generation\":0,\"next_sequence\":1,\"deliveries\":[],\"cursors\":[],\"work_notifications\":[],\"approvals\":[],\"parent_turn_evicted_through\":0,\"authority_generation\":0,\"authority_grants\":[]}}",
        "",
        "{}",
        "{\"schema_version\":1}",
        "{\"schema_version\":2}",
        "{\"schema_version\":3}",
        "{\"schema_version\":4}",
        "{\"schema_version\":5,\"ledger\":{\"session_id\":\"child\",\"capacity_version\":2,\"generation\":0,\"next_sequence\":1,\"deliveries\":[],\"cursors\":[],\"work_notifications\":[],\"approvals\":[],\"authority_grants\":[]}}",
        "{\"schema_version\":5,\"ledger\":{\"session_id\":\"child\",\"capacity_version\":2,\"generation\":1,\"next_sequence\":2,\"deliveries\":[{\"sequence\":1,\"revision\":1,\"id\":\"message\",\"source_id\":\"child\",\"target_id\":\"parent\",\"timestamp_ms\":1,\"payload\":{\"message\":{\"encoding\":\"base64\",\"data\":\"%%%\"}}}],\"cursors\":[],\"work_notifications\":[],\"approvals\":[],\"authority_grants\":[]}}",
        "{\"schema_version\":99,\"ledger\":{}}",
        "{\"schema_version\":1,\"ledger\":{\"session_id\":\"../unsafe\",\"generation\":0,\"next_sequence\":1,\"deliveries\":[],\"cursors\":[],\"work_notifications\":[],\"approvals\":[],\"authority_generation\":0,\"authority_grants\":[]}}",
        "null",
    } });
}

fn fuzzCommunicationRecord(_: void, smith: *std.testing.Smith) !void {
    var buffer: [8192]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var ledger = decode(std.testing.allocator, buffer[0..len]) catch return;
    ledger.deinit(std.testing.allocator);
}

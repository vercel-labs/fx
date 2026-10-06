const std = @import("std");

pub const Effect = enum {
    snapshot_read,
    mutable_read,
    mutation,
    external,
    opaque_exec,
};

pub const Mode = enum { disabled, enabled };

pub const SnapshotIdentity = struct {
    id: []const u8,
    version: []const u8,
};

pub const Authority = struct {
    partition: []const u8,
    epoch: u64,
    generation: u64,
};

pub const Window = struct {
    offset: usize,
    length: usize,
};

pub const Arguments = struct {
    path: []const u8,
    window: Window,
    // Exact option bytes supplied by the caller. The planner does not normalize them.
    options: []const u8,
};

pub const ResultContract = struct {
    schema_id: []const u8,
    version: u32,
    encoding: enum { bytes, utf8, json },
};

// All strings are borrowed and must remain alive and unchanged through execution
// and receipt consumption. Use literals or frozen owned buffers for host bindings.
pub const CallBinding = struct {
    id: u64,
    agent_id: []const u8,
    principal_domain: []const u8,
    task_id: []const u8,
    tool_id: []const u8,
    effect: Effect,
    snapshot: ?SnapshotIdentity,
    args: Arguments,
    result: ResultContract,
    output_budget: usize,
    authority: Authority,
};

// The trusted fixture host supplies this exact binding and current authority.
// This experiment does not implement production permission checks or expiry clocks.
pub const HostAdmission = struct {
    binding: CallBinding,
    current_authority: Authority,
    // Presence certifies this exact snapshot as immutable in the fixture host.
    immutable_snapshot: ?SnapshotIdentity,
};

pub const Admission = union(enum) {
    denied,
    admitted: HostAdmission,
};

pub const LogicalCall = struct {
    request: CallBinding,
    admission: Admission,
};

pub const AdmissionStatus = enum {
    admitted,
    denied,
    stale_authority,
    binding_mismatch,
    uncertified_snapshot,
};

pub const PlannedCall = struct {
    call: LogicalCall,
    status: AdmissionStatus,
    physical_group: ?usize,
};

pub const PhysicalGroup = struct {
    id: usize,
    // Index in Plan.logical_calls; only admitted calls can be representatives.
    representative: usize,
    consumer_count: usize,
};

// The caller owns both arrays. Logical calls are copied, but their strings are
// borrowed and must stay alive and unchanged until receipt consumption ends.
pub const Plan = struct {
    logical_calls: []PlannedCall,
    groups: []PhysicalGroup,

    pub fn deinit(self: *Plan, alloc: std.mem.Allocator) void {
        alloc.free(self.logical_calls);
        alloc.free(self.groups);
        self.* = undefined;
    }
};

pub const ReceiptStatus = enum {
    success,
    admission_rejected,
    unsupported_effect,
    execution_failed,
    output_budget_exceeded,
    invalid_window,
    snapshot_mismatch,
};

// Identity and exact arguments survive sharing. Request strings remain frozen.
// Embedded executor outputs borrow its immutable Snapshot until receipt consumption ends.
pub const Receipt = struct {
    request: CallBinding,
    admission_status: AdmissionStatus,
    physical_group: ?usize,
    status: ReceiptStatus,
    output: []const u8,
};

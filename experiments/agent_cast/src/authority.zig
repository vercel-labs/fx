const std = @import("std");
const contracts = @import("contracts.zig");

const hard_records = 1024;
const hard_owned_bytes = 16 * 1024 * 1024;
const hard_key_bytes = 64 * 1024;

pub const Limits = struct {
    max_records: usize = 256,
    max_owned_bytes: usize = 1024 * 1024,
    max_key_bytes: usize = 4096,
};

pub const ContextHandle = struct { bytes: [32]u8 };
pub const AgentHandle = struct { bytes: [32]u8 };
pub const Permit = struct { bytes: [32]u8 };

pub const TaskDefinition = struct {
    task_id: []const u8,
    principal_domain: []const u8,
    snapshot: contracts.SnapshotIdentity,
    authority_partition: []const u8,
    policy_generation: u64 = 1,
    resource_generation: u64 = 1,
    implementation_generation: u64 = 1,
};

pub const Generations = struct {
    policy: u64,
    resource: u64,
    implementation: u64,
};

pub const PermitState = enum { active, revoked, expired, stale_generations, reclaimed };
pub const PermitStatus = struct {
    state: PermitState,
    logical_id: u64,
    deadline_ns: u64,
    generations: Generations,
};

pub const Stats = struct { records: usize, owned_bytes: usize, metadata_bytes: usize };

const AgentRecord = struct {
    context: [32]u8,
    agent_id: []const u8,
    revoked: bool = false,
};

const ActionRecord = struct {
    context: [32]u8,
    agent: [32]u8,
    request: contracts.CallBinding,
    generations: Generations,
    issued_ns: u64,
    deadline_ns: u64,
    revoked: bool = false,
    reclaimed: bool = false,
};

const Kind = enum { task, agent, action };
const Record = union(Kind) { task: TaskDefinition, agent: AgentRecord, action: ActionRecord };
const Slot = struct {
    generation: u64 = 1,
    token: [32]u8 = @splat(0),
    storage: []u8 = &.{},
    record: ?Record = null,
};

// Single-owner registry. The parent generates a fresh 32-byte CSPRNG secret and
// fresh nonzero runtime epoch for each runtime, keeps the secret host-only, and
// exposes host_* methods exclusively through its inherited trusted control FD.
// No caller-provided current policy or implementation state is accepted by the
// agent methods. now_ns always comes from the parent's trusted monotonic clock.
// Methods use the same explicit allocator. The nominal owned-byte limit charges
// the full allocated slot table and all record strings; allocator bookkeeping
// and this caller-owned Registry value are outside that limit.
pub const Registry = struct {
    limits: Limits,
    secret: [32]u8,
    runtime_epoch: u64,
    issuance_counter: u64 = 0,
    slots: []Slot,
    state: Stats,

    pub fn init(alloc: std.mem.Allocator, limits: Limits, host_secret: [32]u8, runtime_epoch: u64) !Registry {
        if (limits.max_records > hard_records or limits.max_owned_bytes > hard_owned_bytes or
            limits.max_key_bytes == 0 or limits.max_key_bytes > hard_key_bytes) return error.InvalidLimits;
        if (runtime_epoch == 0) return error.InvalidEpoch;
        if (same_token(host_secret, @splat(0))) return error.InvalidSecret;
        const capacity = @min(limits.max_records, limits.max_owned_bytes / @sizeOf(Slot));
        const slots = try alloc.alloc(Slot, capacity);
        for (slots) |*slot| slot.* = .{};
        const metadata_bytes = capacity * @sizeOf(Slot);
        return .{
            .limits = limits,
            .secret = host_secret,
            .runtime_epoch = runtime_epoch,
            .slots = slots,
            .state = .{ .records = 0, .owned_bytes = metadata_bytes, .metadata_bytes = metadata_bytes },
        };
    }

    pub fn deinit(self: *Registry, alloc: std.mem.Allocator) void {
        for (self.slots) |slot| if (slot.record != null) alloc.free(slot.storage);
        alloc.free(self.slots);
        self.secret = @splat(0);
        self.* = undefined;
    }

    pub fn stats(self: *const Registry) Stats {
        return self.state;
    }

    // Host issuer surface. Task identity is (task_id, principal_domain).
    pub fn host_register_task(self: *Registry, alloc: std.mem.Allocator, definition: TaskDefinition) !ContextHandle {
        if (definition.task_id.len == 0 or definition.principal_domain.len == 0 or
            definition.snapshot.id.len == 0 or definition.snapshot.version.len == 0 or
            definition.authority_partition.len == 0 or definition.policy_generation == 0 or
            definition.resource_generation == 0 or definition.implementation_generation == 0) return error.InvalidTask;
        const bytes = try self.string_bytes(&.{ definition.task_id, definition.principal_domain, definition.snapshot.id, definition.snapshot.version, definition.authority_partition });
        for (self.slots) |slot| {
            if (slot.record) |record| switch (record) {
                .task => |existing| if (equal(existing.task_id, definition.task_id) and equal(existing.principal_domain, definition.principal_domain)) {
                    if (!same_task(existing, definition)) return error.TaskConflict;
                    return .{ .bytes = slot.token };
                },
                else => {},
            };
        }
        const index = try self.reserve_slot(bytes);
        const storage = try alloc.alloc(u8, bytes);
        errdefer alloc.free(storage);
        var remaining = storage;
        var owned = definition;
        owned.task_id = copy_string(&remaining, definition.task_id);
        owned.principal_domain = copy_string(&remaining, definition.principal_domain);
        owned.snapshot = .{ .id = copy_string(&remaining, definition.snapshot.id), .version = copy_string(&remaining, definition.snapshot.version) };
        owned.authority_partition = copy_string(&remaining, definition.authority_partition);
        const token = try self.new_token(.task, index);
        self.install(index, token, storage, .{ .task = owned });
        return .{ .bytes = token };
    }

    pub fn host_enroll_agent(self: *Registry, alloc: std.mem.Allocator, context: ContextHandle, agent_id: []const u8) !AgentHandle {
        _ = self.find(.task, context.bytes) orelse return error.UnknownContext;
        if (agent_id.len == 0) return error.InvalidAgent;
        const bytes = try self.string_bytes(&.{agent_id});
        for (self.slots) |slot| {
            if (slot.record) |record| switch (record) {
                .agent => |agent| if (same_token(agent.context, context.bytes) and equal(agent.agent_id, agent_id)) {
                    if (agent.revoked) return error.AgentRevoked;
                    return .{ .bytes = slot.token };
                },
                else => {},
            };
        }
        const index = try self.reserve_slot(bytes);
        const storage = try alloc.dupe(u8, agent_id);
        errdefer alloc.free(storage);
        const token = try self.new_token(.agent, index);
        self.install(index, token, storage, .{ .agent = .{ .context = context.bytes, .agent_id = storage } });
        return .{ .bytes = token };
    }

    // Exact duplicates return the original permit and deadline. Retained IDs are
    // unique for this task context's lifetime, including reclaimed tombstones.
    pub fn host_issue(self: *Registry, alloc: std.mem.Allocator, agent_handle: AgentHandle, request: contracts.CallBinding, implementation_generation: u64, deadline_ns: u64, now_ns: u64) !Permit {
        const agent_index = self.find(.agent, agent_handle.bytes) orelse return error.UnknownAgent;
        const agent = self.slots[agent_index].record.?.agent;
        if (agent.revoked) return error.AgentRevoked;
        const context_index = self.find(.task, agent.context) orelse return error.UnknownContext;
        const task = self.slots[context_index].record.?.task;
        const bytes = try self.binding_bytes(request);
        if (request.effect != .snapshot_read or !equal(request.tool_id, "embedded-content-reader") or
            !equal(request.args.options, "raw") or !equal(request.result.schema_id, "content") or
            request.result.version != 1 or request.result.encoding != .bytes) return error.UnsupportedAction;
        if (!equal(request.agent_id, agent.agent_id) or !equal(request.task_id, task.task_id) or
            !equal(request.principal_domain, task.principal_domain) or !same_snapshot(request.snapshot, task.snapshot)) return error.BindingOutsideTask;
        if (!equal(request.authority.partition, task.authority_partition) or request.authority.epoch != self.runtime_epoch or
            request.authority.generation != task.policy_generation) return error.IssuerAuthorityMismatch;
        if (implementation_generation != task.implementation_generation) return error.ImplementationMismatch;
        for (self.slots) |slot| {
            if (slot.record) |record| switch (record) {
                .action => |action| if (same_token(action.context, agent.context) and action.request.id == request.id) {
                    if (!same_binding(action.request, request) or action.generations.implementation != implementation_generation or
                        !same_token(action.agent, agent_handle.bytes)) return error.DuplicateLogicalId;
                    if (action.reclaimed) return error.ActionReclaimed;
                    return .{ .bytes = slot.token };
                },
                else => {},
            };
        }
        if (deadline_ns <= now_ns) return error.InvalidDeadline;
        const index = try self.reserve_slot(bytes);
        const storage = try alloc.alloc(u8, bytes);
        errdefer alloc.free(storage);
        const owned = copy_binding(request, storage);
        const token = try self.new_token(.action, index);
        self.install(index, token, storage, .{ .action = .{
            .context = agent.context,
            .agent = agent_handle.bytes,
            .request = owned,
            .generations = generations(task),
            .issued_ns = now_ns,
            .deadline_ns = deadline_ns,
        } });
        return .{ .bytes = token };
    }

    pub fn host_revoke(self: *Registry, permit: Permit) !void {
        const index = self.find(.action, permit.bytes) orelse return error.UnknownPermit;
        self.slots[index].record.?.action.revoked = true;
    }

    pub fn host_revoke_agent(self: *Registry, agent: AgentHandle) !void {
        const index = self.find(.agent, agent.bytes) orelse return error.UnknownAgent;
        self.slots[index].record.?.agent.revoked = true;
    }

    pub fn host_update_generations(self: *Registry, context: ContextHandle, current: Generations) !void {
        const index = self.find(.task, context.bytes) orelse return error.UnknownContext;
        const task = &self.slots[index].record.?.task;
        if (current.policy < task.policy_generation or current.resource < task.resource_generation or
            current.implementation < task.implementation_generation) return error.GenerationRollback;
        task.policy_generation = current.policy;
        task.resource_generation = current.resource;
        task.implementation_generation = current.implementation;
    }

    // Reclamation retains the exact binding tombstone and consumes its quota.
    // It fences all future starts and cannot make a logical ID reusable.
    pub fn host_reclaim(self: *Registry, permit: Permit) !void {
        const index = self.find(.action, permit.bytes) orelse return error.UnknownPermit;
        self.slots[index].record.?.action.reclaimed = true;
    }

    // Whole-task teardown frees tombstones and invalidates every task enrollment
    // and action. Reused slots receive new generations and opaque tokens.
    pub fn host_destroy_task(self: *Registry, alloc: std.mem.Allocator, context: ContextHandle) !void {
        const context_index = self.find(.task, context.bytes) orelse return error.UnknownContext;
        for (self.slots, 0..) |slot, index| {
            const belongs = if (slot.record) |record| switch (record) {
                .task => index == context_index,
                .agent => |agent| same_token(agent.context, context.bytes),
                .action => |action| same_token(action.context, context.bytes),
            } else false;
            if (belongs) self.release_slot(alloc, index);
        }
    }

    // Agent surface: the parent authenticates this enrolled handle on its agent
    // connection. Proposed calls never supply current policy or resource state.
    // Query preserves the exact action/deadline and performs no issuance.
    pub fn query(self: *const Registry, authenticated_agent: AgentHandle, permit: Permit, proposed: contracts.CallBinding, now_ns: u64) !PermitStatus {
        const indices = try self.authenticate(authenticated_agent, permit, proposed);
        const action = self.slots[indices.action].record.?.action;
        const task = self.slots[indices.task].record.?.task;
        if (now_ns < action.issued_ns) return error.TimeBeforeIssue;
        const state: PermitState = if (action.reclaimed) .reclaimed else if (action.revoked) .revoked else if (now_ns >= action.deadline_ns) .expired else if (!same_generations(action.generations, generations(task))) .stale_generations else .active;
        return .{ .state = state, .logical_id = action.request.id, .deadline_ns = action.deadline_ns, .generations = action.generations };
    }

    // Invoke at physical start. Revocation fences later validations but cannot
    // retract an already released effect. The broker owns execution deduplication
    // and outcomes for this one logical action; this registry owns authorization.
    // Returned strings borrow registry storage and must not survive any registry
    // mutation/reclaim/deinit. The parent copies preparation before async dispatch.
    pub fn validate_start(self: *const Registry, authenticated_agent: AgentHandle, permit: Permit, proposed: contracts.CallBinding, now_ns: u64) !contracts.LogicalCall {
        const status = try self.query(authenticated_agent, permit, proposed, now_ns);
        switch (status.state) {
            .active => {},
            .revoked => return error.PermitRevoked,
            .expired => return error.PermitExpired,
            .stale_generations => return error.GenerationsChanged,
            .reclaimed => return error.ActionReclaimed,
        }
        const indices = try self.authenticate(authenticated_agent, permit, proposed);
        const request = self.slots[indices.action].record.?.action.request;
        const task = self.slots[indices.task].record.?.task;
        return .{ .request = request, .admission = .{ .admitted = .{
            .binding = request,
            .current_authority = .{ .partition = task.authority_partition, .epoch = self.runtime_epoch, .generation = task.policy_generation },
            .immutable_snapshot = task.snapshot,
        } } };
    }

    const Indices = struct { action: usize, task: usize };

    fn authenticate(self: *const Registry, authenticated_agent: AgentHandle, permit: Permit, proposed: contracts.CallBinding) !Indices {
        const agent_index = self.find(.agent, authenticated_agent.bytes) orelse return error.UnknownAgent;
        const agent = self.slots[agent_index].record.?.agent;
        if (agent.revoked) return error.AgentRevoked;
        const action_index = self.find(.action, permit.bytes) orelse return error.UnknownPermit;
        const action = self.slots[action_index].record.?.action;
        if (!same_token(action.agent, authenticated_agent.bytes) or !same_token(action.context, agent.context)) return error.WrongAgent;
        if (!same_binding(action.request, proposed)) return error.BindingMismatch;
        const task_index = self.find(.task, agent.context) orelse return error.UnknownContext;
        const task = self.slots[task_index].record.?.task;
        if (!equal(action.request.agent_id, agent.agent_id) or !equal(action.request.task_id, task.task_id) or
            !equal(action.request.principal_domain, task.principal_domain) or !same_snapshot(action.request.snapshot, task.snapshot)) return error.BindingOutsideTask;
        return .{ .action = action_index, .task = task_index };
    }

    fn find(self: *const Registry, kind: Kind, token: [32]u8) ?usize {
        for (self.slots, 0..) |slot, index| {
            if (slot.record) |record| {
                if (std.meta.activeTag(record) == kind and same_token(slot.token, token)) return index;
            }
        }
        return null;
    }

    fn string_bytes(self: *const Registry, values: []const []const u8) !usize {
        var total: usize = 0;
        for (values) |value| {
            if (value.len > self.limits.max_key_bytes) return error.KeyTooLarge;
            total = std.math.add(usize, total, value.len) catch return error.OwnedByteLimit;
        }
        if (total > self.limits.max_owned_bytes) return error.OwnedByteLimit;
        return total;
    }

    fn binding_bytes(self: *const Registry, request: contracts.CallBinding) !usize {
        const snapshot = request.snapshot orelse return error.BindingOutsideTask;
        return self.string_bytes(&.{ request.agent_id, request.principal_domain, request.task_id, request.tool_id, snapshot.id, snapshot.version, request.args.path, request.args.options, request.result.schema_id, request.authority.partition });
    }

    fn reserve_slot(self: *const Registry, bytes: usize) !usize {
        if (bytes > self.limits.max_owned_bytes - self.state.owned_bytes) return error.OwnedByteLimit;
        for (self.slots, 0..) |slot, index| if (slot.record == null and slot.generation != std.math.maxInt(u64)) return index;
        return error.RecordCapacity;
    }

    fn new_token(self: *Registry, kind: Kind, index: usize) ![32]u8 {
        const counter = std.math.add(u64, self.issuance_counter, 1) catch return error.CounterExhausted;
        var message: [32]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], self.runtime_epoch, .big);
        std.mem.writeInt(u64, message[8..16], @intCast(index), .big);
        std.mem.writeInt(u64, message[16..24], self.slots[index].generation, .big);
        std.mem.writeInt(u64, message[24..32], counter, .big);
        var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.secret);
        hmac.update("agent-cast-authority/v1");
        hmac.update(@tagName(kind));
        hmac.update(&message);
        var token: [32]u8 = undefined;
        hmac.final(&token);
        self.issuance_counter = counter;
        return token;
    }

    fn install(self: *Registry, index: usize, token: [32]u8, storage: []u8, record: Record) void {
        self.slots[index].token = token;
        self.slots[index].storage = storage;
        self.slots[index].record = record;
        self.state.records += 1;
        self.state.owned_bytes += storage.len;
    }

    fn release_slot(self: *Registry, alloc: std.mem.Allocator, index: usize) void {
        const slot = &self.slots[index];
        self.state.owned_bytes -= slot.storage.len;
        self.state.records -= 1;
        alloc.free(slot.storage);
        slot.storage = &.{};
        slot.record = null;
        slot.token = @splat(0);
        // An exhausted slot is permanently unavailable; generations never wrap.
        slot.generation = std.math.add(u64, slot.generation, 1) catch std.math.maxInt(u64);
    }
};

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn same_token(a: [32]u8, b: [32]u8) bool {
    return std.crypto.timing_safe.eql([32]u8, a, b);
}

fn same_snapshot(optional: ?contracts.SnapshotIdentity, b: contracts.SnapshotIdentity) bool {
    const a = optional orelse return false;
    return equal(a.id, b.id) and equal(a.version, b.version);
}

fn generations(task: TaskDefinition) Generations {
    return .{ .policy = task.policy_generation, .resource = task.resource_generation, .implementation = task.implementation_generation };
}

fn same_generations(a: Generations, b: Generations) bool {
    return a.policy == b.policy and a.resource == b.resource and a.implementation == b.implementation;
}

fn same_task(a: TaskDefinition, b: TaskDefinition) bool {
    return equal(a.task_id, b.task_id) and equal(a.principal_domain, b.principal_domain) and
        same_snapshot(a.snapshot, b.snapshot) and equal(a.authority_partition, b.authority_partition) and same_generations(generations(a), generations(b));
}

fn same_binding(a: contracts.CallBinding, b: contracts.CallBinding) bool {
    const snapshots_equal = if (a.snapshot) |snapshot| same_snapshot(b.snapshot, snapshot) else b.snapshot == null;
    return a.id == b.id and equal(a.agent_id, b.agent_id) and equal(a.principal_domain, b.principal_domain) and
        equal(a.task_id, b.task_id) and equal(a.tool_id, b.tool_id) and a.effect == b.effect and snapshots_equal and
        equal(a.args.path, b.args.path) and a.args.window.offset == b.args.window.offset and a.args.window.length == b.args.window.length and
        equal(a.args.options, b.args.options) and equal(a.result.schema_id, b.result.schema_id) and a.result.version == b.result.version and
        a.result.encoding == b.result.encoding and a.output_budget == b.output_budget and equal(a.authority.partition, b.authority.partition) and
        a.authority.epoch == b.authority.epoch and a.authority.generation == b.authority.generation;
}

fn copy_string(remaining: *[]u8, input: []const u8) []const u8 {
    const output = remaining.*[0..input.len];
    @memcpy(output, input);
    remaining.* = remaining.*[input.len..];
    return output;
}

fn copy_binding(request: contracts.CallBinding, storage: []u8) contracts.CallBinding {
    var remaining = storage;
    var owned = request;
    owned.agent_id = copy_string(&remaining, request.agent_id);
    owned.principal_domain = copy_string(&remaining, request.principal_domain);
    owned.task_id = copy_string(&remaining, request.task_id);
    owned.tool_id = copy_string(&remaining, request.tool_id);
    owned.snapshot = .{ .id = copy_string(&remaining, request.snapshot.?.id), .version = copy_string(&remaining, request.snapshot.?.version) };
    owned.args.path = copy_string(&remaining, request.args.path);
    owned.args.options = copy_string(&remaining, request.args.options);
    owned.result.schema_id = copy_string(&remaining, request.result.schema_id);
    owned.authority.partition = copy_string(&remaining, request.authority.partition);
    std.debug.assert(remaining.len == 0);
    return owned;
}

fn fixture_definition() TaskDefinition {
    return .{ .task_id = "task", .principal_domain = "user", .snapshot = .{ .id = "snapshot", .version = "sha256-fixture" }, .authority_partition = "read" };
}

fn fixture_request(id: u64, agent: []const u8) contracts.CallBinding {
    return .{
        .id = id,
        .agent_id = agent,
        .principal_domain = "user",
        .task_id = "task",
        .tool_id = "embedded-content-reader",
        .effect = .snapshot_read,
        .snapshot = .{ .id = "snapshot", .version = "sha256-fixture" },
        .args = .{ .path = "file", .window = .{ .offset = 0, .length = 3 }, .options = "raw" },
        .result = .{ .schema_id = "content", .version = 1, .encoding = .bytes },
        .output_budget = 64,
        .authority = .{ .partition = "read", .epoch = 7, .generation = 1 },
    };
}

fn fixture_registry(alloc: std.mem.Allocator) !Registry {
    // Deterministic test key only; runtime secrets must come from host CSPRNG.
    return Registry.init(alloc, .{ .max_records = 16, .max_owned_bytes = 65536 }, @splat(0xa5), 7);
}

test "exact current task authority yields a registry owned immutable admission" {
    var registry = try fixture_registry(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);
    const context = try registry.host_register_task(std.testing.allocator, fixture_definition());
    const agent = try registry.host_enroll_agent(std.testing.allocator, context, "a");
    const request = fixture_request(1, "a");
    const permit = try registry.host_issue(std.testing.allocator, agent, request, 1, 100, 10);
    const call = try registry.validate_start(agent, permit, request, 99);
    try std.testing.expect(same_binding(request, call.request));
    try std.testing.expectEqual(@as(u64, 7), call.admission.admitted.current_authority.epoch);
    try std.testing.expectEqual(@as(u64, 1), call.admission.admitted.current_authority.generation);
    try std.testing.expectEqualStrings("read", call.admission.admitted.current_authority.partition);
    try std.testing.expectEqualStrings("sha256-fixture", call.admission.admitted.immutable_snapshot.?.version);
    try std.testing.expect(call.request.args.path.ptr != request.args.path.ptr);
}

test "changing any exact logical binding field rejects validation" {
    var registry = try fixture_registry(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);
    const context = try registry.host_register_task(std.testing.allocator, fixture_definition());
    const agent = try registry.host_enroll_agent(std.testing.allocator, context, "a");
    const original = fixture_request(1, "a");
    const permit = try registry.host_issue(std.testing.allocator, agent, original, 1, 100, 0);
    inline for (0..21) |change| {
        var changed = original;
        switch (change) {
            0 => changed.id = 2,
            1 => changed.agent_id = "b",
            2 => changed.principal_domain = "other-domain",
            3 => changed.task_id = "other-task",
            4 => changed.tool_id = "other-tool",
            5 => changed.effect = .mutation,
            6 => changed.snapshot = null,
            7 => changed.snapshot.?.id = "other-snapshot",
            8 => changed.snapshot.?.version = "other-version",
            9 => changed.args.path = "other-file",
            10 => changed.args.window.offset = 1,
            11 => changed.args.window.length = 4,
            12 => changed.args.options = "other-options",
            13 => changed.result.schema_id = "other-schema",
            14 => changed.result.version = 2,
            15 => changed.result.encoding = .utf8,
            16 => changed.output_budget = 63,
            17 => changed.authority.partition = "other-authority",
            18 => changed.authority.epoch = 8,
            19 => changed.authority.generation = 2,
            20 => changed.effect = .opaque_exec,
            else => unreachable,
        }
        try std.testing.expectError(error.BindingMismatch, registry.validate_start(agent, permit, changed, 1));
    }
}

test "host issuance rejects caller authority and implementation state inconsistent with registry" {
    var registry = try fixture_registry(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);
    const context = try registry.host_register_task(std.testing.allocator, fixture_definition());
    const agent = try registry.host_enroll_agent(std.testing.allocator, context, "a");
    inline for (0..3) |change| {
        var request = fixture_request(1, "a");
        switch (change) {
            0 => request.authority.partition = "unregistered",
            1 => request.authority.epoch = 8,
            2 => request.authority.generation = 2,
            else => unreachable,
        }
        try std.testing.expectError(error.IssuerAuthorityMismatch, registry.host_issue(std.testing.allocator, agent, request, 1, 100, 0));
    }
    try std.testing.expectError(error.ImplementationMismatch, registry.host_issue(std.testing.allocator, agent, fixture_request(1, "a"), 2, 100, 0));
    var mutation = fixture_request(1, "a");
    mutation.effect = .mutation;
    try std.testing.expectError(error.UnsupportedAction, registry.host_issue(std.testing.allocator, agent, mutation, 1, 100, 0));
    try std.testing.expectEqual(@as(usize, 2), registry.stats().records);
}

test "forged tokens and permits belonging to other enrolled agents domains or tasks reject" {
    var registry = try fixture_registry(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);
    const context = try registry.host_register_task(std.testing.allocator, fixture_definition());
    const a = try registry.host_enroll_agent(std.testing.allocator, context, "a");
    const b = try registry.host_enroll_agent(std.testing.allocator, context, "b");
    const request = fixture_request(1, "a");
    const permit = try registry.host_issue(std.testing.allocator, a, request, 1, 100, 0);
    var forged_permit = permit;
    forged_permit.bytes[0] ^= 1;
    var forged_agent = a;
    forged_agent.bytes[0] ^= 1;
    try std.testing.expectError(error.UnknownPermit, registry.query(a, forged_permit, request, 1));
    try std.testing.expectError(error.UnknownAgent, registry.query(forged_agent, permit, request, 1));
    try std.testing.expectError(error.WrongAgent, registry.query(b, permit, request, 1));
    inline for (0..2) |change| {
        var definition = fixture_definition();
        if (change == 0) definition.task_id = "other-task" else definition.principal_domain = "other-domain";
        const other_context = try registry.host_register_task(std.testing.allocator, definition);
        const other_agent = try registry.host_enroll_agent(std.testing.allocator, other_context, "a");
        try std.testing.expectError(error.WrongAgent, registry.query(other_agent, permit, request, 1));
        try std.testing.expectError(error.BindingOutsideTask, registry.host_issue(std.testing.allocator, other_agent, request, 1, 100, 0));
    }
}

test "absolute deadline boundary and duplicate issuance never extend the original action" {
    var registry = try fixture_registry(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);
    const context = try registry.host_register_task(std.testing.allocator, fixture_definition());
    const agent = try registry.host_enroll_agent(std.testing.allocator, context, "a");
    const request = fixture_request(1, "a");
    try std.testing.expectError(error.InvalidDeadline, registry.host_issue(std.testing.allocator, agent, request, 1, 10, 10));
    const permit = try registry.host_issue(std.testing.allocator, agent, request, 1, 100, 10);
    try std.testing.expectError(error.TimeBeforeIssue, registry.query(agent, permit, request, 9));
    try std.testing.expectEqual(PermitState.active, (try registry.query(agent, permit, request, 99)).state);
    try std.testing.expectError(error.PermitExpired, registry.validate_start(agent, permit, request, 100));
    const duplicate = try registry.host_issue(std.testing.allocator, agent, request, 1, 1000, 100);
    try std.testing.expect(same_token(permit.bytes, duplicate.bytes));
    const at_expiry = try registry.host_issue(std.testing.allocator, agent, request, 1, 100, 100);
    const after_expiry = try registry.host_issue(std.testing.allocator, agent, request, 1, 100, 101);
    try std.testing.expect(same_token(permit.bytes, at_expiry.bytes));
    try std.testing.expect(same_token(permit.bytes, after_expiry.bytes));
    try std.testing.expectError(error.InvalidDeadline, registry.host_issue(std.testing.allocator, agent, fixture_request(2, "a"), 1, 100, 101));
    var conflicting = request;
    conflicting.args.window.length = 4;
    try std.testing.expectError(error.DuplicateLogicalId, registry.host_issue(std.testing.allocator, agent, conflicting, 1, 100, 101));
    const status = try registry.query(agent, duplicate, request, 101);
    try std.testing.expectEqual(@as(u64, 100), status.deadline_ns);
    try std.testing.expectEqual(PermitState.expired, status.state);
    try std.testing.expectEqual(@as(usize, 3), registry.stats().records);
    try registry.host_reclaim(permit);
    try std.testing.expectError(error.ActionReclaimed, registry.host_issue(std.testing.allocator, agent, request, 1, 100, 101));
}

test "revocation fences later starts and independent policy resource implementation updates invalidate actions" {
    inline for (0..3) |change| {
        var registry = try fixture_registry(std.testing.allocator);
        defer registry.deinit(std.testing.allocator);
        const context = try registry.host_register_task(std.testing.allocator, fixture_definition());
        const agent = try registry.host_enroll_agent(std.testing.allocator, context, "a");
        const request = fixture_request(1, "a");
        const permit = try registry.host_issue(std.testing.allocator, agent, request, 1, 100, 0);
        _ = try registry.validate_start(agent, permit, request, 1);
        var current: Generations = .{ .policy = 1, .resource = 1, .implementation = 1 };
        switch (change) {
            0 => current.policy = 2,
            1 => current.resource = 2,
            2 => current.implementation = 2,
            else => unreachable,
        }
        try registry.host_update_generations(context, current);
        try std.testing.expectEqual(PermitState.stale_generations, (try registry.query(agent, permit, request, 2)).state);
        try std.testing.expectError(error.GenerationsChanged, registry.validate_start(agent, permit, request, 2));
        try std.testing.expectError(error.GenerationRollback, registry.host_update_generations(context, .{ .policy = 1, .resource = 1, .implementation = 1 }));
    }
    var registry = try fixture_registry(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);
    const context = try registry.host_register_task(std.testing.allocator, fixture_definition());
    const agent = try registry.host_enroll_agent(std.testing.allocator, context, "a");
    const request = fixture_request(1, "a");
    const permit = try registry.host_issue(std.testing.allocator, agent, request, 1, 100, 0);
    _ = try registry.validate_start(agent, permit, request, 1);
    try registry.host_revoke(permit);
    try std.testing.expectError(error.PermitRevoked, registry.validate_start(agent, permit, request, 2));
    try std.testing.expectEqual(PermitState.revoked, (try registry.query(agent, permit, request, 2)).state);
    const duplicate = try registry.host_issue(std.testing.allocator, agent, request, 1, 1000, 2);
    try std.testing.expect(same_token(permit.bytes, duplicate.bytes));
    try registry.host_revoke_agent(agent);
    try std.testing.expectError(error.AgentRevoked, registry.query(agent, permit, request, 3));
}

test "conflicting IDs reject and reclaimed tombstones prevent replay until whole task teardown" {
    var registry = try Registry.init(std.testing.allocator, .{ .max_records = 3, .max_owned_bytes = 8192 }, @splat(0xa5), 7);
    defer registry.deinit(std.testing.allocator);
    const context = try registry.host_register_task(std.testing.allocator, fixture_definition());
    const agent = try registry.host_enroll_agent(std.testing.allocator, context, "a");
    const request = fixture_request(1, "a");
    const permit = try registry.host_issue(std.testing.allocator, agent, request, 1, 100, 0);
    var conflicting = request;
    conflicting.args.window.length = 4;
    try std.testing.expectError(error.DuplicateLogicalId, registry.host_issue(std.testing.allocator, agent, conflicting, 1, 100, 0));
    const before = registry.stats();
    try registry.host_reclaim(permit);
    try std.testing.expectEqual(before.records, registry.stats().records);
    try std.testing.expectEqual(before.owned_bytes, registry.stats().owned_bytes);
    try std.testing.expectError(error.ActionReclaimed, registry.validate_start(agent, permit, request, 1));
    try std.testing.expectError(error.ActionReclaimed, registry.host_issue(std.testing.allocator, agent, request, 1, 1000, 1));
    try std.testing.expectError(error.DuplicateLogicalId, registry.host_issue(std.testing.allocator, agent, conflicting, 1, 1000, 1));
    try std.testing.expectError(error.RecordCapacity, registry.host_issue(std.testing.allocator, agent, fixture_request(2, "a"), 1, 100, 0));
    try registry.host_destroy_task(std.testing.allocator, context);
    try std.testing.expectEqual(@as(usize, 0), registry.stats().records);
    try std.testing.expectEqual(registry.stats().metadata_bytes, registry.stats().owned_bytes);
    const new_context = try registry.host_register_task(std.testing.allocator, fixture_definition());
    const new_agent = try registry.host_enroll_agent(std.testing.allocator, new_context, "a");
    const new_permit = try registry.host_issue(std.testing.allocator, new_agent, conflicting, 1, 100, 0);
    try std.testing.expect(!same_token(context.bytes, new_context.bytes));
    try std.testing.expect(!same_token(agent.bytes, new_agent.bytes));
    try std.testing.expect(!same_token(permit.bytes, new_permit.bytes));
    try std.testing.expectError(error.UnknownPermit, registry.query(new_agent, permit, request, 1));
    try std.testing.expectError(error.UnknownAgent, registry.query(agent, new_permit, conflicting, 1));
    try std.testing.expectError(error.UnknownContext, registry.host_enroll_agent(std.testing.allocator, context, "b"));
    _ = try registry.validate_start(new_agent, new_permit, conflicting, 1);
}

test "runtime epoch changes invalidate every old handle even with identical fixture secret" {
    var first = try fixture_registry(std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    var second = try Registry.init(std.testing.allocator, .{ .max_records = 16, .max_owned_bytes = 65536 }, @splat(0xa5), 8);
    defer second.deinit(std.testing.allocator);
    const first_context = try first.host_register_task(std.testing.allocator, fixture_definition());
    const first_agent = try first.host_enroll_agent(std.testing.allocator, first_context, "a");
    const first_request = fixture_request(1, "a");
    const first_permit = try first.host_issue(std.testing.allocator, first_agent, first_request, 1, 100, 0);
    const second_context = try second.host_register_task(std.testing.allocator, fixture_definition());
    const second_agent = try second.host_enroll_agent(std.testing.allocator, second_context, "a");
    var second_request = first_request;
    second_request.authority.epoch = 8;
    const second_permit = try second.host_issue(std.testing.allocator, second_agent, second_request, 1, 100, 0);
    try std.testing.expect(!same_token(first_permit.bytes, second_permit.bytes));
    try std.testing.expectError(error.UnknownPermit, second.query(second_agent, first_permit, second_request, 1));
    try std.testing.expectError(error.UnknownAgent, second.query(first_agent, second_permit, second_request, 1));
}

test "owned frozen task agent and action bindings survive mutable input reuse" {
    var registry = try fixture_registry(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);
    var task = "task".*;
    var definition = fixture_definition();
    definition.task_id = &task;
    const context = try registry.host_register_task(std.testing.allocator, definition);
    @memset(&task, 'X');
    var agent_name = "a".*;
    const agent = try registry.host_enroll_agent(std.testing.allocator, context, &agent_name);
    agent_name[0] = 'X';
    var path = "file".*;
    var request = fixture_request(1, "a");
    request.args.path = &path;
    const permit = try registry.host_issue(std.testing.allocator, agent, request, 1, 100, 0);
    @memset(&path, 'X');
    const original = fixture_request(1, "a");
    const validated = try registry.validate_start(agent, permit, original, 1);
    try std.testing.expectEqualStrings("task", validated.request.task_id);
    try std.testing.expectEqualStrings("a", validated.request.agent_id);
    try std.testing.expectEqualStrings("file", validated.request.args.path);
    try std.testing.expect(validated.request.args.path.ptr != path[0..].ptr);
}

test "key and record byte quotas reject before owned allocation and failures clean up" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var registry = try fixture_registry(alloc);
    defer registry.deinit(alloc);
    const huge: [4097]u8 = @splat('x');
    var definition = fixture_definition();
    definition.task_id = &huge;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.KeyTooLarge, registry.host_register_task(alloc, definition));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), registry.stats().records);
    failing.fail_index = std.math.maxInt(usize);
    const context = try registry.host_register_task(alloc, fixture_definition());
    const agent = try registry.host_enroll_agent(alloc, context, "a");
    const before = registry.stats();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, registry.host_issue(alloc, agent, fixture_request(1, "a"), 1, 100, 0));
    try std.testing.expectEqual(before.records, registry.stats().records);
    try std.testing.expectEqual(before.owned_bytes, registry.stats().owned_bytes);
    try std.testing.expect(registry.stats().owned_bytes <= registry.limits.max_owned_bytes);
    try std.testing.expectEqual(registry.stats().owned_bytes, failing.allocated_bytes - failing.freed_bytes);
    var tiny = try Registry.init(std.testing.allocator, .{ .max_records = 1, .max_owned_bytes = @sizeOf(Slot) }, @splat(0xa5), 7);
    defer tiny.deinit(std.testing.allocator);
    try std.testing.expectError(error.OwnedByteLimit, tiny.host_register_task(std.testing.allocator, fixture_definition()));
    try std.testing.expectError(error.InvalidLimits, Registry.init(std.testing.allocator, .{ .max_records = 1025 }, @splat(0xa5), 7));
    try std.testing.expectError(error.InvalidSecret, Registry.init(std.testing.allocator, .{}, @splat(0), 7));
    try std.testing.expectError(error.InvalidEpoch, Registry.init(std.testing.allocator, .{}, @splat(0xa5), 0));
}

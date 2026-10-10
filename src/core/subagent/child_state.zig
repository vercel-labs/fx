const std = @import("std");
const domain = @import("domain.zig");
const io_mod = @import("../shared/io.zig");
const session_adapter = @import("../session/session_adapter.zig");
const session_codec = @import("../session/session_codec.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_store = @import("../session/session_store.zig");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const schema_version: u64 = 2;
const state_file = "children.json";
const lock_file = "children.lock";
const owner_marker_file = "owner.json";
const legacy_control_file = "control.json";
const lock_deadline_ms: u64 = 2_000;
const max_state_bytes: usize = 512 * 1024;
pub const max_children: usize = 256;

const PersistentIdentity = struct {
    agent: []u8,
    instructions: []u8,

    fn deinit(self: *PersistentIdentity, alloc: Allocator) void {
        alloc.free(self.agent);
        if (self.instructions.len > 0) alloc.free(self.instructions);
        self.* = undefined;
    }

    fn clone(self: PersistentIdentity, alloc: Allocator) !PersistentIdentity {
        const agent = try alloc.dupe(u8, self.agent);
        errdefer alloc.free(agent);
        return .{
            .agent = agent,
            .instructions = if (self.instructions.len == 0)
                &.{}
            else
                try alloc.dupe(u8, self.instructions),
        };
    }
};

pub const Kind = union(enum) {
    one_off,
    persistent: PersistentIdentity,
};
pub const Phase = enum { idle, running, awaiting_approval, interrupted, finished };
/// `lost`: the work never reached the child's log before a crash; only a
/// v2 parent's reopen repair records it (D33).
pub const Outcome = enum { completed, failed, cancelled, interrupted, lost };

pub const ActiveWork = struct {
    id: []u8,
    request_fingerprint: [32]u8 = @splat(0),
    message: []u8,
    root_user_intent_context: []u8 = &.{},
    root_user_messages: [][]u8 = &.{},
    root_user_evidence_complete: bool = false,
    permission_mode: types.PermissionMode = .yolo,
    created_at_ms: i64,

    pub fn deinit(self: *ActiveWork, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.message);
        if (self.root_user_intent_context.len > 0) {
            alloc.free(self.root_user_intent_context);
        }
        freeStrings(alloc, self.root_user_messages);
        self.* = undefined;
    }

    pub fn clone(self: ActiveWork, alloc: Allocator) !ActiveWork {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const message = try alloc.dupe(u8, self.message);
        errdefer alloc.free(message);
        const context = try alloc.dupe(u8, self.root_user_intent_context);
        errdefer alloc.free(context);
        return .{
            .id = id,
            .request_fingerprint = self.request_fingerprint,
            .message = message,
            .root_user_intent_context = context,
            .root_user_messages = try cloneStrings(alloc, self.root_user_messages),
            .root_user_evidence_complete = self.root_user_evidence_complete,
            .permission_mode = self.permission_mode,
            .created_at_ms = self.created_at_ms,
        };
    }

    pub fn queuedMessage(
        self: ActiveWork,
        alloc: Allocator,
        parent_id: []const u8,
        instructions: []const u8,
    ) !domain.QueuedMessage {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const source_id = try alloc.dupe(u8, parent_id);
        errdefer alloc.free(source_id);
        const content = try alloc.dupe(u8, self.message);
        errdefer alloc.free(content);
        const overlay: []u8 = if (instructions.len == 0)
            &.{}
        else
            try alloc.dupe(u8, instructions);
        errdefer if (overlay.len > 0) alloc.free(overlay);
        const root_context = try alloc.dupe(u8, self.root_user_intent_context);
        errdefer if (root_context.len > 0) alloc.free(root_context);
        return .{
            .id = id,
            .source_id = source_id,
            .content = content,
            .system_prompt_overlay = overlay,
            .root_user_intent_context = root_context,
            .root_user_messages = try cloneStrings(alloc, self.root_user_messages),
            .root_user_evidence_complete = self.root_user_evidence_complete,
            .created_at_ms = self.created_at_ms,
        };
    }
};

pub const Child = struct {
    id: []u8,
    kind: Kind,
    phase: Phase,
    work_generation: u64 = 0,
    active: ?ActiveWork = null,
    last_work_id: ?[]u8 = null,
    last_request_fingerprint: ?[32]u8 = null,
    last_outcome: ?Outcome = null,
    last_failure: ?types.ModelFailureDiagnostic = null,

    pub fn deinit(self: *Child, alloc: Allocator) void {
        alloc.free(self.id);
        switch (self.kind) {
            .one_off => {},
            .persistent => |*persistent| persistent.deinit(alloc),
        }
        if (self.active) |*active| active.deinit(alloc);
        if (self.last_work_id) |id| alloc.free(id);
        self.* = undefined;
    }

    fn clone(self: Child, alloc: Allocator) !Child {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        var kind = switch (self.kind) {
            .one_off => Kind.one_off,
            .persistent => |persistent| Kind{ .persistent = try persistent.clone(alloc) },
        };
        errdefer switch (kind) {
            .one_off => {},
            .persistent => |*persistent| persistent.deinit(alloc),
        };
        var active = if (self.active) |value| try value.clone(alloc) else null;
        errdefer if (active) |*value| value.deinit(alloc);
        return .{
            .id = id,
            .kind = kind,
            .phase = self.phase,
            .work_generation = self.work_generation,
            .active = active,
            .last_work_id = if (self.last_work_id) |value| try alloc.dupe(u8, value) else null,
            .last_request_fingerprint = self.last_request_fingerprint,
            .last_outcome = self.last_outcome,
            .last_failure = self.last_failure,
        };
    }

    pub fn agentName(self: Child) ?[]const u8 {
        return switch (self.kind) {
            .one_off => null,
            .persistent => |persistent| persistent.agent,
        };
    }

    pub fn instructions(self: Child) []const u8 {
        return switch (self.kind) {
            .one_off => "",
            .persistent => |persistent| persistent.instructions,
        };
    }
};

pub const Registry = struct {
    parent_id: []u8,
    generation: u64 = 0,
    children: []Child = &.{},

    pub fn init(alloc: Allocator, parent_id: []const u8) !Registry {
        domain.validateId(parent_id) catch return error.InvalidParentId;
        return .{ .parent_id = try alloc.dupe(u8, parent_id) };
    }

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        alloc.free(self.parent_id);
        for (self.children) |*child| child.deinit(alloc);
        if (self.children.len > 0) alloc.free(self.children);
        self.* = undefined;
    }

    pub fn clone(self: Registry, alloc: Allocator) !Registry {
        const parent_id = try alloc.dupe(u8, self.parent_id);
        errdefer alloc.free(parent_id);
        const children = try alloc.alloc(Child, self.children.len);
        var built: usize = 0;
        errdefer {
            for (children[0..built]) |*child| child.deinit(alloc);
            alloc.free(children);
        }
        for (self.children) |child| {
            children[built] = try child.clone(alloc);
            built += 1;
        }
        return .{
            .parent_id = parent_id,
            .generation = self.generation,
            .children = children,
        };
    }

    pub fn findById(self: *Registry, child_id: []const u8) ?*Child {
        for (self.children) |*child| {
            if (std.mem.eql(u8, child.id, child_id)) return child;
        }
        return null;
    }

    pub fn findPersistent(self: *Registry, agent: []const u8) ?*Child {
        for (self.children) |*child| {
            const name = child.agentName() orelse continue;
            if (std.mem.eql(u8, name, agent)) return child;
        }
        return null;
    }

    pub fn findByOperation(
        self: *Registry,
        operation_id: []const u8,
    ) ?*Child {
        for (self.children) |*child| {
            if (child.active) |active| {
                if (std.mem.eql(u8, active.id, operation_id)) return child;
            }
            if (child.last_work_id) |work_id| {
                if (std.mem.eql(u8, work_id, operation_id)) return child;
            }
        }
        return null;
    }

    pub fn operationFingerprint(child: Child, operation_id: []const u8) ?[32]u8 {
        if (child.active) |active| {
            if (std.mem.eql(u8, active.id, operation_id)) {
                return active.request_fingerprint;
            }
        }
        if (child.last_work_id) |work_id| {
            if (std.mem.eql(u8, work_id, operation_id)) {
                return child.last_request_fingerprint;
            }
        }
        return null;
    }

    pub fn appendOneOff(
        self: *Registry,
        alloc: Allocator,
        child_id: []const u8,
        active: ActiveWork,
    ) !void {
        try self.appendChild(alloc, .{
            .id = try alloc.dupe(u8, child_id),
            .kind = .one_off,
            .phase = .running,
            .work_generation = 1,
            .active = try active.clone(alloc),
        });
    }

    pub fn appendPersistent(
        self: *Registry,
        alloc: Allocator,
        child_id: []const u8,
        agent: []const u8,
        instructions: []const u8,
        active: ActiveWork,
    ) !void {
        if (!domain.validAgentName(agent) or
            !domain.validInstructions(instructions)) return error.InvalidState;
        if (self.findPersistent(agent) != null) return error.AgentAlreadyExists;
        const owned_agent = try alloc.dupe(u8, agent);
        errdefer alloc.free(owned_agent);
        const owned_instructions: []u8 = if (instructions.len == 0)
            &.{}
        else
            try alloc.dupe(u8, instructions);
        errdefer if (owned_instructions.len > 0) alloc.free(owned_instructions);
        var persistent = PersistentIdentity{
            .agent = owned_agent,
            .instructions = owned_instructions,
        };
        errdefer persistent.deinit(alloc);
        try self.appendChild(alloc, .{
            .id = try alloc.dupe(u8, child_id),
            .kind = .{ .persistent = persistent },
            .phase = .running,
            .work_generation = 1,
            .active = try active.clone(alloc),
        });
    }

    fn appendChild(self: *Registry, alloc: Allocator, child: Child) !void {
        if (self.children.len >= max_children) return error.CapacityExceeded;
        if (self.findById(child.id) != null) return error.ChildAlreadyExists;
        const next = try alloc.alloc(Child, self.children.len + 1);
        @memcpy(next[0..self.children.len], self.children);
        next[self.children.len] = child;
        if (self.children.len > 0) alloc.free(self.children);
        self.children = next;
        self.generation +|= 1;
    }

    pub fn startPersistentWork(
        self: *Registry,
        alloc: Allocator,
        agent: []const u8,
        instructions: ?[]const u8,
        active: ActiveWork,
    ) !*Child {
        if (instructions) |value| {
            if (value.len == 0 or !domain.validInstructions(value)) {
                return error.InvalidState;
            }
        }
        const child = self.findPersistent(agent) orelse return error.ChildNotFound;
        switch (child.phase) {
            .idle, .interrupted => {},
            .running, .awaiting_approval => return error.ChildBusy,
            .finished => return error.ChildNotFound,
        }
        var next_active = try active.clone(alloc);
        errdefer next_active.deinit(alloc);
        const next_instructions: ?[]u8 = if (instructions) |value|
            if (value.len == 0) &.{} else try alloc.dupe(u8, value)
        else
            null;
        errdefer if (next_instructions) |value| {
            if (value.len > 0) alloc.free(value);
        };
        if (instructions != null) switch (child.kind) {
            .one_off => return error.ChildNotFound,
            .persistent => |*persistent| {
                if (persistent.instructions.len > 0) alloc.free(persistent.instructions);
                persistent.instructions = next_instructions.?;
            },
        };
        if (child.active) |*old| old.deinit(alloc);
        child.active = next_active;
        child.phase = .running;
        child.work_generation +|= 1;
        self.generation +|= 1;
        return child;
    }

    pub fn finish(
        self: *Registry,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        outcome: Outcome,
        failure: ?types.ModelFailureDiagnostic,
    ) !void {
        const child = self.findById(child_id) orelse return error.ChildNotFound;
        const active = child.active orelse return error.StaleWork;
        if (!std.mem.eql(u8, active.id, work_id)) return error.StaleWork;
        if (failure != null and outcome != .failed) return error.InvalidState;
        const next_work_id = try alloc.dupe(u8, work_id);
        if (child.last_work_id) |old| alloc.free(old);
        child.last_work_id = next_work_id;
        child.last_request_fingerprint = active.request_fingerprint;
        child.last_outcome = outcome;
        child.last_failure = failure;
        child.active.?.deinit(alloc);
        child.active = null;
        child.phase = switch (child.kind) {
            .one_off => .finished,
            .persistent => .idle,
        };
        self.generation +|= 1;
    }

    pub fn interruptActive(self: *Registry, alloc: Allocator) void {
        var changed = false;
        for (self.children) |*child| {
            if (child.phase != .running and child.phase != .awaiting_approval) continue;
            if (child.active) |active| {
                if (child.last_work_id) |old| alloc.free(old);
                child.last_work_id = alloc.dupe(u8, active.id) catch null;
                child.last_request_fingerprint = active.request_fingerprint;
                child.last_outcome = .interrupted;
                child.last_failure = null;
                child.active.?.deinit(alloc);
                child.active = null;
            }
            child.phase = .interrupted;
            changed = true;
        }
        if (changed) self.generation +|= 1;
    }
};

/// Where a parent keeps its children: v1's `children.json` beside its
/// session, or its v2 log (D22). One backend per process.
pub const Backend = union(enum) {
    v1: *session_store.Store,
    v2: *V2Children,
};

/// Held across a load, a change and its save.
pub const Lock = union(enum) {
    v1: io_mod.TimedAdvisoryLock,
    v2: *std.Io.Mutex,

    pub fn release(self: *Lock) void {
        switch (self.*) {
            .v1 => |*lock| lock.release(),
            .v2 => |mutex| mutex.unlock(io_mod.getIo()),
        }
    }
};

pub const Store = struct {
    backend: Backend,
    parent_id: []const u8,
    options: session_child_store.Options = .{},

    pub fn acquireLock(self: Store, alloc: Allocator) !Lock {
        const sessions = switch (self.backend) {
            .v2 => |children| {
                children.lock.lockUncancelable(io_mod.getIo());
                return .{ .v2 = &children.lock };
            },
            .v1 => |value| value,
        };
        var capability = try sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.parent_id,
            self.options,
        );
        defer capability.deinit();
        return .{ .v1 = try capability.acquireTimedAdvisoryLock(
            .subagent_control,
            lock_file,
            lock_deadline_ms,
        ) };
    }

    pub fn load(self: Store, alloc: Allocator) !Registry {
        const sessions = switch (self.backend) {
            .v2 => |children| return children.load(alloc),
            .v1 => |value| value,
        };
        var capability = try sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            self.parent_id,
            self.options,
        );
        defer capability.deinit();
        var file = capability.openFileReadOnly(
            alloc,
            .subagent_control,
            state_file,
        ) catch |err| {
            if (err == error.FileNotFound) return Registry.init(alloc, self.parent_id);
            return err;
        };
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, max_state_bytes);
        defer alloc.free(bytes);
        return parseRegistry(alloc, bytes, self.parent_id);
    }

    pub fn save(self: Store, alloc: Allocator, registry: Registry) !void {
        if (!std.mem.eql(u8, registry.parent_id, self.parent_id)) {
            return error.InvalidParentId;
        }
        const sessions = switch (self.backend) {
            .v2 => |children| return children.save(alloc, registry),
            .v1 => |value| value,
        };
        const bytes = try renderRegistry(alloc, registry);
        defer alloc.free(bytes);
        if (bytes.len > max_state_bytes) return error.StateTooLarge;
        var capability = try sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.parent_id,
            self.options,
        );
        defer capability.deinit();
        var entry = try capability.atomicReplace(
            alloc,
            .subagent_control,
            state_file,
            bytes,
        );
        entry.deinit(alloc);
    }

    pub fn markChildSession(
        self: Store,
        alloc: Allocator,
        child_id: []const u8,
    ) !void {
        // A v2 child's own first line says it is one (`role: child`).
        const sessions = switch (self.backend) {
            .v2 => return,
            .v1 => |value| value,
        };
        var bytes: std.Io.Writer.Allocating = .init(alloc);
        defer bytes.deinit();
        try bytes.writer.writeAll("{\"schema_version\":1,\"parent_id\":");
        try std.json.Stringify.value(self.parent_id, .{}, &bytes.writer);
        try bytes.writer.writeAll("}");
        var capability = try sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            self.options,
        );
        defer capability.deinit();
        var entry = try capability.atomicReplace(
            alloc,
            .subagent_control,
            owner_marker_file,
            bytes.written(),
        );
        entry.deinit(alloc);
    }
};

/// A parent's children in its v2 log (D22). The log is the record, and this
/// copy is the truth while this process holds the parent, the only one that
/// can append to it. Loaded on first use; each save appends what changed.
/// Unfinished work's message and evidence live only here, as v1 drops them
/// on restart too (`Registry.interruptActive`).
pub const V2Children = struct {
    alloc: Allocator,
    parent: *session_adapter.Session,
    /// The parent's workspace, borrowed; children share it.
    workspace: []const u8,
    /// Held across a load, a change and its save, as v1's `children.lock`.
    lock: std.Io.Mutex = .init,
    /// Guards `registry` and `seeds`, so an unlocked load never sees a swap.
    state: std.Io.Mutex = .init,
    registry: ?Registry = null,
    /// Settings for children with no log yet, from their admission; taken
    /// when their work first opens them (D34). Keys and models owned.
    seeds: std.array_hash_map.String(ChildSeed) = .empty,

    pub const ChildSeed = struct {
        preferences: session_codec.DurableSessionPreferences,
        language: types.ConversationLanguage,
    };

    pub fn init(alloc: Allocator, parent: *session_adapter.Session, workspace: []const u8) V2Children {
        return .{ .alloc = alloc, .parent = parent, .workspace = workspace };
    }

    pub fn deinit(self: *V2Children) void {
        if (self.registry) |*registry| registry.deinit(self.alloc);
        for (self.seeds.keys(), self.seeds.values()) |key, seed| {
            self.alloc.free(key);
            self.alloc.free(seed.preferences.model);
        }
        self.seeds.deinit(self.alloc);
        self.* = undefined;
    }

    /// Remembers the settings a new child starts with, replacing older ones.
    pub fn rememberSeed(self: *V2Children, child_id: []const u8, seed: ChildSeed) !void {
        self.state.lockUncancelable(io_mod.getIo());
        defer self.state.unlock(io_mod.getIo());
        var owned = seed;
        owned.preferences.model = try self.alloc.dupe(u8, seed.preferences.model);
        errdefer self.alloc.free(owned.preferences.model);
        if (self.seeds.getPtr(child_id)) |existing| {
            self.alloc.free(existing.preferences.model);
            existing.* = owned;
            return;
        }
        const key = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(key);
        try self.seeds.put(self.alloc, key, owned);
    }

    /// A copy of the seed for `child_id`, or null. Free its model.
    pub fn seedFor(self: *V2Children, alloc: Allocator, child_id: []const u8) !?ChildSeed {
        self.state.lockUncancelable(io_mod.getIo());
        defer self.state.unlock(io_mod.getIo());
        const seed = self.seeds.get(child_id) orelse return null;
        var copy = seed;
        copy.preferences.model = try alloc.dupe(u8, seed.preferences.model);
        return copy;
    }

    fn load(self: *V2Children, alloc: Allocator) !Registry {
        self.state.lockUncancelable(io_mod.getIo());
        defer self.state.unlock(io_mod.getIo());
        return (try self.currentLocked()).clone(alloc);
    }

    fn save(self: *V2Children, alloc: Allocator, next: Registry) !void {
        self.state.lockUncancelable(io_mod.getIo());
        defer self.state.unlock(io_mod.getIo());
        const current = try self.currentLocked();
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const lines = try planLines(arena.allocator(), current.*, next);
        var copy = try next.clone(self.alloc);
        errdefer copy.deinit(self.alloc);
        try self.parent.appendChildLines(lines);
        current.deinit(self.alloc);
        self.registry = copy;
    }

    fn currentLocked(self: *V2Children) !*Registry {
        if (self.registry == null) {
            const children = try self.parent.children(self.alloc);
            defer session_adapter.freeChildren(self.alloc, children);
            self.registry = try registryFromChildren(self.alloc, self.parent.id(), children);
        }
        return &self.registry.?;
    }
};

/// fx's data on a `child_spawned` line: who the child is and which request
/// started the work. Every spawn repeats it, since the fold keeps the newest.
const SpawnData = struct {
    /// A named child's name; null for a one-off.
    agent: ?[]const u8 = null,
    fingerprint: []const u8,
};

/// fx's data on a `child_finished` line.
const FinishData = struct {
    failure: ?[]const u8 = null,
};

/// Pure: the registry a v2 parent's folded children describe. The
/// manager's reopen repair has finished every open item, so an open one
/// here means another writer and is refused. Instructions live in each
/// child's own `prefs` (D34), read when its work runs.
fn registryFromChildren(alloc: Allocator, parent_id: []const u8, folded: []const session_adapter.Child) !Registry {
    var registry = try Registry.init(alloc, parent_id);
    errdefer registry.deinit(alloc);
    if (folded.len > max_children) return error.StateTooLarge;
    if (folded.len == 0) return registry;
    const children = try alloc.alloc(Child, folded.len);
    var built: usize = 0;
    errdefer {
        for (children[0..built]) |*child| child.deinit(alloc);
        alloc.free(children);
    }
    var generation: u64 = 0;
    for (folded) |entry| {
        children[built] = try childFromFolded(alloc, entry);
        built += 1;
        generation = @max(generation, entry.seq);
    }
    registry.children = children;
    registry.generation = generation;
    return registry;
}

fn childFromFolded(alloc: Allocator, entry: session_adapter.Child) !Child {
    if (entry.open) return error.InvalidState;
    const outcome = entry.outcome orelse return error.InvalidState;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const spawn = std.json.parseFromSliceLeaky(SpawnData, sa, entry.spawn_data orelse return error.InvalidState, options) catch return error.InvalidState;
    const finish = if (entry.finish_data) |raw|
        std.json.parseFromSliceLeaky(FinishData, sa, raw, options) catch return error.InvalidState
    else
        FinishData{};
    const last_outcome = fxOutcome(outcome);
    if (finish.failure != null and last_outcome != .failed) return error.InvalidState;
    const fingerprint = try parseFingerprint(spawn.fingerprint);

    const id = try alloc.dupe(u8, entry.id);
    errdefer alloc.free(id);
    const work_id = try alloc.dupe(u8, entry.work_id);
    errdefer alloc.free(work_id);
    var kind: Kind = .one_off;
    if (spawn.agent) |agent| {
        if (!domain.validAgentName(agent)) return error.InvalidState;
        kind = .{ .persistent = .{ .agent = try alloc.dupe(u8, agent), .instructions = &.{} } };
    }
    return .{
        .id = id,
        .kind = kind,
        .phase = switch (last_outcome) {
            .interrupted, .lost => .interrupted,
            .completed, .failed, .cancelled => switch (kind) {
                .one_off => .finished,
                .persistent => .idle,
            },
        },
        .work_generation = entry.seq,
        .last_work_id = work_id,
        .last_request_fingerprint = fingerprint,
        .last_outcome = last_outcome,
        .last_failure = if (finish.failure) |text| types.ModelFailureDiagnostic.init(text) else null,
    };
}

/// Pure: the child lines that take the log from `old` to `next` (D22). A
/// change of phase alone writes nothing. For each child a finish comes
/// before a spawn, so new work on a finished child is one legal batch.
fn planLines(arena: Allocator, old: Registry, next: Registry) ![]session_adapter.ChildLine {
    var lines: std.ArrayList(session_adapter.ChildLine) = .empty;
    for (old.children) |before| {
        if (findChild(next, before.id) == null) return error.InvalidState;
    }
    for (next.children) |after| {
        const before_work: ?[]const u8 = if (findChild(old, after.id)) |before| activeId(before) else null;
        const after_work = activeId(after);
        if (before_work) |work_id| {
            if (after_work == null or !std.mem.eql(u8, after_work.?, work_id)) {
                const last = after.last_work_id orelse return error.InvalidState;
                if (!std.mem.eql(u8, last, work_id)) return error.InvalidState;
                try lines.append(arena, .{ .finished = .{
                    .child = after.id,
                    .work_id = work_id,
                    .outcome = try v2Outcome(after.last_outcome orelse return error.InvalidState),
                    .data = if (after.last_failure) |failure| try stringifyAlloc(arena, FinishData{ .failure = failure.view() }) else null,
                } });
            }
        }
        if (after_work) |work_id| {
            if (before_work == null or !std.mem.eql(u8, before_work.?, work_id)) {
                const fingerprint = std.fmt.bytesToHex(after.active.?.request_fingerprint, .lower);
                try lines.append(arena, .{ .spawned = .{
                    .child = after.id,
                    .work_id = work_id,
                    .data = try stringifyAlloc(arena, SpawnData{ .agent = after.agentName(), .fingerprint = &fingerprint }),
                } });
            }
        }
    }
    return lines.toOwnedSlice(arena);
}

fn findChild(registry: Registry, child_id: []const u8) ?Child {
    for (registry.children) |child| {
        if (std.mem.eql(u8, child.id, child_id)) return child;
    }
    return null;
}

fn activeId(child: Child) ?[]const u8 {
    return if (child.active) |active| active.id else null;
}

fn stringifyAlloc(arena: Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.written();
}

fn fxOutcome(outcome: session_adapter.ChildOutcome) Outcome {
    return switch (outcome) {
        .ok => .completed,
        .failed => .failed,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .lost => .lost,
    };
}

/// Only the manager's reopen repair records `lost` (D22).
fn v2Outcome(outcome: Outcome) !session_adapter.ChildOutcome {
    return switch (outcome) {
        .completed => .ok,
        .failed => .failed,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .lost => error.InvalidState,
    };
}

/// Listing check: reuses discovery's validated identity and every child
/// marker. A legacy session without a metadata-level bit falls back to its
/// first event, read only within a fixed 16 KiB bound; the session index
/// caches the answer under the session's fingerprint, so it is paid once per
/// change. A first event past the bound is unverifiable: listed, not cached.
pub fn isDiscoveredManagedChildSession(
    sessions: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
    subagent_child: ?bool,
) !bool {
    if (subagent_child == true) return true;
    var capability = sessions.openListedSubagentControlReadOnly(alloc, session_id) catch |err| switch (err) {
        error.SessionNotFound => return false,
        else => return err,
    };
    defer if (capability) |*value| value.deinit();
    if (capability) |*value| {
        if (try capabilityHasManagedChildMarker(alloc, value)) return true;
    }
    if (subagent_child) |identity| return identity;
    return sessions.loadListedLegacyChildIdentity(alloc, session_id) catch |err| switch (err) {
        // A session without an event log has no first event to record it.
        error.SessionNotFound, error.FileNotFound => false,
        else => return err,
    };
}

/// Checks only immutable current and legacy child markers. Callers that
/// already hold a loaded session use its durable `subagent_child` bit and
/// this marker-only check rather than reopening session state.
pub fn hasManagedChildMarker(
    sessions: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
) !bool {
    var capability = sessions.openSubagentControlCapabilityReadOnly(
        alloc,
        session_id,
        .{},
    ) catch |err| return switch (err) {
        error.SessionNotFound => false,
        else => err,
    };
    defer capability.deinit();
    return capabilityHasManagedChildMarker(alloc, &capability);
}

pub fn capabilityHasManagedChildMarker(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !bool {
    var owner = capability.openFileReadOnly(
        alloc,
        .subagent_control,
        owner_marker_file,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (owner) |*file| {
        file.deinit();
        return true;
    }

    var legacy = capability.openFileReadOnly(
        alloc,
        .subagent_control,
        legacy_control_file,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (legacy) |*file| {
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, max_state_bytes);
        defer alloc.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidState;
        if (parsed.value.object.get("parent_id")) |parent| {
            if (parent == .string) return true;
        }
    }
    return false;
}

fn renderRegistry(alloc: Allocator, registry: Registry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("{{\"schema_version\":{d},\"parent_id\":", .{schema_version});
    try std.json.Stringify.value(registry.parent_id, .{}, writer);
    try writer.print(",\"generation\":{d},\"children\":[", .{registry.generation});
    for (registry.children, 0..) |child, index| {
        if (index != 0) try writer.writeByte(',');
        try renderChild(writer, child);
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn renderChild(writer: *std.Io.Writer, child: Child) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(child.id, .{}, writer);
    try writer.writeAll(",\"kind\":");
    try std.json.Stringify.value(@tagName(child.kind), .{}, writer);
    try writer.writeAll(",\"persistent\":");
    switch (child.kind) {
        .one_off => try writer.writeAll("null"),
        .persistent => |persistent| {
            try writer.writeAll("{\"agent\":");
            try std.json.Stringify.value(persistent.agent, .{}, writer);
            try writer.writeAll(",\"instructions\":");
            try std.json.Stringify.value(persistent.instructions, .{}, writer);
            try writer.writeByte('}');
        },
    }
    try writer.writeAll(",\"phase\":");
    try std.json.Stringify.value(@tagName(child.phase), .{}, writer);
    try writer.print(",\"work_generation\":{d},\"active\":", .{child.work_generation});
    if (child.active) |active| try renderActive(writer, active) else try writer.writeAll("null");
    try writer.writeAll(",\"last_work_id\":");
    try writeOptionalString(writer, child.last_work_id);
    try writer.writeAll(",\"last_request_fingerprint\":");
    if (child.last_request_fingerprint) |fingerprint| {
        const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
        try std.json.Stringify.value(&fingerprint_hex, .{}, writer);
    } else try writer.writeAll("null");
    try writer.writeAll(",\"last_outcome\":");
    try writeOptionalString(writer, if (child.last_outcome) |outcome| @tagName(outcome) else null);
    try writer.writeAll(",\"last_failure\":");
    try writeOptionalString(writer, if (child.last_failure) |*failure| failure.view() else null);
    try writer.writeByte('}');
}

fn renderActive(writer: *std.Io.Writer, active: ActiveWork) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(active.id, .{}, writer);
    try writer.writeAll(",\"request_fingerprint\":\"");
    const fingerprint_hex = std.fmt.bytesToHex(active.request_fingerprint, .lower);
    try writer.writeAll(&fingerprint_hex);
    try writer.writeByte('"');
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(active.message, .{}, writer);
    try writer.writeAll(",\"root_user_intent_context\":");
    try std.json.Stringify.value(active.root_user_intent_context, .{}, writer);
    try writer.writeAll(",\"root_user_messages\":[");
    for (active.root_user_messages, 0..) |message, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(message, .{}, writer);
    }
    try writer.print(
        "],\"root_user_evidence_complete\":{},\"permission_mode\":\"{s}\",\"created_at_ms\":{d}}}",
        .{ active.root_user_evidence_complete, @tagName(active.permission_mode), active.created_at_ms },
    );
}

fn parseRegistry(alloc: Allocator, bytes: []const u8, parent_id: []const u8) !Registry {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    try exactFields(root, &.{ "schema_version", "parent_id", "generation", "children" });
    const version = try unsigned(root, "schema_version");
    if (version != 1 and version != schema_version) return error.UnsupportedSchema;
    const stored_parent = try string(root, "parent_id");
    if (!std.mem.eql(u8, stored_parent, parent_id)) return error.InvalidParentId;
    const values = root.get("children") orelse return error.InvalidState;
    if (values != .array or values.array.items.len > max_children) return error.InvalidState;
    var registry = try Registry.init(alloc, parent_id);
    errdefer registry.deinit(alloc);
    registry.generation = try unsigned(root, "generation");
    const children = try alloc.alloc(Child, values.array.items.len);
    var built: usize = 0;
    var children_owned = true;
    errdefer if (children_owned) {
        for (children[0..built]) |*child| child.deinit(alloc);
        alloc.free(children);
    };
    for (values.array.items) |value| {
        children[built] = try parseChild(alloc, value, version);
        built += 1;
    }
    registry.children = children;
    children_owned = false;
    try validateRegistry(registry);
    return registry;
}

fn parseChild(alloc: Allocator, value: std.json.Value, version: u64) !Child {
    const source = try object(value);
    const fields = [_][]const u8{ "id", "kind", "persistent", "phase", "work_generation", "active", "last_work_id", "last_request_fingerprint", "last_outcome", "last_failure" };
    try exactFields(source, fields[0..if (version == 1) fields.len - 1 else fields.len]);
    const failure: ?types.ModelFailureDiagnostic = if (version == schema_version) blk: {
        const raw = (try optionalString(source, "last_failure")) orelse break :blk null;
        if (raw.len == 0 or raw.len > types.ModelFailureDiagnostic.max_bytes or
            !text_utils.isTerminalSafe(raw)) return error.InvalidState;
        break :blk types.ModelFailureDiagnostic.init(raw);
    } else null;
    const id_value = try string(source, "id");
    domain.validateId(id_value) catch return error.InvalidState;
    const kind_name = try string(source, "kind");
    const phase = std.meta.stringToEnum(Phase, try string(source, "phase")) orelse return error.InvalidState;
    const persistent_value = source.get("persistent") orelse return error.InvalidState;
    var kind = if (std.mem.eql(u8, kind_name, "one_off")) blk: {
        if (persistent_value != .null) return error.InvalidState;
        break :blk Kind.one_off;
    } else if (std.mem.eql(u8, kind_name, "persistent"))
        Kind{ .persistent = try parsePersistent(alloc, persistent_value) }
    else
        return error.InvalidState;
    errdefer switch (kind) {
        .one_off => {},
        .persistent => |*persistent| persistent.deinit(alloc),
    };
    var active = if (source.get("active")) |active_value|
        if (active_value == .null) null else try parseActive(alloc, active_value)
    else
        return error.InvalidState;
    errdefer if (active) |*item| item.deinit(alloc);
    return .{
        .id = try alloc.dupe(u8, id_value),
        .kind = kind,
        .phase = phase,
        .work_generation = try unsigned(source, "work_generation"),
        .active = active,
        .last_work_id = try optionalStringAlloc(alloc, source, "last_work_id"),
        .last_request_fingerprint = if (try optionalString(source, "last_request_fingerprint")) |raw|
            try parseFingerprint(raw)
        else
            null,
        .last_outcome = if (try optionalString(source, "last_outcome")) |raw|
            std.meta.stringToEnum(Outcome, raw) orelse return error.InvalidState
        else
            null,
        .last_failure = failure,
    };
}

fn parsePersistent(alloc: Allocator, value: std.json.Value) !PersistentIdentity {
    const source = try object(value);
    try exactFields(source, &.{ "agent", "instructions" });
    const agent = try string(source, "agent");
    if (!domain.validAgentName(agent)) return error.InvalidState;
    const instructions = try string(source, "instructions");
    if (!domain.validInstructions(instructions)) return error.InvalidState;
    const owned_agent = try alloc.dupe(u8, agent);
    errdefer alloc.free(owned_agent);
    const owned_instructions: []u8 = if (instructions.len == 0)
        &.{}
    else
        try alloc.dupe(u8, instructions);
    return .{
        .agent = owned_agent,
        .instructions = owned_instructions,
    };
}

fn parseActive(alloc: Allocator, value: std.json.Value) !ActiveWork {
    const source = try object(value);
    try exactFields(source, &.{ "id", "request_fingerprint", "message", "root_user_intent_context", "root_user_messages", "root_user_evidence_complete", "permission_mode", "created_at_ms" });
    const messages_value = source.get("root_user_messages") orelse return error.InvalidState;
    if (messages_value != .array or messages_value.array.items.len > domain.max_admission_items) return error.InvalidState;
    const messages = try alloc.alloc([]u8, messages_value.array.items.len);
    var built: usize = 0;
    errdefer {
        for (messages[0..built]) |message| alloc.free(message);
        alloc.free(messages);
    }
    for (messages_value.array.items) |message| {
        if (message != .string) return error.InvalidState;
        messages[built] = try alloc.dupe(u8, message.string);
        built += 1;
    }
    const evidence = source.get("root_user_evidence_complete") orelse return error.InvalidState;
    if (evidence != .bool) return error.InvalidState;
    const created = source.get("created_at_ms") orelse return error.InvalidState;
    if (created != .integer) return error.InvalidState;
    return .{
        .id = try alloc.dupe(u8, try string(source, "id")),
        .request_fingerprint = try parseFingerprint(try string(source, "request_fingerprint")),
        .message = try alloc.dupe(u8, try string(source, "message")),
        .root_user_intent_context = try alloc.dupe(u8, try string(source, "root_user_intent_context")),
        .root_user_messages = messages,
        .root_user_evidence_complete = evidence.bool,
        .permission_mode = std.meta.stringToEnum(
            types.PermissionMode,
            try string(source, "permission_mode"),
        ) orelse return error.InvalidState,
        .created_at_ms = created.integer,
    };
}

fn validateRegistry(registry: Registry) !void {
    for (registry.children, 0..) |child, index| {
        switch (child.kind) {
            .one_off => {},
            .persistent => |persistent| {
                if (!domain.validAgentName(persistent.agent) or
                    !domain.validInstructions(persistent.instructions))
                {
                    return error.InvalidState;
                }
            },
        }
        if ((child.phase == .running or child.phase == .awaiting_approval) != (child.active != null)) return error.InvalidState;
        if (child.last_failure) |*failure| {
            if (child.last_outcome != .failed or child.last_work_id == null or
                failure.view().len == 0 or !text_utils.isTerminalSafe(failure.view())) return error.InvalidState;
        }
        for (registry.children[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, child.id)) return error.InvalidState;
            if (child.agentName()) |agent| {
                if (prior.agentName()) |prior_agent| {
                    if (std.mem.eql(u8, prior_agent, agent)) return error.InvalidState;
                }
            }
        }
    }
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidState;
}

fn exactFields(source: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
        } else return error.InvalidState;
    }
    if (source.count() != allowed.len) return error.InvalidState;
}

fn string(source: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = source.get(name) orelse return error.InvalidState;
    return if (value == .string) value.string else error.InvalidState;
}

fn optionalString(source: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = source.get(name) orelse return error.InvalidState;
    return switch (value) {
        .null => null,
        .string => value.string,
        else => error.InvalidState,
    };
}

fn optionalStringAlloc(alloc: Allocator, source: std.json.ObjectMap, name: []const u8) !?[]u8 {
    return if (try optionalString(source, name)) |value| try alloc.dupe(u8, value) else null;
}

fn unsigned(source: std.json.ObjectMap, name: []const u8) !u64 {
    const value = source.get(name) orelse return error.InvalidState;
    if (value != .integer or value.integer < 0) return error.InvalidState;
    return @intCast(value.integer);
}

fn parseFingerprint(raw: []const u8) ![32]u8 {
    if (raw.len != 64) return error.InvalidState;
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidState;
    return result;
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| try std.json.Stringify.value(text, .{}, writer) else try writer.writeAll("null");
}

fn cloneStrings(alloc: Allocator, source: []const []u8) ![][]u8 {
    const result = try alloc.alloc([]u8, source.len);
    var built: usize = 0;
    errdefer {
        for (result[0..built]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (source) |value| {
        result[built] = try alloc.dupe(u8, value);
        built += 1;
    }
    return result;
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

test "subagent failure state survives reload and is replaced only by matching work" {
    const alloc = std.testing.allocator;
    const parent_id = "01J00000000000000000000000";
    const child_id = "01J00000000000000000000001";
    var registry = try Registry.init(alloc, parent_id);
    defer registry.deinit(alloc);
    var active = ActiveWork{
        .id = try alloc.dupe(u8, "work-1"),
        .message = try alloc.dupe(u8, "review"),
        .created_at_ms = 1,
    };
    defer active.deinit(alloc);
    try registry.appendPersistent(alloc, child_id, "reviewer", "", active);
    const failure = types.ModelFailureDiagnostic.init("agent_turn_failed: SessionCommitFailed");
    try std.testing.expectError(error.StaleWork, registry.finish(alloc, child_id, "other", .failed, failure));
    try registry.finish(alloc, child_id, "work-1", .failed, failure);
    const encoded = try renderRegistry(alloc, registry);
    defer alloc.free(encoded);
    var restored = try parseRegistry(alloc, encoded, parent_id);
    defer restored.deinit(alloc);
    try std.testing.expectEqualStrings(failure.view(), restored.children[0].last_failure.?.view());

    alloc.free(active.id);
    active.id = try alloc.dupe(u8, "work-2");
    _ = try restored.startPersistentWork(alloc, "reviewer", null, active);
    try std.testing.expectError(error.StaleWork, restored.finish(alloc, child_id, "work-1", .failed, failure));
    try restored.finish(alloc, child_id, "work-2", .completed, null);
    try std.testing.expect(restored.children[0].last_failure == null);
    restored.children[0].last_failure = failure;
    try std.testing.expectError(error.InvalidState, validateRegistry(restored));
}

test "subagent failure codec reads historical absence and rejects invalid detail" {
    const alloc = std.testing.allocator;
    const parent_id = "01J00000000000000000000000";
    const legacy =
        \\{"schema_version":1,"parent_id":"01J00000000000000000000000","generation":1,"children":[{"id":"01J00000000000000000000001","kind":"one_off","persistent":null,"phase":"finished","work_generation":1,"active":null,"last_work_id":"work-1","last_request_fingerprint":"0000000000000000000000000000000000000000000000000000000000000000","last_outcome":"failed"}]}
    ;
    var restored = try parseRegistry(alloc, legacy, parent_id);
    defer restored.deinit(alloc);
    try std.testing.expect(restored.children[0].last_failure == null);
    const encoded = try renderRegistry(alloc, restored);
    defer alloc.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
    defer parsed.deinit();
    const record = &parsed.value.object.getPtr("children").?.array.items[0];
    const bad_values = [_]std.json.Value{
        .{ .string = text_utils.repeat("x", types.ModelFailureDiagnostic.max_bytes + 1) },
        .{ .string = "unsafe\x1b[31m" },
        .{ .integer = 7 },
    };
    for (bad_values) |bad| {
        record.object.getPtr("last_failure").?.* = bad;
        const invalid = try std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
        defer alloc.free(invalid);
        try std.testing.expectError(error.InvalidState, parseRegistry(alloc, invalid, parent_id));
    }
    parsed.value.object.getPtr("schema_version").?.* = .{ .integer = 99 };
    const future = try std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
    defer alloc.free(future);
    try std.testing.expectError(error.UnsupportedSchema, parseRegistry(alloc, future, parent_id));
}

test "parent child state round trips only required delegation state" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "01J00000000000000000000000");
    defer registry.deinit(alloc);
    var active = ActiveWork{
        .id = try alloc.dupe(u8, "work-1"),
        .message = try alloc.dupe(u8, "review this"),
        .created_at_ms = 1,
    };
    defer active.deinit(alloc);
    try registry.appendPersistent(
        alloc,
        "01J00000000000000000000001",
        "reviewer",
        "Review carefully.",
        active,
    );
    const encoded = try renderRegistry(alloc, registry);
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "relationship") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "notification") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "cursor") == null);
    var decoded = try parseRegistry(alloc, encoded, registry.parent_id);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), decoded.children.len);
    try std.testing.expectEqualStrings("reviewer", decoded.children[0].agentName().?);
    try std.testing.expectEqualStrings("Review carefully.", decoded.children[0].instructions());
    try std.testing.expectEqual(Phase.running, decoded.children[0].phase);
}

test "interrupted active work clears ownership and remains round trippable" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "01J00000000000000000000000");
    defer registry.deinit(alloc);
    var active = ActiveWork{
        .id = try alloc.dupe(u8, "work-1"),
        .request_fingerprint = @as([32]u8, @splat(7)),
        .message = try alloc.dupe(u8, "review this"),
        .created_at_ms = 1,
    };
    defer active.deinit(alloc);
    try registry.appendPersistent(
        alloc,
        "01J00000000000000000000001",
        "reviewer",
        "Review carefully.",
        active,
    );

    registry.interruptActive(alloc);

    const child = registry.children[0];
    try std.testing.expectEqual(Phase.interrupted, child.phase);
    try std.testing.expect(child.active == null);
    try std.testing.expectEqualStrings("work-1", child.last_work_id.?);
    try std.testing.expectEqual(@as([32]u8, @splat(7)), child.last_request_fingerprint.?);
    try std.testing.expectEqual(Outcome.interrupted, child.last_outcome.?);
    const encoded = try renderRegistry(alloc, registry);
    defer alloc.free(encoded);
    var decoded = try parseRegistry(alloc, encoded, registry.parent_id);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(Phase.interrupted, decoded.children[0].phase);
    try std.testing.expect(decoded.children[0].active == null);
}

test "invalid registry state returns an error without duplicate cleanup" {
    const alloc = std.testing.allocator;
    const invalid =
        \\{"schema_version":1,"parent_id":"01J00000000000000000000000","generation":1,"children":[{"id":"01J00000000000000000000001","kind":"persistent","persistent":{"agent":"reviewer","instructions":""},"phase":"interrupted","work_generation":1,"active":{"id":"work-1","request_fingerprint":"0000000000000000000000000000000000000000000000000000000000000000","message":"review","root_user_intent_context":"","root_user_messages":[],"root_user_evidence_complete":true,"permission_mode":"auto","created_at_ms":1},"last_work_id":null,"last_request_fingerprint":null,"last_outcome":null}]}
    ;
    try std.testing.expectError(
        error.InvalidState,
        parseRegistry(alloc, invalid, "01J00000000000000000000000"),
    );
}

test "persistent state derives create continue busy and terminal transitions" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "01J00000000000000000000000");
    defer registry.deinit(alloc);
    var first = ActiveWork{
        .id = try alloc.dupe(u8, "work-1"),
        .message = try alloc.dupe(u8, "first"),
        .created_at_ms = 1,
    };
    defer first.deinit(alloc);
    try registry.appendPersistent(
        alloc,
        "01J00000000000000000000001",
        "reviewer",
        "Review carefully.",
        first,
    );
    try std.testing.expectError(
        error.ChildBusy,
        registry.startPersistentWork(
            alloc,
            "reviewer",
            "Must not replace while busy.",
            first,
        ),
    );
    try std.testing.expectEqualStrings(
        "Review carefully.",
        registry.children[0].instructions(),
    );
    try registry.finish(alloc, registry.children[0].id, "work-1", .completed, null);
    var second = ActiveWork{
        .id = try alloc.dupe(u8, "work-2"),
        .message = try alloc.dupe(u8, "second"),
        .created_at_ms = 2,
    };
    defer second.deinit(alloc);
    const child = try registry.startPersistentWork(alloc, "reviewer", null, second);
    try std.testing.expectEqual(Phase.running, child.phase);
    try std.testing.expectEqual(@as(u64, 2), child.work_generation);
    try std.testing.expectEqualStrings("Review carefully.", child.instructions());
    try registry.finish(alloc, child.id, "work-2", .completed, null);
    var third = ActiveWork{
        .id = try alloc.dupe(u8, "work-3"),
        .message = try alloc.dupe(u8, "third"),
        .created_at_ms = 3,
    };
    defer third.deinit(alloc);
    const replaced = try registry.startPersistentWork(
        alloc,
        "reviewer",
        "Audit security only.",
        third,
    );
    try std.testing.expectEqualStrings(
        "Audit security only.",
        replaced.instructions(),
    );
}

fn testWork(alloc: Allocator, id: []const u8, fingerprint_byte: u8) !ActiveWork {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    return .{
        .id = owned_id,
        .message = try alloc.dupe(u8, "do the work"),
        .request_fingerprint = @as([32]u8, @splat(fingerprint_byte)),
        .created_at_ms = 1,
    };
}

fn advance(alloc: Allocator, old: *Registry, next: Registry) void {
    old.deinit(alloc);
    old.* = next;
}

test "a v2 registry change writes only the child lines it implies (D22)" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const parent_id = "01J00000000000000000000000";
    const one_off = "01J00000000000000000000001";
    const named = "01J00000000000000000000002";
    var old = try Registry.init(alloc, parent_id);
    defer old.deinit(alloc);

    // A new one-off child: one spawn, without a name.
    var next = try old.clone(alloc);
    var first = try testWork(alloc, "work-1", 0xab);
    defer first.deinit(alloc);
    try next.appendOneOff(alloc, one_off, first);
    var lines = try planLines(a, old, next);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings(one_off, lines[0].spawned.child);
    try std.testing.expectEqualStrings("work-1", lines[0].spawned.work_id);
    const spawn = try std.json.parseFromSliceLeaky(SpawnData, a, lines[0].spawned.data.?, .{});
    try std.testing.expect(spawn.agent == null);
    try std.testing.expectEqualStrings(text_utils.repeat("ab", 32), spawn.fingerprint);
    advance(alloc, &old, next);

    // A change of phase alone writes nothing.
    next = try old.clone(alloc);
    next.children[0].phase = .awaiting_approval;
    lines = try planLines(a, old, next);
    try std.testing.expectEqual(@as(usize, 0), lines.len);
    advance(alloc, &old, next);

    // A failure: one finish that carries its text.
    next = try old.clone(alloc);
    try next.finish(alloc, one_off, "work-1", .failed, types.ModelFailureDiagnostic.init("boom"));
    lines = try planLines(a, old, next);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(session_adapter.ChildOutcome.failed, lines[0].finished.outcome);
    const finish = try std.json.parseFromSliceLeaky(FinishData, a, lines[0].finished.data.?, .{});
    try std.testing.expectEqualStrings("boom", finish.failure.?);
    advance(alloc, &old, next);

    // A named child: its spawn carries its name.
    next = try old.clone(alloc);
    var second = try testWork(alloc, "work-2", 0xcd);
    defer second.deinit(alloc);
    try next.appendPersistent(alloc, named, "reviewer", "Be brief.", second);
    lines = try planLines(a, old, next);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("reviewer", (try std.json.parseFromSliceLeaky(SpawnData, a, lines[0].spawned.data.?, .{})).agent.?);
    advance(alloc, &old, next);

    // Its finish and its next work in one save: the finish comes first.
    next = try old.clone(alloc);
    try next.finish(alloc, named, "work-2", .completed, null);
    var third = try testWork(alloc, "work-3", 0xef);
    defer third.deinit(alloc);
    _ = try next.startPersistentWork(alloc, "reviewer", null, third);
    lines = try planLines(a, old, next);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("work-2", lines[0].finished.work_id);
    try std.testing.expectEqual(session_adapter.ChildOutcome.ok, lines[0].finished.outcome);
    try std.testing.expect(lines[0].finished.data == null);
    try std.testing.expectEqualStrings("work-3", lines[1].spawned.work_id);
    advance(alloc, &old, next);

    // A child never disappears, and only the manager records `lost`.
    var empty = try Registry.init(alloc, parent_id);
    defer empty.deinit(alloc);
    try std.testing.expectError(error.InvalidState, planLines(a, old, empty));
    var lost = try old.clone(alloc);
    defer lost.deinit(alloc);
    try lost.finish(alloc, named, "work-3", .completed, null);
    lost.children[1].last_outcome = .lost;
    try std.testing.expectError(error.InvalidState, planLines(a, old, lost));
}

test "a v2 parent's folded children rebuild the registry v1 would hold (D22)" {
    const alloc = std.testing.allocator;
    const parent_id = "01J00000000000000000000000";
    const fingerprint = text_utils.repeat("ab", 32);
    var folded = [_]session_adapter.Child{
        .{ .id = @constCast("01J00000000000000000000001"), .work_id = @constCast("w1"), .open = false, .outcome = .ok, .spawn_data = @constCast("{\"fingerprint\":\"" ++ fingerprint ++ "\",\"later\":1}"), .finish_data = null, .seq = 5 },
        .{ .id = @constCast("01J00000000000000000000002"), .work_id = @constCast("w2"), .open = false, .outcome = .failed, .spawn_data = @constCast("{\"agent\":\"reviewer\",\"fingerprint\":\"" ++ fingerprint ++ "\"}"), .finish_data = @constCast("{\"failure\":\"boom\"}"), .seq = 9 },
        .{ .id = @constCast("01J00000000000000000000003"), .work_id = @constCast("w3"), .open = false, .outcome = .lost, .spawn_data = @constCast("{\"agent\":\"writer\",\"fingerprint\":\"" ++ fingerprint ++ "\"}"), .finish_data = null, .seq = 7 },
    };
    var registry = try registryFromChildren(alloc, parent_id, &folded);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 9), registry.generation);
    try std.testing.expectEqual(@as(usize, 3), registry.children.len);
    const one_off = registry.children[0];
    try std.testing.expect(one_off.kind == .one_off);
    try std.testing.expectEqual(Phase.finished, one_off.phase);
    try std.testing.expectEqual(Outcome.completed, one_off.last_outcome.?);
    try std.testing.expectEqualStrings("w1", one_off.last_work_id.?);
    try std.testing.expectEqual(@as([32]u8, @splat(0xab)), one_off.last_request_fingerprint.?);
    try std.testing.expectEqual(@as(u64, 5), one_off.work_generation);
    try std.testing.expect(one_off.active == null);
    const failed = registry.children[1];
    try std.testing.expectEqualStrings("reviewer", failed.agentName().?);
    try std.testing.expectEqualStrings("", failed.instructions());
    try std.testing.expectEqual(Phase.idle, failed.phase);
    try std.testing.expectEqualStrings("boom", failed.last_failure.?.view());
    // A named child lost before its first turn can take new work (D33).
    const lost = registry.children[2];
    try std.testing.expectEqual(Phase.interrupted, lost.phase);
    try std.testing.expectEqual(Outcome.lost, lost.last_outcome.?);

    // Open work, an unreadable spawn, or a failure on another outcome is refused.
    var bad = folded[1];
    bad.open = true;
    try std.testing.expectError(error.InvalidState, registryFromChildren(alloc, parent_id, &.{bad}));
    bad = folded[1];
    bad.spawn_data = @constCast("{\"agent\":\"reviewer\"}");
    try std.testing.expectError(error.InvalidState, registryFromChildren(alloc, parent_id, &.{bad}));
    bad = folded[1];
    bad.outcome = .ok;
    try std.testing.expectError(error.InvalidState, registryFromChildren(alloc, parent_id, &.{bad}));
    bad = folded[1];
    bad.spawn_data = @constCast("{\"agent\":\"Bad Name\",\"fingerprint\":\"" ++ fingerprint ++ "\"}");
    try std.testing.expectError(error.InvalidState, registryFromChildren(alloc, parent_id, &.{bad}));
}

test "v2 children live in the parent's log and come back after a reopen (D22)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try session_adapter.Store.open(alloc, home);
    defer store.deinit(alloc);
    var model = "test-model".*;
    const seed: session_adapter.Seed = .{
        .preferences = .{ .model = &model, .effort = .auto, .fast_mode = false },
        .language = types.ConversationLanguage.default(),
        .permission_state = .{},
    };
    const parent = try session_adapter.Session.create(alloc, &store, "/w", .ask, seed);
    var parent_open = true;
    defer if (parent_open) parent.close();
    try parent.commitTurn(.{ .assistant = .{ .user = .{ .text = @constCast("delegate") }, .assistant = @constCast("ok") } }, types.ConversationLanguage.default());
    const parent_id = try alloc.dupe(u8, parent.id());
    defer alloc.free(parent_id);
    const child_id = "1786460757753-kid";
    {
        var children = V2Children.init(alloc, parent, "/w");
        defer children.deinit();
        const state_store = Store{ .backend = .{ .v2 = &children }, .parent_id = parent_id };
        var lock = try state_store.acquireLock(alloc);
        defer lock.release();
        var registry = try state_store.load(alloc);
        defer registry.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), registry.children.len);
        var work = try testWork(alloc, "work-1", 0x11);
        defer work.deinit(alloc);
        try registry.appendPersistent(alloc, child_id, "reviewer", "", work);
        try state_store.save(alloc, registry);
        try registry.finish(alloc, child_id, "work-1", .completed, null);
        try state_store.save(alloc, registry);
        // A v2 child needs no marker file: its own first line says it is one.
        try state_store.markChildSession(alloc, child_id);

        try children.rememberSeed(child_id, .{ .preferences = seed.preferences, .language = seed.language });
        var copy = (try children.seedFor(alloc, child_id)).?;
        defer copy.preferences.deinit(alloc);
        try std.testing.expectEqualStrings("test-model", copy.preferences.model);
        try std.testing.expect((try children.seedFor(alloc, "1786460757753-none")) == null);
    }
    parent.close();
    parent_open = false;

    const reopened = try session_adapter.Session.resumeSession(alloc, &store, .{ .id = parent_id }, "/w", .ask);
    defer reopened.close();
    var children = V2Children.init(alloc, reopened, "/w");
    defer children.deinit();
    const state_store = Store{ .backend = .{ .v2 = &children }, .parent_id = parent_id };
    var registry = try state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), registry.children.len);
    const child = registry.children[0];
    try std.testing.expectEqualStrings(child_id, child.id);
    try std.testing.expectEqualStrings("reviewer", child.agentName().?);
    try std.testing.expectEqual(Phase.idle, child.phase);
    try std.testing.expectEqualStrings("work-1", child.last_work_id.?);
    try std.testing.expectEqual(Outcome.completed, child.last_outcome.?);
    try std.testing.expectEqual(@as([32]u8, @splat(0x11)), child.last_request_fingerprint.?);
}

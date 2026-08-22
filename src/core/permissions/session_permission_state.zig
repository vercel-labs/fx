const std = @import("std");

const Allocator = std.mem.Allocator;

const legacy_schema_version: u8 = 1;
pub const schema_version: u8 = 2;
pub const max_rules: usize = 1024;
pub const max_identity_bytes: usize = 4096;
pub const max_display_identity_bytes: usize = 4096;

pub const RuleId = struct {
    value: u64,
};

pub const RuleKey = struct {
    pub const Kind = enum {
        command,
        file_mutation,
        structured_tool,
    };

    kind: Kind,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    canonical: []const u8,

    pub fn init(kind: Kind, canonical: []const u8) !RuleKey {
        if (canonical.len == 0 or canonical.len > max_identity_bytes) {
            return error.InvalidPermissionIdentity;
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
        return .{
            .kind = kind,
            .digest = digest,
            .canonical = canonical,
        };
    }

    pub fn eql(a: RuleKey, b: RuleKey) bool {
        return a.kind == b.kind and
            std.mem.eql(u8, &a.digest, &b.digest) and
            std.mem.eql(u8, a.canonical, b.canonical);
    }
};

pub const Decision = enum {
    allow,
    deny,
};

pub const StateDecision = enum {
    allow,
    deny,
    unresolved,
};

pub const Rule = struct {
    id: RuleId,
    key: RuleKey,
    display_identity: []u8,
    decision: Decision,
    generation: u64,

    fn deinit(self: *Rule, alloc: Allocator) void {
        alloc.free(@constCast(self.key.canonical));
        alloc.free(self.display_identity);
        self.* = undefined;
    }
};

pub const State = struct {
    version: u8 = schema_version,
    next_generation: u64 = 1,
    rules: std.ArrayList(Rule) = .empty,

    pub fn deinit(self: *State, alloc: Allocator) void {
        for (self.rules.items) |*rule| rule.deinit(alloc);
        self.rules.deinit(alloc);
        self.* = .{};
    }
};

pub fn validate(state: State) !void {
    return validateSchema(state, schema_version);
}

pub fn validateSchema(state: State, expected_version: u8) !void {
    if (state.version != expected_version or
        state.next_generation == 0 or
        state.rules.items.len > max_rules)
    {
        return error.InvalidPermissionState;
    }
    for (state.rules.items, 0..) |rule, index| {
        if (rule.id.value == 0 or
            rule.generation == 0 or
            rule.id.value > rule.generation or
            rule.id.value >= state.next_generation or
            rule.generation >= state.next_generation or
            rule.key.canonical.len == 0 or
            rule.key.canonical.len > max_identity_bytes or
            rule.display_identity.len == 0 or
            rule.display_identity.len > max_display_identity_bytes)
        {
            return error.InvalidPermissionState;
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(rule.key.canonical, &digest, .{});
        if (!std.mem.eql(u8, &digest, &rule.key.digest)) {
            return error.InvalidPermissionState;
        }
        for (state.rules.items[0..index]) |prior| {
            if (prior.id.value == rule.id.value or RuleKey.eql(prior.key, rule.key)) {
                return error.InvalidPermissionState;
            }
        }
    }
}

const V1CommandIdentity = struct {
    command: []const u8,
    cwd: []const u8,
    background: []const u8,
    backend: []const u8,
    target_os: []const u8,
};

fn readIdentityField(canonical: []const u8, offset: *usize) ![]const u8 {
    const length_end = std.math.add(usize, offset.*, @sizeOf(u64)) catch
        return error.InvalidPermissionIdentity;
    if (length_end > canonical.len) return error.InvalidPermissionIdentity;
    var length_bytes: [@sizeOf(u64)]u8 = undefined;
    @memcpy(&length_bytes, canonical[offset.*..length_end]);
    const length_u64 = std.mem.readInt(u64, &length_bytes, .big);
    const length = std.math.cast(usize, length_u64) orelse
        return error.InvalidPermissionIdentity;
    const value_end = std.math.add(usize, length_end, length) catch
        return error.InvalidPermissionIdentity;
    if (value_end > canonical.len) return error.InvalidPermissionIdentity;
    offset.* = value_end;
    return canonical[length_end..value_end];
}

fn parseV1CommandIdentity(canonical: []const u8) !V1CommandIdentity {
    var offset: usize = 0;
    if (!std.mem.eql(u8, try readIdentityField(canonical, &offset), "fx-permission-state-v1")) {
        return error.InvalidPermissionIdentity;
    }
    const command = try readIdentityField(canonical, &offset);
    const cwd = try readIdentityField(canonical, &offset);
    const background = try readIdentityField(canonical, &offset);
    const backend = try readIdentityField(canonical, &offset);
    const target_os = try readIdentityField(canonical, &offset);
    _ = try readIdentityField(canonical, &offset);
    if (offset != canonical.len or command.len == 0 or cwd.len == 0 or
        target_os.len == 0 or
        (!std.mem.eql(u8, background, "foreground") and
            !std.mem.eql(u8, background, "background")))
    {
        return error.InvalidPermissionIdentity;
    }
    return .{
        .command = command,
        .cwd = cwd,
        .background = background,
        .backend = backend,
        .target_os = target_os,
    };
}

fn writeIdentityField(writer: *std.Io.Writer, value: []const u8) !void {
    const value_len = std.math.cast(u64, value.len) orelse
        return error.InvalidPermissionIdentity;
    var length: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &length, value_len, .big);
    try writer.writeAll(&length);
    try writer.writeAll(value);
}

/// Returns a command key whose canonical bytes belong to `alloc`.
pub fn commandKeyV2(
    alloc: Allocator,
    command: []const u8,
    cwd: []const u8,
    background: []const u8,
    target_os: []const u8,
) !RuleKey {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeIdentityField(&out.writer, "fx-permission-state-v2");
    try writeIdentityField(&out.writer, command);
    try writeIdentityField(&out.writer, cwd);
    try writeIdentityField(&out.writer, background);
    try writeIdentityField(&out.writer, target_os);
    const canonical = try out.toOwnedSlice();
    errdefer alloc.free(canonical);
    return RuleKey.init(.command, canonical);
}

fn migrationRuleIndex(state: State, key: RuleKey) ?usize {
    for (state.rules.items, 0..) |rule, index| {
        if (RuleKey.eql(rule.key, key)) return index;
    }
    return null;
}

fn candidateSuppliesDisplay(candidate: Rule, current: Rule) bool {
    return candidate.generation > current.generation or
        (candidate.generation == current.generation and
            std.mem.order(
                u8,
                candidate.display_identity,
                current.display_identity,
            ) == .lt);
}

fn mergeMigrationCandidate(
    alloc: Allocator,
    migrated: *State,
    source: Rule,
    key: RuleKey,
) !void {
    if (migrationRuleIndex(migrated.*, key)) |index| {
        alloc.free(@constCast(key.canonical));
        const current = &migrated.rules.items[index];
        if (current.decision == .deny and source.decision == .allow) return;
        if (current.decision == .allow and source.decision == .deny) {
            const display_identity = try alloc.dupe(u8, source.display_identity);
            alloc.free(current.display_identity);
            current.display_identity = display_identity;
            current.id = source.id;
            current.generation = source.generation;
            current.decision = .deny;
            return;
        }
        if (candidateSuppliesDisplay(source, current.*)) {
            const display_identity = try alloc.dupe(u8, source.display_identity);
            alloc.free(current.display_identity);
            current.display_identity = display_identity;
        }
        if (source.id.value < current.id.value) current.id = source.id;
        if (source.generation > current.generation) current.generation = source.generation;
        return;
    }

    errdefer alloc.free(@constCast(key.canonical));
    const display_identity = try alloc.dupe(u8, source.display_identity);
    errdefer alloc.free(display_identity);
    try migrated.rules.append(alloc, .{
        .id = source.id,
        .key = key,
        .display_identity = display_identity,
        .decision = source.decision,
        .generation = source.generation,
    });
}

fn ruleIdLessThan(_: void, left: Rule, right: Rule) bool {
    return left.id.value < right.id.value;
}

/// Projects provenance-bearing schema-1 command rules into schema 2.
/// Schema-2 input is cloned unchanged so repeated migration is idempotent.
pub fn migrateV1ToV2(alloc: Allocator, state: State) !State {
    if (state.version == schema_version) {
        try validateSchema(state, schema_version);
        return cloneState(alloc, state);
    }
    try validateSchema(state, legacy_schema_version);

    var migrated: State = .{
        .version = schema_version,
        .next_generation = state.next_generation,
    };
    errdefer migrated.deinit(alloc);
    try migrated.rules.ensureTotalCapacity(alloc, state.rules.items.len);

    for (state.rules.items) |rule| {
        if (rule.key.kind != .command) {
            try appendRuleCopy(alloc, &migrated, rule);
            continue;
        }
        const identity = parseV1CommandIdentity(rule.key.canonical) catch
            return error.InvalidPermissionState;
        if (rule.decision == .allow and
            !std.mem.eql(u8, identity.backend, "none"))
        {
            continue;
        }
        const key = try commandKeyV2(
            alloc,
            identity.command,
            identity.cwd,
            identity.background,
            identity.target_os,
        );
        try mergeMigrationCandidate(alloc, &migrated, rule, key);
    }

    std.mem.sort(Rule, migrated.rules.items, {}, ruleIdLessThan);
    try validateSchema(migrated, schema_version);
    return migrated;
}

pub const SetEvent = struct {
    key: RuleKey,
    display_identity: []const u8,
    decision: Decision,
    expected_generation: ?u64,
};

pub const RevokeEvent = struct {
    id: RuleId,
    expected_generation: u64,
};

pub const ConfirmedRuleEvent = union(enum) {
    set: SetEvent,
    revoke: RevokeEvent,
};

pub const OwnedConfirmedRuleEvent = struct {
    event: ConfirmedRuleEvent,

    pub fn dupe(
        alloc: Allocator,
        event: ConfirmedRuleEvent,
    ) !OwnedConfirmedRuleEvent {
        return .{ .event = switch (event) {
            .revoke => |revoke| .{ .revoke = revoke },
            .set => |set| blk: {
                const canonical = try alloc.dupe(u8, set.key.canonical);
                errdefer alloc.free(canonical);
                const display_identity = try alloc.dupe(u8, set.display_identity);
                break :blk .{ .set = .{
                    .key = .{
                        .kind = set.key.kind,
                        .digest = set.key.digest,
                        .canonical = canonical,
                    },
                    .display_identity = display_identity,
                    .decision = set.decision,
                    .expected_generation = set.expected_generation,
                } };
            },
        } };
    }

    pub fn deinit(self: *OwnedConfirmedRuleEvent, alloc: Allocator) void {
        switch (self.event) {
            .revoke => {},
            .set => |set| {
                alloc.free(@constCast(set.key.canonical));
                alloc.free(@constCast(set.display_identity));
            },
        }
        self.* = undefined;
    }
};

pub const ApplyResult = union(enum) {
    applied: State,
    stale,
    full,
    invalid,

    pub fn takeApplied(self: *ApplyResult) ?State {
        return switch (self.*) {
            .applied => |state| blk: {
                self.* = .invalid;
                break :blk state;
            },
            else => null,
        };
    }
};

pub const ApplyStatus = enum {
    applied,
    stale,
    full,
    invalid,
};

pub fn apply(
    alloc: Allocator,
    state: State,
    event: ConfirmedRuleEvent,
) !ApplyResult {
    validate(state) catch return .invalid;
    return switch (event) {
        .set => |set| applySet(alloc, state, set),
        .revoke => |revoke| applyRevoke(alloc, state, revoke),
    };
}

fn applySet(alloc: Allocator, state: State, event: SetEvent) !ApplyResult {
    if (state.version != schema_version or
        state.next_generation == 0 or
        event.display_identity.len == 0 or
        event.display_identity.len > max_display_identity_bytes or
        event.key.canonical.len == 0 or
        event.key.canonical.len > max_identity_bytes)
    {
        return .invalid;
    }
    const next_generation = std.math.add(u64, state.next_generation, 1) catch
        return .invalid;

    if (keyIndex(state, event.key)) |index| {
        if (event.expected_generation != state.rules.items[index].generation) {
            return .stale;
        }
        const display_identity = try alloc.dupe(u8, event.display_identity);
        errdefer alloc.free(display_identity);
        var next = try cloneState(alloc, state);
        errdefer next.deinit(alloc);
        alloc.free(next.rules.items[index].display_identity);
        next.rules.items[index].display_identity = display_identity;
        next.rules.items[index].decision = event.decision;
        next.rules.items[index].generation = state.next_generation;
        next.next_generation = next_generation;
        return .{ .applied = next };
    }
    if (event.expected_generation != null) return .stale;
    if (state.rules.items.len >= max_rules) return .full;

    var next = try cloneState(alloc, state);
    errdefer next.deinit(alloc);
    const canonical = try alloc.dupe(u8, event.key.canonical);
    errdefer alloc.free(canonical);
    const display_identity = try alloc.dupe(u8, event.display_identity);
    errdefer alloc.free(display_identity);
    try next.rules.append(alloc, .{
        .id = .{ .value = state.next_generation },
        .key = .{
            .kind = event.key.kind,
            .digest = event.key.digest,
            .canonical = canonical,
        },
        .display_identity = display_identity,
        .decision = event.decision,
        .generation = state.next_generation,
    });
    next.next_generation = next_generation;
    return .{ .applied = next };
}

fn cloneState(alloc: Allocator, state: State) !State {
    var copy: State = .{
        .version = state.version,
        .next_generation = state.next_generation,
    };
    errdefer copy.deinit(alloc);
    try copy.rules.ensureTotalCapacity(alloc, state.rules.items.len);
    for (state.rules.items) |rule| {
        try appendRuleCopy(alloc, &copy, rule);
    }
    return copy;
}

pub fn dupe(alloc: Allocator, state: State) !State {
    try validate(state);
    return cloneState(alloc, state);
}

fn appendRuleCopy(alloc: Allocator, state: *State, rule: Rule) !void {
    const canonical = try alloc.dupe(u8, rule.key.canonical);
    errdefer alloc.free(canonical);
    const display_identity = try alloc.dupe(u8, rule.display_identity);
    errdefer alloc.free(display_identity);
    try state.rules.append(alloc, .{
        .id = rule.id,
        .key = .{
            .kind = rule.key.kind,
            .digest = rule.key.digest,
            .canonical = canonical,
        },
        .display_identity = display_identity,
        .decision = rule.decision,
        .generation = rule.generation,
    });
}

fn applyRevoke(
    alloc: Allocator,
    state: State,
    event: RevokeEvent,
) !ApplyResult {
    const index = idIndex(state, event.id) orelse return .stale;
    if (state.rules.items[index].generation != event.expected_generation) {
        return .stale;
    }
    const next_generation = std.math.add(u64, state.next_generation, 1) catch
        return .invalid;
    var next = try cloneState(alloc, state);
    errdefer next.deinit(alloc);
    var removed = next.rules.orderedRemove(index);
    removed.deinit(alloc);
    next.next_generation = next_generation;
    return .{ .applied = next };
}

fn keyIndex(state: State, key: RuleKey) ?usize {
    for (state.rules.items, 0..) |rule, index| {
        if (RuleKey.eql(rule.key, key)) return index;
    }
    return null;
}

fn idIndex(state: State, id: RuleId) ?usize {
    for (state.rules.items, 0..) |rule, index| {
        if (rule.id.value == id.value) return index;
    }
    return null;
}

pub fn ruleForId(state: State, id: RuleId) ?*const Rule {
    for (state.rules.items) |*rule| {
        if (rule.id.value == id.value) return rule;
    }
    return null;
}

pub fn ruleForKey(state: State, key: RuleKey) ?*const Rule {
    const index = keyIndex(state, key) orelse return null;
    return &state.rules.items[index];
}

pub fn decide(state: State, key: RuleKey) StateDecision {
    const index = keyIndex(state, key) orelse return .unresolved;
    return switch (state.rules.items[index].decision) {
        .allow => .allow,
        .deny => .deny,
    };
}

pub fn projectForChild(
    alloc: Allocator,
    state: State,
    delegated_allow_keys: []const RuleKey,
) !State {
    var projected: State = .{
        .version = state.version,
        .next_generation = state.next_generation,
    };
    errdefer projected.deinit(alloc);
    try projected.rules.ensureTotalCapacity(alloc, state.rules.items.len);
    for (state.rules.items) |rule| {
        if (rule.decision == .allow and
            !containsKey(delegated_allow_keys, rule.key))
        {
            continue;
        }
        try appendRuleCopy(alloc, &projected, rule);
    }
    return projected;
}

fn containsKey(keys: []const RuleKey, candidate: RuleKey) bool {
    for (keys) |key| {
        if (RuleKey.eql(key, candidate)) return true;
    }
    return false;
}

test "rule insertion creates a stable nonzero id" {
    const alloc = std.testing.allocator;
    var original: State = .{};
    defer original.deinit(alloc);

    const key = try RuleKey.init(.command, "command\x00git status");
    var result = try apply(alloc, original, .{ .set = .{
        .key = key,
        .display_identity = "git status in /workspace",
        .decision = .deny,
        .expected_generation = null,
    } });
    var next = result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer next.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), original.rules.items.len);
    try std.testing.expectEqual(@as(usize, 1), next.rules.items.len);
    try std.testing.expect(next.rules.items[0].id.value != 0);
    try std.testing.expectEqual(next.rules.items[0].id, ruleForId(next, next.rules.items[0].id).?.id);
}

test "rule replacement preserves id and prior state" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const key = try RuleKey.init(.command, "command\x00git status");

    var inserted_result = try apply(alloc, empty, .{ .set = .{
        .key = key,
        .display_identity = "git status in /workspace",
        .decision = .allow,
        .expected_generation = null,
    } });
    var inserted = inserted_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer inserted.deinit(alloc);
    const original_id = inserted.rules.items[0].id;
    const original_generation = inserted.rules.items[0].generation;

    var replaced_result = try apply(alloc, inserted, .{ .set = .{
        .key = key,
        .display_identity = "git status in /workspace",
        .decision = .deny,
        .expected_generation = original_generation,
    } });
    var replaced = replaced_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer replaced.deinit(alloc);

    try std.testing.expectEqual(Decision.allow, inserted.rules.items[0].decision);
    try std.testing.expectEqual(Decision.deny, replaced.rules.items[0].decision);
    try std.testing.expectEqual(original_id, replaced.rules.items[0].id);
    try std.testing.expect(replaced.rules.items[0].generation > original_generation);
}

test "stale events and generation exhaustion leave state unchanged" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const key = try RuleKey.init(.command, "command\x00git status");
    var inserted_result = try apply(alloc, empty, .{ .set = .{
        .key = key,
        .display_identity = "git status",
        .decision = .deny,
        .expected_generation = null,
    } });
    var inserted = inserted_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer inserted.deinit(alloc);
    const stored = inserted.rules.items[0];

    const stale_set = try apply(alloc, inserted, .{ .set = .{
        .key = key,
        .display_identity = "git status replacement",
        .decision = .allow,
        .expected_generation = stored.generation + 1,
    } });
    try std.testing.expectEqual(
        std.meta.Tag(ApplyResult).stale,
        std.meta.activeTag(stale_set),
    );
    const stale_revoke = try apply(alloc, inserted, .{ .revoke = .{
        .id = stored.id,
        .expected_generation = stored.generation + 1,
    } });
    try std.testing.expectEqual(
        std.meta.Tag(ApplyResult).stale,
        std.meta.activeTag(stale_revoke),
    );
    try std.testing.expectEqual(Decision.deny, inserted.rules.items[0].decision);
    try std.testing.expectEqual(stored.generation, inserted.rules.items[0].generation);

    var exhausted: State = .{ .next_generation = std.math.maxInt(u64) };
    defer exhausted.deinit(alloc);
    const exhausted_result = try apply(alloc, exhausted, .{ .set = .{
        .key = key,
        .display_identity = "git status",
        .decision = .allow,
        .expected_generation = null,
    } });
    try std.testing.expectEqual(
        std.meta.Tag(ApplyResult).invalid,
        std.meta.activeTag(exhausted_result),
    );
    try std.testing.expectEqual(@as(usize, 0), exhausted.rules.items.len);
}

test "rule revocation uses stored id after identity changes" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const original_key = try RuleKey.init(.file_mutation, "file\x00old-preimage");

    var inserted_result = try apply(alloc, empty, .{ .set = .{
        .key = original_key,
        .display_identity = "write_file report.md with old preimage",
        .decision = .deny,
        .expected_generation = null,
    } });
    var inserted = inserted_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer inserted.deinit(alloc);
    const stored = inserted.rules.items[0];

    const changed_key = try RuleKey.init(.file_mutation, "file\x00new-preimage");
    try std.testing.expect(!RuleKey.eql(stored.key, changed_key));

    var revoked_result = try apply(alloc, inserted, .{ .revoke = .{
        .id = stored.id,
        .expected_generation = stored.generation,
    } });
    var revoked = revoked_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer revoked.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), revoked.rules.items.len);
    try std.testing.expect(ruleForId(revoked, stored.id) == null);
}

test "decision matches only the exact canonical key" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const exact = try RuleKey.init(.command, "command\x00/workspace\x00git status");
    var result = try apply(alloc, empty, .{ .set = .{
        .key = exact,
        .display_identity = "git status in /workspace",
        .decision = .allow,
        .expected_generation = null,
    } });
    var state = result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer state.deinit(alloc);

    const neighbor = try RuleKey.init(.command, "command\x00/workspace\x00git status --short");
    try std.testing.expectEqual(StateDecision.allow, decide(state, exact));
    try std.testing.expectEqual(StateDecision.unresolved, decide(state, neighbor));
}

test "child projection preserves denies and filters undelegated allows" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const denied_key = try RuleKey.init(.command, "command\x00denied");
    const allowed_key = try RuleKey.init(.structured_tool, "tool\x00allowed");

    var denied_result = try apply(alloc, empty, .{ .set = .{
        .key = denied_key,
        .display_identity = "denied command",
        .decision = .deny,
        .expected_generation = null,
    } });
    var with_deny = denied_result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer with_deny.deinit(alloc);
    var allowed_result = try apply(alloc, with_deny, .{ .set = .{
        .key = allowed_key,
        .display_identity = "allowed tool",
        .decision = .allow,
        .expected_generation = null,
    } });
    var parent = allowed_result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer parent.deinit(alloc);

    var without_allow = try projectForChild(alloc, parent, &.{});
    defer without_allow.deinit(alloc);
    try std.testing.expectEqual(StateDecision.deny, decide(without_allow, denied_key));
    try std.testing.expectEqual(StateDecision.unresolved, decide(without_allow, allowed_key));

    var with_allow = try projectForChild(alloc, parent, &.{allowed_key});
    defer with_allow.deinit(alloc);
    try std.testing.expectEqual(StateDecision.deny, decide(with_allow, denied_key));
    try std.testing.expectEqual(StateDecision.allow, decide(with_allow, allowed_key));
    try std.testing.expectEqual(@as(usize, 2), parent.rules.items.len);
}

test "state validation rejects duplicate rule ids" {
    const alloc = std.testing.allocator;
    var empty: State = .{};
    defer empty.deinit(alloc);
    const first_key = try RuleKey.init(.command, "command\x00first");
    const second_key = try RuleKey.init(.command, "command\x00second");

    var first_result = try apply(alloc, empty, .{ .set = .{
        .key = first_key,
        .display_identity = "first",
        .decision = .deny,
        .expected_generation = null,
    } });
    var first = first_result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer first.deinit(alloc);
    var second_result = try apply(alloc, first, .{ .set = .{
        .key = second_key,
        .display_identity = "second",
        .decision = .allow,
        .expected_generation = null,
    } });
    var invalid = second_result.takeApplied() orelse return error.TestExpectedAppliedState;
    defer invalid.deinit(alloc);
    invalid.rules.items[1].id = invalid.rules.items[0].id;

    try std.testing.expectError(error.InvalidPermissionState, validate(invalid));
}

test "capacity rejects insertion while preserving replacement" {
    const alloc = std.testing.allocator;
    var state: State = .{ .next_generation = max_rules + 1 };
    defer state.deinit(alloc);
    try state.rules.ensureTotalCapacity(alloc, max_rules);
    for (0..max_rules) |index| {
        const canonical = try std.fmt.allocPrint(alloc, "command-{d}", .{index});
        const key = try RuleKey.init(.command, canonical);
        state.rules.appendAssumeCapacity(.{
            .id = .{ .value = @intCast(index + 1) },
            .key = key,
            .display_identity = try std.fmt.allocPrint(alloc, "command {d}", .{index}),
            .decision = .deny,
            .generation = @intCast(index + 1),
        });
    }
    try validate(state);

    const new_key = try RuleKey.init(.command, "new-command");
    const full = try apply(alloc, state, .{ .set = .{
        .key = new_key,
        .display_identity = "new command",
        .decision = .allow,
        .expected_generation = null,
    } });
    try std.testing.expectEqual(std.meta.Tag(ApplyResult).full, std.meta.activeTag(full));

    const existing = state.rules.items[0];
    var replaced_result = try apply(alloc, state, .{ .set = .{
        .key = existing.key,
        .display_identity = "replacement",
        .decision = .allow,
        .expected_generation = existing.generation,
    } });
    var replaced = replaced_result.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer replaced.deinit(alloc);
    try std.testing.expectEqual(@as(usize, max_rules), replaced.rules.items.len);
    try std.testing.expectEqual(existing.id, replaced.rules.items[0].id);
    try std.testing.expectEqual(Decision.allow, replaced.rules.items[0].decision);
}

fn fixtureIdentity(
    alloc: Allocator,
    fields: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (fields) |field| {
        var length: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(field.len), .big);
        try out.writer.writeAll(&length);
        try out.writer.writeAll(field);
    }
    return out.toOwnedSlice();
}

fn appendFixtureRule(
    alloc: Allocator,
    state: *State,
    id: u64,
    generation: u64,
    kind: RuleKey.Kind,
    canonical: []u8,
    display_identity: []const u8,
    decision: Decision,
) !void {
    errdefer alloc.free(canonical);
    try state.rules.append(alloc, .{
        .id = .{ .value = id },
        .key = try RuleKey.init(kind, canonical),
        .display_identity = try alloc.dupe(u8, display_identity),
        .decision = decision,
        .generation = generation,
    });
}

test "v1 command migration is deny dominant stable and idempotent" {
    const alloc = std.testing.allocator;
    const command = "git status";
    const cwd = "/workspace";
    const foreground = "foreground";
    const macos = "macos";
    const none = "none";
    const target_os = "macos";
    const restricted = "restricted";

    var v1: State = .{ .version = 1, .next_generation = 9 };
    defer v1.deinit(alloc);
    try appendFixtureRule(
        alloc,
        &v1,
        1,
        1,
        .command,
        try fixtureIdentity(alloc, &.{ "fx-permission-state-v1", command, cwd, foreground, none, target_os, restricted }),
        "none allow",
        .allow,
    );
    try appendFixtureRule(
        alloc,
        &v1,
        2,
        2,
        .command,
        try fixtureIdentity(alloc, &.{ "fx-permission-state-v1", command, cwd, foreground, macos, target_os, restricted }),
        "macos deny",
        .deny,
    );
    try appendFixtureRule(
        alloc,
        &v1,
        4,
        4,
        .command,
        try fixtureIdentity(alloc, &.{ "fx-permission-state-v1", "git diff", cwd, foreground, macos, target_os, restricted }),
        "older deny",
        .deny,
    );
    try appendFixtureRule(
        alloc,
        &v1,
        3,
        5,
        .command,
        try fixtureIdentity(alloc, &.{ "fx-permission-state-v1", "git diff", cwd, foreground, none, target_os, restricted }),
        "newer deny",
        .deny,
    );
    try appendFixtureRule(
        alloc,
        &v1,
        6,
        6,
        .command,
        try fixtureIdentity(alloc, &.{ "fx-permission-state-v1", "pwd", cwd, foreground, none, target_os, restricted }),
        "eligible allow",
        .allow,
    );
    try appendFixtureRule(
        alloc,
        &v1,
        7,
        7,
        .command,
        try fixtureIdentity(alloc, &.{ "fx-permission-state-v1", "ps", cwd, foreground, macos, target_os, restricted }),
        "ineligible allow",
        .allow,
    );
    const tool_canonical = try alloc.dupe(u8, "structured-tool-v1");
    try appendFixtureRule(
        alloc,
        &v1,
        8,
        8,
        .structured_tool,
        tool_canonical,
        "unchanged tool",
        .deny,
    );

    var migrated = try migrateV1ToV2(alloc, v1);
    defer migrated.deinit(alloc);
    try validateSchema(migrated, 2);
    try std.testing.expectEqual(@as(u8, 2), migrated.version);
    try std.testing.expectEqual(@as(u64, 9), migrated.next_generation);
    try std.testing.expectEqual(@as(usize, 4), migrated.rules.items.len);
    try std.testing.expectEqualSlices(u64, &.{ 2, 3, 6, 8 }, &.{
        migrated.rules.items[0].id.value,
        migrated.rules.items[1].id.value,
        migrated.rules.items[2].id.value,
        migrated.rules.items[3].id.value,
    });

    const status_key_bytes = try fixtureIdentity(alloc, &.{ "fx-permission-state-v2", command, cwd, foreground, target_os });
    defer alloc.free(status_key_bytes);
    const status_key = try RuleKey.init(.command, status_key_bytes);
    const status_rule = ruleForKey(migrated, status_key) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Decision.deny, status_rule.decision);
    try std.testing.expectEqualStrings("macos deny", status_rule.display_identity);

    const diff_key_bytes = try fixtureIdentity(alloc, &.{ "fx-permission-state-v2", "git diff", cwd, foreground, target_os });
    defer alloc.free(diff_key_bytes);
    const diff_key = try RuleKey.init(.command, diff_key_bytes);
    const diff_rule = ruleForKey(migrated, diff_key) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Decision.deny, diff_rule.decision);
    try std.testing.expectEqual(@as(u64, 3), diff_rule.id.value);
    try std.testing.expectEqual(@as(u64, 5), diff_rule.generation);
    try std.testing.expectEqualStrings("newer deny", diff_rule.display_identity);

    const pwd_key_bytes = try fixtureIdentity(alloc, &.{ "fx-permission-state-v2", "pwd", cwd, foreground, target_os });
    defer alloc.free(pwd_key_bytes);
    const pwd_key = try RuleKey.init(.command, pwd_key_bytes);
    try std.testing.expectEqual(StateDecision.allow, decide(migrated, pwd_key));
    try std.testing.expectEqual(RuleKey.Kind.structured_tool, migrated.rules.items[3].key.kind);
    try std.testing.expectEqualStrings("structured-tool-v1", migrated.rules.items[3].key.canonical);

    var second = try migrateV1ToV2(alloc, migrated);
    defer second.deinit(alloc);
    try validateSchema(second, 2);
    try std.testing.expectEqual(@as(usize, migrated.rules.items.len), second.rules.items.len);
    for (migrated.rules.items, second.rules.items) |expected, actual| {
        try std.testing.expectEqual(expected.id, actual.id);
        try std.testing.expectEqual(expected.generation, actual.generation);
        try std.testing.expectEqual(expected.decision, actual.decision);
        try std.testing.expect(RuleKey.eql(expected.key, actual.key));
        try std.testing.expectEqualStrings(expected.display_identity, actual.display_identity);
    }
}

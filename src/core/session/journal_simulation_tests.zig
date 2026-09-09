//! Bounded deterministic reference simulation, NOT a second production runtime.
//! Uses the real append/ack primitive; everything above opaque bytes is a small
//! test-only policy. Positive controls plus counterexamples explain why each
//! boundary is needed. Passing this model does not discharge the red core tests.
const std = @import("std");
const journal = @import("journal.zig");
const Entry = enum(u8) { start, decision, result_a, result_b, final, end };
const Replay = enum { safe, blocked };
const Ack = enum { commit, before_write, lost_ack };

const Store = struct {
    cursor: journal.Cursor = .{},
    records: [16]Entry = undefined,
    len: usize = 0,
    ack: Ack = .commit,
    started: bool = false,
    decision: bool = false,
    results: [2]bool = .{ false, false },
    final: bool = false,
    ended: bool = false,
    // Independent external transaction: receipt and effect commit together.
    receipts: [2]bool = .{ false, false },
    effects: [2]usize = .{ 0, 0 },
    invocations: [2]usize = .{ 0, 0 },
    provider_requests: usize = 0,

    fn host(self: *Store) journal.Host {
        return .{ .context = self, .append_fn = append };
    }

    fn append(raw: *anyopaque, request: journal.Append) journal.Outcome {
        const self: *Store = @ptrCast(@alignCast(raw));
        if (!std.meta.eql(request.expected, self.cursor)) return .conflict;
        if (self.ack == .before_write) return .{ .not_written = error.BeforeWrite };
        const entry: Entry = @enumFromInt(request.bytes[0]);
        self.records[self.len] = entry;
        self.len += 1;
        self.cursor = request.next;
        switch (entry) {
            .start => self.started = true,
            .decision => self.decision = true,
            .result_a => self.results[0] = true,
            .result_b => self.results[1] = true,
            .final => self.final = true,
            .end => self.ended = true,
        }
        return if (self.ack == .lost_ack) .{ .uncertain = error.LostAck } else .{ .committed = request.next };
    }
};

const Machine = struct {
    store: *Store,
    log: journal.Journal,
    recovering: bool,
    clock: usize = 0,
    crash_at: ?usize = null,
    ignore_receipt: bool = false,
    ignore_blocked: bool = false,
    optimistic: bool = false,

    fn init(store: *Store, recovering: bool) !Machine {
        return .{ .store = store, .log = try journal.Journal.init(store.cursor), .recovering = recovering };
    }

    fn boundary(self: *Machine) !void {
        const now = self.clock;
        self.clock += 1;
        if (self.crash_at == now) return error.Crash;
    }

    fn persist(self: *Machine, entry: Entry) !void {
        try self.boundary();
        const seq = self.log.cursor.seq + 1;
        _ = try self.log.append(self.store.host(), seq, seq, &.{@intFromEnum(entry)});
        try self.boundary();
    }

    fn effect(self: *Machine, index: usize) !void {
        try self.boundary();
        if (!self.store.decision) return error.NoEffectWithoutDecision;
        if (index == 1 and !self.store.results[0]) return error.SecondEffectBeforeFirstResult;
        self.store.invocations[index] += 1;
        if (!self.store.receipts[index] or self.ignore_receipt) {
            self.store.effects[index] += 1;
            self.store.receipts[index] = true;
        }
        if (self.store.effects[index] > 1) return error.DuplicateEffect;
        try self.boundary();
    }

    fn run(self: *Machine, replay: Replay) !void {
        try self.log.ensure_available();
        if (self.store.ended) return;
        if (!self.store.started) try self.persist(.start);
        if (!self.store.decision) {
            self.store.provider_requests += 1;
            if (self.optimistic) try self.effect(0);
            try self.persist(.decision);
        }
        for (0..2) |index| {
            if (self.store.results[index]) continue;
            if (self.recovering and replay == .blocked and !self.ignore_blocked) return error.RecoveryRequired;
            try self.effect(index);
            try self.persist(if (index == 0) .result_a else .result_b);
        }
        if (!self.store.final) {
            self.store.provider_requests += 1;
            try self.persist(.final);
        }
        try self.persist(.end);
    }
};

test "simulation J01 J02 J03 J05 J07 every crash cut preserves safe effects and final output" {
    // 6 acknowledged appends * before/after + 2 effects * before/after = 16.
    for (0..17) |cut| {
        var store: Store = .{};
        var first = try Machine.init(&store, false);
        first.crash_at = cut;
        first.run(.safe) catch |err| try std.testing.expectEqual(error.Crash, err);
        const final_was_durable = store.final;
        const requests_before = store.provider_requests;
        var resumed = try Machine.init(&store, true);
        // Recreating has no effects, appends, or model requests.
        try std.testing.expectEqual(requests_before, store.provider_requests);
        try resumed.run(.safe);
        try std.testing.expectEqual([2]usize{ 1, 1 }, store.effects);
        try std.testing.expect(store.ended);
        try std.testing.expectEqual(@as(usize, 6), store.len);
        if (final_was_durable) try std.testing.expectEqual(requests_before, store.provider_requests);
    }
}

test "simulation J01 store committed but lost ack fences writes until recreation" {
    var store: Store = .{ .ack = .lost_ack };
    var first = try Machine.init(&store, false);
    try std.testing.expectError(error.LostAck, first.run(.safe));
    try std.testing.expectEqual(@as(usize, 1), store.len);
    try std.testing.expectError(error.JournalUnavailable, first.run(.safe));
    try std.testing.expectEqual(@as(usize, 0), store.provider_requests);
    store.ack = .commit;
    var resumed = try Machine.init(&store, true);
    try resumed.run(.safe);
    try std.testing.expectEqual(@as(usize, 6), store.len);
}

test "simulation counterexample optimistic effect violates decision durability" {
    var store: Store = .{};
    var machine = try Machine.init(&store, false);
    machine.optimistic = true;
    try std.testing.expectError(error.NoEffectWithoutDecision, machine.run(.safe));
}

test "simulation counterexample missing atomic receipt duplicates an external effect" {
    var store: Store = .{};
    var first = try Machine.init(&store, false);
    first.crash_at = 5; // after effect A, before result A
    try std.testing.expectError(error.Crash, first.run(.safe));
    try std.testing.expectEqual(@as(usize, 1), store.effects[0]);
    var resumed = try Machine.init(&store, true);
    resumed.ignore_receipt = true;
    try std.testing.expectError(error.DuplicateEffect, resumed.run(.safe));
}

test "simulation J06 blocked recovery never invokes unknown A or unstarted B" {
    var store: Store = .{};
    var first = try Machine.init(&store, false);
    first.crash_at = 5;
    try std.testing.expectError(error.Crash, first.run(.blocked));
    const invocations = store.invocations;
    var resumed = try Machine.init(&store, true);
    try std.testing.expectError(error.RecoveryRequired, resumed.run(.blocked));
    try std.testing.expectEqual(invocations, store.invocations);
    // Abandon records uncertainty; it does not reverse the external transaction.
    try resumed.persist(.end);
    try std.testing.expectEqual([2]usize{ 1, 0 }, store.effects);
}

test "simulation counterexample replaying a blocked tool without receipt duplicates effect" {
    var store: Store = .{};
    var first = try Machine.init(&store, false);
    first.crash_at = 5;
    try std.testing.expectError(error.Crash, first.run(.blocked));
    var resumed = try Machine.init(&store, true);
    resumed.ignore_blocked = true;
    resumed.ignore_receipt = true;
    try std.testing.expectError(error.DuplicateEffect, resumed.run(.blocked));
}

test "simulation counterexample second effect before first result loses sequential recovery evidence" {
    var store: Store = .{ .decision = true };
    var machine = try Machine.init(&store, false);
    try machine.effect(0);
    try std.testing.expectError(error.SecondEffectBeforeFirstResult, machine.effect(1));
}

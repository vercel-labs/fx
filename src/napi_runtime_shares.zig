//! Who may start another of the process's native runtimes. The N-API core
//! claims one for every engine it creates and releases it when the engine's
//! runtime is destroyed, holding its own lock around both; this file only
//! decides, so the rule is tested without Node.
//!
//! A runtime is held for an agent, named by a key the JavaScript loader
//! derives from the agent's name and store (`sdk/node.js`
//! `runtimeShareKey`). While runtimes are contended no agent holds more than
//! its share, so one agent's turns can't keep another's off the native
//! backend (SEC-1, TEST-11):
//!
//! - An agent may claim a free runtime while it holds fewer than its share:
//!   the runtimes divided among the agents that hold any, itself included,
//!   rounded down. An agent alone may hold them all but one.
//! - The last free runtime is kept for an agent that holds none, so a new
//!   agent's turn starts natively at once, however many runtimes another
//!   agent holds.
//! - A runtime claimed without a key counts toward the limit only.
//!
//! A refused claim never waits: the loader runs that engine on WebAssembly.

const std = @import("std");

/// The native runtimes one process runs at once.
pub const max_runtimes = 64;
/// The longest key an agent may claim under; the loader's are SHA-256 hex.
pub const max_key_bytes = 128;

pub const Refusal = error{
    /// Every runtime is in use.
    RuntimesFull,
    /// The agent holds its share, or would take the runtime kept for an
    /// agent that holds none.
    OverShare,
};

const Holder = struct {
    key: [max_key_bytes]u8,
    key_len: usize,
    held: usize,

    fn keyBytes(self: *const Holder) []const u8 {
        return self.key[0..self.key_len];
    }
};

/// The runtimes in use and the agents holding them. Not synchronized: the
/// caller holds a lock around every call. Every holder holds at least one
/// runtime, and their runtimes plus the ones claimed without a key are
/// `active`.
pub const Table = struct {
    active: usize = 0,
    holders: [max_runtimes]Holder = undefined,
    holder_count: usize = 0,

    /// Claims a runtime for the agent `key` names, or for no agent when
    /// `key` is null. `key` is at most `max_key_bytes`. A successful claim
    /// is undone by exactly one `release` with the same key.
    pub fn claim(self: *Table, key: ?[]const u8) Refusal!void {
        if (self.active >= max_runtimes) return error.RuntimesFull;
        const name = key orelse {
            self.active += 1;
            return;
        };
        std.debug.assert(name.len <= max_key_bytes);
        const index = self.find(name);
        const held = if (index) |at| self.holders[at].held else 0;
        if (held >= shareOf(self.holder_count + @intFromBool(index == null))) return error.OverShare;
        if (held > 0 and self.active + 1 == max_runtimes) return error.OverShare;
        if (index) |at| {
            self.holders[at].held += 1;
        } else {
            // At most `active` holders, and `active` is below the limit.
            const holder = &self.holders[self.holder_count];
            @memcpy(holder.key[0..name.len], name);
            holder.key_len = name.len;
            holder.held = 1;
            self.holder_count += 1;
        }
        self.active += 1;
    }

    /// Releases a runtime an earlier `claim` with the same key took.
    pub fn release(self: *Table, key: ?[]const u8) void {
        std.debug.assert(self.active > 0);
        self.active -= 1;
        const name = key orelse return;
        const at = self.find(name) orelse unreachable;
        self.holders[at].held -= 1;
        if (self.holders[at].held > 0) return;
        self.holder_count -= 1;
        self.holders[at] = self.holders[self.holder_count];
    }

    /// The runtimes the agent `key` names holds now.
    fn heldBy(self: *const Table, key: []const u8) usize {
        const at = self.find(key) orelse return 0;
        return self.holders[at].held;
    }

    fn find(self: *const Table, key: []const u8) ?usize {
        for (self.holders[0..self.holder_count], 0..) |*holder, index| {
            if (std.mem.eql(u8, holder.keyBytes(), key)) return index;
        }
        return null;
    }
};

/// The most runtimes an agent may hold while `holders` agents, itself
/// included, hold any.
fn shareOf(holders: usize) usize {
    std.debug.assert(holders > 0);
    return max_runtimes / holders;
}

test "N-API runtime shares let an agent alone hold all but one runtime" {
    var table: Table = .{};
    for (0..max_runtimes - 1) |_| try table.claim("acme");
    try std.testing.expectError(error.OverShare, table.claim("acme"));
    // The runtime kept back goes to an agent that holds none.
    try table.claim("evilcorp");
    try std.testing.expectEqual(@as(usize, max_runtimes), table.active);
    try std.testing.expectError(error.RuntimesFull, table.claim("third"));
    try std.testing.expectError(error.RuntimesFull, table.claim(null));
}

test "N-API runtime shares keep an agent over its share off new runtimes until it is below it" {
    var table: Table = .{};
    for (0..max_runtimes - 1) |_| try table.claim("acme");
    try table.claim("evilcorp");
    // Two agents hold runtimes, so each may hold half of them.
    for (0..max_runtimes / 2) |_| table.release("acme");
    try std.testing.expectEqual(@as(usize, max_runtimes / 2 - 1), table.heldBy("acme"));
    try table.claim("acme");
    try std.testing.expectError(error.OverShare, table.claim("acme"));
    // The runtimes acme gave up go to evilcorp, below its share.
    for (0..max_runtimes / 2 - 2) |_| try table.claim("evilcorp");
    try std.testing.expectEqual(@as(usize, max_runtimes / 2 - 1), table.heldBy("evilcorp"));
    try std.testing.expectEqual(@as(usize, max_runtimes - 1), table.active);
    // The last runtime stays for an agent that holds none.
    try std.testing.expectError(error.OverShare, table.claim("evilcorp"));
    try table.claim("third");
}

test "N-API runtime shares forget an agent that holds none, so its share grows back" {
    var table: Table = .{};
    try table.claim("acme");
    try table.claim("evilcorp");
    table.release("evilcorp");
    try std.testing.expectEqual(@as(usize, 0), table.heldBy("evilcorp"));
    try std.testing.expectEqual(@as(usize, 1), table.holder_count);
    for (0..max_runtimes - 2) |_| try table.claim("acme");
    try std.testing.expectEqual(@as(usize, max_runtimes - 1), table.heldBy("acme"));
    while (table.active > 0) table.release("acme");
    try std.testing.expectEqual(@as(usize, 0), table.holder_count);
}

test "N-API runtime shares count a runtime without a key toward the limit only" {
    var table: Table = .{};
    for (0..max_runtimes) |_| try table.claim(null);
    try std.testing.expectError(error.RuntimesFull, table.claim(null));
    try std.testing.expectError(error.RuntimesFull, table.claim("acme"));
    table.release(null);
    try table.claim("acme");
    try std.testing.expectEqual(@as(usize, 1), table.holder_count);
}

test "N-API runtime shares hold for any order of claims and releases" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    const keys = [_]?[]const u8{ "a", "b", "c", "d", null };
    var table: Table = .{};
    var held: [keys.len]usize = @splat(0);
    for (0..20_000) |_| {
        const which = random.uintLessThan(usize, keys.len);
        if (random.boolean() and held[which] > 0) {
            table.release(keys[which]);
            held[which] -= 1;
        } else {
            const free = max_runtimes - table.active;
            const before = held[which];
            // The agents holding runtimes with this one counted.
            var holders: usize = @intFromBool(before == 0);
            for (keys, held) |key, count| {
                if (key != null and count > 0) holders += 1;
            }
            const claimed = if (table.claim(keys[which])) |_| true else |_| false;
            if (claimed) held[which] += 1;
            if (keys[which] == null) {
                try std.testing.expectEqual(free > 0, claimed);
            } else {
                // An agent that holds none always gets a free runtime, and
                // a claim never takes an agent over its share.
                if (before == 0 and free > 0) try std.testing.expect(claimed);
                if (claimed) try std.testing.expect(before + 1 <= shareOf(holders));
            }
        }
        var total: usize = 0;
        for (held) |count| total += count;
        try std.testing.expectEqual(total, table.active);
        try std.testing.expect(table.active <= max_runtimes);
    }
}

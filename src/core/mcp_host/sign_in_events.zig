//! How MCP sign-ins end, kept for `/trace` whether or not `FX_TRACE` is on:
//! a ring of the last `capacity` outcomes in this process. When it is full,
//! the oldest event goes and `dropped` counts it. The ring belongs to the
//! process, not to a host, because a reload can replace the host while the end
//! of a sign-in is still worth reading.
//!
//! An event holds the server's name from the config, a kind, a reason, and the
//! time. The kinds and reasons are closed sets, and the reasons reuse the sets
//! that already exist: `login_words.Reason.Kind` and the engine's
//! `auth.client.Failure`. No text a server sent, no token, code, address, or
//! header ever goes in (RULES.md R4.8): a reason is a fixed word.
//!
//! The runtime writes the events (`Runtime.signInEnded`) and `/trace` reads
//! them. TLA+ model: `tests/tla/mcp_host/SignIn.tla` `FailureLeavesEvent`.

const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const login_words = @import("login_words.zig");

const Allocator = std.mem.Allocator;

pub const capacity = 32;
const max_server_bytes = 64;

pub const Kind = enum {
    signed_in,
    /// The login is kept, but the request that checks it showed nothing about the token.
    signed_in_unchecked,
    sign_in_failed,
    needs_login,
    not_saved,
};

/// What the host itself ended a sign-in for, or could not do.
pub const HostReason = enum {
    browser_timeout,
    signed_out,
    config_changed,
    store_unreadable,
    store_write_failed,
};

pub const Reason = union(enum) {
    /// A login that worked: nothing went wrong.
    none,
    /// Why the server wants a login (`login_words`).
    login: login_words.Reason.Kind,
    /// Why a sign-in ended without a token (the engine's own).
    failure: mcp.auth.client.Failure,
    host: HostReason,

    /// The fixed word `/trace` shows. `login_words`' `none` is the lack of
    /// any reason, so it has its own word.
    pub fn name(reason: Reason) []const u8 {
        return switch (reason) {
            .none => "none",
            .login => |kind| if (kind == .none) "no_login" else @tagName(kind),
            .failure => |failure| @tagName(failure),
            .host => |host| @tagName(host),
        };
    }
};

pub const Event = struct {
    /// Counted from 1 over the whole process, so a gap shows what was dropped.
    sequence: u64 = 0,
    at_ms: i64 = 0,
    kind: Kind = .signed_in,
    reason: Reason = .none,
    server_len: u8 = 0,
    server_buf: [max_server_bytes]u8 = @splat(0),

    pub fn server(event: *const Event) []const u8 {
        return event.server_buf[0..event.server_len];
    }
};

/// The ring: plain data, with the time given in, so the laws hold on any input.
pub const Log = struct {
    /// Only the first `stored` slots from `head` back are read.
    events: [capacity]Event = undefined,
    head: usize = 0,
    stored: usize = 0,
    total: u64 = 0,

    pub fn push(log: *Log, server: []const u8, kind: Kind, reason: Reason, at_ms: i64) void {
        var event: Event = .{ .at_ms = at_ms, .kind = kind, .reason = reason };
        const kept = text_utils.utf8PrefixByBytes(server, max_server_bytes);
        @memcpy(event.server_buf[0..kept.len], kept);
        event.server_len = @intCast(kept.len);
        log.total +|= 1;
        event.sequence = log.total;
        log.events[log.head] = event;
        log.head = (log.head + 1) % capacity;
        log.stored = @min(log.stored + 1, capacity);
    }

    /// The events the ring let go to make room.
    pub fn dropped(log: *const Log) u64 {
        return log.total - log.stored;
    }

    /// Copies the newest events into `out`, oldest first, and returns how many.
    pub fn snapshot(log: *const Log, out: []Event) usize {
        const count = @min(log.stored, out.len);
        for (out[0..count], 0..) |*event, index| {
            event.* = log.events[(log.head + capacity - count + index) % capacity];
        }
        return count;
    }

    pub fn clear(log: *Log) void {
        log.head = 0;
        log.stored = 0;
        log.total = 0;
    }
};

/// What a reader gets: the events oldest first, owned by the allocator it gave.
pub const Snapshot = struct {
    events: []const Event,
    dropped: u64,
    capacity: usize = capacity,

    /// The newest event that says why `server` needs a login or why its
    /// sign-in failed, or null when none is kept.
    pub fn latestWhy(snap: Snapshot, server: []const u8) ?Event {
        var index = snap.events.len;
        while (index > 0) {
            index -= 1;
            const event = snap.events[index];
            if (event.kind != .needs_login and event.kind != .sign_in_failed) continue;
            if (std.mem.eql(u8, event.server(), server)) return event;
        }
        return null;
    }
};

var mutex: std.Io.Mutex = .init;
var process_log: Log = .{};

/// Keeps one event, stamped now. Any thread may call it.
pub fn record(server: []const u8, kind: Kind, reason: Reason) void {
    const at_ms = io_mod.milliTimestamp();
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    process_log.push(server, kind, reason, at_ms);
}

/// The kept events, copied into `alloc`.
pub fn snapshot(alloc: Allocator) Allocator.Error!Snapshot {
    const events = try alloc.alloc(Event, capacity);
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const count = process_log.snapshot(events);
    return .{ .events = events[0..count], .dropped = process_log.dropped() };
}

pub fn reset() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    process_log.clear();
}

const testing = std.testing;

test "the ring keeps the newest events, drops the oldest, and counts the drops" {
    var log: Log = .{};
    for (0..capacity + 5) |index| log.push("fixture", .sign_in_failed, .{ .failure = .discovery }, @intCast(index));
    var out: [capacity + 5]Event = undefined;
    const count = log.snapshot(&out);
    try testing.expectEqual(@as(usize, capacity), count);
    try testing.expectEqual(@as(u64, 5), log.dropped());
    try testing.expectEqual(@as(u64, 6), out[0].sequence);
    try testing.expectEqual(@as(i64, 5), out[0].at_ms);
    try testing.expectEqual(@as(u64, capacity + 5), out[count - 1].sequence);
    var tail: [2]Event = undefined;
    try testing.expectEqual(@as(usize, 2), log.snapshot(&tail));
    try testing.expectEqual(@as(u64, capacity + 4), tail[0].sequence);
    log.clear();
    try testing.expectEqual(@as(usize, 0), log.snapshot(&out));
    try testing.expectEqual(@as(u64, 0), log.dropped());
}

test "a ring that has not filled drops nothing and keeps each event as it was written" {
    var log: Log = .{};
    log.push("a", .needs_login, .{ .login = .refresh_refused }, 10);
    log.push("b", .signed_in, .none, 20);
    var out: [4]Event = undefined;
    try testing.expectEqual(@as(usize, 2), log.snapshot(&out));
    try testing.expectEqual(@as(u64, 0), log.dropped());
    try testing.expectEqualStrings("a", out[0].server());
    try testing.expectEqual(Kind.needs_login, out[0].kind);
    try testing.expectEqualStrings("refresh_refused", out[0].reason.name());
    try testing.expectEqualStrings("b", out[1].server());
    try testing.expectEqualStrings("none", out[1].reason.name());
}

test "a long server name is cut on a character boundary" {
    var log: Log = .{};
    log.push("x" ++ text_utils.repeat("\xc3\xa9", 100), .sign_in_failed, .{ .host = .signed_out }, 1);
    var out: [1]Event = undefined;
    try testing.expectEqual(@as(usize, 1), log.snapshot(&out));
    try testing.expect(out[0].server().len <= max_server_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(out[0].server()));
}

test "the newest reason for a server is its last needs_login or failed sign-in" {
    var log: Log = .{};
    log.push("a", .needs_login, .{ .login = .login_refused }, 1);
    log.push("b", .sign_in_failed, .{ .failure = .registration }, 2);
    log.push("a", .sign_in_failed, .{ .failure = .discovery }, 3);
    log.push("a", .signed_in_unchecked, .none, 4);
    var events: [capacity]Event = undefined;
    const count = log.snapshot(&events);
    const snap: Snapshot = .{ .events = events[0..count], .dropped = 0 };
    const a = snap.latestWhy("a").?;
    try testing.expectEqualStrings("discovery", a.reason.name());
    try testing.expectEqualStrings("registration", snap.latestWhy("b").?.reason.name());
    try testing.expectEqual(@as(?Event, null), snap.latestWhy("c"));
}

test "every reason is a distinct fixed word of lowercase letters and underscores" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    try seen.put(testing.allocator, Reason.name(.none), {});
    for (std.enums.values(login_words.Reason.Kind)) |kind| try expectNewWord(&seen, Reason.name(.{ .login = kind }));
    for (std.enums.values(mcp.auth.client.Failure)) |failure| try expectNewWord(&seen, Reason.name(.{ .failure = failure }));
    for (std.enums.values(HostReason)) |host| try expectNewWord(&seen, Reason.name(.{ .host = host }));
}

fn expectNewWord(seen: *std.StringHashMapUnmanaged(void), word: []const u8) !void {
    for (word) |c| try testing.expect(std.ascii.isLower(c) or c == '_');
    try testing.expect(word.len > 0);
    const entry = try seen.getOrPut(testing.allocator, word);
    try testing.expect(!entry.found_existing);
}

test "an event holds no text but the server's configured name" {
    // A new byte-array field here would be a place for a server's words to go.
    const event = @typeInfo(Event).@"struct";
    inline for (event.field_names, event.field_types) |name, field_type| {
        const holds_bytes = switch (@typeInfo(field_type)) {
            .array => |array| array.child == u8,
            .pointer => true,
            else => false,
        };
        try testing.expect(!holds_bytes or std.mem.eql(u8, name, "server_buf"));
    }
    inline for (@typeInfo(Reason).@"union".field_types) |field_type| {
        try testing.expect(@typeInfo(field_type) != .pointer and @typeInfo(field_type) != .array);
    }
}

test "the process ring keeps what is recorded until it is reset" {
    reset();
    defer reset();
    record("fixture", .sign_in_failed, .{ .failure = .redemption });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const snap = try snapshot(arena.allocator());
    try testing.expectEqual(@as(usize, 1), snap.events.len);
    try testing.expectEqualStrings("redemption", snap.events[0].reason.name());
    try testing.expect(snap.events[0].at_ms > 0);
    reset();
    try testing.expectEqual(@as(usize, 0), (try snapshot(arena.allocator())).events.len);
}

test "events recorded from several threads are all counted, in order" {
    reset();
    defer reset();
    const threads = 4;
    const each = 250;
    const Worker = struct {
        fn run() void {
            for (0..each) |_| record("fixture", .needs_login, .{ .login = .none });
        }
    };
    var workers: [threads]std.Thread = undefined;
    for (&workers) |*worker| worker.* = try std.Thread.spawn(.{}, Worker.run, .{});
    for (workers) |worker| worker.join();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const snap = try snapshot(arena.allocator());
    try testing.expectEqual(@as(usize, capacity), snap.events.len);
    try testing.expectEqual(@as(u64, threads * each - capacity), snap.dropped);
    for (snap.events[1..], 0..) |event, index| try testing.expectEqual(snap.events[index].sequence + 1, event.sequence);
}

//! The shared usage cache: one file per identity under `~/.fx/usage-cache/`.
//! Every fx process reads it without a lock (writes land by rename) and
//! writes it under an exclusive lock as read, merge, write, rename, so a
//! newer answer is never replaced by an older one (`CacheNeverRegresses`).

const std = @import("std");
const report = @import("report.zig");
const codex = @import("codex.zig");
const grok = @import("grok.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const dir_name = "usage-cache";
pub const schema_version: u32 = 2;
const max_file_bytes: usize = 4 * 1024 * 1024;

/// Whose numbers an entry holds: SHA-256, in hex, of the sign-in kind, a
/// stable subject (the API key, or the fx login account) and the team. The
/// subject never reaches the file.
pub const Identity = [64]u8;

pub fn identityOf(scope: report.Scope, subject: []const u8, team: []const u8) Identity {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx-usage-cache-v1\x00");
    hash.update(@tagName(scope));
    hash.update("\x00");
    hash.update(subject);
    hash.update("\x00");
    hash.update(team);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

/// Today's per-model numbers, from a fetch that started at `at_ms`.
pub const Today = struct {
    day: i64,
    at_ms: i64,
    models: []const report.ModelRow,
};

/// The finished days before `day`: the 7d window's and this calendar
/// month's (empty on the 1st).
pub const Finished = struct {
    day: i64,
    at_ms: i64,
    days_7: []const report.ModelRow,
    month: []const report.ModelRow,
};

pub const Budget = struct {
    at_ms: i64,
    value: report.Budget,
};

/// A ChatGPT plan's limits through Codex, from a fetch that started at `at_ms`.
pub const Codex = struct {
    at_ms: i64,
    value: codex.Usage,
};

/// A Grok plan's allowance and credits, from a fetch that started at `at_ms`.
pub const Grok = struct {
    at_ms: i64,
    value: grok.Usage,
};

pub const Entry = struct {
    today: ?Today = null,
    finished: ?Finished = null,
    budget: ?Budget = null,
    codex: ?Codex = null,
    grok: ?Grok = null,
};

/// An entry and the arena that owns its slices.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    entry: Entry,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

/// Combines what was stored with what a fetch returned, at wall time
/// `now_ms`. Each part keeps the newer of the two: today by fetch start,
/// finished days by day, the budget by fetch start. A stored part stamped
/// after `now_ms` was written while the clock ran ahead, so it yields to the
/// fetch; otherwise a backward clock correction would keep every later fetch
/// out until the clock caught up. Finished days do not change during a day,
/// so they count as ahead only when they are for a later day, and that holds
/// for the fetch too: one that started before the clock was corrected back
/// across midnight read them for a day that has not begun. The result
/// borrows from both inputs.
pub fn merge(stored: Entry, fetched: Entry, now_ms: i64) Entry {
    const s: Entry = .{
        .today = notAfter(Today, stored.today, now_ms),
        .finished = finishedBy(stored.finished, now_ms),
        .budget = notAfter(Budget, stored.budget, now_ms),
        .codex = notAfter(Codex, stored.codex, now_ms),
        .grok = notAfter(Grok, stored.grok, now_ms),
    };
    return .{
        .today = newer(Today, s.today, fetched.today, todayKey),
        .finished = newer(Finished, s.finished, finishedBy(fetched.finished, now_ms), finishedKey),
        .budget = newer(Budget, s.budget, fetched.budget, budgetKey),
        .codex = mergeCodex(s.codex, fetched.codex),
        .grok = mergeGrok(s.grok, fetched.grok),
    };
}

fn finishedBy(part: ?Finished, now_ms: i64) ?Finished {
    const f = part orelse return null;
    return if (f.day > report.utcDay(now_ms)) null else f;
}

fn notAfter(comptime T: type, part: ?T, now_ms: i64) ?T {
    const p = part orelse return null;
    return if (p.at_ms > now_ms) null else p;
}

/// The newer billing; a fetch whose settings request failed keeps the
/// stored plan name.
fn mergeGrok(stored: ?Grok, fetched: ?Grok) ?Grok {
    var result = newer(Grok, stored, fetched, grokKey) orelse return null;
    if (stored) |s| if (result.value.settings == null) {
        result.value.settings = s.value.settings;
    };
    return result;
}

fn grokKey(g: Grok) i64 {
    return g.at_ms;
}

/// The newer limits; a fetch whose activity or breakdown request failed
/// keeps what is already stored.
fn mergeCodex(stored: ?Codex, fetched: ?Codex) ?Codex {
    var result = newer(Codex, stored, fetched, codexKey) orelse return null;
    if (stored) |s| {
        if (result.value.profile == null) result.value.profile = s.value.profile;
        if (result.value.breakdown == null) result.value.breakdown = s.value.breakdown;
    }
    return result;
}

fn codexKey(c: Codex) i64 {
    return c.at_ms;
}

fn todayKey(t: Today) i64 {
    return t.at_ms;
}

fn finishedKey(f: Finished) i64 {
    return f.day;
}

fn budgetKey(b: Budget) i64 {
    return b.at_ms;
}

fn newer(comptime T: type, stored: ?T, fetched: ?T, key: fn (T) i64) ?T {
    const s = stored orelse return fetched;
    const f = fetched orelse return s;
    return if (key(f) >= key(s)) f else s;
}

const Wire = struct {
    schema_version: u32,
    identity: []const u8,
    today: ?Today = null,
    finished: ?Finished = null,
    budget: ?Budget = null,
    codex: ?Codex = null,
    grok: ?Grok = null,
};

pub fn encode(alloc: Allocator, identity: Identity, entry: Entry) ![]u8 {
    var out: Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(Wire{
        .schema_version = schema_version,
        .identity = &identity,
        .today = entry.today,
        .finished = entry.finished,
        .budget = entry.budget,
        .codex = entry.codex,
        .grok = entry.grok,
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Parses a cache file for `identity`. Anything malformed, from another
/// schema, or for another identity reads as absent. The result copies every
/// string, so `bytes` may be freed right after.
pub fn decode(gpa: Allocator, identity: Identity, bytes: []const u8) ?Owned {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const wire = std.json.parseFromSliceLeaky(Wire, arena.allocator(), bytes, .{ .allocate = .alloc_always }) catch {
        arena.deinit();
        return null;
    };
    if (wire.schema_version != schema_version or
        !std.mem.eql(u8, wire.identity, &identity) or
        !validEntry(.{ .today = wire.today, .finished = wire.finished, .budget = wire.budget, .codex = wire.codex, .grok = wire.grok }))
    {
        arena.deinit();
        return null;
    }
    return .{ .arena = arena, .entry = .{ .today = wire.today, .finished = wire.finished, .budget = wire.budget, .codex = wire.codex, .grok = wire.grok } };
}

fn validRows(rows: []const report.ModelRow) bool {
    if (rows.len > report.max_models) return false;
    for (rows) |row| {
        if (row.model.len == 0 or row.model.len > 256) return false;
        if (!row.totals.valid()) return false;
    }
    return true;
}

fn validMoney(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn validEntry(entry: Entry) bool {
    if (entry.today) |t| if (!validRows(t.models)) return false;
    if (entry.finished) |f| if (!validRows(f.days_7) or !validRows(f.month)) return false;
    if (entry.budget) |b| if (!validMoney(b.value.limit) or !validMoney(b.value.spent)) return false;
    if (entry.codex) |c| if (!c.value.valid()) return false;
    if (entry.grok) |g| if (!g.value.valid()) return false;
    return true;
}

fn fileName(buf: *[80]u8, identity: Identity, suffix: []const u8) []const u8 {
    return std.mem.print(buf, "{s}{s}", .{ &identity, suffix }) catch unreachable;
}

/// Reads the stored entry for `identity` from `fx_dir` (`~/.fx`), or null.
pub fn read(gpa: Allocator, io: Io, fx_dir: Io.Dir, identity: Identity) ?Owned {
    var dir = fx_dir.openDir(io, dir_name, .{}) catch return null;
    defer dir.close(io);
    var name_buf: [80]u8 = undefined;
    const bytes = dir.readFileAlloc(io, fileName(&name_buf, identity, ".json"), gpa, .limited(max_file_bytes)) catch return null;
    defer gpa.free(bytes);
    return decode(gpa, identity, bytes);
}

/// `entry` copied into memory of its own, as `read` would return it. Fails
/// when the reader would reject it. Caller owns the result.
pub fn own(gpa: Allocator, identity: Identity, entry: Entry) !Owned {
    if (!validEntry(entry)) return error.InvalidCache;
    const bytes = try encode(gpa, identity, entry);
    defer gpa.free(bytes);
    return decode(gpa, identity, bytes) orelse error.InvalidCache;
}

/// Merges `fetched` into the stored entry under the identity's lock, at
/// wall time `now_ms`, and writes the result by rename. `held` is the
/// caller's own copy of the entry: it counts as well, so a process never
/// stores less than it holds, even after the file was unreadable and a store
/// started over from less. Never writes what `read` would reject, so a bad
/// fetch leaves the file as it was. Returns the merged entry. Caller owns it.
pub fn store(gpa: Allocator, io: Io, fx_dir: Io.Dir, identity: Identity, fetched: Entry, now_ms: i64, held: ?Entry) !Owned {
    fx_dir.createDir(io, dir_name, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try fx_dir.openDir(io, dir_name, .{});
    defer dir.close(io);

    var name_buf: [80]u8 = undefined;
    var lock = try dir.createFile(io, fileName(&name_buf, identity, ".lock"), .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = .fromMode(0o600),
    });
    defer lock.close(io);

    var stored = read(gpa, io, fx_dir, identity);
    defer if (stored) |*s| s.deinit();
    const base: Entry = if (stored) |s| (if (held) |h| merge(h, s.entry, now_ms) else s.entry) else held orelse .{};
    const merged = merge(base, fetched, now_ms);
    if (!validEntry(merged)) return error.InvalidCache;

    const bytes = try encode(gpa, identity, merged);
    defer gpa.free(bytes);
    var tmp_buf: [80]u8 = undefined;
    const tmp_name = fileName(&tmp_buf, identity, ".tmp");
    try dir.writeFile(io, .{ .sub_path = tmp_name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    try dir.rename(tmp_name, dir, fileName(&name_buf, identity, ".json"), io);

    return decode(gpa, identity, bytes) orelse error.InvalidCache;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
/// A wall clock on the day after the fixtures' day 5.
const test_now: i64 = 6 * std.time.ms_per_day;

fn oneRow(comptime cost: f64) []const report.ModelRow {
    return &.{.{ .model = "anthropic/claude-opus-5.5", .totals = .{ .request_count = 2, .total_cost = cost } }};
}

test "merge keeps the newer part of each half" {
    const old: Entry = .{
        .today = .{ .day = 10, .at_ms = 200, .models = oneRow(2) },
        .finished = .{ .day = 10, .at_ms = 100, .days_7 = oneRow(7), .month = oneRow(30) },
        .budget = .{ .at_ms = 200, .value = .{ .limit = 100, .spent = 5, .period = .monthly } },
    };
    // An older fetch arrives late: nothing of it may replace newer data.
    const late = merge(old, .{ .today = .{ .day = 10, .at_ms = 150, .models = oneRow(1) } }, 11 * std.time.ms_per_day);
    try testing.expectEqual(@as(i64, 200), late.today.?.at_ms);
    try testing.expectEqual(@as(f64, 7), late.finished.?.days_7[0].totals.total_cost);
    // A newer fetch with only today keeps the stored finished days and budget.
    const fresh = merge(old, .{ .today = .{ .day = 10, .at_ms = 300, .models = oneRow(3) } }, 11 * std.time.ms_per_day);
    try testing.expectEqual(@as(f64, 3), fresh.today.?.models[0].totals.total_cost);
    try testing.expectEqual(@as(i64, 10), fresh.finished.?.day);
    try testing.expectEqual(@as(f64, 5), fresh.budget.?.value.spent);
}

test "the cache file round-trips and rejects other identities" {
    const a = identityOf(.member, "acct_1", "team_1");
    const b = identityOf(.api_key, "acct_1", "team_1");
    try testing.expect(!std.mem.eql(u8, &a, &b));
    const entry: Entry = .{
        .today = .{ .day = 20737, .at_ms = 1, .models = oneRow(1.5) },
        .budget = .{ .at_ms = 1, .value = .{ .limit = 31600, .spent = 6596.55, .period = .monthly } },
    };
    const bytes = try encode(testing.allocator, a, entry);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.find(u8, bytes, "acct_1") == null);
    var decoded = decode(testing.allocator, a, bytes).?;
    defer decoded.deinit();
    try testing.expectEqualStrings("anthropic/claude-opus-5.5", decoded.entry.today.?.models[0].model);
    try testing.expectEqual(report.RefreshPeriod.monthly, decoded.entry.budget.?.value.period);
    try testing.expect(decode(testing.allocator, b, bytes) == null);
    try testing.expect(decode(testing.allocator, a, "{\"schema_version\":2}") == null);
    try testing.expect(decode(testing.allocator, a, "garbage") == null);
}

test "a decoded entry outlives the bytes it came from" {
    const id = identityOf(.api_key, "k", "");
    const encoded = try encode(testing.allocator, id, .{ .today = .{ .day = 1, .at_ms = 1, .models = oneRow(1) } });
    var decoded = decode(testing.allocator, id, encoded).?;
    defer decoded.deinit();
    @memset(encoded, 'x');
    testing.allocator.free(encoded);
    try testing.expectEqualStrings("anthropic/claude-opus-5.5", decoded.entry.today.?.models[0].model);
}

test "store merges under the lock and never regresses today" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const id = identityOf(.member, "acct_1", "team_1");
    var first = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 500, .models = oneRow(5) },
        .finished = .{ .day = 5, .at_ms = 500, .days_7 = oneRow(7), .month = oneRow(30) },
    }, test_now, null);
    first.deinit();
    var second = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 400, .models = oneRow(4) },
    }, test_now, null);
    defer second.deinit();
    try testing.expectEqual(@as(i64, 500), second.entry.today.?.at_ms);
    try testing.expectEqual(@as(i64, 5), second.entry.finished.?.day);
    var again = read(testing.allocator, io, tmp.dir, id).?;
    defer again.deinit();
    try testing.expectEqual(@as(f64, 5), again.entry.today.?.models[0].totals.total_cost);
}

test "a part stored while the clock ran ahead yields to the next fetch" {
    const day: i64 = 20737;
    const at = day * std.time.ms_per_day + 3 * std.time.ms_per_hour;
    const tomorrow = at + std.time.ms_per_day;
    const ahead: Entry = .{
        .today = .{ .day = day + 1, .at_ms = tomorrow, .models = oneRow(6) },
        .finished = .{ .day = day + 1, .at_ms = tomorrow, .days_7 = oneRow(7), .month = oneRow(30) },
        .budget = .{ .at_ms = tomorrow, .value = .{ .limit = 100, .spent = 60, .period = .monthly } },
    };
    const fetched: Entry = .{
        .today = .{ .day = day, .at_ms = at, .models = oneRow(3) },
        .finished = .{ .day = day, .at_ms = at, .days_7 = oneRow(70), .month = oneRow(300) },
    };
    // Corrected back a day: what was stored for tomorrow yields.
    const corrected = merge(ahead, fetched, at + std.time.ms_per_min);
    try testing.expectEqual(at, corrected.today.?.at_ms);
    try testing.expectEqual(day, corrected.finished.?.day);
    try testing.expect(corrected.budget == null);
    // Once the clock passes it, the stored parts are simply newer.
    const later = merge(ahead, fetched, tomorrow + std.time.ms_per_min);
    try testing.expectEqual(tomorrow, later.today.?.at_ms);
    try testing.expectEqual(day + 1, later.finished.?.day);
    try testing.expectEqual(@as(f64, 60), later.budget.?.value.spent);
    // A small correction within a day drops today but keeps the finished
    // days, which do not change during the day.
    const same_day: Entry = .{
        .today = .{ .day = day, .at_ms = at + 10 * std.time.ms_per_min, .models = oneRow(4) },
        .finished = .{ .day = day, .at_ms = at + 10 * std.time.ms_per_min, .days_7 = oneRow(7), .month = oneRow(30) },
    };
    const small = merge(same_day, .{ .today = .{ .day = day, .at_ms = at, .models = oneRow(3) } }, at + std.time.ms_per_min);
    try testing.expectEqual(at, small.today.?.at_ms);
    try testing.expect(small.finished != null);
    try testing.expectEqual(@as(f64, 7), small.finished.?.days_7[0].totals.total_cost);
    // A fetch that started tomorrow by the old clock keeps its finished days
    // out; its today is stored and yields to the next fetch.
    const straddling = merge(fetched, ahead, at + std.time.ms_per_min);
    try testing.expectEqual(day, straddling.finished.?.day);
    try testing.expectEqual(tomorrow, straddling.today.?.at_ms);
}

test "a store never keeps less than the caller holds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const id = identityOf(.api_key, "k", "");
    var first = try store(testing.allocator, io, tmp.dir, id, .{
        .finished = .{ .day = 5, .at_ms = 500, .days_7 = oneRow(7), .month = oneRow(30) },
    }, test_now, null);
    defer first.deinit();
    var name_buf: [80]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const path = try std.mem.print(&path_buf, "{s}/{s}", .{ dir_name, fileName(&name_buf, id, ".json") });
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "garbage" });
    // The fetch skipped the finished days because the caller already had them.
    var second = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 600, .models = oneRow(4) },
    }, test_now, first.entry);
    defer second.deinit();
    try testing.expect(second.entry.finished != null);
    try testing.expectEqual(@as(i64, 5), second.entry.finished.?.day);
    const read_back = read(testing.allocator, io, tmp.dir, id);
    try testing.expect(read_back != null);
    var kept = read_back.?;
    defer kept.deinit();
    try testing.expectEqual(@as(i64, 5), kept.entry.finished.?.day);
    try testing.expectEqual(@as(i64, 600), kept.entry.today.?.at_ms);

    // A readable file with less than the caller holds (a store that started
    // over from an unreadable file, with yesterday's finished days) does not
    // take the caller's finished days either.
    const older = try encode(testing.allocator, id, .{
        .finished = .{ .day = 4, .at_ms = 400, .days_7 = oneRow(1), .month = oneRow(1) },
    });
    defer testing.allocator.free(older);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = older });
    var third = try store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 700, .models = oneRow(5) },
    }, test_now, second.entry);
    defer third.deinit();
    try testing.expect(third.entry.finished != null);
    try testing.expectEqual(@as(i64, 5), third.entry.finished.?.day);
}

test "store never writes an entry its reader would reject" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const id = identityOf(.api_key, "k", "");
    var first = try store(testing.allocator, io, tmp.dir, id, .{
        .finished = .{ .day = 5, .at_ms = 500, .days_7 = oneRow(7), .month = oneRow(30) },
    }, test_now, null);
    first.deinit();
    const huge = [_]report.ModelRow{.{ .model = "m", .totals = .{ .request_count = 1, .total_cost = std.math.inf(f64) } }};
    try testing.expectError(error.InvalidCache, store(testing.allocator, io, tmp.dir, id, .{
        .today = .{ .day = 5, .at_ms = 600, .models = &huge },
    }, test_now, null));
    try testing.expectError(error.InvalidCache, own(testing.allocator, id, .{ .today = .{ .day = 5, .at_ms = 600, .models = &huge } }));
    const read_back = read(testing.allocator, io, tmp.dir, id);
    try testing.expect(read_back != null);
    var kept = read_back.?;
    defer kept.deinit();
    try testing.expectEqual(@as(i64, 5), kept.entry.finished.?.day);
    try testing.expect(kept.entry.today == null);
}

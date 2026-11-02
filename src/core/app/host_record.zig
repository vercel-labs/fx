//! The host record: which sessions ran together in one fx
//! process, so resuming one of them brings the others back. One JSON file
//! per host in `~/.fx/hosts/`, named by the host's group id, listing the
//! open instances' session ids in launch order, each with the agent profile
//! its instance runs in. Session files never change.
//!
//! The choice of what to restore is pure (`chooseRestore`); reading, writing,
//! and removing files are the edges.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

pub const format_version: u32 = 1;
pub const group_id_len = 16;
const max_record_bytes = 64 * 1024;

/// How many records `pruneOldest` keeps: the newest by when they were last
/// written. Every resume reads them all, so this bounds that work. An older
/// group's sessions still resume, one at a time.
pub const max_records = 100;
const max_id_len = 128;

/// One host's record. Its slices are borrowed from whoever holds it.
pub const Record = struct {
    group_id: []const u8,
    updated_ms: i64,
    sessions: []const []const u8,
    /// The profile each session's instance runs in, by index. Empty in a
    /// record written before profiles were saved, which names none.
    profiles: []const ?[]const u8 = &.{},
};

/// A session a record lists, with its instance's profile when it names one.
pub const Member = struct {
    id: []const u8,
    profile: ?[]const u8,
};

/// What resuming a session brings back: the group it came from, the profile
/// the resumed session ran in, and the group's other sessions in their saved
/// order. `others` is allocated by `chooseRestore`; its strings are borrowed
/// from the records.
pub const Restore = struct {
    group_id: []const u8,
    profile: ?[]const u8,
    others: []const Member,

    pub fn deinit(self: *Restore, alloc: Allocator) void {
        alloc.free(self.others);
        self.* = undefined;
    }
};

/// Which sessions come back with `resumed`, or null when no record lists it.
/// The newest record that lists `resumed` wins. Each of its other sessions
/// comes back only when no newer record lists it: a session resumed into
/// another host since then belongs to that host's group now.
pub fn chooseRestore(alloc: Allocator, records: []const Record, resumed: []const u8) !?Restore {
    var chosen: ?usize = null;
    for (records, 0..) |record, index| {
        if (!lists(record, resumed)) continue;
        if (chosen) |best| if (!newer(record, records[best])) continue;
        chosen = index;
    }
    const pick = records[chosen orelse return null];
    var profile: ?[]const u8 = null;
    var found = false;
    var others: std.ArrayList(Member) = .empty;
    errdefer others.deinit(alloc);
    for (pick.sessions, 0..) |id, index| {
        if (std.mem.eql(u8, id, resumed)) {
            if (!found) profile = profileAt(pick, index);
            found = true;
            continue;
        }
        if (listsMember(others.items, id)) continue;
        if (movedOn(records, pick, id)) continue;
        try others.append(alloc, .{ .id = id, .profile = profileAt(pick, index) });
    }
    return .{ .group_id = pick.group_id, .profile = profile, .others = try others.toOwnedSlice(alloc) };
}

fn profileAt(record: Record, index: usize) ?[]const u8 {
    return if (index < record.profiles.len) record.profiles[index] else null;
}

fn listsMember(members: []const Member, id: []const u8) bool {
    for (members) |member| if (std.mem.eql(u8, member.id, id)) return true;
    return false;
}

/// Whether `a` was written after `b`. Equal times order by group id, so the
/// choice never depends on the order files are listed in.
fn newer(a: Record, b: Record) bool {
    if (a.updated_ms != b.updated_ms) return a.updated_ms > b.updated_ms;
    return std.mem.order(u8, a.group_id, b.group_id) == .gt;
}

fn lists(record: Record, id: []const u8) bool {
    return listsOne(record.sessions, id);
}

fn listsOne(ids: []const []const u8, id: []const u8) bool {
    for (ids) |value| if (std.mem.eql(u8, value, id)) return true;
    return false;
}

fn movedOn(records: []const Record, pick: Record, id: []const u8) bool {
    for (records) |record| {
        if (newer(record, pick) and lists(record, id)) return true;
    }
    return false;
}

/// Whether `id` is safe as a session or group id, and so as a file name:
/// 1 to 128 ASCII letters, digits, `-`, or `_`.
pub fn isValidId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

const Wire = struct {
    version: u32,
    updated_ms: i64,
    sessions: []const []const u8,
    profiles: ?[]const ?[]const u8 = null,
};

/// The record's file contents. The caller owns the bytes.
pub fn encode(alloc: Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(Wire{
        .version = format_version,
        .updated_ms = record.updated_ms,
        .sessions = record.sessions,
        .profiles = if (record.profiles.len > 0) record.profiles else null,
    }, .{ .emit_null_optional_fields = false }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Reads record `group_id` from `bytes`, copying every string into `arena`.
/// Rejects another version, a malformed file, any unsafe id or profile name,
/// and a profile list that doesn't match the sessions.
pub fn decode(arena: Allocator, group_id: []const u8, bytes: []const u8) !Record {
    if (!isValidId(group_id)) return error.InvalidHostRecord;
    const parsed = std.json.parseFromSlice(Wire, arena, bytes, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidHostRecord;
    const wire = parsed.value;
    if (wire.version != format_version) return error.InvalidHostRecord;
    const sessions = try arena.alloc([]const u8, wire.sessions.len);
    for (wire.sessions, sessions) |id, *copy| {
        if (!isValidId(id)) return error.InvalidHostRecord;
        copy.* = try arena.dupe(u8, id);
    }
    const names = wire.profiles orelse &.{};
    if (wire.profiles != null and names.len != sessions.len) return error.InvalidHostRecord;
    const profiles = try arena.alloc(?[]const u8, names.len);
    for (names, profiles) |name, *copy| {
        copy.* = if (name) |value| copy: {
            if (!isValidId(value)) return error.InvalidHostRecord;
            break :copy try arena.dupe(u8, value);
        } else null;
    }
    return .{
        .group_id = try arena.dupe(u8, group_id),
        .updated_ms = wire.updated_ms,
        .sessions = sessions,
        .profiles = profiles,
    };
}

/// Every record in `dir_path`, in an arena the caller frees with `deinit`.
/// A missing folder holds none; a file that can't be read is skipped and
/// logged.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    records: []const Record,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn loadAll(alloc: Allocator, dir_path: []const u8) !Loaded {
    const io = io_mod.getIo();
    var loaded: Loaded = .{ .arena = .init(alloc), .records = &.{} };
    errdefer loaded.arena.deinit();
    const arena = loaded.arena.allocator();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return loaded,
        else => return err,
    };
    defer dir.close(io);
    var records: std.ArrayList(Record) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const group_id = entry.name[0 .. entry.name.len - ".json".len];
        const bytes = dir.readFileAlloc(io, entry.name, arena, .limited(max_record_bytes)) catch |err| {
            debug_trace.logf("host", "host_record_skipped file={s} err={s}", .{ entry.name, @errorName(err) });
            continue;
        };
        const record = decode(arena, group_id, bytes) catch |err| {
            debug_trace.logf("host", "host_record_skipped file={s} err={s}", .{ entry.name, @errorName(err) });
            continue;
        };
        try records.append(arena, record);
    }
    loaded.records = records.items;
    return loaded;
}

/// Writes `record` whole to `dir_path`, creating the folder when needed.
pub fn write(alloc: Allocator, dir_path: []const u8, record: Record) !void {
    if (!isValidId(record.group_id)) return error.InvalidHostRecord;
    for (record.sessions) |id| if (!isValidId(id)) return error.InvalidHostRecord;
    if (record.profiles.len > 0 and record.profiles.len != record.sessions.len) return error.InvalidHostRecord;
    for (record.profiles) |name| if (name) |value| if (!isValidId(value)) return error.InvalidHostRecord;
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), dir_path);
    const path = try filePath(alloc, dir_path, record.group_id);
    defer alloc.free(path);
    const bytes = try encode(alloc, record);
    defer alloc.free(bytes);
    try io_mod.writeFileAtomic(alloc, path, bytes);
}

/// The groups of `records` past the newest `keep`, oldest last written
/// first, leaving out `keep_group`, which the caller is about to use.
/// Caller owns the slice; its strings are borrowed from `records`.
pub fn staleGroups(alloc: Allocator, records: []const Record, keep: usize, keep_group: ?[]const u8) ![]const []const u8 {
    const order = try alloc.alloc(usize, records.len);
    defer alloc.free(order);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order, records, struct {
        fn lessThan(list: []const Record, a: usize, b: usize) bool {
            return newer(list[a], list[b]);
        }
    }.lessThan);
    var stale: std.ArrayList([]const u8) = .empty;
    errdefer stale.deinit(alloc);
    var kept: usize = 0;
    for (order) |index| {
        const record = records[index];
        if (keep_group) |group| if (std.mem.eql(u8, record.group_id, group)) continue;
        if (kept < keep) {
            kept += 1;
            continue;
        }
        try stale.append(alloc, record.group_id);
    }
    std.mem.reverse([]const u8, stale.items);
    return stale.toOwnedSlice(alloc);
}

/// Removes from `dir_path` the records `staleGroups` picks out of `records`
/// with `max_records`. Returns how many it removed; one that can't be
/// removed is logged and left.
pub fn pruneOldest(alloc: Allocator, dir_path: []const u8, records: []const Record, keep_group: ?[]const u8) !usize {
    const stale = try staleGroups(alloc, records, max_records, keep_group);
    defer alloc.free(stale);
    var removed: usize = 0;
    for (stale) |group| {
        remove(alloc, dir_path, group) catch |err| {
            debug_trace.logf("host", "host_record_prune_failed group={s} err={s}", .{ group, @errorName(err) });
            continue;
        };
        removed += 1;
    }
    if (removed > 0) debug_trace.eventf("host", "host_records_pruned", .{}, "removed={d} kept={d}", .{ removed, records.len - removed });
    return removed;
}

/// Removes record `group_id` from `dir_path`, if it is there.
pub fn remove(alloc: Allocator, dir_path: []const u8, group_id: []const u8) !void {
    if (!isValidId(group_id)) return error.InvalidHostRecord;
    const path = try filePath(alloc, dir_path, group_id);
    defer alloc.free(path);
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn filePath(alloc: Allocator, dir_path: []const u8, group_id: []const u8) ![]u8 {
    return alloc.print("{s}/{s}.json", .{ dir_path, group_id });
}

/// A new random group id of lowercase hex.
pub fn newGroupId() [group_id_len]u8 {
    var bytes: [group_id_len / 2]u8 = undefined;
    io_mod.getIo().random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

test "a host record round-trips through its file contents" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const sessions = [_][]const u8{ "s-1", "s_2", "S3" };
    const names = [_]?[]const u8{ "main", null, "reviewer" };
    const bytes = try encode(alloc, .{ .group_id = "g1", .updated_ms = 42, .sessions = &sessions, .profiles = &names });
    defer alloc.free(bytes);
    const record = try decode(arena.allocator(), "g1", bytes);
    try std.testing.expectEqualStrings("g1", record.group_id);
    try std.testing.expectEqual(@as(i64, 42), record.updated_ms);
    try std.testing.expectEqual(@as(usize, 3), record.sessions.len);
    for (sessions, record.sessions) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqualStrings("main", record.profiles[0].?);
    try std.testing.expect(record.profiles[1] == null);
    try std.testing.expectEqualStrings("reviewer", record.profiles[2].?);
    // A record written before profiles were saved names none.
    const legacy = try decode(arena.allocator(), "g2", "{\"version\":1,\"updated_ms\":1,\"sessions\":[\"a\"]}");
    try std.testing.expectEqual(@as(usize, 0), legacy.profiles.len);
}

test "a host record rejects another version, bad JSON, and unsafe ids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidHostRecord, decode(a, "g", "{\"version\":2,\"updated_ms\":1,\"sessions\":[]}"));
    try std.testing.expectError(error.InvalidHostRecord, decode(a, "g", "not json"));
    try std.testing.expectError(error.InvalidHostRecord, decode(a, "g", "{\"version\":1,\"updated_ms\":1,\"sessions\":[\"../x\"]}"));
    try std.testing.expectError(error.InvalidHostRecord, decode(a, "../g", "{\"version\":1,\"updated_ms\":1,\"sessions\":[]}"));
    // A profile list must match the sessions, and each name must be safe.
    try std.testing.expectError(error.InvalidHostRecord, decode(a, "g", "{\"version\":1,\"updated_ms\":1,\"sessions\":[\"a\"],\"profiles\":[]}"));
    try std.testing.expectError(error.InvalidHostRecord, decode(a, "g", "{\"version\":1,\"updated_ms\":1,\"sessions\":[\"a\"],\"profiles\":[\"../p\"]}"));
    try std.testing.expect(!isValidId(""));
    try std.testing.expect(!isValidId("a/b"));
    try std.testing.expect(isValidId("Abc-12_z"));
}

test "restoring a session brings back its newest group, minus sessions that moved on" {
    const alloc = std.testing.allocator;
    const records = [_]Record{
        .{ .group_id = "old", .updated_ms = 10, .sessions = &.{ "a", "b", "c" } },
        .{ .group_id = "new", .updated_ms = 20, .sessions = &.{ "d", "a", "e", "a" } },
        .{ .group_id = "later", .updated_ms = 30, .sessions = &.{ "e", "f" } },
    };
    // `a` is in "old" and "new"; "new" wins. `e` moved on to "later".
    var restore = (try chooseRestore(alloc, &records, "a")).?;
    defer restore.deinit(alloc);
    try std.testing.expectEqualStrings("new", restore.group_id);
    try std.testing.expectEqual(@as(usize, 1), restore.others.len);
    try std.testing.expectEqualStrings("d", restore.others[0].id);
    // Each session comes back with its own instance's profile, the
    // resumed one included.
    const profiled = [_]Record{
        .{ .group_id = "p", .updated_ms = 1, .sessions = &.{ "x", "y", "z" }, .profiles = &.{ "reviewer", null, "main" } },
    };
    var named = (try chooseRestore(alloc, &profiled, "x")).?;
    defer named.deinit(alloc);
    try std.testing.expectEqualStrings("reviewer", named.profile.?);
    try std.testing.expect(named.others[0].profile == null);
    try std.testing.expectEqualStrings("main", named.others[1].profile.?);
    try std.testing.expect(restore.profile == null);
    // A session no record lists restores nothing.
    try std.testing.expect((try chooseRestore(alloc, &records, "z")) == null);
    // Equal times order by group id, not by listing order.
    const tied = [_]Record{
        .{ .group_id = "b", .updated_ms = 5, .sessions = &.{ "x", "y" } },
        .{ .group_id = "a", .updated_ms = 5, .sessions = &.{ "x", "z" } },
    };
    var tie = (try chooseRestore(alloc, &tied, "x")).?;
    defer tie.deinit(alloc);
    try std.testing.expectEqualStrings("b", tie.group_id);
}

/// Checks `chooseRestore` for `resumed` over `records`: the newest record
/// that lists `resumed` wins, and it brings back that record's other
/// sessions in order, except any a newer record lists.
fn expectRestore(alloc: Allocator, records: []const Record, resumed: []const u8) !void {
    var result = try chooseRestore(alloc, records, resumed);
    defer if (result) |*value| value.deinit(alloc);
    var listed = false;
    for (records) |record| listed = listed or lists(record, resumed);
    try std.testing.expectEqual(listed, result != null);
    const restore = result orelse return;
    const pick = for (records) |record| {
        if (std.mem.eql(u8, record.group_id, restore.group_id)) break record;
    } else return error.TestUnexpectedResult;
    // The winner lists `resumed`, and no newer record does.
    try std.testing.expect(lists(pick, resumed));
    for (records) |record| try std.testing.expect(!(newer(record, pick) and lists(record, resumed)));
    // Every session brought back is the winner's, once, in its order, not the
    // resumed one, and listed by no newer record.
    var last: ?usize = null;
    for (restore.others, 0..) |member, index| {
        const id = member.id;
        try std.testing.expect(!std.mem.eql(u8, id, resumed));
        try std.testing.expect(!listsMember(restore.others[0..index], id));
        try std.testing.expect(!movedOn(records, pick, id));
        const position = for (pick.sessions, 0..) |value, at| {
            if (std.mem.eql(u8, value, id)) break at;
        } else return error.TestUnexpectedResult;
        if (last) |previous| try std.testing.expect(previous < position);
        last = position;
    }
    // And none of the winner's other sessions is left out without reason.
    for (pick.sessions) |id| {
        if (std.mem.eql(u8, id, resumed) or movedOn(records, pick, id)) continue;
        try std.testing.expect(listsMember(restore.others, id));
    }
}

const ids_pool = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
const groups_pool = [_][]const u8{ "g0", "g1", "g2", "g3", "g4", "g5" };

test "restoring holds for random sets of records" {
    var prng = std.Random.DefaultPrng.init(0x4057_2ec0);
    const random = prng.random();
    var session_buf: [6][6][]const u8 = undefined;
    var records: [6]Record = undefined;
    for (0..5_000) |_| {
        const count = random.uintAtMost(usize, records.len);
        for (records[0..count], 0..) |*record, index| {
            const len = random.uintAtMost(usize, session_buf[index].len);
            for (session_buf[index][0..len]) |*id| id.* = ids_pool[random.uintLessThan(usize, ids_pool.len)];
            record.* = .{ .group_id = groups_pool[index], .updated_ms = random.uintAtMost(u8, 4), .sessions = session_buf[index][0..len] };
        }
        try expectRestore(std.testing.allocator, records[0..count], ids_pool[random.uintLessThan(usize, ids_pool.len)]);
    }
}

test "restoring holds for fuzzed sets of records" {
    try std.testing.fuzz({}, fuzzRestore, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").host_restore.*),
    });
}

test "a host record file decodes or is refused on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzDecode, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"version\":1,\"updated_ms\":5,\"sessions\":[\"abc\",\"def\"]}",
            "{\"version\":1,\"updated_ms\":5,\"sessions\":[\"abc\"],\"profiles\":[\"main\"]}",
            "{\"version\":2}",
            "[]",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").host_record_decode.*),
    });
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    const record = decode(arena, "0123456789abcdef", bytes) catch return;
    // What decodes is a record fx would write, and it writes back the same.
    for (record.sessions) |id| try std.testing.expect(isValidId(id));
    try std.testing.expect(record.profiles.len == 0 or record.profiles.len == record.sessions.len);
    const encoded = try encode(arena, record);
    const again = try decode(arena, record.group_id, encoded);
    try std.testing.expectEqual(record.updated_ms, again.updated_ms);
    try std.testing.expectEqual(record.sessions.len, again.sessions.len);
    for (record.sessions, again.sessions) |a, b| try std.testing.expectEqualStrings(a, b);
}

fn fuzzRestore(_: void, smith: *std.testing.Smith) !void {
    var session_buf: [6][6][]const u8 = undefined;
    var records: [6]Record = undefined;
    var count: usize = 0;
    while (count < records.len and !smith.eos()) : (count += 1) {
        const len = smith.valueRangeAtMost(u8, 0, @intCast(session_buf[count].len));
        for (session_buf[count][0..len]) |*id| id.* = ids_pool[smith.index(ids_pool.len)];
        records[count] = .{ .group_id = groups_pool[count], .updated_ms = smith.valueRangeAtMost(u8, 0, 4), .sessions = session_buf[count][0..len] };
    }
    try expectRestore(std.testing.allocator, records[0..count], ids_pool[smith.index(ids_pool.len)]);
}

test "pruning keeps the newest records and the group in use" {
    const alloc = std.testing.allocator;
    const none: []const []const u8 = &.{};
    const records = [_]Record{
        .{ .group_id = "aaaaaaaaaaaaaaaa", .updated_ms = 10, .sessions = none },
        .{ .group_id = "bbbbbbbbbbbbbbbb", .updated_ms = 50, .sessions = none },
        .{ .group_id = "cccccccccccccccc", .updated_ms = 30, .sessions = none },
        .{ .group_id = "dddddddddddddddd", .updated_ms = 40, .sessions = none },
        .{ .group_id = "eeeeeeeeeeeeeeee", .updated_ms = 20, .sessions = none },
    };
    const stale = try staleGroups(alloc, &records, 2, null);
    defer alloc.free(stale);
    try std.testing.expectEqual(@as(usize, 3), stale.len);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaa", stale[0]);
    try std.testing.expectEqualStrings("eeeeeeeeeeeeeeee", stale[1]);
    try std.testing.expectEqualStrings("cccccccccccccccc", stale[2]);

    // The group being restored stays even when it is the oldest, and it
    // takes none of the newest places.
    const kept = try staleGroups(alloc, &records, 2, "aaaaaaaaaaaaaaaa");
    defer alloc.free(kept);
    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings("eeeeeeeeeeeeeeee", kept[0]);
    try std.testing.expectEqualStrings("cccccccccccccccc", kept[1]);

    const few = try staleGroups(alloc, &records, max_records, null);
    defer alloc.free(few);
    try std.testing.expectEqual(@as(usize, 0), few.len);
}

test "host records are written whole, listed, and removed" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const dir_path = try alloc.print("{s}/hosts", .{root});
    defer alloc.free(dir_path);

    var empty = try loadAll(alloc, dir_path);
    try std.testing.expectEqual(@as(usize, 0), empty.records.len);
    empty.deinit();

    try write(alloc, dir_path, .{ .group_id = "g1", .updated_ms = 7, .sessions = &.{ "a", "b" } });
    try write(alloc, dir_path, .{ .group_id = "g1", .updated_ms = 8, .sessions = &.{ "b", "c" } });
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "hosts/junk.json", .data = "nope" });
    var loaded = try loadAll(alloc, dir_path);
    try std.testing.expectEqual(@as(usize, 1), loaded.records.len);
    try std.testing.expectEqual(@as(i64, 8), loaded.records[0].updated_ms);
    try std.testing.expectEqualStrings("c", loaded.records[0].sessions[1]);
    loaded.deinit();

    try remove(alloc, dir_path, "g1");
    try remove(alloc, dir_path, "g1");
    var after = try loadAll(alloc, dir_path);
    try std.testing.expectEqual(@as(usize, 0), after.records.len);
    after.deinit();
    try std.testing.expectError(error.InvalidHostRecord, write(alloc, dir_path, .{ .group_id = "../x", .updated_ms = 1, .sessions = &.{} }));
}

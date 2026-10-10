//! Usage recovery markers: `~/.fx/usage-recovery/<session-id>` for v1
//! sessions and `~/.fx/usage-recovery-v2/<session-id>` for sessions-v2.
//!
//! A marker says "this session's saved usage may owe the profile ledger".
//! Its body is `"v1 <protected_ms>\n"`, mode 0600, read by older fx binaries
//! with the same validator (`session_store.validateUsageRecoveryMarker`).
//!
//! The ordering contract older fx binaries rely on:
//!
//! 1. `prepareCheckpoint` before persisting a snapshot. When the snapshot
//!    owes the ledger the marker is durable first, keeping the oldest
//!    protected time while the saved state already owed it.
//! 2. Persist the snapshot (the host's `SessionSink`).
//! 3. `finishCheckpoint` after that persist. When the snapshot owes nothing
//!    the marker is unlinked and its directory fsynced.
//!
//! Differences from older fx:
//!
//! - `list` degrades per entry. A malformed entry is reported as malformed,
//!   with its mtime when it has one, instead of failing the whole registry;
//!   more than 512 entries are counted as `omitted`.
//! - Writes stage their temp file in `~/.fx`, not in the marker directory,
//!   so a crash mid-write never leaves an entry older readers reject.
//! - v1 and v2 share one writer: both create and repair `~/.fx` and the
//!   marker directory, and `clear` always fsyncs the directory.
//! - `clear` also removes a malformed marker for the session.

const std = @import("std");
const record = @import("../codec/record.zig");
const durable = @import("durable.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

pub const profile_dir_name = ".fx";
/// fx's `max_usage_recovery_sessions` and `max_usage_markers`.
pub const max_registry_entries: usize = 512;

pub const Kind = enum {
    v1,
    v2,

    pub fn dirName(kind: Kind) []const u8 {
        return switch (kind) {
            .v1 => "usage-recovery",
            .v2 => "usage-recovery-v2",
        };
    }
};

/// fx's `session_layout.validateSessionId`: 1 to 255 bytes of
/// `[A-Za-z0-9._-]`, not `.` or `..`. v1 also rejects `v2` in any case,
/// the sessions-v2 folder name.
pub fn validSessionId(kind: Kind, id: []const u8) bool {
    if (id.len == 0 or id.len > 255 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    if (kind == .v1 and std.ascii.eqlIgnoreCase(id, "v2")) return false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn requireSessionId(kind: Kind, id: []const u8) error{InvalidSessionId}!void {
    if (!validSessionId(kind, id)) return error.InvalidSessionId;
}

// ---------------------------------------------------------------------------
// One marker

pub const Shape = union(enum) {
    absent,
    valid: i64,
    malformed: Malformed,
};

pub const Malformed = enum {
    /// A directory, symlink, or other non-regular entry.
    not_file,
    /// The name is not a session id.
    invalid_name,
    /// A replace temp an older binary left behind after a crash.
    replace_temp,
    /// Hard linked, not 0600, empty, or over 24 bytes.
    unsafe_file,
    /// Not `"v1 <ms>\n"` with a non-negative i64.
    invalid_body,
};

/// fx's `validateUsageRecoveryMarker`, as a classification.
fn inspect(io: Io, dir: Dir, name: []const u8) !Shape {
    const file = dir.openFile(io, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        error.SymLinkLoop, error.IsDir, error.NotDir, error.NoDevice, error.PipeBusy => return .{ .malformed = .not_file },
        error.AccessDenied, error.PermissionDenied => return .{ .malformed = .unsafe_file },
        else => |e| return e,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return .{ .malformed = .not_file };
    if (stat.nlink != 1 or stat.size == 0 or stat.size > record.max_marker_bytes or
        durable.modeOf(stat.permissions) != durable.file_mode)
    {
        return .{ .malformed = .unsafe_file };
    }
    var buffer: [record.max_marker_bytes]u8 = undefined;
    const body = buffer[0..@intCast(stat.size)];
    const got = file.readPositionalAll(io, body, 0) catch return .{ .malformed = .invalid_body };
    if (got != body.len) return .{ .malformed = .invalid_body };
    return .{ .valid = record.parseMarker(body) catch return .{ .malformed = .invalid_body } };
}

/// Opens `~/.fx/<kind dir>` for reading: null when either is missing, and
/// `InvalidUsageRecoveryIndex` when either is not a private directory.
fn openForRead(io: Io, home: Dir, kind: Kind) !?Dir {
    const profile = (durable.openDirNoFollow(io, home, profile_dir_name) catch |err| switch (err) {
        error.DurablePathUnsafe => return error.InvalidUsageRecoveryIndex,
        else => return err,
    }) orelse return null;
    defer profile.close(io);
    durable.checkPrivateDir(try profile.stat(io)) catch return error.InvalidUsageRecoveryIndex;
    const dir = (durable.openDirNoFollow(io, profile, kind.dirName()) catch |err| switch (err) {
        error.DurablePathUnsafe => return error.InvalidUsageRecoveryIndex,
        else => return err,
    }) orelse return null;
    errdefer dir.close(io);
    durable.checkPrivateDir(try dir.stat(io)) catch return error.InvalidUsageRecoveryIndex;
    return dir;
}

/// The protected time of one session's marker, or null when it has none.
/// A malformed marker is `InvalidUsageRecoveryIndex`.
pub fn read(io: Io, home: Dir, kind: Kind, session_id: []const u8) !?i64 {
    try requireSessionId(kind, session_id);
    const dir = (try openForRead(io, home, kind)) orelse return null;
    defer dir.close(io);
    return switch (try inspect(io, dir, session_id)) {
        .absent => null,
        .valid => |ms| ms,
        .malformed => error.InvalidUsageRecoveryIndex,
    };
}

pub const Policy = enum {
    /// Keep an existing valid marker: its time is older.
    keep_oldest,
    /// Write `protected_ms` unless the marker already holds it.
    replace,
};

pub const WriteResult = enum { written, kept, unchanged };

const Dirs = struct {
    profile: Dir,
    markers: Dir,

    fn close(dirs: Dirs, io: Io) void {
        dirs.markers.close(io);
        dirs.profile.close(io);
    }
};

fn openForWrite(io: Io, home: Dir, kind: Kind) !Dirs {
    const profile = try durable.openOrCreatePrivateDir(io, home, profile_dir_name);
    errdefer profile.close(io);
    const markers = try durable.openOrCreatePrivateDir(io, profile, kind.dirName());
    return .{ .profile = profile, .markers = markers };
}

/// Makes the session's marker durable (replace + directory fsync) before
/// the caller persists a snapshot that owes the ledger.
pub fn write(io: Io, home: Dir, kind: Kind, session_id: []const u8, protected_ms: i64, policy: Policy, probe: durable.Probe) !WriteResult {
    try requireSessionId(kind, session_id);
    var body_buffer: [record.max_marker_bytes]u8 = undefined;
    const body = try record.writeMarker(&body_buffer, protected_ms);
    const dirs = try openForWrite(io, home, kind);
    defer dirs.close(io);
    switch (try inspect(io, dirs.markers, session_id)) {
        .valid => |existing| {
            if (policy == .keep_oldest) return .kept;
            if (existing == protected_ms) return .unchanged;
        },
        // An unreadable marker carries no time to keep, so it is replaced.
        .absent, .malformed => {},
    }
    try durable.replace(io, dirs.markers, session_id, body, .{ .temp_dir = dirs.profile, .probe = probe });
    return .written;
}

/// Removes the session's marker once a checkpoint that owes nothing is
/// durable, then fsyncs the directory. True when a marker was removed.
pub fn clear(io: Io, home: Dir, kind: Kind, session_id: []const u8, probe: durable.Probe) !bool {
    try requireSessionId(kind, session_id);
    const dir = (try openForRead(io, home, kind)) orelse return false;
    defer dir.close(io);
    const stat = dir.statFile(io, session_id, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind == .directory) return error.InvalidUsageRecoveryIndex;
    dir.deleteFile(io, session_id) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    probe.at(.marker_deleted);
    try durable.syncDir(dir);
    return true;
}

// ---------------------------------------------------------------------------
// Checkpoint ordering

pub const CheckpointInput = struct {
    now_ms: i64,
    /// Time of the session's last durable usage checkpoint.
    saved_at_ms: i64,
    /// Whether that durable checkpoint owes the ledger.
    saved_owes: bool,
    /// Whether the checkpoint about to be persisted owes the ledger.
    next_owes: bool,
};

pub const Checkpoint = struct {
    /// Time to persist with the checkpoint: strictly after `saved_at_ms`.
    at_ms: i64,
    owes: bool,
};

/// Step 1: before persisting. fx's `prepareUsageRecoveryCheckpoint`.
pub fn prepareCheckpoint(io: Io, home: Dir, kind: Kind, session_id: []const u8, input: CheckpointInput, probe: durable.Probe) !Checkpoint {
    const now_ms = @max(input.now_ms, 0);
    const at_ms = if (now_ms > input.saved_at_ms)
        now_ms
    else
        std.math.add(i64, input.saved_at_ms, 1) catch return error.InvalidSessionFormat;
    if (input.next_owes) {
        if (input.saved_owes) {
            _ = try write(io, home, kind, session_id, input.saved_at_ms, .keep_oldest, probe);
        } else {
            _ = try write(io, home, kind, session_id, at_ms, .replace, probe);
        }
    }
    return .{ .at_ms = at_ms, .owes = input.next_owes };
}

/// Step 3: after the checkpoint is durable. fx's `finishUsageRecoveryCheckpoint`.
pub fn finishCheckpoint(io: Io, home: Dir, kind: Kind, session_id: []const u8, checkpoint: Checkpoint, probe: durable.Probe) !void {
    if (!checkpoint.owes) _ = try clear(io, home, kind, session_id, probe);
}

// ---------------------------------------------------------------------------
// Registry

pub const Entry = struct {
    /// Owned by the registry.
    name: []const u8,
    /// The entry's mtime, when it could be read.
    modified_at_ns: ?i96,
    state: union(enum) {
        marker: i64,
        malformed: Malformed,
    },
};

pub const Registry = struct {
    entries: []Entry = &.{},
    /// Entries past `max_registry_entries`, not listed.
    omitted: usize = 0,

    pub fn deinit(registry: *Registry, gpa: Allocator) void {
        for (registry.entries) |entry| gpa.free(entry.name);
        gpa.free(registry.entries);
        registry.* = undefined;
    }

    pub fn markerCount(registry: Registry) usize {
        var count: usize = 0;
        for (registry.entries) |entry| count += @intFromBool(entry.state == .marker);
        return count;
    }
};

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Every entry of the kind's marker directory, sorted by name, each with its
/// own verdict. Never creates or changes anything. Fails as a whole only
/// when `~/.fx` or the directory itself is unsafe.
pub fn list(gpa: Allocator, io: Io, home: Dir, kind: Kind) !Registry {
    const dir = (try openForRead(io, home, kind)) orelse return .{};
    defer dir.close(io);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| gpa.free(entry.name);
        entries.deinit(gpa);
    }
    var omitted: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |item| {
        if (entries.items.len == max_registry_entries) {
            omitted += 1;
            continue;
        }
        const modified_at_ns: ?i96 = if (dir.statFile(io, item.name, .{ .follow_symlinks = false })) |stat|
            stat.mtime.nanoseconds
        else |_|
            null;
        const state: @FieldType(Entry, "state") = if (item.kind != .file)
            .{ .malformed = .not_file }
        else if (durable.isReplaceTemp(item.name))
            .{ .malformed = .replace_temp }
        else if (!validSessionId(kind, item.name))
            .{ .malformed = .invalid_name }
        else switch (try inspect(io, dir, item.name)) {
            // Gone since the listing read it: no longer an entry.
            .absent => continue,
            .valid => |ms| .{ .marker = ms },
            .malformed => |why| .{ .malformed = why },
        };
        try entries.ensureUnusedCapacity(gpa, 1);
        entries.appendAssumeCapacity(.{ .name = try gpa.dupe(u8, item.name), .modified_at_ns = modified_at_ns, .state = state });
    }
    // At most `max_registry_entries` unique names: insertion sort is quick
    // enough and much smaller than a general sort.
    std.sort.insertion(Entry, entries.items, {}, lessThan);
    return .{ .entries = try entries.toOwnedSlice(gpa), .omitted = omitted };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const Home = struct {
    tmp: testing.TmpDir,

    fn init() Home {
        return .{ .tmp = testing.tmpDir(.{ .iterate = true }) };
    }

    fn deinit(home: *Home) void {
        home.tmp.cleanup();
    }

    fn markers(home: *Home, kind: Kind) !Dir {
        var profile = try home.tmp.dir.openDir(testing.io, profile_dir_name, .{});
        defer profile.close(testing.io);
        return profile.openDir(testing.io, kind.dirName(), .{ .iterate = true });
    }

    fn body(home: *Home, kind: Kind, id: []const u8, buffer: []u8) ![]u8 {
        var dir = try home.markers(kind);
        defer dir.close(testing.io);
        return dir.readFile(testing.io, id, buffer);
    }

    /// Plants a raw entry in the marker directory, creating both directories.
    fn plant(home: *Home, kind: Kind, name: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
        var profile = try durable.openOrCreatePrivateDir(testing.io, home.tmp.dir, profile_dir_name);
        defer profile.close(testing.io);
        var dir = try durable.openOrCreatePrivateDir(testing.io, profile, kind.dirName());
        defer dir.close(testing.io);
        try dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes, .flags = .{ .permissions = .fromMode(mode) } });
        try dir.setFilePermissions(testing.io, name, .fromMode(mode), .{});
    }

    fn profileEntries(home: *Home) !usize {
        var profile = try home.tmp.dir.openDir(testing.io, profile_dir_name, .{ .iterate = true });
        defer profile.close(testing.io);
        var count: usize = 0;
        var it = profile.iterate();
        while (try it.next(testing.io)) |_| count += 1;
        return count;
    }
};

const no_probe: durable.Probe = .{};

test "write creates private directories and a byte-exact 0600 marker" {
    var home = Home.init();
    defer home.deinit();
    inline for (.{ Kind.v1, Kind.v2 }) |kind| {
        try testing.expectEqual(WriteResult.written, try write(testing.io, home.tmp.dir, kind, "abc_DEF-1.x", 1234, .replace, no_probe));
        var buffer: [32]u8 = undefined;
        try testing.expectEqualStrings("v1 1234\n", try home.body(kind, "abc_DEF-1.x", &buffer));
        var dir = try home.markers(kind);
        defer dir.close(testing.io);
        try testing.expectEqual(durable.file_mode, durable.modeOf((try dir.statFile(testing.io, "abc_DEF-1.x", .{})).permissions));
        try testing.expectEqual(durable.dir_mode, durable.modeOf((try dir.stat(testing.io)).permissions));
        try testing.expectEqual(@as(?i64, 1234), try read(testing.io, home.tmp.dir, kind, "abc_DEF-1.x"));
    }
    // Only the two marker directories: no temp file was left in ~/.fx.
    try testing.expectEqual(@as(usize, 2), try home.profileEntries());
}

test "a marker write stages its temp in ~/.fx, never in the marker directory" {
    const Seen = struct {
        home: Dir,
        in_markers: usize = 0,
        in_profile: usize = 0,
        fn hit(ctx: ?*anyopaque, point: durable.Point) void {
            const seen: *@This() = @ptrCast(@alignCast(ctx.?));
            if (point != .replace_temp_synced) return;
            seen.in_profile += temps(seen.home, profile_dir_name);
            seen.in_markers += temps(seen.home, profile_dir_name ++ "/" ++ "usage-recovery");
        }
        fn temps(home: Dir, path: []const u8) usize {
            var dir = home.openDir(testing.io, path, .{ .iterate = true }) catch return 0;
            defer dir.close(testing.io);
            var count: usize = 0;
            var it = dir.iterate();
            while (it.next(testing.io) catch null) |entry| count += @intFromBool(durable.isReplaceTemp(entry.name));
            return count;
        }
    };
    var home = Home.init();
    defer home.deinit();
    var seen: Seen = .{ .home = home.tmp.dir };
    _ = try write(testing.io, home.tmp.dir, .v1, "s", 1, .replace, .{ .ctx = &seen, .hit = Seen.hit });
    try testing.expectEqual(@as(usize, 1), seen.in_profile);
    try testing.expectEqual(@as(usize, 0), seen.in_markers);
}

test "keep_oldest keeps a valid marker; replace rewrites only a different time" {
    var home = Home.init();
    defer home.deinit();
    const io = testing.io;
    try testing.expectEqual(WriteResult.written, try write(io, home.tmp.dir, .v1, "s", 10, .keep_oldest, no_probe));
    try testing.expectEqual(WriteResult.kept, try write(io, home.tmp.dir, .v1, "s", 20, .keep_oldest, no_probe));
    try testing.expectEqual(@as(?i64, 10), try read(io, home.tmp.dir, .v1, "s"));
    try testing.expectEqual(WriteResult.unchanged, try write(io, home.tmp.dir, .v1, "s", 10, .replace, no_probe));
    try testing.expectEqual(WriteResult.written, try write(io, home.tmp.dir, .v1, "s", 30, .replace, no_probe));
    try testing.expectEqual(@as(?i64, 30), try read(io, home.tmp.dir, .v1, "s"));
}

test "a malformed marker is replaced even under keep_oldest" {
    var home = Home.init();
    defer home.deinit();
    try home.plant(.v1, "s", "garbage", 0o600);
    try testing.expectError(error.InvalidUsageRecoveryIndex, read(testing.io, home.tmp.dir, .v1, "s"));
    try testing.expectEqual(WriteResult.written, try write(testing.io, home.tmp.dir, .v1, "s", 5, .keep_oldest, no_probe));
    try testing.expectEqual(@as(?i64, 5), try read(testing.io, home.tmp.dir, .v1, "s"));
}

test "write repairs a 0755 profile and marker directory" {
    var home = Home.init();
    defer home.deinit();
    const io = testing.io;
    try home.tmp.dir.createDir(io, profile_dir_name, .fromMode(0o755));
    try home.tmp.dir.setFilePermissions(io, profile_dir_name, .fromMode(0o755), .{});
    try testing.expectError(error.InvalidUsageRecoveryIndex, list(testing.allocator, io, home.tmp.dir, .v1));
    _ = try write(io, home.tmp.dir, .v1, "s", 1, .replace, no_probe);
    try testing.expectEqual(durable.dir_mode, durable.modeOf((try home.tmp.dir.statFile(io, profile_dir_name, .{})).permissions));
}

test "invalid session ids are refused" {
    var home = Home.init();
    defer home.deinit();
    for ([_][]const u8{ "", ".", "..", "a/b", "a b", "V2" }) |id| {
        try testing.expectError(error.InvalidSessionId, write(testing.io, home.tmp.dir, .v1, id, 1, .replace, no_probe));
    }
    try testing.expect(validSessionId(.v2, "v2"));
    try testing.expect(!validSessionId(.v1, "v2"));
    const long = [_]u8{'a'} ** 256;
    try testing.expect(!validSessionId(.v1, &long));
    try testing.expect(validSessionId(.v1, long[0..255]));
    try testing.expectError(error.InvalidUsageRecoveryMarker, write(testing.io, home.tmp.dir, .v1, "s", -1, .replace, no_probe));
}

test "clear unlinks, reports absence, and refuses a directory entry" {
    var home = Home.init();
    defer home.deinit();
    const io = testing.io;
    try testing.expect(!try clear(io, home.tmp.dir, .v2, "s", no_probe));
    _ = try write(io, home.tmp.dir, .v2, "s", 1, .replace, no_probe);
    try testing.expect(try clear(io, home.tmp.dir, .v2, "s", no_probe));
    try testing.expect(!try clear(io, home.tmp.dir, .v2, "s", no_probe));
    try testing.expectEqual(@as(?i64, null), try read(io, home.tmp.dir, .v2, "s"));

    try home.plant(.v1, "bad", "v1 x\n", 0o600);
    try testing.expect(try clear(io, home.tmp.dir, .v1, "bad", no_probe));

    var dir = try home.markers(.v1);
    defer dir.close(io);
    try dir.createDir(io, "nested", .fromMode(0o700));
    try testing.expectError(error.InvalidUsageRecoveryIndex, clear(io, home.tmp.dir, .v1, "nested", no_probe));
}

test "checkpoint: owes → marker first; keeps the oldest time while owed; clears when settled" {
    var home = Home.init();
    defer home.deinit();
    const io = testing.io;
    const h = home.tmp.dir;

    // Fresh session, first checkpoint owes: marker at the checkpoint time.
    const first = try prepareCheckpoint(io, h, .v1, "s", .{ .now_ms = 100, .saved_at_ms = 0, .saved_owes = false, .next_owes = true }, no_probe);
    try testing.expectEqual(Checkpoint{ .at_ms = 100, .owes = true }, first);
    try testing.expectEqual(@as(?i64, 100), try read(io, h, .v1, "s"));
    try finishCheckpoint(io, h, .v1, "s", first, no_probe);
    try testing.expectEqual(@as(?i64, 100), try read(io, h, .v1, "s"));

    // Still owed: the clock is not ahead, so the time steps past the saved one
    // and the marker keeps its older protected time.
    const second = try prepareCheckpoint(io, h, .v1, "s", .{ .now_ms = 90, .saved_at_ms = 100, .saved_owes = true, .next_owes = true }, no_probe);
    try testing.expectEqual(Checkpoint{ .at_ms = 101, .owes = true }, second);
    try testing.expectEqual(@as(?i64, 100), try read(io, h, .v1, "s"));

    // A lost marker while owed is restored at the saved time.
    _ = try clear(io, h, .v1, "s", no_probe);
    _ = try prepareCheckpoint(io, h, .v1, "s", .{ .now_ms = 200, .saved_at_ms = 101, .saved_owes = true, .next_owes = true }, no_probe);
    try testing.expectEqual(@as(?i64, 101), try read(io, h, .v1, "s"));

    // Settled: no write before, cleared after.
    const settled = try prepareCheckpoint(io, h, .v1, "s", .{ .now_ms = 300, .saved_at_ms = 200, .saved_owes = true, .next_owes = false }, no_probe);
    try testing.expectEqual(@as(?i64, 101), try read(io, h, .v1, "s"));
    try finishCheckpoint(io, h, .v1, "s", settled, no_probe);
    try testing.expectEqual(@as(?i64, null), try read(io, h, .v1, "s"));

    try testing.expectError(error.InvalidSessionFormat, prepareCheckpoint(io, h, .v1, "s", .{ .now_ms = 0, .saved_at_ms = std.math.maxInt(i64), .saved_owes = false, .next_owes = false }, no_probe));
}

test "registry degrades per entry, sorted, with mtimes" {
    var home = Home.init();
    defer home.deinit();
    const io = testing.io;
    const h = home.tmp.dir;
    _ = try write(io, h, .v1, "good-b", 2, .replace, no_probe);
    _ = try write(io, h, .v1, "good-a", 1, .replace, no_probe);
    try home.plant(.v1, ".DS_Store", "\x00\x00\x00\x01Bud1", 0o644);
    try home.plant(.v1, ".good-a.tmp.0123456789abcdef0123456789abcdef", "", 0o600);
    try home.plant(.v1, "empty", "", 0o600);
    try home.plant(.v1, "loose", "v1 3\n", 0o644);
    try home.plant(.v1, "body", "v1 -3\n", 0o600);
    try home.plant(.v1, "bad name", "v1 3\n", 0o600);
    var dir = try home.markers(.v1);
    defer dir.close(io);
    try dir.createDir(io, "folder", .fromMode(0o700));
    try dir.symLink(io, "good-a", "link", .{});

    var registry = try list(testing.allocator, io, h, .v1);
    defer registry.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), registry.omitted);
    try testing.expectEqual(@as(usize, 2), registry.markerCount());

    const Want = struct { name: []const u8, ms: ?i64 = null, why: ?Malformed = null };
    const want = [_]Want{
        .{ .name = ".DS_Store", .why = .unsafe_file },
        .{ .name = ".good-a.tmp.0123456789abcdef0123456789abcdef", .why = .replace_temp },
        .{ .name = "bad name", .why = .invalid_name },
        .{ .name = "body", .why = .invalid_body },
        .{ .name = "empty", .why = .unsafe_file },
        .{ .name = "folder", .why = .not_file },
        .{ .name = "good-a", .ms = 1 },
        .{ .name = "good-b", .ms = 2 },
        .{ .name = "link", .why = .not_file },
        .{ .name = "loose", .why = .unsafe_file },
    };
    try testing.expectEqual(want.len, registry.entries.len);
    for (want, registry.entries) |w, entry| {
        try testing.expectEqualStrings(w.name, entry.name);
        try testing.expect(entry.modified_at_ns != null);
        if (w.ms) |ms| {
            try testing.expectEqual(ms, entry.state.marker);
        } else {
            try testing.expectEqual(w.why.?, entry.state.malformed);
        }
    }
}

test "registry caps listed entries at 512 and counts the rest" {
    var home = Home.init();
    defer home.deinit();
    var name_buffer: [16]u8 = undefined;
    for (0..max_registry_entries + 3) |i| {
        const name = try std.fmt.bufPrint(&name_buffer, "s{d}", .{i});
        try home.plant(.v2, name, "v1 1\n", 0o600);
    }
    var registry = try list(testing.allocator, testing.io, home.tmp.dir, .v2);
    defer registry.deinit(testing.allocator);
    try testing.expectEqual(max_registry_entries, registry.entries.len);
    try testing.expectEqual(@as(usize, 3), registry.omitted);
}

test "registry reads never create anything and reject an unsafe directory" {
    var home = Home.init();
    defer home.deinit();
    const io = testing.io;
    var empty = try list(testing.allocator, io, home.tmp.dir, .v1);
    empty.deinit(testing.allocator);
    try testing.expectEqual(@as(?i64, null), try read(io, home.tmp.dir, .v1, "s"));
    try testing.expectError(error.FileNotFound, home.tmp.dir.statFile(io, profile_dir_name, .{}));

    try home.plant(.v1, "s", "v1 1\n", 0o600);
    var profile = try home.tmp.dir.openDir(io, profile_dir_name, .{});
    defer profile.close(io);
    try profile.setFilePermissions(io, Kind.v1.dirName(), .fromMode(0o755), .{});
    try testing.expectError(error.InvalidUsageRecoveryIndex, list(testing.allocator, io, home.tmp.dir, .v1));
}

test "captured fx markers validate and re-encode byte-identically" {
    const Captured = struct { kind: Kind, id: []const u8, bytes: []const u8 };
    const captured = [_]Captured{
        .{ .kind = .v1, .id = "-0mOs2ToHDxY", .bytes = @embedFile("../testdata/u04/usage-recovery/-0mOs2ToHDxY") },
        .{ .kind = .v1, .id = "7elup-r3q_tk", .bytes = @embedFile("../testdata/u04/usage-recovery/7elup-r3q_tk") },
        .{ .kind = .v1, .id = "Cn0Q2_7cxZ_z", .bytes = @embedFile("../testdata/u04/usage-recovery/Cn0Q2_7cxZ_z") },
        .{ .kind = .v2, .id = "9765RiSMBar-", .bytes = @embedFile("../testdata/u04/usage-recovery-v2/9765RiSMBar-") },
    };
    var home = Home.init();
    defer home.deinit();
    for (captured) |item| {
        try home.plant(item.kind, item.id, item.bytes, 0o600);
        const ms = (try read(testing.io, home.tmp.dir, item.kind, item.id)).?;
        // Rewriting the same time is a no-op; a different time and back
        // produces fx's exact bytes again.
        try testing.expectEqual(WriteResult.unchanged, try write(testing.io, home.tmp.dir, item.kind, item.id, ms, .replace, no_probe));
        _ = try write(testing.io, home.tmp.dir, item.kind, item.id, ms + 1, .replace, no_probe);
        _ = try write(testing.io, home.tmp.dir, item.kind, item.id, ms, .replace, no_probe);
        var buffer: [32]u8 = undefined;
        try testing.expectEqualStrings(item.bytes, try home.body(item.kind, item.id, &buffer));
    }
}

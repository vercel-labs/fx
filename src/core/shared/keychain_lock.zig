//! Where the lock of a Keychain item that is one for the user, whatever the
//! profile, is kept. With `FX_HOME` set, fx processes in different profiles
//! share such an item, the fx login's and the MCP credentials', so their lock
//! is in `~/.fx`, the folder the default profile locks in, and not in each
//! profile (`tests/tla/oauth_session/KeychainLock.tla`). `oauth_session.zig`
//! (the fx login) and `mcp_host/credentials.zig` (the MCP credential store)
//! take their locks through here, so the rule is in one place.
//!
//! The lock stays in the profile when the item isn't one for the user (the
//! profile-file backend), when `FX_HOME` isn't set (the profile is `~/.fx`
//! already), and, with a debug trace line, when `HOME` is not an absolute
//! path, when `~/.fx` can't be opened or made private, and when the lock
//! can't be taken there for any reason but another fx holding it: a link, a
//! file other users can read, a folder, or a fifo in its place. Such a login
//! or credential works as it did before profiles shared its lock, and an older
//! fx in a profile `FX_HOME` moved never shared it.

const std = @import("std");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");
const leased_lock = @import("leased_lock.zig");
const profile_paths = @import("profile_paths.zig");

/// What names a lock in trace lines and says where its files are.
pub const Item = struct {
    /// The `debug_trace` scope.
    scope: []const u8,
    /// How trace lines name the lock.
    label: []const u8,
    /// The folder of `~/.fx` that holds the lock files, or null for `~/.fx`.
    folder: ?[]const u8 = null,
};

/// What the process's environment says about where locks go, as values, so
/// the choice is tested without touching it.
pub const Environment = struct {
    /// `FX_HOME` moved fx's folder.
    fx_home_active: bool,
    /// `HOME`, as the process has it.
    home: ?[]const u8,

    pub fn current() Environment {
        return .{ .fx_home_active = profile_paths.fxHomeActive(), .home = io_mod.getenv("HOME") };
    }
};

const Choice = union(enum) {
    /// The profile: the item is one per profile, or the profile is `~/.fx`.
    profile,
    /// The profile, because `HOME` is not an absolute path.
    home_not_absolute,
    /// `~/.fx`, with this `HOME`.
    shared: []const u8,
};

/// Pure: where the lock of an item goes. `keychain` is whether the item is in
/// the Keychain, one for the user.
fn choose(keychain: bool, env: Environment) Choice {
    if (!keychain or !env.fx_home_active) return .profile;
    const path = env.home orelse return .home_not_absolute;
    if (!std.Io.Dir.path.isAbsolute(path)) return .home_not_absolute;
    return .{ .shared = path };
}

/// The folder that holds the lock files of `item` for every profile, `~/.fx`
/// or its `item.folder` made private if missing, or null when they stay in
/// the profile. A choice other than the plain ones writes a trace line.
pub fn open(keychain: bool, env: Environment, item: Item) ?io_mod.VerifiedDir {
    const parent = switch (choose(keychain, env)) {
        .profile => return null,
        .home_not_absolute => {
            debug_trace.logf(item.scope, "{s} lock kept in the profile step=home err=HomeNotAbsolute", .{item.label});
            return null;
        },
        .shared => |path| path,
    };
    var home = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent, .{ .iterate = true }) catch |err| {
            debug_trace.logf(item.scope, "{s} lock kept in the profile step=open_home err={s}", .{ item.label, @errorName(err) });
            return null;
        },
    };
    defer home.close();
    var fx_dir = io_mod.openOrCreateVerifiedPrivateDir(&home, profile_paths.root_dir_name) catch |err| {
        debug_trace.logf(item.scope, "{s} lock kept in the profile step=open_shared err={s}", .{ item.label, @errorName(err) });
        return null;
    };
    const folder = item.folder orelse return fx_dir;
    defer fx_dir.close();
    return io_mod.openOrCreateVerifiedPrivateDir(&fx_dir, folder) catch |err| {
        debug_trace.logf(item.scope, "{s} lock kept in the profile step=open_folder err={s}", .{ item.label, @errorName(err) });
        return null;
    };
}

/// A lock that was taken.
pub const Held = struct {
    lock: io_mod.TimedAdvisoryLock,
    /// The stamp a leased lock was taken with, 0 for one that isn't leased.
    stamp_ms: i64 = 0,
    /// Whether its file is in the shared folder, and not in the profile's.
    in_shared: bool,
};

/// Takes leased lock `name` (`leased_lock.acquire`) in `shared`, or in `profile`
/// when there is no shared folder or the lock can't be taken there
/// (`keepInProfile`). `error.LockBusy` is another fx holding it, in whichever
/// folder it was taken.
pub fn acquireLeased(
    profile: *io_mod.VerifiedDir,
    shared: ?*io_mod.VerifiedDir,
    name: []const u8,
    started_ms: i64,
    wait_ms: i64,
    ops: io_mod.LockOps,
    item: Item,
) !Held {
    if (shared) |dir| {
        if (leased_lock.acquire(dir, name, started_ms, wait_ms, ops, item.scope, item.label)) |taken| {
            return .{ .lock = taken.lock, .stamp_ms = taken.stamp_ms, .in_shared = true };
        } else |err| try keepInProfile(err, item, name);
    }
    const taken = try leased_lock.acquire(profile, name, started_ms, wait_ms, ops, item.scope, item.label);
    return .{ .lock = taken.lock, .stamp_ms = taken.stamp_ms, .in_shared = false };
}

/// Takes lock `name` in the same folders, if no other fx holds it now:
/// `error.LockBusy` when one does. It is not leased.
pub fn acquireOnce(
    profile: *io_mod.VerifiedDir,
    shared: ?*io_mod.VerifiedDir,
    name: []const u8,
    item: Item,
) !Held {
    if (shared) |dir| {
        if (io_mod.acquireTimedAdvisoryLock(dir, name, 0)) |lock| {
            return .{ .lock = lock, .in_shared = true };
        } else |err| try keepInProfile(err, item, name);
    }
    return .{ .lock = try io_mod.acquireTimedAdvisoryLock(profile, name, 0), .in_shared = false };
}

/// Of the two folders opened for a lock, the one that holds it; the other is
/// closed.
pub fn keepFolder(held: Held, profile: io_mod.VerifiedDir, shared: ?io_mod.VerifiedDir) io_mod.VerifiedDir {
    if (held.in_shared) {
        var unused = profile;
        unused.close();
        return shared.?;
    }
    if (shared) |dir| {
        var unused = dir;
        unused.close();
    }
    return profile;
}

/// The rule for a lock that couldn't be taken in the shared folder: another fx
/// holding it, running out of memory, and a cancel are the caller's to
/// handle; any other error keeps the lock in the profile and says so in one
/// trace line, with the path and the error.
fn keepInProfile(err: anyerror, item: Item, name: []const u8) !void {
    switch (err) {
        error.LockBusy, error.OutOfMemory, error.Cancelled => return err,
        else => {},
    }
    if (item.folder) |folder| {
        debug_trace.logf(item.scope, "{s} lock kept in the profile step=take_shared path=~/{s}/{s}/{s} err={s}", .{ item.label, profile_paths.root_dir_name, folder, name, @errorName(err) });
    } else {
        debug_trace.logf(item.scope, "{s} lock kept in the profile step=take_shared path=~/{s}/{s} err={s}", .{ item.label, profile_paths.root_dir_name, name, @errorName(err) });
    }
}

const testing = std.testing;
const lock_fixtures = @import("lock_fixtures.zig");

const test_item: Item = .{ .scope = "test", .label = "test item" };
const test_folder_item: Item = .{ .scope = "test", .label = "test item", .folder = "locks" };

/// A folder `name` under `tmp`, opened.
fn testDir(tmp: testing.TmpDir, name: []const u8) !io_mod.VerifiedDir {
    try tmp.dir.createDirPath(testing.io, name);
    return .{ .dir = try tmp.dir.openDir(testing.io, name, .{ .iterate = true }) };
}

test "the lock goes to ~/.fx only for a Keychain item under FX_HOME, with an absolute HOME" {
    const home = "/Users/example";
    try testing.expectEqualStrings(home, choose(true, .{ .fx_home_active = true, .home = home }).shared);
    // The profile-file backend saves a login per profile, so it locks there.
    try testing.expectEqual(Choice.profile, choose(false, .{ .fx_home_active = true, .home = home }));
    // No FX_HOME: the profile is ~/.fx already.
    try testing.expectEqual(Choice.profile, choose(true, .{ .fx_home_active = false, .home = home }));
    try testing.expectEqual(Choice.profile, choose(true, .{ .fx_home_active = false, .home = null }));
    // A HOME fx can't build ~/.fx from keeps the lock in the profile.
    for ([_]?[]const u8{ null, "", "relative/home", "~" }) |bad| {
        try testing.expectEqual(Choice.home_not_absolute, choose(true, .{ .fx_home_active = true, .home = bad }));
    }
}

test "a HOME that is not an absolute path keeps the lock in the profile and says so" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try lock_fixtures.traceTo(tmp);
    defer debug_trace.resetForTest();

    for ([_]?[]const u8{ null, "", "relative/home" }) |bad| {
        try testing.expect(open(true, .{ .fx_home_active = true, .home = bad }, test_item) == null);
    }
    const trace = try lock_fixtures.readTrace(tmp);
    defer testing.allocator.free(trace);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, trace, "[test] test item lock kept in the profile step=home err=HomeNotAbsolute"));
    // The plain cases say nothing.
    try testing.expect(open(true, .{ .fx_home_active = false, .home = null }, test_item) == null);
    try testing.expect(open(false, .{ .fx_home_active = true, .home = null }, test_item) == null);
    const after = try lock_fixtures.readTrace(tmp);
    defer testing.allocator.free(after);
    try testing.expectEqual(trace.len, after.len);
}

test "~/.fx and the item's folder are made private, and one that can't be opened keeps the lock in the profile and says so" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home);
    try lock_fixtures.traceTo(tmp);
    defer debug_trace.resetForTest();
    const env: Environment = .{ .fx_home_active = true, .home = home };

    var made = open(true, env, test_folder_item) orelse return error.TestExpectedSharedLockDir;
    made.close();
    for ([_][]const u8{ ".fx", ".fx/locks" }) |path| {
        const stat = try tmp.dir.statFile(testing.io, path, .{});
        try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    }
    // An existing ~/.fx other users could write is made private, as the default profile does.
    {
        // Iterating, so Linux gives a descriptor `fchmod` accepts.
        var fx_dir = try tmp.dir.openDir(testing.io, ".fx", .{ .iterate = true });
        defer fx_dir.close(testing.io);
        try fx_dir.setPermissions(testing.io, std.Io.File.Permissions.fromMode(0o777));
    }
    var again = open(true, env, test_item) orelse return error.TestExpectedSharedLockDir;
    again.close();
    const reopened = try tmp.dir.statFile(testing.io, ".fx", .{});
    try testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(reopened.permissions.toMode() & 0o777)));

    // A file where ~/.fx should be, a folder that isn't there, and a file where its folder should be.
    try tmp.dir.deleteTree(testing.io, ".fx");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".fx", .data = "" });
    try testing.expect(open(true, env, test_item) == null);
    try tmp.dir.deleteFile(testing.io, ".fx");
    try testing.expect(open(true, .{ .fx_home_active = true, .home = "/nonexistent-fx-home-for-test" }, test_item) == null);
    try tmp.dir.createDirPath(testing.io, ".fx");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".fx/locks", .data = "" });
    try testing.expect(open(true, env, test_folder_item) == null);

    const trace = try lock_fixtures.readTrace(tmp);
    defer testing.allocator.free(trace);
    try testing.expect(std.mem.find(u8, trace, "test item lock kept in the profile step=open_shared err=") != null);
    try testing.expect(std.mem.find(u8, trace, "test item lock kept in the profile step=open_home err=FileNotFound") != null);
    try testing.expect(std.mem.find(u8, trace, "test item lock kept in the profile step=open_folder err=") != null);
}

test "a shared lock is taken in the shared folder, and another fx holding it is never worked around" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var shared = try testDir(tmp, "home/.fx");
    defer shared.close();

    var first_profile = try testDir(tmp, "profile-a");
    defer first_profile.close();
    var first = try acquireLeased(&first_profile, &shared, "x.lock", io_mod.awakeMilliTimestamp(), 0, .{}, test_item);
    defer first.lock.release();
    try testing.expect(first.in_shared);
    try testing.expect(first.stamp_ms > 0);
    _ = try tmp.dir.statFile(testing.io, "home/.fx/x.lock", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "profile-a/x.lock", .{}));

    var second_profile = try testDir(tmp, "profile-b");
    defer second_profile.close();
    try testing.expectError(error.LockBusy, acquireLeased(&second_profile, &shared, "x.lock", io_mod.awakeMilliTimestamp(), 0, .{}, test_item));
    try testing.expectError(error.LockBusy, acquireOnce(&second_profile, &shared, "x.lock", test_item));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "profile-b/x.lock", .{}));
}

test "without a shared folder the lock is the profile's, taken once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var profile = try testDir(tmp, "profile");
    defer profile.close();

    var leased = try acquireLeased(&profile, null, "x.lock", io_mod.awakeMilliTimestamp(), 0, .{}, test_item);
    try testing.expect(!leased.in_shared);
    try testing.expectError(error.LockBusy, acquireOnce(&profile, null, "x.lock", test_item));
    leased.lock.release();
    var once = try acquireOnce(&profile, null, "x.lock", test_item);
    try testing.expect(!once.in_shared);
    try testing.expectEqual(@as(i64, 0), once.stamp_ms);
    once.lock.release();
}

/// `~/.fx/x.lock` in `state`: each way of taking the lock keeps it in the
/// profile, with one trace line that names the path and the error.
fn expectKeptInProfile(state: lock_fixtures.State) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try lock_fixtures.traceTo(tmp);
    defer debug_trace.resetForTest();
    var shared = try testDir(tmp, "home/.fx");
    defer shared.close();
    try lock_fixtures.plant(tmp.dir, "home/.fx/x.lock", state);
    var profile = try testDir(tmp, "profile");
    defer profile.close();

    var leased = try acquireLeased(&profile, &shared, "x.lock", io_mod.awakeMilliTimestamp(), 0, .{}, test_item);
    try testing.expect(!leased.in_shared);
    try testing.expectError(error.LockBusy, acquireLeased(&profile, &shared, "x.lock", io_mod.awakeMilliTimestamp(), 0, .{}, test_item));
    leased.lock.release();
    var once = try acquireOnce(&profile, &shared, "x.lock", test_item);
    try testing.expect(!once.in_shared);
    try testing.expectError(error.LockBusy, acquireOnce(&profile, &shared, "x.lock", test_item));
    once.lock.release();
    _ = try tmp.dir.statFile(testing.io, "profile/x.lock", .{});

    const trace = try lock_fixtures.readTrace(tmp);
    defer testing.allocator.free(trace);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, trace, "test item lock kept in the profile step=take_shared path=~/.fx/x.lock err="));
}

test "a symlink in place of the shared lock keeps it in the profile" {
    try expectKeptInProfile(.symlink);
}

test "a shared lock file of mode 644 keeps it in the profile" {
    try expectKeptInProfile(.mode_644);
}

test "a folder in place of the shared lock keeps it in the profile" {
    try expectKeptInProfile(.folder);
}

test "a fifo in place of the shared lock keeps it in the profile" {
    try expectKeptInProfile(.fifo);
}

test "a lock in the item's folder names it in the trace, and the folder that holds it stays open" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try lock_fixtures.traceTo(tmp);
    defer debug_trace.resetForTest();
    var shared = try testDir(tmp, "home/.fx/locks");
    var profile = try testDir(tmp, "profile");
    try lock_fixtures.plant(tmp.dir, "home/.fx/locks/y.lock", .folder);

    var held = try acquireOnce(&profile, &shared, "y.lock", test_folder_item);
    try testing.expect(!held.in_shared);
    var folder = keepFolder(held, profile, shared);
    defer folder.close();
    // The profile's folder holds the lock; the shared one was closed.
    _ = try folder.dir.statFile(testing.io, "y.lock", .{});
    held.lock.release();

    const trace = try lock_fixtures.readTrace(tmp);
    defer testing.allocator.free(trace);
    try testing.expect(std.mem.find(u8, trace, "step=take_shared path=~/.fx/locks/y.lock err=") != null);
}

test "keepFolder keeps the shared folder when it holds the lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var shared = try testDir(tmp, "home/.fx");
    var profile = try testDir(tmp, "profile");
    var held = try acquireOnce(&profile, &shared, "z.lock", test_item);
    try testing.expect(held.in_shared);
    var folder = keepFolder(held, profile, shared);
    defer folder.close();
    _ = try folder.dir.statFile(testing.io, "z.lock", .{});
    held.lock.release();
}

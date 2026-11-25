//! The locked write of `remote` into `~/.fx/sandbox/config.json` (spec U9).
//! Setup hands over the destination it confirmed. The write takes
//! `config.lock`, reads the file again, and writes only the `remote` key. It
//! refuses to write when a key other than `remote` changed since this process
//! loaded the file, and it never reads or writes through a symlink. The folder
//! comes from `fx_home`, which the host sets, never from model or tool input.

const std = @import("std");
const config = @import("config.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const remote_slot = @import("remote_slot.zig");
const setup = @import("setup.zig");

/// How long the write waits for `config.lock`, the same limit as V2 (spec U9).
pub const lock_wait_ms: u64 = 60 * 1000;

/// A `.config.json.tmp.*` file this old, or older, is left by a write that did
/// not finish. The next write deletes it (spec U9).
pub const stale_temp_age_s: i64 = 60 * 60;

const sandbox_name = "sandbox";
const config_name = "config.json";
const lock_name = "config.lock";
const temp_prefix = ".config.json.tmp.";
const symlink_text = "{s} is a symbolic link; fx does not write through links. Replace it with a regular file, or add the remote section by hand.";

/// The fx home that holds `sandbox/`, and the user's home for `~/` in the config.
pub const Paths = struct {
    fx_home: []const u8,
    home: []const u8,
};

/// Writes `destination` as the config's `remote`. `loaded` is the fingerprint
/// of the keys other than `remote` that this process loaded. `loaded_remote` is
/// the `remote` this process has: the one it loaded, or the one its own write
/// set (null when it has none). `now_s` is the Unix time in seconds: it sets
/// `confirmed_at` and ages the stale temp files. The result is setup's
/// `WriteResult`, so the host passes it to `setup.step`. An `invalid` result's
/// text is allocated with `alloc`, which the caller frees.
pub fn writeRemote(
    alloc: std.mem.Allocator,
    paths: Paths,
    loaded: config.Fingerprint,
    loaded_remote: ?remote_slot.Destination,
    destination: setup.Destination,
    cancel_flag: *const std.atomic.Value(bool),
    now_s: i64,
) setup.WriteResult {
    return writeWithLockLimit(alloc, paths, loaded, loaded_remote, destination, cancel_flag, now_s, lock_wait_ms);
}

/// `writeRemote` with the lock wait as a parameter, so a test can make it short.
fn writeWithLockLimit(
    alloc: std.mem.Allocator,
    paths: Paths,
    loaded: config.Fingerprint,
    loaded_remote: ?remote_slot.Destination,
    destination: setup.Destination,
    cancel_flag: *const std.atomic.Value(bool),
    now_s: i64,
    lock_limit_ms: u64,
) setup.WriteResult {
    const result = writeLocked(alloc, paths, loaded, loaded_remote, destination, cancel_flag, now_s, lock_limit_ms);
    traceResult(result);
    return result;
}

fn writeLocked(
    alloc: std.mem.Allocator,
    paths: Paths,
    loaded: config.Fingerprint,
    loaded_remote: ?remote_slot.Destination,
    destination: setup.Destination,
    cancel_flag: *const std.atomic.Value(bool),
    now_s: i64,
    lock_limit_ms: u64,
) setup.WriteResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const confirmed_at = isoTime(arena, now_s) catch return failed(.write_failed);

    const zio = io_mod.getIo();
    // The parent of a folder that may be created is opened with iteration: Linux returns an O_PATH handle
    // otherwise, and the sync that follows a create fails on it with EBADF.
    var home_dir = io_mod.openDirAbsoluteNoFollow(paths.fx_home, .{ .iterate = true }) catch return failed(.write_failed);
    defer home_dir.close(zio);
    var sandbox = io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, sandbox_name) catch return failed(.write_failed);
    defer sandbox.close();

    var lock = io_mod.acquireTimedAdvisoryLockCancellable(&sandbox, lock_name, lock_limit_ms, cancel_flag) catch |err| return switch (err) {
        error.LockBusy => failed(.write_lock_busy),
        error.Cancelled => .canceled,
        else => failed(.write_failed),
    };
    defer lock.release();

    return writeUnderLock(alloc, arena, paths, loaded, loaded_remote, destination, &sandbox, confirmed_at, now_s);
}

fn writeUnderLock(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    paths: Paths,
    loaded: config.Fingerprint,
    loaded_remote: ?remote_slot.Destination,
    destination: setup.Destination,
    sandbox: *io_mod.VerifiedDir,
    confirmed_at: []const u8,
    now_s: i64,
) setup.WriteResult {
    const config_path = std.Io.Dir.path.join(arena, &.{ paths.fx_home, sandbox_name, config_name }) catch return failed(.write_failed);
    if (isSymbolicLink(sandbox)) return invalid(alloc, symlink_text, .{config_path});

    const text = readConfigText(arena, sandbox) catch |err| switch (err) {
        error.OutOfMemory => return failed(.write_failed),
        else => return invalid(alloc, "{s}: could not be read: {s}", .{ config_path, @errorName(err) }),
    };

    var diagnostic: config.Diagnostic = .{};
    var current: config.Config = .{};
    if (text) |bytes| {
        current = config.parse(arena, bytes, paths.home, &diagnostic) catch |err| switch (err) {
            error.OutOfMemory => return failed(.write_failed),
            error.InvalidSandboxConfig => return invalid(alloc, "{s}: {s}", .{ config_path, diagnostic.message }),
        };
    }

    const fingerprint = config.fingerprintWithoutRemote(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return failed(.write_failed),
        error.InvalidSandboxConfig => return invalid(alloc, "{s}: the keys could not be read", .{config_path}),
    };
    if (!std.mem.eql(u8, &fingerprint, &loaded)) return .config_changed;

    // The file's remote is the one this process has, so the destination the user
    // consented to replaces it. Otherwise another process changed it: the same
    // destination is kept, and any other is a conflict (spec U9).
    if (current.remote) |remote| {
        const has_loaded_remote = if (loaded_remote) |known|
            sameIds(remote.team_id, remote.project_id, remote.user_id, known.team_id, known.project_id, known.user_id)
        else
            false;
        if (!has_loaded_remote) {
            const same = sameIds(remote.team_id, remote.project_id, remote.user_id, destination.team.id, destination.project.id, destination.user_id);
            return if (same) .kept else .config_changed;
        }
    }

    const bytes = configWithRemote(arena, text, destination, confirmed_at) catch |err| switch (err) {
        error.OutOfMemory => return failed(.write_failed),
        error.InvalidSandboxConfig => return invalid(alloc, "{s}: the keys could not be read", .{config_path}),
    };
    var check: config.Diagnostic = .{};
    _ = config.parse(arena, bytes, paths.home, &check) catch return failed(.write_failed);

    io_mod.durableReplaceVerified(arena, sandbox, config_name, bytes) catch return failed(.write_failed);
    removeStaleTemps(sandbox, temp_prefix, now_s);
    return .written;
}

/// Whether two remotes name the same team, project and user.
fn sameIds(team_a: []const u8, project_a: []const u8, user_a: []const u8, team_b: []const u8, project_b: []const u8, user_b: []const u8) bool {
    return std.mem.eql(u8, team_a, team_b) and
        std.mem.eql(u8, project_a, project_b) and
        std.mem.eql(u8, user_a, user_b);
}

/// Whether `config.json` is a symlink. A lookup that fails is not a link here:
/// the read reports that failure with its own text.
fn isSymbolicLink(sandbox: *io_mod.VerifiedDir) bool {
    const stat = sandbox.dir.statFile(io_mod.getIo(), config_name, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .sym_link;
}

fn invalid(alloc: std.mem.Allocator, comptime format: []const u8, args: anytype) setup.WriteResult {
    const message = alloc.print(format, args) catch return failed(.write_failed);
    return .{ .invalid = message };
}

const WithRemoteError = error{ OutOfMemory, InvalidSandboxConfig };

/// The config text with `remote` set to `destination`. Every other key keeps its
/// value and its place in the file. The file is written with two-space
/// indentation, so its formatting changes; the canonical fingerprint does not.
fn configWithRemote(
    arena: std.mem.Allocator,
    text: ?[]const u8,
    destination: setup.Destination,
    confirmed_at: []const u8,
) WithRemoteError![]const u8 {
    var root: std.json.Value = .{ .object = .empty };
    if (text) |bytes| {
        root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSandboxConfig,
        };
    }
    if (root != .object) return error.InvalidSandboxConfig;
    try root.object.put(arena, "remote", try remoteValue(arena, destination, confirmed_at));

    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

fn remoteValue(
    arena: std.mem.Allocator,
    destination: setup.Destination,
    confirmed_at: []const u8,
) std.mem.Allocator.Error!std.json.Value {
    var remote: std.json.ObjectMap = .empty;
    try remote.put(arena, "backend", .{ .string = "vercel" });
    try remote.put(arena, "team_id", .{ .string = destination.team.id });
    try remote.put(arena, "team_slug", .{ .string = destination.team.slug });
    try remote.put(arena, "project_id", .{ .string = destination.project.id });
    try remote.put(arena, "project_name", .{ .string = destination.project.name });
    try remote.put(arena, "user_id", .{ .string = destination.user_id });
    try remote.put(arena, "confirmed_at", .{ .string = confirmed_at });
    return .{ .object = remote };
}

/// The config text, or null when there is no file. Any other file that is not
/// a regular file is an error, so the write never reads through a link.
fn readConfigText(arena: std.mem.Allocator, sandbox: *io_mod.VerifiedDir) !?[]const u8 {
    var file = io_mod.openExistingReadOnlyRegularFile(sandbox.dir, config_name, .no_follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(arena, &file, config.max_bytes);
}

/// Deletes the leftover temp files named `prefix` that are older than the stale age
/// (U9, V5). Only regular files with one link are deleted. Every durable write that
/// leaves temp files calls this, so the age rule is written once.
pub fn removeStaleTemps(dir: *io_mod.VerifiedDir, prefix: []const u8, now_s: i64) void {
    const zio = io_mod.getIo();
    const cutoff_s = now_s - stale_temp_age_s;
    var entries = dir.dir.iterate();
    while (entries.next(zio) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const stat = dir.dir.statFile(zio, entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file or stat.nlink != 1) continue;
        if (stat.mtime.toSeconds() > cutoff_s) continue;
        dir.dir.deleteFile(zio, entry.name) catch continue;
    }
}

// The other copy is `formatIso8601` in src/acp/sessions.zig; core cannot import acp.
/// `now_s` as an ISO 8601 UTC time in whole seconds, as the driver writes it.
fn isoTime(arena: std.mem.Allocator, now_s: i64) ![]const u8 {
    const secs = std.math.cast(u64, now_s) orelse return error.InvalidClock;
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return arena.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

fn failed(reason: setup.Reason) setup.WriteResult {
    return .{ .failed = reason };
}

fn traceResult(result: setup.WriteResult) void {
    switch (result) {
        .failed => |reason| debug_trace.logf("config", "event=remote_write outcome=failed reason={s}", .{@tagName(reason)}),
        else => debug_trace.logf("config", "event=remote_write outcome={s}", .{@tagName(result)}),
    }
}

const testing = std.testing;

const test_now_s: i64 = 1_800_000_000;
const test_home = "/Users/example";
const loaded_text = "{\"grace_ms\":2000}";
const same_remote_text = "{\"grace_ms\":2000,\"remote\":{\"backend\":\"vercel\",\"team_id\":\"team_1\",\"team_slug\":\"acme\",\"project_id\":\"prj_1\",\"project_name\":\"repo\",\"user_id\":\"usr_1\",\"confirmed_at\":\"2026-11-21T10:00:00Z\"}}";

const Racer = struct {
    alloc: std.mem.Allocator,
    paths: Paths,
    loaded: config.Fingerprint,
    loaded_remote: ?remote_slot.Destination = null,
    destination: setup.Destination,
    cancel: std.atomic.Value(bool) = .init(false),
    result: setup.WriteResult = .written,

    fn run(self: *Racer) void {
        self.result = writeRemote(self.alloc, self.paths, self.loaded, self.loaded_remote, self.destination, &self.cancel, test_now_s);
    }
};

fn testDestination() setup.Destination {
    return .{
        .team = .{ .id = "team_1", .slug = "acme", .name = "Acme" },
        .project = .{ .id = "prj_1", .name = "repo" },
        .user_id = "usr_1",
    };
}

fn otherProject() setup.Destination {
    var destination = testDestination();
    destination.project = .{ .id = "prj_2", .name = "other" };
    return destination;
}

/// Creates `fxhome/sandbox` under `dir` and returns the absolute `fxhome`.
fn makeHome(alloc: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    try dir.createDirPath(testing.io, "fxhome/sandbox");
    return io_mod.dirRealpathAlloc(alloc, dir, "fxhome");
}

fn putConfig(dir: std.Io.Dir, text: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = "fxhome/sandbox/config.json", .data = text });
}

fn readConfig(arena: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(testing.io, "fxhome/sandbox/config.json", arena, .limited(config.max_bytes));
}

fn fingerprintOf(alloc: std.mem.Allocator, text: ?[]const u8) !config.Fingerprint {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    return config.fingerprintWithoutRemote(arena_state.allocator(), text);
}

fn writeOnce(
    alloc: std.mem.Allocator,
    fx_home: []const u8,
    loaded: config.Fingerprint,
    destination: setup.Destination,
) setup.WriteResult {
    return writeOnceWithRemote(alloc, fx_home, loaded, null, destination);
}

fn writeOnceWithRemote(
    alloc: std.mem.Allocator,
    fx_home: []const u8,
    loaded: config.Fingerprint,
    loaded_remote: ?remote_slot.Destination,
    destination: setup.Destination,
) setup.WriteResult {
    var cancel = std.atomic.Value(bool).init(false);
    return writeRemote(alloc, .{ .fx_home = fx_home, .home = test_home }, loaded, loaded_remote, destination, &cancel, test_now_s);
}

/// Runs one write in its own thread. `entered` is set before the write starts
/// waiting for the lock, so the test can cancel it without a sleep.
const CancelWait = struct {
    alloc: std.mem.Allocator,
    paths: Paths,
    loaded: config.Fingerprint,
    destination: setup.Destination,
    cancel: std.atomic.Value(bool) = .init(false),
    entered: std.Io.Event = .unset,
    result: setup.WriteResult = .written,

    fn run(self: *CancelWait) void {
        self.entered.set(io_mod.getIo());
        self.result = writeWithLockLimit(self.alloc, self.paths, self.loaded, null, self.destination, &self.cancel, test_now_s, 5000);
    }
};

test "a first write into an fx home with no sandbox folder creates it, and the write succeeds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    try tmp.dir.createDirPath(testing.io, "fxhome");
    const fx_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fxhome");
    defer alloc.free(fx_home);

    const result = writeOnce(alloc, fx_home, config.absent_fingerprint, testDestination());
    try testing.expect(result == .written);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const text = try readConfig(arena_state.allocator(), tmp.dir);
    try testing.expect(std.mem.find(u8, text, "usr_1") != null);
}

test "a new write sets remote when there was no config file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);

    const result = writeOnce(alloc, fx_home, config.absent_fingerprint, testDestination());
    try testing.expect(result == .written);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try readConfig(arena, tmp.dir);
    var diagnostic: config.Diagnostic = .{};
    const cfg = try config.parse(arena, text, test_home, &diagnostic);
    const remote = cfg.remote.?;
    try testing.expectEqualStrings("team_1", remote.team_id);
    try testing.expectEqualStrings("acme", remote.team_slug);
    try testing.expectEqualStrings("prj_1", remote.project_id);
    try testing.expectEqualStrings("repo", remote.project_name);
    try testing.expectEqualStrings("usr_1", remote.user_id);
    try testing.expectEqualStrings("2027-01-15T08:00:00Z", remote.confirmed_at);
}

test "a write keeps every other key with its value, in the file's order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const original =
        \\{
        \\  "provider": ["sandbox-cli"],
        \\  "provider_args": ["--json"],
        \\  "grace_ms": 2000,
        \\  "rules": [{"command": "zig build*", "runner": "remote"}],
        \\  "workspaces": {"/Users/example/repo": "remote"},
        \\  "env": ["PATH"],
        \\  "profiles": {"media": ["--gpu"]},
        \\  "include": {"/Users/example/repo": ["dist/out.json"]},
        \\  "bring_back": {"/Users/example/repo": ["dist/out.json"]},
        \\  "vcpus": 2
        \\}
    ;
    try putConfig(tmp.dir, original);
    const loaded = try fingerprintOf(alloc, original);

    const result = writeOnce(alloc, fx_home, loaded, testDestination());
    try testing.expect(result == .written);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try readConfig(arena, tmp.dir);
    const written_fingerprint = try fingerprintOf(alloc, text);
    try testing.expectEqualSlices(u8, &loaded, &written_fingerprint);

    const names = [_][]const u8{ "provider", "provider_args", "grace_ms", "rules", "workspaces", "env", "profiles", "include", "bring_back", "vcpus", "remote" };
    const written = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const keys = written.object.keys();
    try testing.expectEqual(names.len, keys.len);
    for (names, keys) |want, got| try testing.expectEqualStrings(want, got);
}

test "invalid JSON is refused as invalid, and the file is not overwritten" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try putConfig(tmp.dir, "{not json");

    const result = writeOnce(alloc, fx_home, config.absent_fingerprint, testDestination());
    try testing.expect(result == .invalid);
    defer alloc.free(result.invalid);
    try testing.expect(std.mem.startsWith(u8, result.invalid, fx_home));

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expectEqualStrings("{not json", try readConfig(arena_state.allocator(), tmp.dir));
}

test "a key other than remote that changed after load is E14, and the file is not overwritten" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const loaded = try fingerprintOf(alloc, loaded_text);
    try putConfig(tmp.dir, "{\"grace_ms\":3000}");

    const result = writeOnce(alloc, fx_home, loaded, testDestination());
    try testing.expect(result == .config_changed);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expectEqualStrings("{\"grace_ms\":3000}", try readConfig(arena_state.allocator(), tmp.dir));
}

test "the same remote set meanwhile by another process is kept, and the file is not written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const loaded = try fingerprintOf(alloc, loaded_text);
    try putConfig(tmp.dir, same_remote_text);

    const result = writeOnce(alloc, fx_home, loaded, testDestination());
    try testing.expect(result == .kept);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expectEqualStrings(same_remote_text, try readConfig(arena_state.allocator(), tmp.dir));
}

/// The remote this process loaded: the one `same_remote_text` holds.
fn loadedSameRemote() remote_slot.Destination {
    return .{ .team_id = "team_1", .team_slug = "acme", .project_id = "prj_1", .project_name = "repo", .user_id = "usr_1" };
}

/// A remote this process did not load: the file's remote changed after load.
fn loadedOtherRemote() remote_slot.Destination {
    return .{ .team_id = "team_1", .team_slug = "acme", .project_id = "prj_0", .project_name = "old", .user_id = "usr_1" };
}

test "a file remote that is still the one this process loaded is replaced by the consented destination" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const loaded = try fingerprintOf(alloc, loaded_text);
    try putConfig(tmp.dir, same_remote_text);
    var destination = testDestination();
    destination.user_id = "usr_2";

    const result = writeOnceWithRemote(alloc, fx_home, loaded, loadedSameRemote(), destination);
    try testing.expect(result == .written);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: config.Diagnostic = .{};
    const cfg = try config.parse(arena, try readConfig(arena, tmp.dir), test_home, &diagnostic);
    try testing.expectEqualStrings("usr_2", cfg.remote.?.user_id);
}

test "a file remote another process set to the destination is kept, and the file is not written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const loaded = try fingerprintOf(alloc, loaded_text);
    try putConfig(tmp.dir, same_remote_text);

    const result = writeOnceWithRemote(alloc, fx_home, loaded, loadedOtherRemote(), testDestination());
    try testing.expect(result == .kept);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expectEqualStrings(same_remote_text, try readConfig(arena_state.allocator(), tmp.dir));
}

test "a file remote another process set to the same project for another user is E14, and the file is not overwritten" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const loaded = try fingerprintOf(alloc, loaded_text);
    try putConfig(tmp.dir, same_remote_text);
    var destination = testDestination();
    destination.user_id = "usr_2";

    const result = writeOnceWithRemote(alloc, fx_home, loaded, loadedOtherRemote(), destination);
    try testing.expect(result == .config_changed);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expectEqualStrings(same_remote_text, try readConfig(arena_state.allocator(), tmp.dir));
}

test "a different remote set meanwhile by another process is E14, and the file is not overwritten" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const loaded = try fingerprintOf(alloc, loaded_text);
    try putConfig(tmp.dir, same_remote_text);

    const result = writeOnce(alloc, fx_home, loaded, otherProject());
    try testing.expect(result == .config_changed);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expectEqualStrings(same_remote_text, try readConfig(arena_state.allocator(), tmp.dir));
}

test "the written folder is 0700 and the config file 0600" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);

    const result = writeOnce(alloc, fx_home, config.absent_fingerprint, testDestination());
    try testing.expect(result == .written);

    const file_stat = try tmp.dir.statFile(testing.io, "fxhome/sandbox/config.json", .{});
    try testing.expectEqual(0o600, file_stat.permissions.toMode() & 0o777);
    var sandbox_dir = try tmp.dir.openDir(testing.io, "fxhome/sandbox", .{});
    defer sandbox_dir.close(testing.io);
    const dir_stat = try sandbox_dir.stat(testing.io);
    try testing.expectEqual(0o700, dir_stat.permissions.toMode() & 0o777);
}

test "a stale temp file is deleted and a fresh one is kept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fxhome/sandbox/.config.json.tmp.stale", .data = "old" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fxhome/sandbox/.config.json.tmp.fresh", .data = "new" });
    try tmp.dir.setTimestamps(testing.io, "fxhome/sandbox/.config.json.tmp.stale", .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, test_now_s - 2 * 60 * 60) * std.time.ns_per_s } },
    });
    try tmp.dir.setTimestamps(testing.io, "fxhome/sandbox/.config.json.tmp.fresh", .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, test_now_s - 10 * 60) * std.time.ns_per_s } },
    });

    const result = writeOnce(alloc, fx_home, config.absent_fingerprint, testDestination());
    try testing.expect(result == .written);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "fxhome/sandbox/.config.json.tmp.stale", .{}));
    _ = try tmp.dir.statFile(testing.io, "fxhome/sandbox/.config.json.tmp.fresh", .{});
}

test "two writes at once: one is written and the other kept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const paths: Paths = .{ .fx_home = fx_home, .home = test_home };

    var first: Racer = .{ .alloc = alloc, .paths = paths, .loaded = config.absent_fingerprint, .destination = testDestination() };
    var second: Racer = .{ .alloc = alloc, .paths = paths, .loaded = config.absent_fingerprint, .destination = testDestination() };
    const a = try std.Thread.spawn(.{}, Racer.run, .{&first});
    const b = try std.Thread.spawn(.{}, Racer.run, .{&second});
    a.join();
    b.join();
    try testing.expect((first.result == .written and second.result == .kept) or
        (first.result == .kept and second.result == .written));
}

test "two writes at once for different projects: one is written and the other is E14" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    const paths: Paths = .{ .fx_home = fx_home, .home = test_home };

    var first: Racer = .{ .alloc = alloc, .paths = paths, .loaded = config.absent_fingerprint, .destination = testDestination() };
    var second: Racer = .{ .alloc = alloc, .paths = paths, .loaded = config.absent_fingerprint, .destination = otherProject() };
    const a = try std.Thread.spawn(.{}, Racer.run, .{&first});
    const b = try std.Thread.spawn(.{}, Racer.run, .{&second});
    a.join();
    b.join();
    try testing.expect((first.result == .written and second.result == .config_changed) or
        (first.result == .config_changed and second.result == .written));
}

test "a lock held past the wait is E9 write: config lock busy, and nothing is written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try putConfig(tmp.dir, loaded_text);
    const loaded = try fingerprintOf(alloc, loaded_text);

    var home_dir = try io_mod.openDirAbsoluteNoFollow(fx_home, .{ .iterate = true });
    defer home_dir.close(testing.io);
    var sandbox = try io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, "sandbox");
    defer sandbox.close();
    var held = try io_mod.acquireTimedAdvisoryLock(&sandbox, "config.lock", 1000);
    defer held.release();

    var cancel = std.atomic.Value(bool).init(false);
    const result = writeWithLockLimit(alloc, .{ .fx_home = fx_home, .home = test_home }, loaded, null, testDestination(), &cancel, test_now_s, 20);
    try testing.expect(result == .failed);
    try testing.expectEqual(setup.Reason.write_lock_busy, result.failed);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expectEqualStrings(loaded_text, try readConfig(arena_state.allocator(), tmp.dir));
}

test "a cancel while the lock is awaited ends canceled, and nothing is written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try putConfig(tmp.dir, loaded_text);
    const loaded = try fingerprintOf(alloc, loaded_text);

    var home_dir = try io_mod.openDirAbsoluteNoFollow(fx_home, .{ .iterate = true });
    defer home_dir.close(testing.io);
    var sandbox = try io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, "sandbox");
    defer sandbox.close();
    var held = try io_mod.acquireTimedAdvisoryLock(&sandbox, "config.lock", 1000);
    defer held.release();

    var wait: CancelWait = .{
        .alloc = alloc,
        .paths = .{ .fx_home = fx_home, .home = test_home },
        .loaded = loaded,
        .destination = testDestination(),
    };
    const writer = try std.Thread.spawn(.{}, CancelWait.run, .{&wait});
    try wait.entered.waitTimeout(io_mod.getIo(), .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    wait.cancel.store(true, .release);
    writer.join();
    try testing.expect(wait.result == .canceled);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expectEqualStrings(loaded_text, try readConfig(arena_state.allocator(), tmp.dir));
}

test "a symlinked config.json is refused with its reason, and the file it points to is not touched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const fx_home = try makeHome(alloc, tmp.dir);
    defer alloc.free(fx_home);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.json", .data = "keep" });
    const outside = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outside.json");
    defer alloc.free(outside);
    var sandbox_dir = try tmp.dir.openDir(testing.io, "fxhome/sandbox", .{});
    defer sandbox_dir.close(testing.io);
    try sandbox_dir.symLink(testing.io, outside, "config.json", .{});

    const result = writeOnce(alloc, fx_home, config.absent_fingerprint, testDestination());
    try testing.expect(result == .invalid);
    defer alloc.free(result.invalid);
    const expected = try alloc.print("{s}/sandbox/config.json is a symbolic link; fx does not write through links. Replace it with a regular file, or add the remote section by hand.", .{fx_home});
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, result.invalid);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("keep", try tmp.dir.readFileAlloc(testing.io, "outside.json", arena, .limited(64)));
    const link = try tmp.dir.statFile(testing.io, "fxhome/sandbox/config.json", .{ .follow_symlinks = false });
    try testing.expect(link.kind == .sym_link);
}

test "a symlinked sandbox folder is refused, and nothing is written outside fx_home" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    try tmp.dir.createDirPath(testing.io, "fxhome");
    try tmp.dir.createDirPath(testing.io, "outside");
    const fx_home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fxhome");
    defer alloc.free(fx_home);
    const outside = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outside");
    defer alloc.free(outside);
    var fx_home_dir = try tmp.dir.openDir(testing.io, "fxhome", .{});
    defer fx_home_dir.close(testing.io);
    try fx_home_dir.symLink(testing.io, outside, "sandbox", .{ .is_directory = true });

    const result = writeOnce(alloc, fx_home, config.absent_fingerprint, testDestination());
    try testing.expect(result == .failed);
    try testing.expectEqual(setup.Reason.write_failed, result.failed);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "outside/config.json", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "outside/config.lock", .{}));
}

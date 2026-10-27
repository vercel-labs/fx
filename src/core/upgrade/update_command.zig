//! `proto-fx update` and `/update`: one run that checks or installs from
//! the configured method and returns an `UpdateSnapshot` (D140, D141), plus
//! the optional startup check, which only reads a cached result and starts a
//! throttled background check (D143).
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const helpers = @import("upgrade_helpers.zig");
const auto_upgrade = @import("auto_upgrade.zig");
const source_update = @import("source_update.zig");
const release_update = @import("release_update.zig");
const daemon_refresh = @import("daemon_refresh.zig");
const update_snapshot = @import("update_snapshot.zig");

const Allocator = std.mem.Allocator;

pub const Method = update_snapshot.Method;
pub const UpdateSnapshot = update_snapshot.UpdateSnapshot;

/// What this binary was built from, recorded by build.zig.
pub const Build = struct {
    version: []const u8,
    revision: []const u8,
    checkout: []const u8 = "",
    zig_exe: []const u8 = "",
};

/// The `update` object of `~/.proto-fx/settings.json`.
pub const Settings = struct {
    method: Method = .source,
    /// Overrides the checkout recorded at build time.
    checkout: ?[]const u8 = null,
    /// `owner/name` of the GitHub repository whose releases to install.
    repo: []const u8 = "",
    api_base: []const u8 = "https://api.github.com",
    check_on_startup: bool = true,
};

pub const Options = struct {
    check: bool = false,
    force: bool = false,
    json: bool = false,
    /// Hidden: the startup check's background run, which only records.
    background: bool = false,
};

pub fn parseArgs(args: []const [:0]const u8) !Options {
    var options: Options = .{};
    for (args) |arg| {
        const flag: *bool = if (std.mem.eql(u8, arg, "--check"))
            &options.check
        else if (std.mem.eql(u8, arg, "--force"))
            &options.force
        else if (std.mem.eql(u8, arg, "--json"))
            &options.json
        else if (std.mem.eql(u8, arg, "--background"))
            &options.background
        else
            return error.InvalidUpdateArgs;
        if (flag.*) return error.InvalidUpdateArgs;
        flag.* = true;
    }
    if (options.check and options.force) return error.InvalidUpdateArgs;
    if (options.background) options.check = true;
    return options;
}

pub const Deps = struct {
    runner: source_update.Runner = .{},
    /// The binary to replace; the running executable when null.
    executable_path: ?[]const u8 = null,
    /// Stream the build's output to stderr.
    stream: bool = false,
    /// Move an idle supervisor onto the new binary after installing.
    refresh_supervisor: bool = true,
};

/// Checks or updates. Snapshot strings live in `arena`.
pub fn run(arena: Allocator, build: Build, settings: Settings, options: Options, deps: Deps) UpdateSnapshot {
    var snapshot: UpdateSnapshot = .{
        .method = settings.method,
        .check_only = options.check,
        .outcome = .failed,
        .version = build.version,
        .revision = build.revision,
    };
    switch (settings.method) {
        .source => runSource(arena, build, settings, options, deps, &snapshot),
        .release => runRelease(arena, build, settings, options, deps, &snapshot),
    }
    if (snapshot.outcome == .updated and deps.refresh_supervisor) snapshot.supervisor = daemon_refresh.refresh(arena);
    return snapshot;
}

fn runSource(arena: Allocator, build: Build, settings: Settings, options: Options, deps: Deps, snapshot: *UpdateSnapshot) void {
    const checkout = settings.checkout orelse build.checkout;
    snapshot.checkout = checkout;
    if (checkout.len == 0) return refuse(snapshot, "this binary does not know which checkout it was built from; set update.checkout in ~/.proto-fx/settings.json");
    const source: source_update.Source = .{
        .checkout = checkout,
        .zig_exe = if (build.zig_exe.len > 0) build.zig_exe else "zig",
        .revision = build.revision,
    };
    var status = source_update.inspect(arena, deps.runner, source, true) catch |err| return fail(snapshot, err, source_update.describe(err));
    fillStatus(snapshot, status);
    const available = status.updateAvailable(build.revision);
    if (options.check or (!available and !options.force)) {
        snapshot.outcome = if (available) .available else .up_to_date;
        return;
    }
    source_update.pullAndBuild(arena, deps.runner, source, status, deps.stream) catch |err| return fail(snapshot, err, source_update.describe(err));
    if (source_update.inspect(arena, deps.runner, source, false)) |after| {
        status = after;
        fillStatus(snapshot, status);
    } else |_| {}
    const built = source_update.builtBinaryPath(arena, checkout) catch |err| return fail(snapshot, err, @errorName(err));
    var probe = deps.runner.run(deps.runner.ctx, arena, .{ .argv = &.{ built, "--version" }, .cwd = checkout }) catch |err| return fail(snapshot, err, "the new binary could not start");
    if (!probe.ok) return fail(snapshot, error.BuildFailed, "the new binary did not start, so it was not installed");
    probe.deinit(arena);
    const target = targetPath(arena, deps) catch |err| return fail(snapshot, err, "the running executable could not be found");
    _ = source_update.installAtomic(arena, built, target) catch |err| return fail(snapshot, err, source_update.describe(err));
    snapshot.installed_path = target;
    snapshot.outcome = .updated;
}

fn runRelease(arena: Allocator, build: Build, settings: Settings, options: Options, deps: Deps, snapshot: *UpdateSnapshot) void {
    snapshot.repo = settings.repo;
    if (settings.repo.len == 0) return refuse(snapshot, release_update.describe(error.NoRepository));
    var client: std.http.Client = .{ .allocator = arena, .io = io_mod.getIo() };
    defer client.deinit();
    const feed: release_update.Feed = .{
        .api_base = settings.api_base,
        .repo = settings.repo,
        .token = io_mod.getenv("GH_TOKEN") orelse io_mod.getenv("GITHUB_TOKEN"),
    };
    const release = release_update.fetchLatest(arena, &client, feed) catch |err| return fail(snapshot, err, release_update.describe(err));
    snapshot.latest_version = release_update.version(release.value);
    const available = release_update.isNewer(release.value, build.version);
    if (options.check or (!available and !options.force)) {
        snapshot.outcome = if (available) .available else .up_to_date;
        return;
    }
    const target = targetPath(arena, deps) catch |err| return fail(snapshot, err, "the running executable could not be found");
    release_update.install(arena, &client, feed, release.value, target) catch |err| return fail(snapshot, err, release_update.describe(err));
    snapshot.installed_path = target;
    snapshot.outcome = .updated;
}

fn fillStatus(snapshot: *UpdateSnapshot, status: source_update.Status) void {
    snapshot.branch = status.branch;
    snapshot.upstream = status.upstream;
    snapshot.head = status.head;
    snapshot.ahead = status.ahead;
    snapshot.behind = status.behind;
    snapshot.dirty = status.dirty;
    snapshot.fetch_error = status.fetch_error;
}

fn targetPath(arena: Allocator, deps: Deps) ![]const u8 {
    if (deps.executable_path) |path| return path;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return arena.dupe(u8, try helpers.currentExecutablePath(&buf));
}

fn refuse(snapshot: *UpdateSnapshot, message: []const u8) void {
    snapshot.outcome = .refused;
    snapshot.message = message;
}

fn fail(snapshot: *UpdateSnapshot, err: anyerror, message: []const u8) void {
    snapshot.outcome = switch (err) {
        error.NotACheckout, error.DirtyCheckout, error.Diverged, error.DetachedHead, error.NoRepository => .refused,
        else => .failed,
    };
    snapshot.message = message;
}

/// Reads the `update` object of the profile settings; `PROTO_FX_UPDATE_METHOD`
/// overrides its method. Strings live in `arena`.
pub fn loadSettings(arena: Allocator, home: ?[]const u8) Settings {
    var settings: Settings = .{};
    if (home) |dir| readSettings(arena, dir, &settings) catch {};
    if (io_mod.getenv("PROTO_FX_UPDATE_METHOD")) |raw| {
        if (Method.parse(raw)) |method| settings.method = method;
    }
    return settings;
}

fn readSettings(arena: Allocator, home: []const u8, settings: *Settings) !void {
    const path = try profile_paths.settingsPath(arena, home);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(arena, &file, 1 << 20);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) return;
    const update = root.object.get("update") orelse return;
    if (update != .object) return;
    if (update.object.get("method")) |value| if (value == .string) {
        if (Method.parse(value.string)) |method| settings.method = method;
    };
    if (update.object.get("checkout")) |value| if (value == .string and value.string.len > 0) {
        settings.checkout = value.string;
    };
    if (update.object.get("repo")) |value| if (value == .string) {
        settings.repo = value.string;
    };
    if (update.object.get("api_base")) |value| if (value == .string and value.string.len > 0) {
        settings.api_base = value.string;
    };
    if (update.object.get("check_on_startup")) |value| if (value == .bool) {
        settings.check_on_startup = value.bool;
    };
}

// The startup check (D143). The terminal reads the last background result
// and, at most once a day, starts `proto-fx update --check --background` as a
// detached process that records the next one. Neither blocks startup, and
// neither runs for `proto-fx help` or any other one-shot command.

const check_file_name = "update-check.json";
const check_interval_ms: i64 = 24 * 60 * 60 * 1000;

const CheckRecord = struct {
    checked_at_ms: i64 = 0,
    /// The binary that ran the check; a result for another build is stale.
    revision: []const u8 = "",
    outcome: []const u8 = "",
    behind: u32 = 0,
    upstream: ?[]const u8 = null,
    latest_version: []const u8 = "",
};

/// Records a background check's result.
pub fn recordCheck(alloc: Allocator, home: []const u8, snapshot: UpdateSnapshot) !void {
    const record: CheckRecord = .{
        .checked_at_ms = io_mod.milliTimestamp(),
        .revision = snapshot.revision,
        .outcome = @tagName(snapshot.outcome),
        .behind = snapshot.behind,
        .upstream = snapshot.upstream,
        .latest_version = snapshot.latest_version,
    };
    const json = try std.json.Stringify.valueAlloc(alloc, record, .{});
    defer alloc.free(json);
    const path = try checkPath(alloc, home);
    defer alloc.free(path);
    try io_mod.writeFileAtomic(alloc, path, json);
}

fn checkPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, check_file_name });
}

fn readCheck(arena: Allocator, home: []const u8) ?CheckRecord {
    const path = checkPath(arena, home) catch return null;
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(arena, &file, 4096) catch return null;
    return std.json.parseFromSliceLeaky(CheckRecord, arena, bytes, .{ .ignore_unknown_fields = true }) catch null;
}

/// The notice for a recorded available update, or null. The caller owns it.
pub fn startupNotice(alloc: Allocator, home: []const u8, build: Build) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const record = readCheck(arena_state.allocator(), home) orelse return null;
    if (!std.mem.eql(u8, record.outcome, "available") or !std.mem.eql(u8, record.revision, build.revision)) return null;
    if (record.latest_version.len > 0) {
        return try alloc.print("proto-fx {s} is available. Run /update to install it and resume here.", .{record.latest_version});
    }
    if (record.behind > 0) {
        return try alloc.print("proto-fx update available: {d} new commit{s} on {s}. Run /update to rebuild and resume here.", .{
            record.behind,
            if (record.behind == 1) "" else "s",
            record.upstream orelse "the upstream",
        });
    }
    return try alloc.dupe(u8, "proto-fx update available: the checkout has commits this binary was not built from. Run /update to rebuild and resume here.");
}

/// Whether the terminal should start a background check now.
pub fn backgroundCheckDue(alloc: Allocator, home: []const u8, build: Build, settings: Settings, executable: []const u8) bool {
    if (!settings.check_on_startup) return false;
    if (io_mod.getenv("PROTO_FX_UPDATE_CHECK")) |raw| if (std.mem.eql(u8, raw, "0")) return false;
    // A development build in a checkout's zig-out is what the source method
    // rebuilds; it never checks on its own.
    if (auto_upgrade.isDevelopmentBuildPath(executable)) return false;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const record = readCheck(arena_state.allocator(), home) orelse return true;
    if (!std.mem.eql(u8, record.revision, build.revision)) return true;
    return io_mod.milliTimestamp() - record.checked_at_ms >= check_interval_ms;
}

/// Starts the background check in its own process group, detached from the
/// terminal. Startup never waits for it: a detached thread reaps it when it
/// ends, so it is not left a zombie for the rest of the session (D214).
pub fn startBackgroundCheck(executable: []const u8) void {
    const child = std.process.spawn(io_mod.getIo(), .{
        .argv = &.{ executable, "update", "--check", "--background" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch return;
    reapInBackground(child);
}

/// Waits for `child` on a detached thread. Without a thread it is waited
/// for when the terminal exits, by the system.
fn reapInBackground(child: std.process.Child) void {
    const thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, reap, .{child}) catch return;
    thread.detach();
}

fn reap(child: std.process.Child) void {
    var owned = child;
    _ = owned.wait(io_mod.getIo()) catch {};
}

test "a background check child is reaped without the caller waiting" {
    const child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const pid = child.id.?;
    reapInBackground(child);
    // Once reaped, the pid no longer names a process of ours.
    var waited: usize = 0;
    while (waited < 500) : (waited += 1) {
        if (std.posix.system.kill(pid, @fromBackingInt(@intCast(0))) != 0) return;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return error.TestChildNotReaped;
}

/// After `/update` ends the terminal: updates, then says what happens next.
/// The caller relaunches either way, so a failed update resumes the session
/// on the binary that was already installed.
pub fn runBeforeRelaunch(alloc: Allocator, build: Build, home: ?[]const u8, executable: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const settings = loadSettings(arena, home);
    const snapshot = run(arena, build, settings, .{}, .{
        .executable_path = executable,
        .stream = true,
        // The relaunched terminal moves the supervisor once this one's
        // connection has closed.
        .refresh_supervisor = false,
    });
    const text = try snapshot.renderText(arena);
    std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text) catch {};
    return snapshot.outcome == .updated;
}

const test_build: Build = .{ .version = "0.3.0", .revision = "111111111111", .checkout = "/Users/example/proto-fx" };

test "update arguments accept check, force and json once each" {
    const checked = try parseArgs(&.{ "--check", "--json" });
    try std.testing.expect(checked.check and checked.json and !checked.force);
    const background = try parseArgs(&.{"--background"});
    try std.testing.expect(background.check and background.background);
    try std.testing.expectError(error.InvalidUpdateArgs, parseArgs(&.{ "--check", "--check" }));
    try std.testing.expectError(error.InvalidUpdateArgs, parseArgs(&.{ "--check", "--force" }));
    try std.testing.expectError(error.InvalidUpdateArgs, parseArgs(&.{"--channel"}));
}

test "a source check reports commits behind without building" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake: source_update.FakeRunner = .{ .head = "111111111111aaaa", .counts = "0\t4" };
    const snapshot = run(arena_state.allocator(), test_build, .{}, .{ .check = true }, .{ .runner = fake.runner(), .refresh_supervisor = false });
    try std.testing.expectEqual(update_snapshot.Outcome.available, snapshot.outcome);
    try std.testing.expectEqual(@as(u32, 4), snapshot.behind);
    try std.testing.expect(fake.ran("fetch"));
    try std.testing.expect(!fake.ran("merge"));
    try std.testing.expect(!fake.ran("build"));
}

test "a source update refuses a dirty checkout and skips an up to date one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dirty: source_update.FakeRunner = .{ .head = "111111111111aaaa", .counts = "0\t1", .porcelain = " M x\n" };
    const refused = run(arena, test_build, .{}, .{}, .{ .runner = dirty.runner(), .refresh_supervisor = false });
    try std.testing.expectEqual(update_snapshot.Outcome.refused, refused.outcome);
    try std.testing.expect(!dirty.ran("build"));

    var current: source_update.FakeRunner = .{ .head = "111111111111aaaa" };
    const up_to_date = run(arena, test_build, .{}, .{}, .{ .runner = current.runner(), .refresh_supervisor = false });
    try std.testing.expectEqual(update_snapshot.Outcome.up_to_date, up_to_date.outcome);
    try std.testing.expect(!current.ran("build"));

    const unknown = run(arena, .{ .version = "0.3.0", .revision = "1" }, .{}, .{}, .{ .runner = current.runner(), .refresh_supervisor = false });
    try std.testing.expectEqual(update_snapshot.Outcome.refused, unknown.outcome);
}

test "the startup notice reads only a fresh result for this build" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, profile_paths.root_dir_name);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try std.testing.expect(try startupNotice(alloc, home, test_build) == null);
    try std.testing.expect(backgroundCheckDue(alloc, home, test_build, .{}, "/Users/example/.local/bin/proto-fx"));
    try std.testing.expect(!backgroundCheckDue(alloc, home, test_build, .{}, "/Users/example/proto-fx/zig-out/bin/proto-fx"));
    try std.testing.expect(!backgroundCheckDue(alloc, home, test_build, .{ .check_on_startup = false }, "/Users/example/.local/bin/proto-fx"));

    try recordCheck(alloc, home, .{ .method = .source, .check_only = true, .outcome = .available, .version = "0.3.0", .revision = "111111111111", .behind = 2, .upstream = "origin/main" });
    const notice = (try startupNotice(alloc, home, test_build)).?;
    defer alloc.free(notice);
    try std.testing.expectEqualStrings("proto-fx update available: 2 new commits on origin/main. Run /update to rebuild and resume here.", notice);
    try std.testing.expect(!backgroundCheckDue(alloc, home, test_build, .{}, "/Users/example/.local/bin/proto-fx"));
    // A result recorded by another build is stale.
    try std.testing.expect(try startupNotice(alloc, home, .{ .version = "0.3.0", .revision = "222222222222" }) == null);
}

test "settings select the method, checkout and release feed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, profile_paths.root_dir_name);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = profile_paths.root_dir_name ++ "/settings.json",
        .data = "{\"model\":\"m\",\"update\":{\"method\":\"release\",\"repo\":\"example/proto-fx\",\"api_base\":\"http://127.0.0.1:9\",\"check_on_startup\":false}}",
    });
    const home = try io_mod.dirRealpathAlloc(arena_state.allocator(), tmp.dir, ".");
    const settings = loadSettings(arena_state.allocator(), home);
    try std.testing.expectEqual(Method.release, settings.method);
    try std.testing.expectEqualStrings("example/proto-fx", settings.repo);
    try std.testing.expectEqualStrings("http://127.0.0.1:9", settings.api_base);
    try std.testing.expect(!settings.check_on_startup);
    try std.testing.expect(settings.checkout == null);
    try std.testing.expectEqual(Method.source, loadSettings(arena_state.allocator(), null).method);
}

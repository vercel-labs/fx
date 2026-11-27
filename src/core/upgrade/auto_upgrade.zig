const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const helpers = @import("upgrade_helpers.zig");
const update_target = @import("update_target.zig");

const Allocator = std.mem.Allocator;

const default_check_interval_ms: u64 = 30 * 60 * 1000;
const initial_delay_ms: u64 = 10_000;
const sleep_increment_ms: u64 = 50;
/// Upper bound stop() waits for the upgrade thread once cancellation has
/// been requested; a stuck network read must not delay process exit.
const stop_join_budget_ms: i64 = 250;
const download_dir_prefix = "fx-auto-upgrade-";
/// A download directory this old belongs to no live upgrade: its process ended
/// before the upgrade thread could remove it.
const stale_download_dir_ns: i128 = std.time.ns_per_hour;

pub const State = enum(u8) {
    idle = 0,
    checking = 1,
    waiting = 2,
    downloading = 3,
    ready = 4,
    failed = 5,
};

pub const RelaunchRequest = struct {
    executable_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    executable_path_len: usize = 0,
    previous_revision_buf: [update_target.max_revision_bytes]u8 = undefined,
    previous_revision_len: u8 = 0,

    pub fn executablePath(self: *const RelaunchRequest) []const u8 {
        return self.executable_path_buf[0..self.executable_path_len];
    }

    pub fn previousRevision(self: *const RelaunchRequest) ?[]const u8 {
        if (self.previous_revision_len == 0) return null;
        return self.previous_revision_buf[0..self.previous_revision_len];
    }
};

/// How long fx waits between update checks. `FX_TEST_UPGRADE_CHECK_INTERVAL_MS`,
/// a positive number of milliseconds, replaces the thirty minutes; only tests
/// set it (`tests/e2e/tui-resume.test.ts`, "a newer dev release replaces the
/// update that waits for ctrl+g").
fn checkIntervalMs() u64 {
    return parseCheckIntervalMs(io_mod.getenv("FX_TEST_UPGRADE_CHECK_INTERVAL_MS"));
}

fn parseCheckIntervalMs(text: ?[]const u8) u64 {
    const value = text orelse return default_check_interval_ms;
    const ms = std.fmt.parseInt(u32, value, 10) catch return default_check_interval_ms;
    return if (ms > 0) ms else default_check_interval_ms;
}

/// The build that an earlier check installed while this fx runs. Later checks
/// compare a release with it, not with the running build, so the installed
/// release is never installed again: a dev release replaces it when its commit
/// differs, and a stable release when its version is higher
/// (`update_target.Target.shouldInstall`). This tracks what fx installed, not
/// the file itself, so a binary another process writes there is not noticed.
const StagedBuild = struct {
    installed: bool = false,
    channel: update_target.Channel = .stable,
    version_buf: [update_target.max_version_bytes]u8 = undefined,
    version_len: usize = 0,
    revision_buf: [update_target.max_revision_bytes]u8 = undefined,
    revision_len: usize = 0,

    /// Copies what `target` names. Its version and revision passed the
    /// target's own length checks, so they fit.
    fn record(self: *StagedBuild, target: update_target.Target) void {
        const version = target.version();
        const revision = target.revision() orelse "";
        @memcpy(self.version_buf[0..version.len], version);
        @memcpy(self.revision_buf[0..revision.len], revision);
        self.version_len = version.len;
        self.revision_len = revision.len;
        self.channel = target.channel();
        self.installed = true;
    }

    /// The build a release is compared with: the staged one once a check has
    /// installed one, otherwise the running build.
    fn baseline(self: *const StagedBuild, current: update_target.CurrentBuild) update_target.CurrentBuild {
        if (!self.installed) return current;
        return .{
            .channel = self.channel,
            .version = self.version_buf[0..self.version_len],
            .revision = self.revision_buf[0..self.revision_len],
        };
    }
};

pub fn shouldEnableForCurrentExecutable() bool {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io_mod.getIo(), &exe_buf) catch return true;
    return !isDevelopmentBuildPath(exe_buf[0..n]);
}

pub fn isDevelopmentBuildPath(path: []const u8) bool {
    return std.mem.find(u8, path, "/zig-out/bin/") != null or
        std.mem.find(u8, path, "\\zig-out\\bin\\") != null;
}

/// Where a Ctrl+G restart that waits for running turns stands. Main loop
/// only (`tests/tla/recovery/RestartWait.tla`).
pub const RestartWait = enum {
    none,
    /// The running turns stop at their next step boundary and hold there;
    /// a second Ctrl+G cancels.
    waiting,
    /// Every turn held or ended, and the held turns were let go; fx exits
    /// for the relaunch once none runs.
    releasing,
};

const restart_wait_label = "restart waits: ctrl+g to cancel";

pub const AutoUpgrade = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(State.idle)),
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    render_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    version_mutex: std.Io.Mutex = .init,
    latest_version_buf: [64]u8 = undefined,
    latest_version_len: u8 = 0,
    previous_revision_buf: [update_target.max_revision_bytes]u8 = undefined,
    previous_revision_len: u8 = 0,

    selected_channel: update_target.Channel = .stable,

    transfer_interrupt: helpers.TransferInterrupt = .{},
    /// Held across the final stop check and the install, so process exit can
    /// wait out an install already under way and no install starts after it.
    install_mutex: std.Io.Mutex = .init,

    relaunch_request: ?RelaunchRequest = null,
    /// Main loop only. Ctrl+G accepted the upgrade while turns ran
    /// (`app_upgrade_runtime` `collectUpgradeFacts`).
    restart: RestartWait = .none,
    /// Main loop only. Timestamp of the last key press routed to the app.
    last_user_input_ms: ?i64 = null,
    /// Main loop only. Timestamp when `state` was first observed as `.ready`.
    ready_since_ms: ?i64 = null,
    /// Main loop only. Set if an automatic idle restart failed to prepare a
    /// relaunch, so `collectUpgradeFacts` does not repeat the error notice.
    auto_restart_failed: bool = false,

    pub fn configure_channel(self: *AutoUpgrade, selected: update_target.Channel) void {
        self.selected_channel = selected;
    }

    pub fn channel(self: *const AutoUpgrade) update_target.Channel {
        return self.selected_channel;
    }

    pub fn start(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
    ) void {
        self.setPreviousRevision(current.revision);
        self.thread = std.Thread.spawn(.{}, runLoop, .{ self, alloc, current }) catch return;
    }

    fn requestStop(self: *AutoUpgrade) void {
        self.should_stop.store(true, .release);
        // Wake a thread blocked in a transfer read so it can observe the
        // cancel flag instead of stalling on the socket.
        self.transfer_interrupt.interrupt();
    }

    /// Stops the upgrade thread without joining it. Only an install already
    /// under way is waited out, since it is a local copy; once this returns no
    /// install can start, so process exit cannot interrupt one midway.
    pub fn stopForProcessExit(self: *AutoUpgrade) void {
        self.requestStop();
        self.install_mutex.lockUncancelable(io_mod.getIo());
        self.install_mutex.unlock(io_mod.getIo());
    }

    pub fn stop(self: *AutoUpgrade) void {
        self.requestStop();
        const t = self.thread orelse return;
        const deadline_ms = io_mod.milliTimestamp() + stop_join_budget_ms;
        while (!self.stopped.load(.acquire) and io_mod.milliTimestamp() < deadline_ms) {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (self.stopped.load(.acquire)) {
            t.join();
        } else {
            // The thread is stuck in a network read; process exit reaps it.
            // downloadAndInstall rechecks should_stop before touching the
            // executable, so a late wake-up cannot install.
            debug_trace.logf("upgrade", "stop detaching upgrade thread mid-transfer", .{});
        }
        self.thread = null;
    }

    pub fn getState(self: *const AutoUpgrade) State {
        return @fromBackingInt(@intCast(self.state.load(.acquire)));
    }

    fn transferControl(self: *AutoUpgrade) helpers.TransferControl {
        return .{
            .cancel = &self.should_stop,
            .interrupt = &self.transfer_interrupt,
        };
    }

    pub fn requestRelaunch(self: *AutoUpgrade, executable_path: []const u8) !void {
        if (executable_path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
        var request = RelaunchRequest{
            .executable_path_len = executable_path.len,
        };
        @memcpy(
            request.executable_path_buf[0..executable_path.len],
            executable_path,
        );
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        if (self.selected_channel == .dev and self.previous_revision_len > 0) {
            @memcpy(
                request.previous_revision_buf[0..self.previous_revision_len],
                self.previous_revision_buf[0..self.previous_revision_len],
            );
            request.previous_revision_len = self.previous_revision_len;
        }
        self.relaunch_request = request;
    }

    /// The relaunch the exit runs, consumed once. An exit while the restart
    /// still waits for turns to stop is not that restart (`/quit`, Ctrl+D,
    /// a signal): it quits, so the prepared relaunch is dropped.
    pub fn takeRelaunchRequest(self: *AutoUpgrade) ?RelaunchRequest {
        const request = self.relaunch_request;
        self.relaunch_request = null;
        if (self.restart != .none) {
            if (request != null) debug_trace.logf("upgrade", "event=relaunch_dropped reason=exit_while_restart_waits", .{});
            return null;
        }
        return request;
    }

    /// A second Ctrl+G cancelled the waiting restart: the relaunch it
    /// prepared is dropped, so a later exit quits
    /// (`tests/tla/recovery/Resume.tla` CancelledRestartStays).
    pub fn cancelRestart(self: *AutoUpgrade) void {
        if (self.relaunch_request != null) debug_trace.logf("upgrade", "event=relaunch_dropped reason=restart_cancelled", .{});
        self.relaunch_request = null;
        self.restart = .none;
    }

    pub fn statusLabel(self: *AutoUpgrade, buf: []u8) []const u8 {
        if (self.restart == .waiting) return restart_wait_label;
        const state = self.getState();
        switch (state) {
            .downloading => {
                var ver_buf: [32]u8 = undefined;
                const ver = self.getLatestVersion(&ver_buf);
                return std.mem.print(buf, "upgrading to {s}...", .{ver}) catch "";
            },
            .ready => return "update ready: ctrl+g to reload",
            .failed => return "upgrade failed",
            else => return "",
        }
    }

    pub fn takeRenderDirty(self: *AutoUpgrade) bool {
        return self.render_dirty.swap(false, .acq_rel);
    }

    fn getLatestVersion(self: *AutoUpgrade, out: []u8) []const u8 {
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        const len = self.latest_version_len;
        if (len == 0) return "";
        const n: usize = @min(len, out.len);
        @memcpy(out[0..n], self.latest_version_buf[0..n]);
        return out[0..n];
    }

    fn setState(self: *AutoUpgrade, state: State) void {
        const next = @backingInt(state);
        const previous = self.state.swap(next, .acq_rel);
        if (previous != next) self.markRenderDirty();
    }

    fn setPreviousRevision(self: *AutoUpgrade, revision: []const u8) void {
        const valid = update_target.isValidRevision(revision);
        const len: u8 = if (valid) @intCast(revision.len) else 0;
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        if (len > 0) @memcpy(self.previous_revision_buf[0..len], revision);
        self.previous_revision_len = len;
    }

    fn setLatestVersion(self: *AutoUpgrade, version: []const u8) void {
        const stripped = update_target.normalizeVersion(version);
        const len: u8 = @intCast(@min(stripped.len, 32));
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        @memcpy(self.latest_version_buf[0..len], stripped[0..len]);
        self.latest_version_len = len;
        self.markRenderDirty();
    }

    fn markRenderDirty(self: *AutoUpgrade) void {
        self.render_dirty.store(true, .release);
    }

    fn runLoop(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
    ) void {
        defer self.stopped.store(true, .release);
        const interval_ms = checkIntervalMs();
        // Checks go on after an update is ready, so a later release replaces
        // the waiting one and Ctrl+G restarts into the latest.
        var staged: StagedBuild = .{};
        self.sleepInterruptible(initial_delay_ms);

        while (!self.should_stop.load(.acquire)) {
            if (!staged.installed) self.setState(.checking);
            self.runOnce(alloc, current, &staged);
            if (!staged.installed and self.getState() != .failed) self.setState(.waiting);
            self.sleepInterruptible(interval_ms);
        }
    }

    fn runOnce(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
        staged: *StagedBuild,
    ) void {
        const cdn_base = helpers.resolveCdnBase();
        if (helpers.cancelRequested(&self.should_stop)) return;
        var target = helpers.fetchTarget(alloc, self.selected_channel, cdn_base, self.transferControl()) catch return;
        defer target.deinit(alloc);

        if (!target.shouldInstall(staged.baseline(current))) return;

        var label_buf: [64]u8 = undefined;
        const label = target.writeDisplayLabel(&label_buf) catch return;
        // With an update already waiting, the later one downloads behind it:
        // the footer keeps offering Ctrl+G, and a failed download leaves the
        // waiting update in place, since only a finished install replaces it.
        if (!staged.installed) {
            self.setLatestVersion(label);
            self.setState(.downloading);
        }

        self.downloadAndInstall(alloc, target, cdn_base) catch |err| {
            if (staged.installed) {
                debug_trace.logf("upgrade", "event=later_download_dropped target={s} err={s} kept=waiting_update", .{ label, @errorName(err) });
                return;
            }
            self.setState(.failed);
            return;
        };
        staged.record(target);
        self.setLatestVersion(label);
        self.setState(.ready);
    }

    const InstallError = error{
        AllocFailed,
        DownloadFailed,
        ChecksumFailed,
        ExtractionFailed,
        SelfExeNotFound,
        InstallFailed,
        Cancelled,
    };

    fn downloadAndInstall(
        self: *AutoUpgrade,
        alloc: Allocator,
        target: update_target.Target,
        cdn_base: []const u8,
    ) InstallError!void {
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        const tmp_base: []const u8 = io_mod.getenv("TMPDIR") orelse "/tmp";
        sweepStaleDownloadDirs(tmp_base, io_mod.nanoTimestamp());
        var rand_buf: [8]u8 = undefined;
        io_mod.getIo().random(&rand_buf);
        const rand_hex = std.fmt.bytesToHex(rand_buf, .lower);
        const tmp_dir = alloc.print("{s}/" ++ download_dir_prefix ++ "{s}", .{ tmp_base, rand_hex }) catch return error.AllocFailed;
        defer alloc.free(tmp_dir);
        defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), tmp_dir) catch {};

        std.Io.Dir.createDirAbsolute(io_mod.getIo(), tmp_dir, .default_dir) catch return error.ExtractionFailed;

        const archive_path = alloc.print("{s}/fx.tar.gz", .{tmp_dir}) catch return error.AllocFailed;
        defer alloc.free(archive_path);

        const archive_url = alloc.print("{s}/{s}/fx-{s}.tar.gz", .{ cdn_base, target.artifactRef(), helpers.platform }) catch return error.AllocFailed;
        defer alloc.free(archive_url);

        helpers.downloadFileStreaming(&client, archive_url, archive_path, self.transferControl()) catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            else => error.DownloadFailed,
        };

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        const checksum_url = alloc.print("{s}/{s}/fx-{s}.tar.gz.sha256", .{ cdn_base, target.artifactRef(), helpers.platform }) catch return error.AllocFailed;
        defer alloc.free(checksum_url);

        helpers.verifyChecksum(&client, archive_path, checksum_url, self.transferControl()) catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            else => error.ChecksumFailed,
        };

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        helpers.extractTarGz(alloc, archive_path, tmp_dir) catch return error.ExtractionFailed;

        const extracted_bin = alloc.print("{s}/fx", .{tmp_dir}) catch return error.AllocFailed;
        defer alloc.free(extracted_bin);

        var self_exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const self_exe = helpers.currentExecutablePath(&self_exe_buf) catch return error.SelfExeNotFound;
        try self.installUnlessStopped(alloc, extracted_bin, self_exe);
    }

    /// Holds install_mutex across the stop check and the copy, so
    /// stopForProcessExit waits out an install already under way and no
    /// install starts after it.
    fn installUnlessStopped(
        self: *AutoUpgrade,
        alloc: Allocator,
        extracted_bin: []const u8,
        self_exe: []const u8,
    ) InstallError!void {
        self.install_mutex.lockUncancelable(io_mod.getIo());
        defer self.install_mutex.unlock(io_mod.getIo());
        if (self.should_stop.load(.acquire)) return error.Cancelled;
        io_mod.copyFileAtomic(alloc, extracted_bin, self_exe) catch return error.InstallFailed;
    }

    fn sleepInterruptible(self: *AutoUpgrade, total_ms: u64) void {
        var remaining = total_ms;
        while (remaining > 0 and !self.should_stop.load(.acquire)) {
            const chunk = @min(remaining, sleep_increment_ms);
            io_mod.sleep(chunk * @as(u64, std.time.ns_per_ms));
            remaining -|= chunk;
        }
    }
};

/// Removes download directories in `tmp_base` left by upgrades whose process
/// ended mid-download, such as an interactive exit that did not join the
/// upgrade thread.
fn sweepStaleDownloadDirs(tmp_base: []const u8, now_ns: i128) void {
    if (!std.Io.Dir.path.isAbsolute(tmp_base)) return;
    const zio = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(zio, tmp_base, .{ .iterate = true }) catch return;
    defer dir.close(zio);
    var entries = dir.iterate();
    while (entries.next(zio) catch return) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, download_dir_prefix)) continue;
        const stat = dir.statFile(zio, entry.name, .{ .follow_symlinks = false }) catch continue;
        if (now_ns - stat.mtime.nanoseconds < stale_download_dir_ns) continue;
        dir.deleteTree(zio, entry.name) catch |err| {
            debug_trace.logf("upgrade", "stale download dir not removed err={s}", .{@errorName(err)});
            continue;
        };
        debug_trace.logf("upgrade", "removed stale download dir", .{});
    }
}

test "download sweep removes only stale upgrade directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const zio = std.testing.io;
    try tmp.dir.createDir(zio, "unrelated", .default_dir);
    try tmp.dir.writeFile(zio, .{ .sub_path = download_dir_prefix ++ "file", .data = "" });
    try tmp.dir.createDir(zio, download_dir_prefix ++ "abandoned", .default_dir);
    const base = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(base);
    const created_ns = (try tmp.dir.statFile(zio, download_dir_prefix ++ "abandoned", .{})).mtime.nanoseconds;

    sweepStaleDownloadDirs(base, created_ns + stale_download_dir_ns - 1);
    _ = try tmp.dir.statFile(zio, download_dir_prefix ++ "abandoned", .{});

    // Far past every entry's age limit, only prefixed directories go.
    sweepStaleDownloadDirs(base, created_ns + 10 * stale_download_dir_ns);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(zio, download_dir_prefix ++ "abandoned", .{}),
    );
    _ = try tmp.dir.statFile(zio, "unrelated", .{});
    _ = try tmp.dir.statFile(zio, download_dir_prefix ++ "file", .{});
}

test "process-exit stop waits out an install already under way" {
    var au = AutoUpgrade{};
    var install_started = std.atomic.Value(bool).init(false);
    var install_done = std.atomic.Value(bool).init(false);
    const installer = try std.Thread.spawn(.{}, struct {
        fn run(self: *AutoUpgrade, started: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            self.install_mutex.lockUncancelable(io_mod.getIo());
            started.store(true, .release);
            io_mod.sleep(50 * std.time.ns_per_ms);
            done.store(true, .release);
            self.install_mutex.unlock(io_mod.getIo());
        }
    }.run, .{ &au, &install_started, &install_done });
    defer installer.join();
    while (!install_started.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    au.stopForProcessExit();
    try std.testing.expect(install_done.load(.acquire));
}

test "no install starts after a process-exit stop" {
    var au = AutoUpgrade{};
    au.stopForProcessExit();
    // Without the stop check, the copy of these missing paths would fail
    // with InstallFailed instead.
    try std.testing.expectError(
        error.Cancelled,
        au.installUnlessStopped(std.testing.allocator, "/nonexistent/fx-extracted", "/nonexistent/fx"),
    );
}

test "the check interval is thirty minutes unless a positive number of milliseconds is given" {
    try std.testing.expectEqual(default_check_interval_ms, parseCheckIntervalMs(null));
    try std.testing.expectEqual(@as(u64, 200), parseCheckIntervalMs("200"));
    try std.testing.expectEqual(default_check_interval_ms, parseCheckIntervalMs("0"));
    try std.testing.expectEqual(default_check_interval_ms, parseCheckIntervalMs("-5"));
    try std.testing.expectEqual(default_check_interval_ms, parseCheckIntervalMs("soon"));
    try std.testing.expectEqual(default_check_interval_ms, parseCheckIntervalMs("99999999999"));
}

test "a staged dev build is the baseline, so only a different revision replaces it" {
    const alloc = std.testing.allocator;
    const current: update_target.CurrentBuild = .{
        .channel = .stable,
        .version = "0.0.18",
        .revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    var first = try update_target.Target.parseDevManifest(alloc, "{\"version\":\"0.0.18\",\"commit\":\"1111111111111111111111111111111111111111\"}");
    defer first.deinit(alloc);
    var newest = try update_target.Target.parseDevManifest(alloc, "{\"version\":\"0.0.18\",\"commit\":\"2222222222222222222222222222222222222222\"}");
    defer newest.deinit(alloc);

    var staged: StagedBuild = .{};
    try std.testing.expectEqualStrings(current.revision, staged.baseline(current).revision);
    try std.testing.expect(first.shouldInstall(staged.baseline(current)));

    staged.record(first);
    try std.testing.expect(!first.shouldInstall(staged.baseline(current)));
    try std.testing.expect(newest.shouldInstall(staged.baseline(current)));

    staged.record(newest);
    try std.testing.expect(!newest.shouldInstall(staged.baseline(current)));
    try std.testing.expectEqual(update_target.Channel.dev, staged.baseline(current).channel);
}

test "a staged stable build is the baseline, so only a higher version replaces it" {
    const alloc = std.testing.allocator;
    const current: update_target.CurrentBuild = .{ .channel = .stable, .version = "0.0.18", .revision = "" };
    var staged_target = try update_target.Target.initStable(alloc, "v0.0.19");
    defer staged_target.deinit(alloc);
    var same = try update_target.Target.initStable(alloc, "0.0.19");
    defer same.deinit(alloc);
    var older = try update_target.Target.initStable(alloc, "0.0.18");
    defer older.deinit(alloc);
    var higher = try update_target.Target.initStable(alloc, "0.0.20");
    defer higher.deinit(alloc);

    var staged: StagedBuild = .{};
    staged.record(staged_target);
    try std.testing.expectEqualStrings("0.0.19", staged.baseline(current).version);
    try std.testing.expect(!same.shouldInstall(staged.baseline(current)));
    try std.testing.expect(!older.shouldInstall(staged.baseline(current)));
    try std.testing.expect(higher.shouldInstall(staged.baseline(current)));
}

test "statusLabel idle returns empty" {
    var au = AutoUpgrade{};
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqual(@as(usize, 0), label.len);
}

test "stop joins a finished upgrade thread" {
    var au = AutoUpgrade{};
    const t = try std.Thread.spawn(.{}, struct {
        fn run(self: *AutoUpgrade) void {
            io_mod.sleep(10 * std.time.ns_per_ms);
            self.stopped.store(true, .release);
        }
    }.run, .{&au});
    au.thread = t;
    const started_ms = io_mod.milliTimestamp();
    au.stop();
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < stop_join_budget_ms);
    try std.testing.expect(au.thread == null);
    try std.testing.expect(au.stopped.load(.acquire));
}

test "stop detaches instead of blocking on a stuck upgrade thread" {
    var au = AutoUpgrade{};
    var blocker = std.atomic.Value(bool).init(false);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(block: *std.atomic.Value(bool)) void {
            // Never reports stopped; simulates a thread wedged in a network
            // read. The blocker keeps it alive until the test process moves on.
            while (!block.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
        }
    }.run, .{&blocker});
    au.thread = t;
    const started_ms = io_mod.milliTimestamp();
    au.stop();
    const elapsed_ms = io_mod.milliTimestamp() - started_ms;
    blocker.store(true, .release);
    t.join();
    try std.testing.expect(elapsed_ms >= stop_join_budget_ms);
    try std.testing.expect(elapsed_ms < stop_join_budget_ms * 4);
    try std.testing.expect(au.thread == null);
    try std.testing.expect(!au.stopped.load(.acquire));
}

test "selected release channel is owned by the upgrade runtime" {
    var au = AutoUpgrade{};
    try std.testing.expectEqual(update_target.Channel.stable, au.channel());

    au.configure_channel(.dev);
    try std.testing.expectEqual(update_target.Channel.dev, au.channel());
}

test "development build paths disable auto upgrade" {
    try std.testing.expect(isDevelopmentBuildPath("/repo/zig-out/bin/fx"));
    try std.testing.expect(isDevelopmentBuildPath("C:\\repo\\zig-out\\bin\\fx.exe"));
    try std.testing.expect(!isDevelopmentBuildPath("/Users/me/.local/bin/fx"));
}

test "statusLabel downloading shows ellipsis" {
    var au = AutoUpgrade{};
    au.setLatestVersion("v0.3.0");
    au.setState(.downloading);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqualStrings("upgrading to 0.3.0...", label);
}

test "statusLabel ready explains ctrl+g reload" {
    var au = AutoUpgrade{};
    au.setState(.ready);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqualStrings("update ready: ctrl+g to reload", label);
}

test "setLatestVersion stores normalized version" {
    var au = AutoUpgrade{};
    _ = au.takeRenderDirty();
    au.setLatestVersion("v1.2.3");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.2.3", au.getLatestVersion(&buf));
    try std.testing.expect(au.takeRenderDirty());
}

test "relaunch request owns its path and previous revision and is consumed once" {
    var au = AutoUpgrade{};
    var path = [_]u8{ '/', 't', 'm', 'p', '/', 'f', 'x' };
    var revision: [40]u8 = @splat('1');
    au.configure_channel(.dev);
    au.setPreviousRevision(&revision);
    try au.requestRelaunch(&path);
    path[1] = 'x';
    revision[0] = '2';

    const request = au.takeRelaunchRequest() orelse
        return error.TestExpectedRelaunchRequest;
    try std.testing.expectEqualStrings("/tmp/fx", request.executablePath());
    try std.testing.expectEqualStrings(
        "1111111111111111111111111111111111111111",
        request.previousRevision().?,
    );
    try std.testing.expect(au.takeRelaunchRequest() == null);
}

test "an exit while the restart waits for turns drops the relaunch" {
    var au = AutoUpgrade{};
    try au.requestRelaunch("/tmp/fx");
    au.restart = .waiting;
    try std.testing.expect(au.takeRelaunchRequest() == null);
    // Dropped, not kept for a later exit.
    au.restart = .none;
    try std.testing.expect(au.takeRelaunchRequest() == null);
}

test "a cancelled restart drops the relaunch it prepared" {
    var au = AutoUpgrade{};
    try au.requestRelaunch("/tmp/fx-upgraded");
    au.restart = .waiting;
    au.cancelRestart();
    try std.testing.expectEqual(RestartWait.none, au.restart);
    try std.testing.expect(au.takeRelaunchRequest() == null);
}

test "a waiting restart says how to cancel it" {
    var au = AutoUpgrade{};
    var buf: [64]u8 = undefined;
    au.restart = .waiting;
    try std.testing.expectEqualStrings("restart waits: ctrl+g to cancel", au.statusLabel(&buf));
    au.restart = .none;
    try std.testing.expect(!std.mem.eql(u8, "restart waits: ctrl+g to cancel", au.statusLabel(&buf)));
}

test "statusLabel waiting returns empty" {
    var au = AutoUpgrade{};
    au.setState(.waiting);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqual(@as(usize, 0), label.len);
}

test "statusLabel checking returns empty" {
    var au = AutoUpgrade{};
    au.setState(.checking);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqual(@as(usize, 0), label.len);
}

test "statusLabel failed shows upgrade failed" {
    var au = AutoUpgrade{};
    au.setState(.failed);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqualStrings("upgrade failed", label);
}

test "getState returns the current atomic state" {
    var au = AutoUpgrade{};
    try std.testing.expectEqual(State.idle, au.getState());
    try std.testing.expect(!au.takeRenderDirty());
    au.setState(.checking);
    try std.testing.expectEqual(State.checking, au.getState());
    try std.testing.expect(au.takeRenderDirty());
    try std.testing.expect(!au.takeRenderDirty());
    au.setState(.checking);
    try std.testing.expect(!au.takeRenderDirty());
}

test "setLatestVersion truncates to stored capacity" {
    var au = AutoUpgrade{};
    au.setLatestVersion("v1234567890123456789012345678901234567890");

    var buf: [40]u8 = undefined;
    const latest = au.getLatestVersion(&buf);
    try std.testing.expectEqual(@as(usize, 32), latest.len);
    try std.testing.expectEqualStrings("12345678901234567890123456789012", latest);
}

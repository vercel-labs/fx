const std = @import("std");
const io_mod = @import("../shared/io.zig");
const helpers = @import("upgrade_helpers.zig");
const update_target = @import("update_target.zig");

const Allocator = std.mem.Allocator;

const check_interval_ms: u64 = 30 * 60 * 1000;
const initial_delay_ms: u64 = 10_000;
const sleep_increment_ms: u64 = 50;

pub const State = enum(u8) {
    idle = 0,
    checking = 1,
    waiting = 2,
    downloading = 3,
    ready = 4,
    failed = 5,
};

pub const RelaunchRequest = struct {
    executable_path_buf: [std.fs.max_path_bytes]u8 = undefined,
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

pub fn shouldEnableForCurrentExecutable() bool {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io_mod.getIo(), &exe_buf) catch return true;
    return !isDevelopmentBuildPath(exe_buf[0..n]);
}

pub fn isDevelopmentBuildPath(path: []const u8) bool {
    return std.mem.find(u8, path, "/zig-out/bin/") != null or
        std.mem.find(u8, path, "\\zig-out\\bin\\") != null;
}

pub const AutoUpgrade = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.idle)),
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    render_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    version_mutex: std.Io.Mutex = .init,
    latest_version_buf: [64]u8 = undefined,
    latest_version_len: u8 = 0,
    previous_revision_buf: [update_target.max_revision_bytes]u8 = undefined,
    previous_revision_len: u8 = 0,

    selected_channel: update_target.Channel = .stable,

    relaunch_request: ?RelaunchRequest = null,

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

    pub fn stop(self: *AutoUpgrade) void {
        self.should_stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn getState(self: *const AutoUpgrade) State {
        return @enumFromInt(self.state.load(.acquire));
    }

    pub fn requestRelaunch(self: *AutoUpgrade, executable_path: []const u8) !void {
        if (executable_path.len > std.fs.max_path_bytes) return error.NameTooLong;
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

    pub fn takeRelaunchRequest(self: *AutoUpgrade) ?RelaunchRequest {
        const request = self.relaunch_request;
        self.relaunch_request = null;
        return request;
    }

    pub fn statusLabel(self: *AutoUpgrade, buf: []u8) []const u8 {
        const state = self.getState();
        switch (state) {
            .downloading => {
                var ver_buf: [32]u8 = undefined;
                const ver = self.getLatestVersion(&ver_buf);
                return std.fmt.bufPrint(buf, "upgrading to {s}...", .{ver}) catch "";
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
        const next = @intFromEnum(state);
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
        self.sleepInterruptible(initial_delay_ms);

        while (!self.should_stop.load(.acquire)) {
            if (self.getState() == .ready) return;
            self.setState(.checking);
            self.runOnce(alloc, current);

            const post_state = self.getState();
            if (post_state == .ready) return;

            if (post_state != .failed) self.setState(.waiting);
            self.sleepInterruptible(check_interval_ms);
        }
    }

    fn runOnce(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
    ) void {
        const cdn_base = helpers.resolveCdnBase();
        var target = helpers.fetchTarget(alloc, self.selected_channel, cdn_base) catch return;
        defer target.deinit(alloc);

        if (!target.shouldInstall(current)) return;

        var label_buf: [64]u8 = undefined;
        const label = target.writeDisplayLabel(&label_buf) catch return;
        self.setLatestVersion(label);
        self.setState(.downloading);

        self.downloadAndInstall(alloc, target, cdn_base) catch {
            self.setState(.failed);
            return;
        };
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
        var rand_buf: [8]u8 = undefined;
        io_mod.getIo().random(&rand_buf);
        const rand_hex = std.fmt.bytesToHex(rand_buf, .lower);
        const tmp_dir = std.fmt.allocPrint(alloc, "{s}/fx-auto-upgrade-{s}", .{ tmp_base, rand_hex }) catch return error.AllocFailed;
        defer alloc.free(tmp_dir);
        defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), tmp_dir) catch {};

        std.Io.Dir.createDirAbsolute(io_mod.getIo(), tmp_dir, .default_dir) catch return error.ExtractionFailed;

        const archive_path = std.fmt.allocPrint(alloc, "{s}/fx.tar.gz", .{tmp_dir}) catch return error.AllocFailed;
        defer alloc.free(archive_path);

        const archive_url = std.fmt.allocPrint(alloc, "{s}/{s}/fx-{s}.tar.gz", .{ cdn_base, target.artifactRef(), helpers.platform }) catch return error.AllocFailed;
        defer alloc.free(archive_url);

        helpers.downloadFileStreaming(&client, archive_url, archive_path) catch return error.DownloadFailed;

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        const checksum_url = std.fmt.allocPrint(alloc, "{s}/{s}/fx-{s}.tar.gz.sha256", .{ cdn_base, target.artifactRef(), helpers.platform }) catch return error.AllocFailed;
        defer alloc.free(checksum_url);

        helpers.verifyChecksum(&client, archive_path, checksum_url) catch return error.ChecksumFailed;

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        helpers.extractTarGz(alloc, archive_path, tmp_dir) catch return error.ExtractionFailed;

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        const extracted_bin = std.fmt.allocPrint(alloc, "{s}/fx", .{tmp_dir}) catch return error.AllocFailed;
        defer alloc.free(extracted_bin);

        var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_exe = helpers.currentExecutablePath(&self_exe_buf) catch return error.SelfExeNotFound;
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

test "statusLabel idle returns empty" {
    var au = AutoUpgrade{};
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqual(@as(usize, 0), label.len);
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
    var revision = [_]u8{'1'} ** 40;
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

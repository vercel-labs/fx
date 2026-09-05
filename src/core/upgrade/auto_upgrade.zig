const std = @import("std");
const io_mod = @import("../shared/io.zig");
const helpers = @import("upgrade_helpers.zig");
const update_target = @import("update_target.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

const stable_check_interval_ms: u64 = 30 * 60 * 1000;
const dev_check_interval_ms: u64 = 60 * 1000;
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
        self.version_mutex.lockUncancelable(io_mod.getIo());
        self.should_stop.store(true, .release);
        self.version_mutex.unlock(io_mod.getIo());
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
        if (self.getState() != .ready or self.should_stop.load(.acquire)) {
            self.version_mutex.unlock(io_mod.getIo());
            debug_trace.logf("auto_upgrade", "relaunch admission lost: upgrade is not ready", .{});
            return error.NotReady;
        }
        defer self.version_mutex.unlock(io_mod.getIo());
        self.should_stop.store(true, .release);
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
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        self.setLatestVersionLocked(version);
    }

    fn setLatestVersionLocked(self: *AutoUpgrade, version: []const u8) void {
        const stripped = update_target.normalizeVersion(version);
        const len: u8 = @intCast(@min(stripped.len, 32));
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
        var installed: ?update_target.Target = null;
        defer if (installed) |*target| target.deinit(alloc);
        self.sleepInterruptible(initial_delay_ms);

        while (!self.should_stop.load(.acquire)) {
            self.runOnce(alloc, current, &installed, .{});
            if (self.selected_channel == .stable and self.getState() == .ready) return;
            self.sleepInterruptible(if (self.selected_channel == .dev)
                dev_check_interval_ms
            else
                stable_check_interval_ms);
        }
    }

    // Private effect boundaries for exercising a real cycle without network or installation.
    const CycleDeps = struct {
        ctx: ?*anyopaque = null,
        fetch: *const fn (?*anyopaque, Allocator, update_target.Channel, []const u8) error{ FetchFailed, OutOfMemory }!update_target.Target = fetchDefault,
        install: *const fn (?*anyopaque, *AutoUpgrade, Allocator, update_target.Target, []const u8) InstallError!void = installDefault,

        fn fetchTarget(self: CycleDeps, alloc: Allocator, selected: update_target.Channel, base: []const u8) error{ FetchFailed, OutOfMemory }!update_target.Target {
            return self.fetch(self.ctx, alloc, selected, base);
        }
    };

    fn fetchDefault(_: ?*anyopaque, alloc: Allocator, selected: update_target.Channel, base: []const u8) error{ FetchFailed, OutOfMemory }!update_target.Target {
        return helpers.fetchTarget(alloc, selected, base);
    }

    fn installDefault(_: ?*anyopaque, self: *AutoUpgrade, alloc: Allocator, target: update_target.Target, base: []const u8) InstallError!void {
        return self.downloadAndInstall(alloc, target, base);
    }

    fn waitForStop(self: *AutoUpgrade) std.Io.Cancelable!void {
        while (!self.should_stop.load(.acquire)) {
            try io_mod.getIo().sleep(.fromMilliseconds(sleep_increment_ms), .awake);
        }
    }

    // The caller owns the returned target. Drain late results before the worker
    // exits so cancellation cannot leak a target or outlive its allocator.
    fn fetchInterruptible(
        self: *AutoUpgrade,
        alloc: Allocator,
        selected: update_target.Channel,
        base: []const u8,
        deps: CycleDeps,
    ) error{ FetchFailed, OutOfMemory, Cancelled }!update_target.Target {
        if (self.should_stop.load(.acquire)) return error.Cancelled;
        const Event = union(enum) {
            fetched: error{ FetchFailed, OutOfMemory }!update_target.Target,
            stopped: std.Io.Cancelable!void,
        };
        var buffer: [2]Event = undefined;
        var select: std.Io.Select(Event) = .init(io_mod.getIo(), &buffer);
        defer while (select.cancel()) |event| switch (event) {
            .fetched => |result| {
                var target = result catch continue;
                target.deinit(alloc);
            },
            .stopped => {},
        };
        select.concurrent(.stopped, waitForStop, .{self}) catch return error.FetchFailed;
        select.concurrent(.fetched, CycleDeps.fetchTarget, .{ deps, alloc, selected, base }) catch return error.FetchFailed;
        switch (select.await() catch return error.Cancelled) {
            .fetched => |result| {
                var target = try result;
                if (self.should_stop.load(.acquire)) {
                    target.deinit(alloc);
                    return error.Cancelled;
                }
                return target;
            },
            .stopped => return error.Cancelled,
        }
    }

    fn beginDownload(self: *AutoUpgrade, label: []const u8) bool {
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        if (self.should_stop.load(.acquire)) return false;
        self.setLatestVersionLocked(label);
        self.setState(.downloading);
        return true;
    }

    fn finishCycle(self: *AutoUpgrade) void {
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        if (self.should_stop.load(.acquire)) return;
        if (self.getState() == .checking) self.setState(.waiting);
    }

    fn runOnce(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
        installed: *?update_target.Target,
        deps: CycleDeps,
    ) void {
        self.version_mutex.lockUncancelable(io_mod.getIo());
        if (self.should_stop.load(.acquire) or
            (self.selected_channel == .stable and self.getState() == .ready))
        {
            self.version_mutex.unlock(io_mod.getIo());
            return;
        }
        if (self.getState() != .ready) self.setState(.checking);
        self.version_mutex.unlock(io_mod.getIo());
        defer self.finishCycle();

        const cdn_base = helpers.resolveCdnBase();
        var target = self.fetchInterruptible(alloc, self.selected_channel, cdn_base, deps) catch return;
        var owns_target = true;
        defer if (owns_target) target.deinit(alloc);

        const baseline: update_target.CurrentBuild = if (installed.*) |previous| .{
            .channel = previous.channel(),
            .version = previous.version(),
            .revision = previous.revision() orelse "unknown",
        } else current;
        if (!target.shouldInstall(baseline)) {
            self.version_mutex.lockUncancelable(io_mod.getIo());
            defer self.version_mutex.unlock(io_mod.getIo());
            if (installed.* != null and !self.should_stop.load(.acquire)) self.setState(.ready);
            return;
        }

        var label_buf: [64]u8 = undefined;
        const label = target.writeDisplayLabel(&label_buf) catch return;
        if (!self.beginDownload(label)) return;

        deps.install(deps.ctx, self, alloc, target, cdn_base) catch |err| {
            debug_trace.logf("auto_upgrade", "candidate {s} not installed: {s}", .{ target.artifactRef(), @errorName(err) });
            self.version_mutex.lockUncancelable(io_mod.getIo());
            defer self.version_mutex.unlock(io_mod.getIo());
            if (!self.should_stop.load(.acquire)) self.setState(if (err == error.Superseded) .waiting else .failed);
            return;
        };
        if (installed.*) |*previous| previous.deinit(alloc);
        installed.* = target;
        owns_target = false;

        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        if (!self.should_stop.load(.acquire)) self.setState(.ready);
    }

    const InstallError = error{
        AllocFailed,
        DownloadFailed,
        ChecksumFailed,
        ExtractionFailed,
        SelfExeNotFound,
        InstallFailed,
        Cancelled,
        RevalidationFailed,
        Superseded,
    };

    fn revalidateCandidate(
        self: *AutoUpgrade,
        alloc: Allocator,
        target: update_target.Target,
        cdn_base: []const u8,
        deps: CycleDeps,
    ) InstallError!void {
        if (self.should_stop.load(.acquire)) return error.Cancelled;
        if (target == .dev) {
            var latest = self.fetchInterruptible(alloc, .dev, cdn_base, deps) catch |err| return switch (err) {
                error.Cancelled => error.Cancelled,
                error.FetchFailed, error.OutOfMemory => error.RevalidationFailed,
            };
            defer latest.deinit(alloc);
            if (self.should_stop.load(.acquire)) return error.Cancelled;
            if (latest != .dev or !std.ascii.eqlIgnoreCase(latest.dev.revision, target.dev.revision)) {
                debug_trace.logf("auto_upgrade", "discarding superseded candidate {s}; manifest now names {s}", .{ target.artifactRef(), latest.artifactRef() });
                return error.Superseded;
            }
        }
    }

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
        try self.revalidateCandidate(alloc, target, cdn_base, .{});
        if (self.should_stop.load(.acquire)) return error.Cancelled;
        io_mod.copyFileAtomic(alloc, extracted_bin, self_exe) catch return error.InstallFailed;
    }

    fn sleepInterruptible(self: *AutoUpgrade, total_ms: u64) void {
        const io = io_mod.getIo();
        const started = std.Io.Clock.Timestamp.now(io, .awake);
        while (!self.should_stop.load(.acquire)) {
            const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
            const elapsed_ms: u64 = @intCast(@max(0, elapsed));
            if (elapsed_ms >= total_ms) return;
            const chunk = @min(total_ms - elapsed_ms, sleep_increment_ms);
            io.sleep(.fromMilliseconds(@intCast(chunk)), .awake) catch return;
        }
    }
};

const TestCycle = struct {
    const original_revision = "a" ** 64;
    const revision_b = "0123456789ab" ++ "b" ** 28;
    const revision_c = "0123456789ab" ++ "c" ** 28;
    const revision_d = "0123456789ab" ++ "d" ** 28;
    const current: update_target.CurrentBuild = .{
        .channel = .dev,
        .version = "0.3.0",
        .revision = original_revision,
    };

    updater: AutoUpgrade = .{ .selected_channel = .dev },
    installed: ?update_target.Target = null,
    revision: []const u8 = revision_b,
    stable_version: []const u8 = "0.4.0",
    fetch_count: usize = 0,
    install_count: usize = 0,
    copy_count: usize = 0,
    fetch_error: bool = false,
    install_error: ?AutoUpgrade.InstallError = null,
    revalidation_revision: ?[]const u8 = null,
    revalidation_error: bool = false,
    reload_during_fetch: bool = false,
    reload_during_install: bool = false,
    reload_rejected: bool = false,
    stop_during_fetch: bool = false,
    stop_during_install: bool = false,
    stop_after_copy: bool = false,

    fn deinit(self: *TestCycle) void {
        if (self.installed) |*target| target.deinit(std.testing.allocator);
    }

    fn deps(self: *TestCycle) AutoUpgrade.CycleDeps {
        return .{ .ctx = self, .fetch = fetch, .install = install };
    }

    fn cycle(self: *TestCycle) void {
        self.updater.runOnce(std.testing.allocator, current, &self.installed, self.deps());
    }

    fn fetch(ctx: ?*anyopaque, alloc: Allocator, selected: update_target.Channel, _: []const u8) error{ FetchFailed, OutOfMemory }!update_target.Target {
        const self: *TestCycle = @ptrCast(@alignCast(ctx.?));
        self.fetch_count += 1;
        if (self.reload_during_fetch) {
            self.updater.requestRelaunch("/tmp/fx") catch return error.FetchFailed;
        }
        if (self.stop_during_fetch) self.updater.stop();
        if (self.fetch_error) return error.FetchFailed;
        if (selected == .stable) return update_target.Target.initStable(alloc, self.stable_version) catch return error.FetchFailed;
        var manifest_buf: [160]u8 = undefined;
        const manifest = std.fmt.bufPrint(&manifest_buf, "{{\"version\":\"0.3.0\",\"commit\":\"{s}\"}}", .{self.revision}) catch return error.FetchFailed;
        return update_target.Target.parseDevManifest(alloc, manifest) catch return error.FetchFailed;
    }

    fn install(ctx: ?*anyopaque, updater: *AutoUpgrade, alloc: Allocator, target: update_target.Target, base: []const u8) AutoUpgrade.InstallError!void {
        const self: *TestCycle = @ptrCast(@alignCast(ctx.?));
        self.install_count += 1;
        if (self.reload_during_install) {
            updater.requestRelaunch("/tmp/fx") catch |err| {
                self.reload_rejected = err == error.NotReady;
            };
        }
        if (self.install_error) |err| return err;
        if (self.stop_during_install) updater.stop();
        if (self.revalidation_revision) |revision| self.revision = revision;
        self.fetch_error = self.revalidation_error;
        try updater.revalidateCandidate(alloc, target, base, self.deps());
        self.copy_count += 1;
        if (self.stop_after_copy) updater.stop();
    }
};

test "auto upgrade dev cycles retain full installed identity through B C D and original reload revision" {
    var fixture = TestCycle{};
    defer fixture.deinit();
    fixture.updater.setPreviousRevision(TestCycle.original_revision);

    for ([_][]const u8{ TestCycle.revision_b, TestCycle.revision_c, TestCycle.revision_d }, 1..) |revision, count| {
        fixture.revision = revision;
        fixture.cycle();
        try std.testing.expectEqual(State.ready, fixture.updater.getState());
        try std.testing.expectEqualStrings(revision, fixture.installed.?.revision().?);
        try std.testing.expectEqual(count, fixture.copy_count);
        try std.testing.expect(fixture.updater.takeRenderDirty());
        const fetch_count = fixture.fetch_count;
        fixture.cycle();
        try std.testing.expectEqual(count, fixture.install_count);
        try std.testing.expectEqual(fetch_count + 1, fixture.fetch_count);
        try std.testing.expectEqual(State.ready, fixture.updater.getState());
        try std.testing.expect(!fixture.updater.takeRenderDirty());
    }
    try fixture.updater.requestRelaunch("/tmp/fx");
    const request = fixture.updater.takeRelaunchRequest().?;
    try std.testing.expectEqualStrings(TestCycle.original_revision, request.previousRevision().?);
    try std.testing.expect(fixture.updater.should_stop.load(.acquire));
}

test "auto upgrade discovery failure preserves ready but failed replacement does not" {
    var fixture = TestCycle{};
    defer fixture.deinit();
    fixture.cycle();
    _ = fixture.updater.takeRenderDirty();
    fixture.fetch_error = true;
    fixture.cycle();
    try std.testing.expectEqual(State.ready, fixture.updater.getState());
    try std.testing.expect(!fixture.updater.takeRenderDirty());
    try std.testing.expectEqual(@as(usize, 1), fixture.install_count);

    fixture.fetch_error = false;
    fixture.revision = TestCycle.revision_c;
    for ([_]AutoUpgrade.InstallError{ error.DownloadFailed, error.ChecksumFailed, error.ExtractionFailed, error.InstallFailed }) |err| {
        fixture.install_error = err;
        fixture.cycle();
        try std.testing.expectEqual(State.failed, fixture.updater.getState());
        try std.testing.expectEqualStrings(TestCycle.revision_b, fixture.installed.?.revision().?);
        try std.testing.expectEqual(@as(usize, 1), fixture.copy_count);
        try std.testing.expectError(error.NotReady, fixture.updater.requestRelaunch("/tmp/fx"));
    }
    fixture.install_error = null;
    fixture.cycle();
    try std.testing.expectEqual(State.ready, fixture.updater.getState());
    try std.testing.expectEqualStrings(TestCycle.revision_c, fixture.installed.?.revision().?);
}

test "auto upgrade restores installed target after failed or superseded replacement without redownload" {
    for ([_]AutoUpgrade.InstallError{ error.DownloadFailed, error.Superseded }) |err| {
        var fixture = TestCycle{};
        defer fixture.deinit();
        fixture.cycle();
        fixture.revision = TestCycle.revision_c;
        fixture.install_error = err;
        fixture.cycle();
        try std.testing.expectEqual(if (err == error.Superseded) State.waiting else State.failed, fixture.updater.getState());
        try std.testing.expectError(error.NotReady, fixture.updater.requestRelaunch("/tmp/fx"));

        fixture.revision = TestCycle.revision_b;
        _ = fixture.updater.takeRenderDirty();
        fixture.cycle();
        try std.testing.expectEqual(State.ready, fixture.updater.getState());
        try std.testing.expect(fixture.updater.takeRenderDirty());
        try std.testing.expectEqual(@as(usize, 2), fixture.install_count);
        try std.testing.expectEqual(@as(usize, 1), fixture.copy_count);
        try std.testing.expectEqualStrings(TestCycle.revision_b, fixture.installed.?.revision().?);
        fixture.cycle();
        try std.testing.expect(!fixture.updater.takeRenderDirty());
        try fixture.updater.requestRelaunch("/tmp/fx");
    }
}

test "auto upgrade does not restore installed target after stop during discovery" {
    var fixture = TestCycle{};
    defer fixture.deinit();
    fixture.cycle();
    fixture.revision = TestCycle.revision_c;
    fixture.install_error = error.DownloadFailed;
    fixture.cycle();
    fixture.revision = TestCycle.revision_b;
    fixture.stop_during_fetch = true;
    fixture.cycle();
    try std.testing.expectEqual(State.checking, fixture.updater.getState());
    try std.testing.expectEqual(@as(usize, 2), fixture.install_count);
    try std.testing.expectError(error.NotReady, fixture.updater.requestRelaunch("/tmp/fx"));
}

const BlockedManifestTest = struct {
    server: *std.Io.net.Server,
    base: []const u8,
    fixture: *TestCycle,
    partial_body: bool,
    revalidation: bool,
    requested: std.atomic.Value(bool) = .init(false),
    fetch_exited: std.atomic.Value(bool) = .init(false),
    worker_exited: std.atomic.Value(bool) = .init(false),
    peer_closed: bool = false,
    revalidation_error: ?AutoUpgrade.InstallError = null,

    fn serve(self: *BlockedManifestTest) !void {
        const io = io_mod.getIo();
        const stream = try self.server.accept(io);
        defer stream.close(io);
        var read_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        const request = try reader.interface.takeDelimiterInclusive('\n');
        try std.testing.expectEqualStrings("GET /dev.json HTTP/1.1\r\n", request);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
        }
        if (self.partial_body) {
            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            try writer.interface.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\n{\r\n");
            try writer.interface.flush();
        }
        self.requested.store(true, .release);
        // Only the client can end this stall. Server cancellation is deferred
        // until after stop has joined the updater and its latency is checked.
        var byte: [1]u8 = undefined;
        self.peer_closed = try reader.interface.readSliceShort(&byte) == 0;
    }

    fn fetch(ctx: ?*anyopaque, alloc: Allocator, selected: update_target.Channel, _: []const u8) error{ FetchFailed, OutOfMemory }!update_target.Target {
        const self: *BlockedManifestTest = @ptrCast(@alignCast(ctx.?));
        defer self.fetch_exited.store(true, .release);
        return AutoUpgrade.fetchDefault(null, alloc, selected, self.base);
    }

    fn run(self: *BlockedManifestTest) void {
        defer self.worker_exited.store(true, .release);
        const deps: AutoUpgrade.CycleDeps = .{ .ctx = self, .fetch = fetch };
        if (self.revalidation) {
            self.fixture.updater.revalidateCandidate(std.testing.allocator, self.fixture.installed.?, self.base, deps) catch |err| {
                self.revalidation_error = err;
            };
        } else {
            self.fixture.updater.runOnce(std.testing.allocator, TestCycle.current, &self.fixture.installed, deps);
        }
    }
};

test "auto upgrade stop joins blocked HTTP manifest discovery and revalidation" {
    for ([_]bool{ false, true }) |partial_body| {
        for ([_]bool{ false, true }) |revalidation| {
            const io = io_mod.getIo();
            var fixture = TestCycle{};
            defer fixture.deinit();
            fixture.cycle();
            _ = fixture.updater.takeRenderDirty();
            if (revalidation) fixture.updater.setState(.downloading);
            const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
            var server = try address.listen(io, .{ .reuse_address = true });
            defer server.deinit(io);
            var base_buf: [80]u8 = undefined;
            const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
            var probe: BlockedManifestTest = .{
                .server = &server,
                .base = base,
                .fixture = &fixture,
                .partial_body = partial_body,
                .revalidation = revalidation,
            };
            var serving = try io.concurrent(BlockedManifestTest.serve, .{&probe});
            defer _ = serving.cancel(io) catch {};
            fixture.updater.thread = try std.Thread.spawn(.{}, BlockedManifestTest.run, .{&probe});
            defer fixture.updater.stop();
            const deadline = io_mod.milliTimestamp() + 2_000;
            while (!probe.requested.load(.acquire) and !probe.worker_exited.load(.acquire) and io_mod.milliTimestamp() < deadline) {
                try io.sleep(.fromMilliseconds(1), .awake);
            }
            try std.testing.expect(probe.requested.load(.acquire));
            try io.sleep(.fromMilliseconds(20), .awake);
            try std.testing.expect(!probe.fetch_exited.load(.acquire));
            try std.testing.expect(!probe.worker_exited.load(.acquire));
            const started = io_mod.milliTimestamp();
            if (!revalidation) try fixture.updater.requestRelaunch("/tmp/fx");
            fixture.updater.stop();
            try std.testing.expect(io_mod.milliTimestamp() - started < 1_000);
            try std.testing.expect(probe.fetch_exited.load(.acquire));
            try std.testing.expect(probe.worker_exited.load(.acquire));
            try std.testing.expect(fixture.updater.thread == null);
            try serving.await(io);
            try std.testing.expect(probe.peer_closed);
            try std.testing.expectEqualStrings(TestCycle.revision_b, fixture.installed.?.revision().?);
            if (revalidation) {
                try std.testing.expectEqual(error.Cancelled, probe.revalidation_error.?);
                try std.testing.expectEqual(State.downloading, fixture.updater.getState());
            } else {
                try std.testing.expectEqual(State.ready, fixture.updater.getState());
                try std.testing.expect(!fixture.updater.takeRenderDirty());
                try std.testing.expect(fixture.updater.takeRelaunchRequest() != null);
            }
        }
    }
}

test "auto upgrade revalidation discards superseded candidate and bounds each cycle" {
    var fixture = TestCycle{};
    defer fixture.deinit();
    fixture.revalidation_revision = TestCycle.revision_c;
    fixture.cycle();
    try std.testing.expectEqual(@as(usize, 2), fixture.fetch_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.install_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.copy_count);
    try std.testing.expect(fixture.installed == null);
    try std.testing.expectEqual(State.waiting, fixture.updater.getState());
    fixture.revalidation_revision = null;
    fixture.cycle();
    try std.testing.expectEqualStrings(TestCycle.revision_c, fixture.installed.?.revision().?);
    try std.testing.expectEqual(State.ready, fixture.updater.getState());

    fixture.revision = TestCycle.revision_d;
    fixture.revalidation_error = true;
    fixture.cycle();
    try std.testing.expectEqual(State.failed, fixture.updater.getState());
    try std.testing.expectEqual(@as(usize, 1), fixture.copy_count);
    try std.testing.expectEqualStrings(TestCycle.revision_c, fixture.installed.?.revision().?);
    fixture.revalidation_error = false;
    fixture.fetch_error = false;
    fixture.cycle();
    try std.testing.expectEqualStrings(TestCycle.revision_d, fixture.installed.?.revision().?);
}

test "auto upgrade reload wins admission while discovery is in flight" {
    var fixture = TestCycle{};
    defer fixture.deinit();
    fixture.cycle();
    _ = fixture.updater.takeRenderDirty();
    fixture.revision = TestCycle.revision_c;
    fixture.reload_during_fetch = true;
    fixture.cycle();
    try std.testing.expectEqual(@as(usize, 1), fixture.install_count);
    try std.testing.expectEqualStrings(TestCycle.revision_b, fixture.installed.?.revision().?);
    try std.testing.expectEqual(State.ready, fixture.updater.getState());
    try std.testing.expect(!fixture.updater.takeRenderDirty());
    try std.testing.expect(fixture.updater.takeRelaunchRequest() != null);
    try std.testing.expect(!fixture.updater.beginDownload("late candidate"));
    const fetch_count = fixture.fetch_count;
    fixture.cycle();
    try std.testing.expectEqual(fetch_count, fixture.fetch_count);
}

test "auto upgrade replacement wins admission before reload" {
    var fixture = TestCycle{};
    defer fixture.deinit();
    fixture.cycle();
    fixture.revision = TestCycle.revision_c;
    fixture.reload_during_install = true;
    fixture.cycle();
    try std.testing.expect(fixture.reload_rejected);
    try std.testing.expect(fixture.updater.takeRelaunchRequest() == null);
    try std.testing.expect(!fixture.updater.should_stop.load(.acquire));
    try std.testing.expectEqualStrings(TestCycle.revision_c, fixture.installed.?.revision().?);
    try fixture.updater.requestRelaunch("/tmp/fx");
}

test "auto upgrade cancellation blocks late admission copy and ready publication" {
    var discovery = TestCycle{ .stop_during_fetch = true };
    defer discovery.deinit();
    discovery.cycle();
    try std.testing.expectEqual(@as(usize, 0), discovery.install_count);
    try std.testing.expect(discovery.installed == null);
    try std.testing.expectEqual(State.checking, discovery.updater.getState());

    var installing = TestCycle{ .stop_during_install = true };
    defer installing.deinit();
    installing.cycle();
    try std.testing.expectEqual(@as(usize, 0), installing.copy_count);
    try std.testing.expect(installing.installed == null);
    try std.testing.expectEqual(State.downloading, installing.updater.getState());

    var copied = TestCycle{ .stop_after_copy = true };
    defer copied.deinit();
    copied.cycle();
    try std.testing.expectEqual(@as(usize, 1), copied.copy_count);
    try std.testing.expectEqualStrings(TestCycle.revision_b, copied.installed.?.revision().?);
    try std.testing.expectEqual(State.downloading, copied.updater.getState());
    try std.testing.expectError(error.NotReady, copied.updater.requestRelaunch("/tmp/fx"));
}

test "auto upgrade stable stops discovery after ready and skips dev revalidation" {
    var fixture = TestCycle{};
    defer fixture.deinit();
    fixture.updater.configure_channel(.stable);
    fixture.cycle();
    try std.testing.expectEqual(State.ready, fixture.updater.getState());
    try std.testing.expectEqual(@as(usize, 1), fixture.fetch_count);
    fixture.stable_version = "0.5.0";
    fixture.cycle();
    try std.testing.expectEqual(@as(usize, 1), fixture.fetch_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.copy_count);
    try fixture.updater.requestRelaunch("/tmp/fx");
    try std.testing.expect(fixture.updater.takeRelaunchRequest().?.previousRevision() == null);
}

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
    au.setState(.ready);
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

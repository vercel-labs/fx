const std = @import("std");
const io_mod = @import("../shared/io.zig");
const output_contracts = @import("../output/output_contracts.zig");
const helpers = @import("upgrade_helpers.zig");
const update_target = @import("update_target.zig");

const Allocator = std.mem.Allocator;

pub const platform = helpers.platform;

const progress_label = "upgrading...";
const found_hold_ns = 150 * std.time.ns_per_ms;

pub const RunResult = struct {
    snapshot: output_contracts.UpgradeSnapshot,
    target_owned: ?update_target.Target = null,

    pub fn deinit(self: *RunResult, alloc: Allocator) void {
        if (self.target_owned) |*target| target.deinit(alloc);
        self.* = undefined;
    }
};

const RunError = error{
    FetchFailed,
    DownloadFailed,
    ChecksumFetchFailed,
    ChecksumMismatch,
    ExtractionFailed,
    SelfExeNotFound,
    ReplaceFailed,
    OutOfMemory,
};

pub fn run(
    alloc: Allocator,
    current: update_target.CurrentBuild,
    channel: update_target.Channel,
    format: output_contracts.OutputFormat,
) RunResult {
    return runInner(alloc, current, channel, format) catch |err| failureResult(current, channel, err);
}

fn runInner(
    alloc: Allocator,
    current: update_target.CurrentBuild,
    channel: update_target.Channel,
    format: output_contracts.OutputFormat,
) RunError!RunResult {
    var done = std.atomic.Value(bool).init(false);
    var progress = ProgressState{};
    var worker_result = WorkerResult{};

    const show_progress = format == .text;
    const worker = std.Thread.spawn(.{}, upgradeWorker, .{ alloc, current, channel, &done, &worker_result, &progress, show_progress }) catch
        return error.FetchFailed;

    if (show_progress) {
        progressWait(&done, &progress, &worker_result, current.version);
    } else {
        worker.join();
    }
    if (format == .text) worker.join();

    return completeRunResult(alloc, current, channel, worker_result);
}

fn completeRunResult(
    alloc: Allocator,
    current: update_target.CurrentBuild,
    channel: update_target.Channel,
    worker_result: WorkerResult,
) RunError!RunResult {
    if (worker_result.err) |e| {
        if (worker_result.target_owned) |target_value| {
            var target = target_value;
            target.deinit(alloc);
        }
        return workerErrorToRunError(e);
    }

    const target = worker_result.target_owned orelse return error.FetchFailed;
    const latest = target.version();
    const latest_revision = target.revision() orelse "";

    if (!target.shouldInstall(current)) {
        return .{
            .snapshot = .{
                .current = versionLabel(current.version),
                .latest = latest,
                .channel = channel.label(),
                .current_channel = current.channel.label(),
                .current_revision = current.revision,
                .latest_revision = latest_revision,
                .status = .up_to_date,
            },
            .target_owned = target,
        };
    }

    return .{
        .snapshot = .{
            .current = versionLabel(current.version),
            .latest = latest,
            .channel = channel.label(),
            .current_channel = current.channel.label(),
            .current_revision = current.revision,
            .latest_revision = latest_revision,
            .status = .upgraded,
        },
        .target_owned = target,
    };
}

fn failureResult(
    current: update_target.CurrentBuild,
    channel: update_target.Channel,
    err: RunError,
) RunResult {
    return .{ .snapshot = .{
        .current = versionLabel(current.version),
        .latest = "",
        .channel = channel.label(),
        .current_channel = current.channel.label(),
        .current_revision = current.revision,
        .status = .failed,
        .err_message = failureMessage(err),
    } };
}

fn failureMessage(err: RunError) []const u8 {
    return switch (err) {
        error.FetchFailed => "failed to fetch latest version from CDN",
        error.DownloadFailed => "failed to download release archive",
        error.ChecksumFetchFailed => "failed to fetch checksum from CDN",
        error.ChecksumMismatch => "downloaded archive failed integrity check",
        error.ExtractionFailed => "failed to extract release archive",
        error.SelfExeNotFound => "could not determine path of running binary",
        error.ReplaceFailed => "failed to replace binary (permission denied?)",
        error.OutOfMemory => "out of memory",
    };
}

fn workerErrorToRunError(err: UpgradeError) RunError {
    return switch (err) {
        .fetch_failed => error.FetchFailed,
        .download_failed => error.DownloadFailed,
        .checksum_fetch_failed => error.ChecksumFetchFailed,
        .checksum_mismatch => error.ChecksumMismatch,
        .extraction_failed => error.ExtractionFailed,
        .self_exe_not_found => error.SelfExeNotFound,
        .replace_failed => error.ReplaceFailed,
        .out_of_memory => error.OutOfMemory,
    };
}

fn upgradeWorker(
    alloc: Allocator,
    current: update_target.CurrentBuild,
    channel: update_target.Channel,
    done: *std.atomic.Value(bool),
    result: *WorkerResult,
    progress: *ProgressState,
    show_progress: bool,
) void {
    defer done.store(true, .release);
    upgradeWorkerInner(alloc, current, channel, result, progress, show_progress) catch {
        if (result.err == null) result.err = .out_of_memory;
    };
}

fn upgradeWorkerInner(
    alloc: Allocator,
    current: update_target.CurrentBuild,
    channel: update_target.Channel,
    result: *WorkerResult,
    progress: *ProgressState,
    show_progress: bool,
) !void {
    const cdn_base = helpers.resolveCdnBase();
    const fetched_target = helpers.fetchTarget(alloc, channel, cdn_base) catch {
        result.err = .fetch_failed;
        return;
    };
    result.target_owned = fetched_target;
    const target = result.target_owned.?;

    if (!target.shouldInstall(current)) return;
    progress.markUpdateFound();
    if (show_progress) io_mod.sleep(found_hold_ns);

    const tmp_base: []const u8 = io_mod.getenv("TMPDIR") orelse "/tmp";
    var rand_buf: [8]u8 = undefined;
    io_mod.getIo().random(&rand_buf);
    const rand_hex = std.fmt.bytesToHex(rand_buf, .lower);
    const tmp_dir = try std.fmt.allocPrint(alloc, "{s}/fx-upgrade-{s}", .{ tmp_base, rand_hex });
    defer alloc.free(tmp_dir);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), tmp_dir) catch {};

    std.Io.Dir.createDirAbsolute(io_mod.getIo(), tmp_dir, .default_dir) catch {
        result.err = .extraction_failed;
        return;
    };

    const archive_path = try std.fmt.allocPrint(alloc, "{s}/fx.tar.gz", .{tmp_dir});
    defer alloc.free(archive_path);

    const archive_url = try std.fmt.allocPrint(alloc, "{s}/{s}/fx-{s}.tar.gz", .{ cdn_base, target.artifactRef(), helpers.platform });
    defer alloc.free(archive_url);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    helpers.downloadFileStreamingWithProgress(&client, archive_url, archive_path, .{
        .ctx = progress,
        .start = progressDownloadStart,
        .update = progressDownloadUpdate,
    }) catch {
        result.err = .download_failed;
        return;
    };
    progress.markFinishing();

    const checksum_url = try std.fmt.allocPrint(alloc, "{s}/{s}/fx-{s}.tar.gz.sha256", .{ cdn_base, target.artifactRef(), helpers.platform });
    defer alloc.free(checksum_url);

    helpers.verifyChecksum(&client, archive_path, checksum_url) catch |err| {
        result.err = switch (err) {
            error.ChecksumFetchFailed => .checksum_fetch_failed,
            error.ChecksumMismatch => .checksum_mismatch,
        };
        return;
    };

    helpers.extractTarGz(alloc, archive_path, tmp_dir) catch {
        result.err = .extraction_failed;
        return;
    };

    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = helpers.currentExecutablePath(&self_exe_buf) catch {
        result.err = .self_exe_not_found;
        return;
    };

    helpers.replaceInstalledSet(alloc, tmp_dir, self_exe) catch {
        result.err = .replace_failed;
        return;
    };
}

const ProgressPhase = enum(u8) {
    checking,
    found,
    downloading_known,
    downloading_unknown,
    finishing,
};

const ProgressSnapshot = struct {
    phase: ProgressPhase,
    downloaded: u64,
    total: u64,
};

const ProgressState = struct {
    phase: std.atomic.Value(u8) = .init(@intFromEnum(ProgressPhase.checking)),
    downloaded: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),

    fn markUpdateFound(self: *ProgressState) void {
        self.phase.store(@intFromEnum(ProgressPhase.found), .release);
    }

    fn markDownloadStart(self: *ProgressState, total: ?u64) void {
        self.downloaded.store(0, .release);
        self.total.store(total orelse 0, .release);
        self.phase.store(@intFromEnum(if (total == null) ProgressPhase.downloading_unknown else ProgressPhase.downloading_known), .release);
    }

    fn markDownloadProgress(self: *ProgressState, downloaded: u64, total: ?u64) void {
        self.downloaded.store(downloaded, .release);
        if (total) |n| self.total.store(n, .release);
    }

    fn markFinishing(self: *ProgressState) void {
        self.phase.store(@intFromEnum(ProgressPhase.finishing), .release);
    }

    fn snapshot(self: *ProgressState) ProgressSnapshot {
        const raw_phase = self.phase.load(.acquire);
        return .{
            .phase = progressPhaseFromRaw(raw_phase),
            .downloaded = self.downloaded.load(.acquire),
            .total = self.total.load(.acquire),
        };
    }
};

fn progressPhaseFromRaw(raw: u8) ProgressPhase {
    return switch (raw) {
        @intFromEnum(ProgressPhase.checking) => .checking,
        @intFromEnum(ProgressPhase.found) => .found,
        @intFromEnum(ProgressPhase.downloading_known) => .downloading_known,
        @intFromEnum(ProgressPhase.downloading_unknown) => .downloading_unknown,
        @intFromEnum(ProgressPhase.finishing) => .finishing,
        else => .checking,
    };
}

fn progressDownloadStart(ctx: *anyopaque, total: ?u64) void {
    const progress: *ProgressState = @ptrCast(@alignCast(ctx));
    progress.markDownloadStart(total);
}

fn progressDownloadUpdate(ctx: *anyopaque, downloaded: u64, total: ?u64) void {
    const progress: *ProgressState = @ptrCast(@alignCast(ctx));
    progress.markDownloadProgress(downloaded, total);
}

fn progressWait(done: *std.atomic.Value(bool), progress: *ProgressState, worker_result: *const WorkerResult, current: []const u8) void {
    const stderr = std.Io.File.stderr();
    const zio = io_mod.getIo();
    var buf: [128]u8 = undefined;
    var rendered_row = false;

    while (!done.load(.acquire)) {
        const snapshot = progress.snapshot();
        var latest_buf: [64]u8 = undefined;
        const latest_label = target_label_after_progress_snapshot(snapshot, worker_result, &latest_buf);
        if (formatProgressStatusLine(&buf, snapshot, current, latest_label)) |text| {
            if (rendered_row) stderr.writeStreamingAll(zio, "\r\x1b[K") catch return;
            stderr.writeStreamingAll(zio, text) catch return;
            rendered_row = true;
        }
        io_mod.sleep(50 * std.time.ns_per_ms);
    }
    if (rendered_row) stderr.writeStreamingAll(zio, "\r\x1b[K") catch {};
}

fn target_label_after_progress_snapshot(
    snapshot: ProgressSnapshot,
    worker_result: *const WorkerResult,
    out: []u8,
) ?[]const u8 {
    if (snapshot.phase == .checking) return null;
    const target = worker_result.target_owned orelse return null;
    return target.writeDisplayLabel(out) catch null;
}

fn progressPercent(downloaded: u64, total: u64) ?u8 {
    if (total == 0) return null;
    const clamped = @min(downloaded, total);
    const pct = (@as(u128, clamped) * 100) / @as(u128, total);
    return @intCast(pct);
}

fn formatProgressStatusLine(buf: []u8, snapshot: ProgressSnapshot, current: []const u8, latest_label: ?[]const u8) ?[]const u8 {
    return switch (snapshot.phase) {
        .checking => null,
        .found => blk: {
            const latest = latest_label orelse return null;
            var out: std.Io.Writer = .fixed(buf);
            out.print("fx {s} -> {s}", .{ current, versionLabel(latest) }) catch return out.buffered();
            break :blk out.buffered();
        },
        .downloading_known => if (snapshot.total > 0)
            formatProgressLine(buf, progressPercent(snapshot.downloaded, snapshot.total).?)
        else
            progress_label,
        .downloading_unknown => progress_label,
        .finishing => if (snapshot.total > 0)
            formatProgressLine(buf, 100)
        else
            progress_label,
    };
}

fn formatProgressLine(buf: []u8, percent: u8) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.print("{d}%", .{percent}) catch return out.buffered();
    return out.buffered();
}

const WorkerResult = struct {
    target_owned: ?update_target.Target = null,
    err: ?UpgradeError = null,
};

const UpgradeError = enum {
    fetch_failed,
    download_failed,
    checksum_fetch_failed,
    checksum_mismatch,
    extraction_failed,
    self_exe_not_found,
    replace_failed,
    out_of_memory,
};

fn versionLabel(v: []const u8) []const u8 {
    if (v.len > 0 and v[0] != 'v') return v;
    return if (v.len > 1) v[1..] else v;
}

test "versionLabel strips lowercase v prefix" {
    try std.testing.expectEqualStrings("0.1.0", versionLabel("v0.1.0"));
    try std.testing.expectEqualStrings("0.1.0", versionLabel("0.1.0"));
    try std.testing.expectEqualStrings("v", versionLabel("v"));
    try std.testing.expectEqualStrings("V0.1.0", versionLabel("V0.1.0"));
}

test "completeRunResult reports up to date when normalized versions match" {
    const alloc = std.testing.allocator;
    const target = try update_target.Target.initStable(alloc, "v0.2.10");

    var result = try completeRunResult(alloc, .{
        .channel = .stable,
        .version = "0.2.10",
        .revision = "0123456789ab",
    }, .stable, .{ .target_owned = target });
    defer result.deinit(alloc);

    try std.testing.expectEqual(output_contracts.UpgradeSnapshot.Status.up_to_date, result.snapshot.status);
    try std.testing.expectEqualStrings("0.2.10", result.snapshot.current);
    try std.testing.expectEqualStrings("0.2.10", result.snapshot.latest);
}

test "completeRunResult reports upgraded when latest differs" {
    const alloc = std.testing.allocator;
    const target = try update_target.Target.initStable(alloc, "0.2.11");

    var result = try completeRunResult(alloc, .{
        .channel = .stable,
        .version = "0.2.10",
        .revision = "0123456789ab",
    }, .stable, .{ .target_owned = target });
    defer result.deinit(alloc);

    try std.testing.expectEqual(output_contracts.UpgradeSnapshot.Status.upgraded, result.snapshot.status);
    try std.testing.expectEqualStrings("0.2.10", result.snapshot.current);
    try std.testing.expectEqualStrings("0.2.11", result.snapshot.latest);
}

test "completeRunResult reports no update for an older stable target" {
    const alloc = std.testing.allocator;
    const target = try update_target.Target.initStable(alloc, "v0.0.1");

    var result = try completeRunResult(alloc, .{
        .channel = .stable,
        .version = "0.0.2",
        .revision = "0123456789ab",
    }, .stable, .{ .target_owned = target });
    defer result.deinit(alloc);

    try std.testing.expectEqual(output_contracts.UpgradeSnapshot.Status.up_to_date, result.snapshot.status);
    try std.testing.expectEqualStrings("0.0.2", result.snapshot.current);
    try std.testing.expectEqualStrings("0.0.1", result.snapshot.latest);
}

test "completeRunResult maps worker errors and frees latest version" {
    const alloc = std.testing.allocator;
    const target = try update_target.Target.initStable(alloc, "0.2.11");

    try std.testing.expectError(
        error.DownloadFailed,
        completeRunResult(alloc, .{
            .channel = .stable,
            .version = "0.2.10",
            .revision = "0123456789ab",
        }, .stable, .{
            .target_owned = target,
            .err = .download_failed,
        }),
    );
}

test "failureResult preserves active error messages" {
    const result = failureResult(.{
        .channel = .stable,
        .version = "v0.2.10",
        .revision = "0123456789ab",
    }, .stable, error.ChecksumMismatch);

    try std.testing.expectEqual(output_contracts.UpgradeSnapshot.Status.failed, result.snapshot.status);
    try std.testing.expectEqualStrings("0.2.10", result.snapshot.current);
    try std.testing.expectEqualStrings("", result.snapshot.latest);
    try std.testing.expectEqualStrings("downloaded archive failed integrity check", result.snapshot.err_message.?);
}

test "progressPercent clamps download progress to 100" {
    try std.testing.expectEqual(@as(u8, 0), progressPercent(0, 100).?);
    try std.testing.expectEqual(@as(u8, 48), progressPercent(48, 100).?);
    try std.testing.expectEqual(@as(u8, 100), progressPercent(120, 100).?);
    try std.testing.expectEqual(null, progressPercent(1, 0));
}

test "formatProgressLine renders percent only" {
    var buf: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "0%",
        formatProgressLine(&buf, 0),
    );
    try std.testing.expectEqualStrings(
        "50%",
        formatProgressLine(&buf, 50),
    );
    try std.testing.expectEqualStrings(
        "100%",
        formatProgressLine(&buf, 100),
    );
}

test "formatProgressStatusLine renders plain status for unknown download length" {
    var buf: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "upgrading...",
        formatProgressStatusLine(&buf, .{
            .phase = .downloading_unknown,
            .downloaded = 1,
            .total = 0,
        }, "0.3.39", null).?,
    );
}

test "formatProgressStatusLine keeps checking silent" {
    var buf: [128]u8 = undefined;

    try std.testing.expect(formatProgressStatusLine(&buf, .{
        .phase = .checking,
        .downloaded = 0,
        .total = 0,
    }, "0.3.39", null) == null);
}

test "formatProgressStatusLine renders found update before download starts" {
    var buf: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "fx 0.3.39 -> 0.3.40",
        formatProgressStatusLine(&buf, .{
            .phase = .found,
            .downloaded = 0,
            .total = 0,
        }, "0.3.39", "v0.3.40").?,
    );
}

test "progress target is read only after the publishing phase snapshot" {
    const alloc = std.testing.allocator;
    var target = try update_target.Target.initStable(alloc, "v0.3.40");
    defer target.deinit(alloc);
    const worker_result = WorkerResult{ .target_owned = target };
    var label_buf: [64]u8 = undefined;

    try std.testing.expect(target_label_after_progress_snapshot(.{
        .phase = .checking,
        .downloaded = 0,
        .total = 0,
    }, &worker_result, &label_buf) == null);
    try std.testing.expectEqualStrings(
        "0.3.40",
        target_label_after_progress_snapshot(.{
            .phase = .found,
            .downloaded = 0,
            .total = 0,
        }, &worker_result, &label_buf).?,
    );
}

test "formatProgressStatusLine renders percent only with known progress" {
    var buf: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "12%",
        formatProgressStatusLine(&buf, .{
            .phase = .downloading_known,
            .downloaded = 12,
            .total = 100,
        }, "0.3.39", null).?,
    );
    try std.testing.expectEqualStrings(
        "50%",
        formatProgressStatusLine(&buf, .{
            .phase = .downloading_known,
            .downloaded = 50,
            .total = 100,
        }, "0.3.39", null).?,
    );
    try std.testing.expectEqualStrings(
        "upgrading...",
        formatProgressStatusLine(&buf, .{
            .phase = .downloading_unknown,
            .downloaded = 1,
            .total = 0,
        }, "0.3.39", null).?,
    );
    try std.testing.expectEqualStrings(
        "100%",
        formatProgressStatusLine(&buf, .{
            .phase = .finishing,
            .downloaded = 100,
            .total = 100,
        }, "0.3.39", null).?,
    );
    try std.testing.expectEqualStrings(
        "upgrading...",
        formatProgressStatusLine(&buf, .{
            .phase = .finishing,
            .downloaded = 100,
            .total = 0,
        }, "0.3.39", null).?,
    );
}

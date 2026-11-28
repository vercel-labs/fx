//! Budget gate for the `grep_files` content scan.
//!
//! Measures `grep_search.collectDirectoryMatches` against the floor: the native
//! listing of the same tree plus one read of every file, with the same threads.
//! The scan must stay within 1.6 times that floor.
//!
//!     zig build run-bench-grep -Doptimize=ReleaseSafe -- 20000 5

const std = @import("std");
const benchmark_exports = @import("benchmark_exports");

const Allocator = std.mem.Allocator;

const default_file_count: usize = 20_000;
const default_rounds: usize = 5;
const max_scan_to_listing_and_read_ratio: f64 = 1.6;
const expected_match_count: usize = 1;
const needle = "UNIQUE_NEEDLE_7f3a";
const needle_file_text = "UNIQUE_NEEDLE_7f3a here\n";
const files_per_folder: usize = 100;
const folders_per_package: usize = 10;
const lines_per_file: usize = 30;
const filler_line = "total_value = compute_total(item_list, scale_factor) + offset\n";
const batch_files: usize = 16;
const max_workers: usize = 8;
const read_buf_bytes: usize = 64 * 1024;
const ns_per_ms: f64 = 1_000_000.0;
const usage_text = "usage: grep-bench [file_count] [rounds]\n";

const file_body = makeFileBody();

fn makeFileBody() [lines_per_file * filler_line.len]u8 {
    var body: [lines_per_file * filler_line.len]u8 = undefined;
    for (0..lines_per_file) |line_index| {
        @memcpy(body[line_index * filler_line.len ..][0..filler_line.len], filler_line);
    }
    return body;
}

const Config = struct {
    file_count: usize,
    rounds: usize,
};

fn parseConfig(args: []const [:0]const u8) ?Config {
    if (args.len > 3) return null;
    var config: Config = .{ .file_count = default_file_count, .rounds = default_rounds };
    if (args.len >= 2) config.file_count = std.fmt.parseInt(usize, args[1], 10) catch return null;
    if (args.len == 3) config.rounds = std.fmt.parseInt(usize, args[2], 10) catch return null;
    if (config.file_count == 0 or config.rounds == 0) return null;
    return config;
}

const FloorRun = struct {
    io: std.Io,
    files: []const []const u8,
    next_batch: std.atomic.Value(usize) = .init(0),
    bytes_read: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn work(self: *FloorRun) void {
        var read_buf: [read_buf_bytes]u8 = undefined;
        while (true) {
            const batch = self.next_batch.fetchAdd(1, .monotonic);
            const first = batch * batch_files;
            if (first >= self.files.len) return;
            const last = @min(first + batch_files, self.files.len);
            for (self.files[first..last]) |path| {
                const bytes = readWholeFile(self.io, path, &read_buf) catch {
                    self.failed.store(true, .release);
                    return;
                };
                _ = self.bytes_read.fetchAdd(bytes, .monotonic);
            }
        }
    }
};

fn readWholeFile(io: std.Io, path: []const u8, buf: []u8) !u64 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var total: u64 = 0;
    var chunks = [_][]u8{buf};
    while (true) {
        const count = file.readStreaming(io, &chunks) catch |err| switch (err) {
            error.EndOfStream => return total,
            else => return err,
        };
        total += count;
    }
}

fn runFloor(run: *FloorRun, thread_count: usize) !void {
    var threads: [max_workers]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    while (spawned + 1 < thread_count) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, FloorRun.work, .{run});
    }
    run.work();
}

const FloorSample = struct {
    elapsed_ns: u64,
    bytes: u64,
};

fn timeFloor(io: std.Io, files: []const []const u8, thread_count: usize) !FloorSample {
    var run: FloorRun = .{ .io = io, .files = files };
    const started = nowNs(io);
    try runFloor(&run, thread_count);
    const elapsed_ns: u64 = @intCast(nowNs(io) - started);
    if (run.failed.load(.acquire)) return error.FloorReadFailed;
    const bytes = run.bytes_read.load(.monotonic);
    if (bytes == 0) return error.FloorReadNothing;
    return .{ .elapsed_ns = elapsed_ns, .bytes = bytes };
}

const ListingSample = struct {
    elapsed_ns: u64,
    files: usize,
};

fn timeListing(io: std.Io, root: []const u8) !ListingSample {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const started = nowNs(io);
    // The options grep_files uses (grep_search.listCandidates).
    const listing = try benchmark_exports.tool_files.list(std.heap.c_allocator, arena.allocator(), root, root, .{ .include_hidden_in_repository = true });
    const elapsed_ns: u64 = @intCast(nowNs(io) - started);
    return .{ .elapsed_ns = elapsed_ns, .files = listing.files.len };
}

const ScanSample = struct {
    elapsed_ns: u64,
    matches: usize,
};

fn timeScan(io: std.Io, root: []const u8) !ScanSample {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const started = nowNs(io);
    // The tool runtime's scratch allocator (tool_dispatch.zig DispatchContext).
    const result = try benchmark_exports.grep_search.collectDirectoryMatches(std.heap.c_allocator, arena.allocator(), root, root, needle, false, null);
    const elapsed_ns: u64 = @intCast(nowNs(io) - started);
    return .{ .elapsed_ns = elapsed_ns, .matches = result.matches.len };
}

fn nowNs(io: std.Io) i128 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

fn scanThreadCount() usize {
    return @max(1, @min(max_workers, std.Thread.getCpuCount() catch 1));
}

fn tempRootPath(init: std.process.Init) ![]u8 {
    const temp_base = init.environ_map.get("TMPDIR") orelse "/tmp";
    const name = try init.gpa.print("fx-grep-bench-{d}", .{std.c.getpid()});
    defer init.gpa.free(name);
    return std.Io.Dir.path.join(init.gpa, &.{ temp_base, name });
}

fn removeTree(io: std.Io, root: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, root) catch |err| {
        std.debug.print("warning: could not remove {s}: {s}\n", .{ root, @errorName(err) });
    };
}

/// Writes the tree and returns the absolute path of every file, the needle file last.
fn writeTree(io: std.Io, arena: Allocator, root: []const u8, file_count: usize) ![]const []const u8 {
    const cwd = std.Io.Dir.cwd();
    const files_per_package = files_per_folder * folders_per_package;
    const paths = try arena.alloc([]const u8, file_count + 1);
    for (paths[0..file_count], 0..) |*path, index| {
        const package = index / files_per_package;
        const folder = (index / files_per_folder) % folders_per_package;
        const file = index % files_per_folder;
        const folder_path = try arena.print("{s}/pkg_{d:0>2}/mod_{d}", .{ root, package, folder });
        if (file == 0) try cwd.createDirPath(io, folder_path);
        const file_path = try arena.print("{s}/file_{d:0>3}.py", .{ folder_path, file });
        try cwd.writeFile(io, .{ .sub_path = file_path, .data = &file_body });
        path.* = file_path;
    }
    const needle_path = try arena.print("{s}/pkg_00/needle.py", .{root});
    try cwd.writeFile(io, .{ .sub_path = needle_path, .data = needle_file_text });
    paths[file_count] = needle_path;
    return paths;
}

fn lessThanU64(_: void, left: u64, right: u64) bool {
    return left < right;
}

fn median(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, lessThanU64);
    return samples[samples.len / 2];
}

const Report = struct {
    file_count: usize,
    thread_count: usize,
    listing_median_ns: u64,
    floor_median_ns: u64,
    scan_median_ns: u64,

    fn ratio(self: Report) f64 {
        const listing_and_read_ns = self.listing_median_ns + self.floor_median_ns;
        return @as(f64, @floatFromInt(self.scan_median_ns)) / @as(f64, @floatFromInt(listing_and_read_ns));
    }

    fn passed(self: Report) bool {
        return self.ratio() <= max_scan_to_listing_and_read_ratio;
    }
};

fn measure(init: std.process.Init, out: *std.Io.Writer, config: Config) !Report {
    const gpa = init.gpa;
    const io = init.io;
    const root = try tempRootPath(init);
    defer gpa.free(root);
    removeTree(io, root);
    defer removeTree(io, root);

    var path_arena = std.heap.ArenaAllocator.init(gpa);
    defer path_arena.deinit();
    const files = try writeTree(io, path_arena.allocator(), root, config.file_count);

    const thread_count = scanThreadCount();
    const listing_samples = try gpa.alloc(u64, config.rounds);
    defer gpa.free(listing_samples);
    const floor_samples = try gpa.alloc(u64, config.rounds);
    defer gpa.free(floor_samples);
    const scan_samples = try gpa.alloc(u64, config.rounds);
    defer gpa.free(scan_samples);

    for (0..config.rounds + 1) |round| {
        const listing = try timeListing(io, root);
        if (listing.files != files.len) {
            try out.print("listing found {d} files, expected {d}\n", .{ listing.files, files.len });
            try out.flush();
            return error.UnexpectedListingCount;
        }
        const floor = try timeFloor(io, files, thread_count);
        const scan = try timeScan(io, root);
        if (scan.matches != expected_match_count) {
            try out.print("scan found {d} matches, expected {d}\n", .{ scan.matches, expected_match_count });
            try out.flush();
            return error.UnexpectedMatchCount;
        }
        if (round == 0) continue;
        listing_samples[round - 1] = listing.elapsed_ns;
        floor_samples[round - 1] = floor.elapsed_ns;
        scan_samples[round - 1] = scan.elapsed_ns;
    }

    return .{
        .file_count = files.len,
        .thread_count = thread_count,
        .listing_median_ns = median(listing_samples),
        .floor_median_ns = median(floor_samples),
        .scan_median_ns = median(scan_samples),
    };
}

fn printReport(out: *std.Io.Writer, report: Report) !void {
    try out.print("=== grep_files scan benchmark ===\n", .{});
    try out.print("files:                     {d}\n", .{report.file_count});
    try out.print("threads:                   {d}\n", .{report.thread_count});
    try out.print("listing median:            {d:.2} ms\n", .{nsToMs(report.listing_median_ns)});
    try out.print("read floor median:         {d:.2} ms\n", .{nsToMs(report.floor_median_ns)});
    try out.print("scan median:               {d:.2} ms\n", .{nsToMs(report.scan_median_ns)});
    try out.print("ratio scan/(listing+read): {d:.2}\n", .{report.ratio()});
    try out.print("budget:                    <= {d:.2}\n", .{max_scan_to_listing_and_read_ratio});
    try out.print("{s}\n", .{if (report.passed()) "PASS" else "FAIL"});
    try out.flush();
}

fn nsToMs(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / ns_per_ms;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const config = parseConfig(args) orelse {
        std.debug.print("{s}", .{usage_text});
        std.process.exit(2);
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    const report = try measure(init, out, config);
    try printReport(out, report);
    if (!report.passed()) return error.ScanBudgetExceeded;
}

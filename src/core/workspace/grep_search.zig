const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const glob_pattern = @import("glob_pattern.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("pathing.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_files = @import("tool_files.zig");

const Allocator = std.mem.Allocator;

/// Maximum number of matches rendered to model-visible output.
pub const output_cap: usize = 200;

/// Maximum number of matching lines collected before grep stops scanning.
pub const collection_cap: usize = 2000;

const file_byte_cap: usize = 50 * 1024 * 4;

/// Filesystem match collected by grep search.
pub const Match = struct {
    absolute_path: []const u8,
    line_number: usize,
    line: []const u8,
};

/// Reason a grep collection stopped before exhausting the search root.
pub const TruncatedReason = enum {
    collection_cap,
};

/// Owned-in-arena result of a grep search collection pass.
pub const Result = struct {
    matches: []const Match,
    truncated_reason: ?TruncatedReason = null,
    candidate_count: usize = 0,
    candidate_cap: usize = tool_files.default_candidate_cap,
    candidate_incomplete: bool = false,
    skipped_overlong: usize = 0,
};

/// Owned-in-arena summary of a grep search count pass.
pub const CountResult = struct {
    matching_lines: usize = 0,
    matching_files: usize = 0,
    candidate_count: usize = 0,
    candidate_cap: usize = tool_files.default_candidate_cap,
    candidate_incomplete: bool = false,
    skipped_overlong: usize = 0,
};

/// Collects literal line matches below a directory root. Returned slices are
/// owned by `arena`, which only the calling thread uses. `scratch` must be
/// thread-safe; it backs the listing and the content scan and is released
/// before return, so retained memory grows with matches, not scanned bytes.
pub fn collectDirectoryMatches(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
) !Result {
    return collectDirectoryMatchesWithIgnored(scratch, arena, workspace_root, absolute_root, pattern, case_insensitive, tool_files.default_skipped_names, include);
}

pub fn collectDirectoryMatchesWithIgnored(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
) !Result {
    return collectDirectoryMatchesWithOptions(scratch, arena, workspace_root, absolute_root, pattern, case_insensitive, ignored_names, include, .{});
}

pub fn countDirectoryMatchesWithIgnored(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
) !CountResult {
    return countDirectoryMatchesWithOptions(scratch, arena, workspace_root, absolute_root, pattern, case_insensitive, ignored_names, include, .{});
}

fn collectDirectoryMatchesWithOptions(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
    list_options: tool_files.Options,
) !Result {
    const listing = try listCandidates(scratch, arena, workspace_root, absolute_root, ignored_names, list_options);
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(arena);
    const truncated_reason = try scanCandidateList(scratch, arena, workspace_root, absolute_root, listing.files, pattern, case_insensitive, include, &matches);
    return finishMatches(arena, &matches, truncated_reason, .fromListing(listing));
}

fn countDirectoryMatchesWithOptions(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
    list_options: tool_files.Options,
) !CountResult {
    const listing = try listCandidates(scratch, arena, workspace_root, absolute_root, ignored_names, list_options);
    var count_result: CountResult = .{ .candidate_cap = listing.candidate_cap };
    try countCandidateList(scratch, workspace_root, absolute_root, listing.files, pattern, case_insensitive, include, &count_result);
    return finishCount(count_result, .fromListing(listing));
}

fn listCandidates(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    ignored_names: []const []const u8,
    list_options: tool_files.Options,
) !tool_files.Listing {
    var options = list_options;
    options.skipped_names = ignored_names;
    options.include_hidden_in_repository = true;
    return tool_files.list(scratch, arena, workspace_root, absolute_root, options);
}

/// Collects literal line matches from a single regular-file root.
pub fn collectRegularFileRoot(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
) !Result {
    _ = workspace_root;
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(arena);

    if (include) |include_pattern| {
        if (!include_pattern.matchesBasename(std.fs.path.basename(absolute_path))) {
            return finishMatches(arena, &matches, null, .{
                .cap = tool_files.default_candidate_cap,
            });
        }
    }

    const truncated_reason = try scanFile(arena, absolute_path, pattern, case_insensitive, &matches);

    return finishMatches(arena, &matches, truncated_reason, .{
        .count = 1,
        .cap = tool_files.default_candidate_cap,
    });
}

/// Counts literal line matches from a single regular-file root.
pub fn countRegularFileRoot(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
) !CountResult {
    _ = workspace_root;
    if (include) |include_pattern| {
        if (!include_pattern.matchesBasename(std.fs.path.basename(absolute_path))) {
            return finishCount(.{}, .{ .cap = tool_files.default_candidate_cap });
        }
    }

    const file_count = try countFile(arena, absolute_path, pattern, case_insensitive);
    return finishCount(.{
        .matching_lines = file_count.matching_lines,
        .matching_files = if (file_count.matching_lines > 0) 1 else 0,
    }, .{
        .count = 1,
        .cap = tool_files.default_candidate_cap,
    });
}

const CandidateStats = struct {
    count: usize = 0,
    cap: usize = tool_files.default_candidate_cap,
    incomplete: bool = false,
    skipped_overlong: usize = 0,

    fn fromListing(listing: tool_files.Listing) CandidateStats {
        return .{
            .count = listing.files.len,
            .cap = listing.candidate_cap,
            .incomplete = listing.incomplete,
            .skipped_overlong = listing.skipped_overlong,
        };
    }
};

fn finishMatches(arena: Allocator, matches: *std.ArrayList(Match), truncated_reason: ?TruncatedReason, stats: CandidateStats) !Result {
    return .{
        .matches = try matches.toOwnedSlice(arena),
        .truncated_reason = truncated_reason,
        .candidate_count = stats.count,
        .candidate_cap = stats.cap,
        .candidate_incomplete = stats.incomplete,
        .skipped_overlong = stats.skipped_overlong,
    };
}

fn finishCount(result: CountResult, stats: CandidateStats) CountResult {
    var out = result;
    out.candidate_count = stats.count;
    out.candidate_cap = stats.cap;
    out.candidate_incomplete = stats.incomplete;
    out.skipped_overlong += stats.skipped_overlong;
    return out;
}

const CandidateFile = struct {
    display_path: []const u8,
    read_path: []const u8,
};

fn candidateKind(absolute_path: []const u8) !std.Io.File.Kind {
    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute_path, .{ .follow_symlinks = false });
    return stat.kind;
}

fn resolveCandidateFile(
    arena: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    candidate: []const u8,
    absolute_match_buf: []u8,
) !?CandidateFile {
    const absolute_match = joinAbsolutePathScratch(absolute_match_buf, provider_root, candidate) catch |err| {
        debug_trace.logf("core", "grep_files scan skipped root={s} path={s} err={s}", .{ provider_root, candidate, @errorName(err) });
        return null;
    };
    const entry_kind = candidateKind(absolute_match) catch |err| {
        debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ absolute_match, @errorName(err) });
        return null;
    };
    if (entry_kind != .file and entry_kind != .sym_link) return null;

    const read_path = resolveDirectoryEntryTarget(arena, workspace_root, absolute_match, entry_kind) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ absolute_match, @errorName(err) });
        return null;
    } orelse return null;

    return .{
        .display_path = absolute_match,
        .read_path = read_path,
    };
}

/// Files per unit of parallel work. Workers take batches in candidate order.
const batch_files: usize = 16;
/// Fewer selected files than this are scanned on the calling thread.
const parallel_min_files: usize = 64;
const max_scan_workers: usize = 8;

const ScanMode = enum { matches, count };

/// One selected candidate's outcome, written only by the worker that owns its
/// batch and read only after every worker has joined.
const FileOutcome = struct {
    matches: []const Match = &.{},
    matching_lines: usize = 0,
};

/// Shared state of one parallel content scan. Merging in candidate order makes
/// the output identical to a single-threaded scan, including where the
/// collection cap truncates it.
const ParallelScan = struct {
    /// Thread-safe and temporary: candidate resolution and per-file matches.
    work: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    files: []const []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    mode: ScanMode,
    outcomes: []FileOutcome,
    next_batch: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    /// Guarded by `mutex`: which batches are done, how many leading batches
    /// are done, and how many matches those leading batches hold.
    batch_done: []bool,
    done_prefix: usize = 0,
    prefix_matches: usize = 0,
    out_of_memory: bool = false,

    fn run(self: *ParallelScan) void {
        while (!self.stop.load(.acquire)) {
            const batch = self.next_batch.fetchAdd(1, .monotonic);
            const first = batch * batch_files;
            if (first >= self.files.len) return;
            const last = @min(first + batch_files, self.files.len);
            for (first..last) |index| {
                _ = self.scanOne(index) catch {
                    self.mutex.lockUncancelable(io_mod.getIo());
                    self.out_of_memory = true;
                    self.mutex.unlock(io_mod.getIo());
                    self.stop.store(true, .release);
                    return;
                };
            }
            self.finishBatch(batch);
        }
    }

    fn scanOne(self: *ParallelScan, index: usize) Allocator.Error!void {
        var absolute_match_buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate_file = try resolveCandidateFile(self.work, self.workspace_root, self.provider_root, self.files[index], absolute_match_buf[0..]) orelse return;
        switch (self.mode) {
            .matches => {
                var local: std.ArrayList(Match) = .empty;
                _ = scanFileAt(self.work, candidate_file.display_path, candidate_file.read_path, self.pattern, self.case_insensitive, &local) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ candidate_file.display_path, @errorName(err) });
                    return;
                };
                self.outcomes[index] = .{ .matches = local.items };
            },
            .count => {
                const file_count = countFileAt(candidate_file.display_path, candidate_file.read_path, self.pattern, self.case_insensitive) catch |err| {
                    debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ candidate_file.display_path, @errorName(err) });
                    return;
                };
                self.outcomes[index] = .{ .matching_lines = file_count.matching_lines };
            },
        }
    }

    /// Once the leading done batches hold the collection cap, no later file
    /// can change the merged result, so the remaining work stops.
    fn finishBatch(self: *ParallelScan, batch: usize) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.batch_done[batch] = true;
        while (self.done_prefix < self.batch_done.len and self.batch_done[self.done_prefix]) : (self.done_prefix += 1) {
            const first = self.done_prefix * batch_files;
            for (self.outcomes[first..@min(first + batch_files, self.outcomes.len)]) |outcome| self.prefix_matches += outcome.matches.len;
        }
        if (self.mode == .matches and self.prefix_matches >= collection_cap) self.stop.store(true, .release);
    }
};

fn workerCount(files: usize) usize {
    if (builtin.single_threaded or files < parallel_min_files) return 1;
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(@min(max_scan_workers, cpus), std.math.divCeil(usize, files, batch_files) catch 1));
}

/// Scans `files` with up to `max_scan_workers` threads, the calling thread
/// included. A helper that cannot start leaves its share to the others.
fn runParallelScan(scan: *ParallelScan) Allocator.Error!void {
    const helpers = workerCount(scan.files.len) - 1;
    var threads: [max_scan_workers]std.Thread = undefined;
    var started: usize = 0;
    if (!builtin.single_threaded) {
        while (started < helpers) : (started += 1) {
            threads[started] = std.Thread.spawn(.{}, ParallelScan.run, .{scan}) catch break;
        }
    }
    scan.run();
    for (threads[0..started]) |thread| thread.join();
    if (scan.out_of_memory) return error.OutOfMemory;
}

fn selectCandidates(work: Allocator, candidates: []const []const u8, include: ?glob_pattern.Pattern) ![]const []const u8 {
    const include_pattern = include orelse return candidates;
    var selected: std.ArrayList([]const u8) = .empty;
    for (candidates) |candidate| {
        if (include_pattern.matchesPath(candidate)) try selected.append(work, candidate);
    }
    return selected.toOwnedSlice(work);
}

fn initParallelScan(
    work: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    files: []const []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    mode: ScanMode,
) !ParallelScan {
    const outcomes = try work.alloc(FileOutcome, files.len);
    @memset(outcomes, .{});
    const batch_done = try work.alloc(bool, std.math.divCeil(usize, files.len, batch_files) catch 0);
    @memset(batch_done, false);
    return .{
        .work = work,
        .workspace_root = workspace_root,
        .provider_root = provider_root,
        .files = files,
        .pattern = pattern,
        .case_insensitive = case_insensitive,
        .mode = mode,
        .outcomes = outcomes,
        .batch_done = batch_done,
    };
}

fn scanCandidateList(
    scratch: Allocator,
    arena: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    candidates: []const []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
    matches: *std.ArrayList(Match),
) !?TruncatedReason {
    var work_state = std.heap.ArenaAllocator.init(scratch);
    defer work_state.deinit();
    const work = work_state.allocator();
    const files = try selectCandidates(work, candidates, include);
    var scan = try initParallelScan(work, workspace_root, provider_root, files, pattern, case_insensitive, .matches);
    try runParallelScan(&scan);
    for (scan.outcomes) |outcome| {
        var retained_path: ?[]const u8 = null;
        for (outcome.matches) |match| {
            if (matches.items.len >= collection_cap) return .collection_cap;
            try appendMatch(arena, matches, &retained_path, match.absolute_path, match.line_number, match.line);
            if (matches.items.len >= collection_cap) return .collection_cap;
        }
    }
    return null;
}

fn countCandidateList(
    scratch: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    candidates: []const []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
    count_result: *CountResult,
) !void {
    var work_state = std.heap.ArenaAllocator.init(scratch);
    defer work_state.deinit();
    const work = work_state.allocator();
    const files = try selectCandidates(work, candidates, include);
    var scan = try initParallelScan(work, workspace_root, provider_root, files, pattern, case_insensitive, .count);
    try runParallelScan(&scan);
    for (scan.outcomes) |outcome| {
        if (outcome.matching_lines == 0) continue;
        count_result.matching_files += 1;
        count_result.matching_lines += outcome.matching_lines;
    }
}

const FileCount = struct {
    matching_lines: usize = 0,
};

fn joinAbsolutePathScratch(buffer: []u8, absolute_root: []const u8, entry_path: []const u8) ![]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    return std.fs.path.join(fba.allocator(), &.{ absolute_root, entry_path }) catch |err| switch (err) {
        error.OutOfMemory => error.NameTooLong,
    };
}

fn resolveDirectoryEntryTarget(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8, entry_kind: std.Io.File.Kind) !?[]const u8 {
    const resolved = try io_mod.realpathAlloc(arena, absolute_path);
    if (entry_kind == .sym_link and !pathing.pathInside(workspace_root, resolved)) {
        debug_trace.logf("core", "grep_files skipped external symlink target path={s} target={s}", .{ absolute_path, resolved });
        return null;
    }
    return resolved;
}

fn scanFile(
    arena: Allocator,
    absolute_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    matches: *std.ArrayList(Match),
) !?TruncatedReason {
    return scanFileAt(arena, absolute_path, absolute_path, pattern, case_insensitive, matches);
}

fn countFile(
    arena: Allocator,
    absolute_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
) !FileCount {
    _ = arena;
    return countFileAt(absolute_path, absolute_path, pattern, case_insensitive);
}

fn countFileAt(
    display_path: []const u8,
    read_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
) !FileCount {
    var content_buf: [file_byte_cap + 1]u8 = undefined;
    const content = (try readModelSafeContent(display_path, read_path, &content_buf)) orelse return .{};

    var result: FileCount = .{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!lineMatchesPattern(line, pattern, case_insensitive)) continue;
        result.matching_lines += 1;
    }
    return result;
}

fn scanFileAt(
    arena: Allocator,
    display_path: []const u8,
    read_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    matches: *std.ArrayList(Match),
) !?TruncatedReason {
    var content_buf: [file_byte_cap + 1]u8 = undefined;
    const content = (try readModelSafeContent(display_path, read_path, &content_buf)) orelse return null;

    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var retained_path: ?[]const u8 = null;
    while (lines.next()) |line| : (line_number += 1) {
        if (!lineMatchesPattern(line, pattern, case_insensitive)) continue;
        if (matches.items.len >= collection_cap) return .collection_cap;
        try appendMatch(arena, matches, &retained_path, display_path, line_number, line);
        if (matches.items.len >= collection_cap) return .collection_cap;
    }
    return null;
}

fn readModelSafeContent(
    display_path: []const u8,
    read_path: []const u8,
    content_buf: *[file_byte_cap + 1]u8,
) !?[]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), read_path, .{});
    defer file.close(io_mod.getIo());

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &read_buf);
    const content_len = reader.interface.readSliceShort(content_buf) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
    };
    const content = content_buf[0..content_len];
    if (content.len > file_byte_cap) {
        logOversizedFile(display_path);
        return null;
    }
    if (!text_utils.isModelSafeText(content)) {
        const reason = modelUnsafeReason(content);
        debug_trace.logf("core", "grep_files skipped non-text file path={s} reason={s}", .{ display_path, reason });
        return null;
    }
    return content;
}

fn appendMatch(
    arena: Allocator,
    matches: *std.ArrayList(Match),
    retained_path: *?[]const u8,
    absolute_path: []const u8,
    line_number: usize,
    line: []const u8,
) !void {
    try matches.ensureUnusedCapacity(arena, 1);
    const path = retained_path.* orelse path: {
        const owned_path = try arena.dupe(u8, absolute_path);
        retained_path.* = owned_path;
        break :path owned_path;
    };
    const owned_line = try arena.dupe(u8, line);
    matches.appendAssumeCapacity(.{
        .absolute_path = path,
        .line_number = line_number,
        .line = owned_line,
    });
}

fn logOversizedFile(absolute_path: []const u8) void {
    debug_trace.logf("core", "grep_files skipped oversized file path={s}", .{absolute_path});
}

fn modelUnsafeReason(content: []const u8) []const u8 {
    if (std.mem.findScalar(u8, content, 0) != null) return "contains_nul";
    if (!std.unicode.utf8ValidateSlice(content)) return "invalid_utf8";
    return "not_model_safe";
}

fn lineMatchesPattern(line: []const u8, pattern: []const u8, case_insensitive: bool) bool {
    return if (case_insensitive)
        text_utils.containsIgnoreCase(line, pattern)
    else
        std.mem.find(u8, line, pattern) != null;
}

fn writeTempFile(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) ![]u8 {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn createBrokenSymlinkOrSkip(tmp: *std.testing.TmpDir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) return error.SkipZigTest;
        return err;
    };
}

fn createSymlinkOrSkip(tmp: *std.testing.TmpDir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) return error.SkipZigTest;
        return err;
    };
}

fn contentWithPrefix(alloc: Allocator, len: usize, prefix: []const u8) ![]u8 {
    const content = try alloc.alloc(u8, len);
    @memset(content, 'x');
    const prefix_len = @min(prefix.len, content.len);
    @memcpy(content[0..prefix_len], prefix[0..prefix_len]);
    return content;
}

fn readFileToEndForTest(alloc: Allocator, absolute_path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, absolute_path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}

fn readTrace(alloc: Allocator, trace_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer file.close(io_mod.getIo());
    var read_buf: [1024]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    return reader.interface.allocRemaining(alloc, std.Io.Limit.limited(4096));
}

test "grep search preserves explicitly requested ignored directory roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const ignored = try writeTempFile(alloc, &tmp, "node_modules/pkg/ignored.txt", "needle ignored\n");
    defer alloc.free(ignored);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, try io_mod.dirRealpathAlloc(arena_state.allocator(), tmp.dir, "node_modules/pkg"), "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "node_modules/pkg/ignored.txt"));
    try std.testing.expectEqualStrings("needle ignored", result.matches[0].line);
}

test "grep search preserves explicitly requested ignored file roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const ignored = try writeTempFile(alloc, &tmp, "node_modules/pkg/ignored.txt", "needle ignored\n");
    defer alloc.free(ignored);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, ignored, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "node_modules/pkg/ignored.txt"));
    try std.testing.expectEqualStrings("needle ignored", result.matches[0].line);
}

test "grep search does not ignore workspace because ignored name is outside workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(alloc, &tmp, "build/workspace/src/file.txt", "needle kept\n");
    defer alloc.free(path);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "build/workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "src/file.txt"));
}

test "grep search falls back to Zig scanner outside git repositories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const file_path = try writeTempFile(alloc, &tmp, "src/main.zig", "needle fallback\n");
    defer alloc.free(file_path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "src/main.zig"));
    try std.testing.expectEqualStrings("needle fallback", result.matches[0].line);
}

test "grep search scans untracked files after git grep tracked backend" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    try runGitForTest(alloc, workspace, &.{"init"});
    const tracked = try writeTempFile(alloc, &tmp, "tracked.txt", "no match\n");
    defer alloc.free(tracked);
    try runGitForTest(alloc, workspace, &.{ "add", "tracked.txt" });
    const untracked = try writeTempFile(alloc, &tmp, "untracked.txt", "needle untracked\n");
    defer alloc.free(untracked);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "untracked.txt"));
    try std.testing.expectEqualStrings("needle untracked", result.matches[0].line);
}

test "grep search git grep backend skips files with unsafe bytes outside matched line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    try runGitForTest(alloc, workspace, &.{"init"});
    const unsafe = try writeTempFile(alloc, &tmp, "unsafe.txt", "needle safe\ninvalid \xff bytes\n");
    defer alloc.free(unsafe);
    try runGitForTest(alloc, workspace, &.{ "add", "unsafe.txt" });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
}

test "grep search logs skipped non-model-safe files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const binary = try writeTempFile(alloc, &tmp, "binary.txt", "needle\x00binary\n");
    defer alloc.free(binary);
    const trace_path = try std.fs.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, binary, "needle", false, null);
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files skipped non-text file path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "binary.txt") != null);
    try std.testing.expect(std.mem.find(u8, trace, "reason=contains_nul") != null);
}

test "grep search logs skipped per-file scan errors during directory traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const good = try writeTempFile(alloc, &tmp, "good.txt", "needle good\n");
    defer alloc.free(good);
    try createBrokenSymlinkOrSkip(&tmp, "missing-target.txt", "broken.txt");
    const trace_path = try std.fs.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var pattern = try glob_pattern.Pattern.compile(alloc, "*.txt");
    defer pattern.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, pattern);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files scan skipped path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "broken.txt") != null);
}

test "grep search directory traversal skips external symlink targets with trace" {
    const alloc = std.testing.allocator;
    var workspace_tmp = std.testing.tmpDir(.{});
    defer workspace_tmp.cleanup();
    var external_tmp = std.testing.tmpDir(.{});
    defer external_tmp.cleanup();

    const workspace = try workspaceRoot(alloc, workspace_tmp);
    defer alloc.free(workspace);
    const internal_target = try writeTempFile(alloc, &workspace_tmp, "target/internal.txt", "needle internal\n");
    defer alloc.free(internal_target);
    const external_target = try writeTempFile(alloc, &external_tmp, "outside.txt", "needle external\n");
    defer alloc.free(external_target);
    try workspace_tmp.dir.createDirPath(io_mod.getIo(), "links");
    try createSymlinkOrSkip(&workspace_tmp, "../target/internal.txt", "links/internal.txt");
    try createSymlinkOrSkip(&workspace_tmp, external_target, "links/external.txt");

    const trace_path = try std.fs.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const links_root = try io_mod.dirRealpathAlloc(arena_state.allocator(), workspace_tmp.dir, "links");
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, links_root, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "links/internal.txt"));
    try std.testing.expectEqualStrings("needle internal", result.matches[0].line);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files skipped external symlink target path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "links/external.txt") != null);
    try std.testing.expect(std.mem.find(u8, trace, external_target) != null);
}

test "grep search file-byte cap uses one-byte sentinel limit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exact_content = try contentWithPrefix(alloc, file_byte_cap, "needle\n");
    defer alloc.free(exact_content);
    const exact = try writeTempFile(alloc, &tmp, "exact.txt", exact_content);
    defer alloc.free(exact);
    const over_content = try contentWithPrefix(alloc, file_byte_cap + 1, "needle\n");
    defer alloc.free(over_content);
    const over = try writeTempFile(alloc, &tmp, "over.txt", over_content);
    defer alloc.free(over);

    const exact_at_cap_limit = readFileToEndForTest(alloc, exact, file_byte_cap);
    if (exact_at_cap_limit) |bytes| {
        defer alloc.free(bytes);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.StreamTooLong, err);
    }

    const exact_read = try readFileToEndForTest(alloc, exact, file_byte_cap + 1);
    defer alloc.free(exact_read);
    try std.testing.expectEqual(file_byte_cap, exact_read.len);

    const over_read = readFileToEndForTest(alloc, over, file_byte_cap + 1);
    if (over_read) |bytes| {
        defer alloc.free(bytes);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.StreamTooLong, err);
    }
}

test "grep search scans files exactly at byte cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const content = try contentWithPrefix(alloc, file_byte_cap, "needle\n");
    defer alloc.free(content);
    const exact = try writeTempFile(alloc, &tmp, "exact.txt", content);
    defer alloc.free(exact);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, exact, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "exact.txt"));
    try std.testing.expectEqual(@as(usize, 1), result.matches[0].line_number);
    try std.testing.expectEqualStrings("needle", result.matches[0].line);
}

test "grep search retained allocations scale with matches not scanned bytes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const nonmatching_content = try contentWithPrefix(alloc, 12 * 1024, "not here\n");
    defer alloc.free(nonmatching_content);

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "large/file-{d}.txt", .{i});
        const path = try writeTempFile(alloc, &tmp, name, nonmatching_content);
        alloc.free(path);
    }
    const matching = try writeTempFile(alloc, &tmp, "large/match.txt", "needle kept\n");
    defer alloc.free(matching);

    var retained_buf: [8 * 1024]u8 = undefined;
    var retained_fba = std.heap.FixedBufferAllocator.init(&retained_buf);
    const result = try collectDirectoryMatches(std.testing.allocator, retained_fba.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "large/match.txt"));
    try std.testing.expectEqualStrings("needle kept", result.matches[0].line);
}

test "grep search logs oversized files and continues directory traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const good = try writeTempFile(alloc, &tmp, "good.txt", "needle good\n");
    defer alloc.free(good);
    const content = try contentWithPrefix(alloc, file_byte_cap + 1, "needle hidden\n");
    defer alloc.free(content);
    const large = try writeTempFile(alloc, &tmp, "large.txt", content);
    defer alloc.free(large);
    const trace_path = try std.fs.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "good.txt"));

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files skipped oversized file path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "large.txt") != null);
}

test "grep search skips oversized regular-file roots with trace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const content = try contentWithPrefix(alloc, file_byte_cap + 1, "needle hidden\n");
    defer alloc.free(content);
    const large = try writeTempFile(alloc, &tmp, "large.txt", content);
    defer alloc.free(large);
    const trace_path = try std.fs.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, large, "needle", false, null);
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files skipped oversized file path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "large.txt") != null);
}

test "grep search finds match beyond former traversal cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var i: usize = 0;
    while (i < 2050) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "many/file-{d:0>4}.txt", .{i});
        const path = try writeTempFile(alloc, &tmp, name, "not here\n");
        alloc.free(path);
    }
    const late = try writeTempFile(alloc, &tmp, "zzzz/match.txt", "needle late\n");
    defer alloc.free(late);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "zzzz/match.txt"));
}

test "grep_files path narrowing applies before candidate cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const outside = try writeTempFile(alloc, &tmp, "aaa/outside.txt", "needle outside\n");
    defer alloc.free(outside);
    const target = try writeTempFile(alloc, &tmp, "src/core/target.txt", "needle target\n");
    defer alloc.free(target);
    const narrowed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "src/core");
    defer alloc.free(narrowed_root);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatchesWithOptions(
        std.testing.allocator,
        arena_state.allocator(),
        workspace,
        narrowed_root,
        "needle",
        false,
        tool_files.default_skipped_names,
        null,
        .{ .candidate_cap = 1 },
    );

    try std.testing.expectEqual(@as(usize, 1), result.candidate_count);
    try std.testing.expect(!result.candidate_incomplete);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "src/core/target.txt"));
    try std.testing.expectEqualStrings("needle target", result.matches[0].line);
}

test "grep search collection cap saturation reports metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();
    var i: usize = 0;
    while (i < collection_cap + 1) : (i += 1) {
        try content.writer.writeAll("needle\n");
    }
    const path = try writeTempFile(alloc, &tmp, "many.txt", content.written());
    defer alloc.free(path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, path, "needle", false, null);

    try std.testing.expectEqual(collection_cap, result.matches.len);
    try std.testing.expectEqual(TruncatedReason.collection_cap, result.truncated_reason.?);
}

test "grep search collection cap takes precedence at traversal boundary" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "file-{d:0>4}.txt", .{i});
        const path = try writeTempFile(alloc, &tmp, name, "not here\n");
        alloc.free(path);
    }

    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();
    i = 0;
    while (i < collection_cap + 1) : (i += 1) {
        try content.writer.writeAll("needle\n");
    }
    const match_path = try writeTempFile(alloc, &tmp, "zzzz/many.txt", content.written());
    defer alloc.free(match_path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(collection_cap, result.matches.len);
    try std.testing.expectEqual(TruncatedReason.collection_cap, result.truncated_reason.?);
}

test "grep search does not import tool dispatch layer" {
    const alloc = std.testing.allocator;
    var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), "src/core/workspace/grep_search.zig", .{});
    defer file.close(io_mod.getIo());
    const source = try io_mod.readFileToEnd(alloc, &file, 128 * 1024);
    defer alloc.free(source);

    const forbidden = "tool_" ++ "dispatch.zig";
    try std.testing.expect(std.mem.find(u8, source, forbidden) == null);
}

fn runGitForTest(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    try argv.appendSlice(alloc, args);

    const result = std.process.run(alloc, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

test "grep search parallel scan matches single-threaded order and cap truncation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    // 1500 files of 2 matches each exceed the collection cap, so the first
    // 1000 files in sorted order must fill it exactly. Many more batches than
    // workers means a premature stop would leave files unscanned.
    const content = "needle one\nother\nneedle two\n";
    for (0..1500) |index| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "many/file-{d:0>4}.txt", .{index});
        alloc.free(try writeTempFile(alloc, &tmp, name, content));
    }

    for (0..5) |_| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);
        try std.testing.expectEqual(TruncatedReason.collection_cap, result.truncated_reason.?);
        try std.testing.expectEqual(collection_cap, result.matches.len);
        for (result.matches, 0..) |match, position| {
            var want_buf: [64]u8 = undefined;
            const want = try std.fmt.bufPrint(&want_buf, "many/file-{d:0>4}.txt", .{position / 2});
            try std.testing.expect(std.mem.endsWith(u8, match.absolute_path, want));
            try std.testing.expectEqual(2 * (position % 2) + 1, match.line_number);
        }

        const counted = try countDirectoryMatchesWithIgnored(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, tool_files.default_skipped_names, null);
        try std.testing.expectEqual(@as(usize, 3000), counted.matching_lines);
        try std.testing.expectEqual(@as(usize, 1500), counted.matching_files);
    }
}

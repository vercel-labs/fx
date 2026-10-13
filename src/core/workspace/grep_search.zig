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

/// Bytes read from a file at a time. A line up to this long is matched in
/// place; a longer one is matched piece by piece, and a match keeps only its
/// first `chunk_bytes` bytes plus one, enough for the output to mark the cut.
/// Files of any size are searched with this one buffer.
const chunk_bytes: usize = 64 * 1024;

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
    candidate_cap_reached: bool = false,
    skipped_overlong: usize = 0,
};

/// Owned-in-arena summary of a grep search count pass.
pub const CountResult = struct {
    matching_lines: usize = 0,
    matching_files: usize = 0,
    candidate_count: usize = 0,
    candidate_cap: usize = tool_files.default_candidate_cap,
    candidate_incomplete: bool = false,
    candidate_cap_reached: bool = false,
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
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(arena);

    if (!try fileRootIncluded(arena, workspace_root, absolute_path, include)) {
        return finishMatches(arena, &matches, null, .{
            .cap = tool_files.default_candidate_cap,
        });
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
    if (!try fileRootIncluded(arena, workspace_root, absolute_path, include)) {
        return finishCount(.{}, .{ .cap = tool_files.default_candidate_cap });
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

/// Whether a file named as the search root passes `include`. A pattern with
/// a slash matches the file's path relative to the workspace, as it would in
/// a search of the whole workspace; one without matches the base name.
fn fileRootIncluded(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8, include: ?glob_pattern.Pattern) Allocator.Error!bool {
    const include_pattern = include orelse return true;
    if (!include_pattern.has_path_separator) return include_pattern.matchesBasename(std.Io.Dir.path.basename(absolute_path));
    return include_pattern.matchesPath(try pathing.workspaceRelativePath(arena, workspace_root, absolute_path));
}

const CandidateStats = struct {
    count: usize = 0,
    cap: usize = tool_files.default_candidate_cap,
    incomplete: bool = false,
    cap_reached: bool = false,
    skipped_overlong: usize = 0,

    fn fromListing(listing: tool_files.Listing) CandidateStats {
        return .{
            .count = listing.files.len,
            .cap = listing.candidate_cap,
            .incomplete = listing.incomplete,
            .cap_reached = listing.cap_reached,
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
        .candidate_cap_reached = stats.cap_reached,
        .skipped_overlong = stats.skipped_overlong,
    };
}

fn finishCount(result: CountResult, stats: CandidateStats) CountResult {
    var out = result;
    out.candidate_count = stats.count;
    out.candidate_cap = stats.cap;
    out.candidate_incomplete = stats.incomplete;
    out.candidate_cap_reached = stats.cap_reached;
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
/// collection cap truncates it. Batches are handed out in candidate order, so
/// once finished batches hold the cap, no batch that has not started can
/// reach the merged result.
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
    /// Guarded by `mutex`: the matches every finished batch holds, and the
    /// first file of the earliest batch that ran out of memory.
    done_matches: usize = 0,
    out_of_memory_from: ?usize = null,

    fn run(self: *ParallelScan) void {
        while (!self.stop.load(.acquire)) {
            const batch = self.next_batch.fetchAdd(1, .monotonic);
            const first = batch * batch_files;
            if (first >= self.files.len) return;
            const last = @min(first + batch_files, self.files.len);
            for (first..last) |index| {
                _ = self.scanOne(index) catch {
                    self.mutex.lockUncancelable(io_mod.getIo());
                    self.out_of_memory_from = @min(self.out_of_memory_from orelse first, first);
                    self.mutex.unlock(io_mod.getIo());
                    self.stop.store(true, .release);
                    return;
                };
            }
            self.finishBatch(first, last);
        }
    }

    fn scanOne(self: *ParallelScan, index: usize) Allocator.Error!void {
        var absolute_match_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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
                const file_count = countFileAt(self.work, candidate_file.display_path, candidate_file.read_path, self.pattern, self.case_insensitive) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ candidate_file.display_path, @errorName(err) });
                    return;
                };
                self.outcomes[index] = .{ .matching_lines = file_count.matching_lines };
            },
        }
    }

    /// Every finished batch came before any batch not yet started, so once
    /// they hold the collection cap the remaining work stops. Matches past the
    /// cut are never buffered beyond the batches already running.
    fn finishBatch(self: *ParallelScan, first: usize, last: usize) void {
        var batch_matches: usize = 0;
        for (self.outcomes[first..last]) |outcome| batch_matches += outcome.matches.len;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.done_matches += batch_matches;
        if (self.mode == .matches and self.done_matches >= collection_cap) self.stop.store(true, .release);
    }
};

fn workerCount(files: usize) usize {
    if (builtin.single_threaded or files < parallel_min_files) return 1;
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(@min(max_scan_workers, cpus), std.math.divCeil(usize, files, batch_files) catch 1));
}

/// Scans `files` with up to `max_scan_workers` threads, the calling thread
/// included. A helper that cannot start leaves its share to the others. Running
/// out of memory is recorded in `out_of_memory_from` for the caller to judge.
fn runParallelScan(scan: *ParallelScan) void {
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
    return .{
        .work = work,
        .workspace_root = workspace_root,
        .provider_root = provider_root,
        .files = files,
        .pattern = pattern,
        .case_insensitive = case_insensitive,
        .mode = mode,
        .outcomes = outcomes,
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
    runParallelScan(&scan);
    return mergeMatches(arena, &scan, matches);
}

/// Appends the scanned matches in candidate order up to the collection cap.
/// Running out of memory fails the search only when the cut is not reached
/// before the file where it happened.
fn mergeMatches(arena: Allocator, scan: *const ParallelScan, matches: *std.ArrayList(Match)) Allocator.Error!?TruncatedReason {
    for (scan.outcomes, 0..) |outcome, index| {
        if (scan.out_of_memory_from) |from| if (index >= from) return error.OutOfMemory;
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
    runParallelScan(&scan);
    // A count needs every file.
    if (scan.out_of_memory_from != null) return error.OutOfMemory;
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
    return std.Io.Dir.path.join(fba.allocator(), &.{ absolute_root, entry_path }) catch |err| switch (err) {
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
    return countFileAt(arena, absolute_path, absolute_path, pattern, case_insensitive);
}

/// `scratch` holds the window for matching across the pieces of a line
/// longer than `chunk_bytes`, and only when such a line appears.
fn countFileAt(
    scratch: Allocator,
    display_path: []const u8,
    read_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
) !FileCount {
    var counter: struct {
        matching_lines: usize = 0,

        pub fn line(self: *@This(), number: usize, text: []const u8) Allocator.Error!bool {
            _ = number;
            _ = text;
            self.matching_lines += 1;
            return false;
        }
    } = .{};
    return switch (try scanLines(scratch, display_path, read_path, pattern, case_insensitive, &counter)) {
        .done, .stopped => .{ .matching_lines = counter.matching_lines },
        .not_text => .{},
    };
}

fn scanFileAt(
    arena: Allocator,
    display_path: []const u8,
    read_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    matches: *std.ArrayList(Match),
) !?TruncatedReason {
    var collector: struct {
        arena: Allocator,
        matches: *std.ArrayList(Match),
        display_path: []const u8,
        retained_path: ?[]const u8 = null,

        pub fn line(self: *@This(), number: usize, text: []const u8) Allocator.Error!bool {
            try appendMatch(self.arena, self.matches, &self.retained_path, self.display_path, number, text);
            return self.matches.items.len >= collection_cap;
        }
    } = .{ .arena = arena, .matches = matches, .display_path = display_path };
    const first = matches.items.len;
    return switch (try scanLines(arena, display_path, read_path, pattern, case_insensitive, &collector)) {
        .done => null,
        .stopped => .collection_cap,
        .not_text => {
            // The whole file is skipped, so drop the lines already taken from it.
            matches.shrinkRetainingCapacity(first);
            return null;
        },
    };
}

const ScanEnd = enum { done, stopped, not_text };

/// Streams the regular file at `read_path` with one `chunk_bytes` buffer,
/// whatever its size, and calls `sink.line(number, text)` for each line that
/// contains `pattern`; `sink.line` returns true to stop. Lines are split at
/// '\n' as `std.mem.splitScalar` splits a whole file, so the text after the
/// last newline is a final line, even when empty. A NUL byte or invalid UTF-8
/// anywhere ends the scan as `.not_text`.
fn scanLines(
    scratch: Allocator,
    display_path: []const u8,
    read_path: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    sink: anytype,
) !ScanEnd {
    // Only regular files are read, and never with a blocking open: opening a
    // FIFO for reading would wait for a writer that may never come.
    var file = try io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), read_path, .follow);
    defer file.close(io_mod.getIo());

    var read_buf: [chunk_bytes]u8 = undefined;
    var file_reader = file.reader(io_mod.getIo(), &read_buf);
    const reader = &file_reader.interface;
    var long: LongLine = .{};
    defer long.deinit(scratch);

    var number: usize = 1;
    while (true) {
        const line: []const u8, const last = if (reader.peekDelimiterInclusive('\n')) |with_newline|
            .{ with_newline[0 .. with_newline.len - 1], false }
        else |err| switch (err) {
            error.EndOfStream => .{ reader.buffered(), true },
            error.StreamTooLong => {
                // The line is longer than the buffer. Take what is buffered,
                // up to the last whole UTF-8 sequence, and keep reading it.
                const buffered = reader.buffered();
                const piece = buffered[0 .. buffered.len - incompleteUtf8Tail(buffered)];
                if (!isLineText(display_path, piece)) return .not_text;
                try long.add(scratch, piece, pattern, case_insensitive);
                reader.toss(piece.len);
                continue;
            },
            error.ReadFailed => return file_reader.err.?,
        };
        if (!isLineText(display_path, line)) return .not_text;
        const matched, const text = if (long.len == 0)
            .{ lineMatchesPattern(line, pattern, case_insensitive), line }
        else blk: {
            try long.add(scratch, line, pattern, case_insensitive);
            break :blk .{ long.matched, long.kept() };
        };
        if (matched and try sink.line(number, text)) return .stopped;
        if (last) return .done;
        long.reset();
        reader.toss(line.len + 1);
        number += 1;
    }
}

/// A line longer than `chunk_bytes`, matched piece by piece.
const LongLine = struct {
    /// Bytes seen so far.
    len: usize = 0,
    matched: bool = false,
    /// The first `chunk_bytes` bytes plus one, kept for a match.
    head: [chunk_bytes + 1]u8 = undefined,
    head_len: usize = 0,
    /// The last `pattern.len - 1` bytes seen, followed by room for as many
    /// from the next piece, so a match across two pieces is found.
    window: []u8 = &.{},
    carry_len: usize = 0,

    fn deinit(self: *LongLine, scratch: Allocator) void {
        scratch.free(self.window);
    }

    fn reset(self: *LongLine) void {
        self.len = 0;
        self.matched = false;
        self.head_len = 0;
        self.carry_len = 0;
    }

    fn kept(self: *const LongLine) []const u8 {
        return self.head[0..self.head_len];
    }

    fn add(self: *LongLine, scratch: Allocator, piece: []const u8, pattern: []const u8, case_insensitive: bool) Allocator.Error!void {
        const take = @min(piece.len, self.head.len - self.head_len);
        @memcpy(self.head[self.head_len..][0..take], piece[0..take]);
        self.head_len += take;
        self.len += piece.len;
        if (self.matched) return;
        if (lineMatchesPattern(piece, pattern, case_insensitive)) {
            self.matched = true;
            return;
        }
        // A pattern of one byte or less cannot span two pieces.
        if (pattern.len <= 1) return;
        const carry_cap = pattern.len - 1;
        if (self.window.len == 0) self.window = try scratch.alloc(u8, 2 * carry_cap);
        const prefix = piece[0..@min(piece.len, carry_cap)];
        @memcpy(self.window[self.carry_len..][0..prefix.len], prefix);
        if (lineMatchesPattern(self.window[0 .. self.carry_len + prefix.len], pattern, case_insensitive)) {
            self.matched = true;
            return;
        }
        // Carry the last `carry_cap` bytes of the line so far.
        if (piece.len >= carry_cap) {
            @memcpy(self.window[0..carry_cap], piece[piece.len - carry_cap ..]);
            self.carry_len = carry_cap;
        } else {
            const total = self.carry_len + piece.len;
            const keep = @min(total, carry_cap);
            @memmove(self.window[0..keep], self.window[total - keep .. total]);
            self.carry_len = keep;
        }
    }
};

/// Number of bytes at the end of `bytes` that start a UTF-8 sequence the
/// buffer cut short, at most 3.
fn incompleteUtf8Tail(bytes: []const u8) usize {
    var back: usize = 1;
    while (back <= @min(3, bytes.len)) : (back += 1) {
        const byte = bytes[bytes.len - back];
        if (byte & 0b1100_0000 == 0b1000_0000) continue;
        const needed = std.unicode.utf8ByteSequenceLength(byte) catch return 0;
        return if (needed > back) back else 0;
    }
    return 0;
}

fn isLineText(display_path: []const u8, line: []const u8) bool {
    if (text_utils.isModelSafeText(line)) return true;
    debug_trace.logf("core", "grep_files skipped non-text file path={s} reason={s}", .{ display_path, modelUnsafeReason(line) });
    return false;
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
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
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
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) return error.SkipZigTest;
        return err;
    };
}

fn createSymlinkOrSkip(tmp: *std.testing.TmpDir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
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
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "trace.log" });
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
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "trace.log" });
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

    const trace_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "trace.log" });
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

test "grep search skips a symlink to a FIFO instead of waiting for a writer" {
    const alloc = std.testing.allocator;
    var workspace_tmp = std.testing.tmpDir(.{});
    defer workspace_tmp.cleanup();
    const workspace = try workspaceRoot(alloc, workspace_tmp);
    defer alloc.free(workspace);
    const real = try writeTempFile(alloc, &workspace_tmp, "docs/real.txt", "needle real\n");
    defer alloc.free(real);
    const fifo = try std.Io.Dir.path.joinZ(alloc, &.{ workspace, "pipe" });
    defer alloc.free(fifo);
    if (mkfifo(fifo, 0o600) != 0) return error.SkipZigTest;
    try createSymlinkOrSkip(&workspace_tmp, "../pipe", "docs/trap.txt");

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    // A blocking open of the FIFO would wait here forever for a writer.
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "docs/real.txt"));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "grep search scans a file root of any size" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    // 3,000 lines of 100 bytes put the match past 290 KiB, several chunks in.
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    for (0..3000) |_| try content.appendSlice(alloc, text_utils.repeat("x", 99) ++ "\n");
    try content.appendSlice(alloc, "needle late\n");
    const large = try writeTempFile(alloc, &tmp, "large.txt", content.items);
    defer alloc.free(large);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, large, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expectEqual(@as(usize, 3001), result.matches[0].line_number);
    try std.testing.expectEqualStrings("needle late", result.matches[0].line);

    const counted = try countRegularFileRoot(arena_state.allocator(), workspace, large, "needle", false, null);
    try std.testing.expectEqual(@as(usize, 1), counted.matching_lines);
}

test "grep search searches large files during directory traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const good = try writeTempFile(alloc, &tmp, "good.txt", "needle good\n");
    defer alloc.free(good);
    const content = try contentWithPrefix(alloc, 300 * 1024, "needle first\n");
    defer alloc.free(content);
    const large = try writeTempFile(alloc, &tmp, "large.txt", content);
    defer alloc.free(large);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatches(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
}

test "grep search finds a match split across the chunks of a long line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    // One line of three chunks, with "needle" starting three bytes before
    // the first chunk edge, so neither piece holds all of it.
    const content = try alloc.alloc(u8, 3 * chunk_bytes + 1);
    defer alloc.free(content);
    @memset(content, 'x');
    @memcpy(content[chunk_bytes - 3 ..][0..6], "needle");
    content[content.len - 1] = '\n';
    const long = try writeTempFile(alloc, &tmp, "long.txt", content);
    defer alloc.free(long);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    for ([_]struct { pattern: []const u8, case_insensitive: bool }{
        .{ .pattern = "needle", .case_insensitive = false },
        .{ .pattern = "NEEDLE", .case_insensitive = true },
    }) |case| {
        const result = try collectRegularFileRoot(arena_state.allocator(), workspace, long, case.pattern, case.case_insensitive, null);
        try std.testing.expectEqual(@as(usize, 1), result.matches.len);
        try std.testing.expectEqual(@as(usize, 1), result.matches[0].line_number);
        // The match keeps the line's first chunk plus one byte to mark the cut.
        try std.testing.expectEqual(chunk_bytes + 1, result.matches[0].line.len);
    }
    const missing = try collectRegularFileRoot(arena_state.allocator(), workspace, long, "needles", false, null);
    try std.testing.expectEqual(@as(usize, 0), missing.matches.len);
}

test "grep search keeps a UTF-8 character cut by a chunk edge as text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    // A long line of two-byte characters offset by one byte, so a chunk edge
    // falls inside a character, then a match on the next line.
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    try content.append(alloc, 'a');
    for (0..chunk_bytes) |_| try content.appendSlice(alloc, "\u{e9}");
    try content.appendSlice(alloc, "\nneedle after\n");
    const wide = try writeTempFile(alloc, &tmp, "wide.txt", content.items);
    defer alloc.free(wide);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, wide, "needle", false, null);
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expectEqual(@as(usize, 2), result.matches[0].line_number);
}

test "grep search skips a file whose NUL byte comes after a match" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const content = try contentWithPrefix(alloc, 2 * chunk_bytes, "needle early\n");
    defer alloc.free(content);
    content[content.len - 2] = 0;
    const binary = try writeTempFile(alloc, &tmp, "binary.dat", content);
    defer alloc.free(binary);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectRegularFileRoot(arena_state.allocator(), workspace, binary, "needle", false, null);
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    const counted = try countRegularFileRoot(arena_state.allocator(), workspace, binary, "needle", false, null);
    try std.testing.expectEqual(@as(usize, 0), counted.matching_lines);

    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "grep_files skipped non-text file path=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "reason=contains_nul") != null);
}

test "grep search include matches a file root by its workspace path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const file = try writeTempFile(alloc, &tmp, "src/main.zig", "needle\n");
    defer alloc.free(file);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]struct { include: []const u8, matches: usize }{
        .{ .include = "src/*.zig", .matches = 1 },
        .{ .include = "src/main.zig", .matches = 1 },
        .{ .include = "main.zig", .matches = 1 },
        .{ .include = "lib/*.zig", .matches = 0 },
        .{ .include = "*.ts", .matches = 0 },
    }) |case| {
        var include = try glob_pattern.Pattern.compile(arena, case.include);
        defer include.deinit(arena);
        const result = try collectRegularFileRoot(arena, workspace, file, "needle", false, include);
        try std.testing.expectEqual(case.matches, result.matches.len);
        const counted = try countRegularFileRoot(arena, workspace, file, "needle", false, include);
        try std.testing.expectEqual(case.matches, counted.matching_lines);
    }
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
        const name = try std.mem.print(&name_buf, "large/file-{d}.txt", .{i});
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

test "grep search finds match beyond former traversal cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var i: usize = 0;
    while (i < 2050) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.mem.print(&name_buf, "many/file-{d:0>4}.txt", .{i});
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
        const name = try std.mem.print(&name_buf, "file-{d:0>4}.txt", .{i});
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
        const name = try std.mem.print(&name_buf, "many/file-{d:0>4}.txt", .{index});
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
            const want = try std.mem.print(&want_buf, "many/file-{d:0>4}.txt", .{position / 2});
            try std.testing.expect(std.mem.endsWith(u8, match.absolute_path, want));
            try std.testing.expectEqual(2 * (position % 2) + 1, match.line_number);
        }

        const counted = try countDirectoryMatchesWithIgnored(std.testing.allocator, arena_state.allocator(), workspace, workspace, "needle", false, tool_files.default_skipped_names, null);
        try std.testing.expectEqual(@as(usize, 3000), counted.matching_lines);
        try std.testing.expectEqual(@as(usize, 1500), counted.matching_files);
    }
}

test "parallel grep stops once finished batches hold the cap, even with an earlier batch still running" {
    var work_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer work_state.deinit();
    const work = work_state.allocator();
    const files = try work.alloc([]const u8, batch_files * 4);
    for (files) |*file| file.* = "f";
    var scan = try initParallelScan(work, "/w", "/w", files, "x", false, .matches);
    const many = try work.alloc(Match, collection_cap);
    for (many) |*match| match.* = .{ .absolute_path = "/w/f", .line_number = 1, .line = "x" };

    // Batch 0 is still running; batch 1 finishes holding the cap.
    scan.outcomes[batch_files] = .{ .matches = many };
    scan.finishBatch(batch_files, batch_files * 2);
    try std.testing.expect(scan.stop.load(.acquire));

    // Below the cap the scan keeps going.
    var short = try initParallelScan(work, "/w", "/w", files, "x", false, .matches);
    short.outcomes[batch_files] = .{ .matches = many[0 .. collection_cap - 1] };
    short.finishBatch(batch_files, batch_files * 2);
    try std.testing.expect(!short.stop.load(.acquire));
}

test "grep fails for running out of memory only before the cut" {
    var work_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer work_state.deinit();
    const work = work_state.allocator();
    const files = try work.alloc([]const u8, batch_files * 3);
    for (files) |*file| file.* = "f";
    const many = try work.alloc(Match, collection_cap);
    for (many) |*match| match.* = .{ .absolute_path = "/w/f", .line_number = 1, .line = "x" };

    // The cut lands in the first file, so a later batch running out of
    // memory changes nothing.
    var past = try initParallelScan(work, "/w", "/w", files, "x", false, .matches);
    past.outcomes[0] = .{ .matches = many };
    past.out_of_memory_from = batch_files * 2;
    var kept: std.ArrayList(Match) = .empty;
    try std.testing.expectEqual(@as(?TruncatedReason, .collection_cap), try mergeMatches(work, &past, &kept));
    try std.testing.expectEqual(collection_cap, kept.items.len);

    // Before the cut, the missing matches would change the result.
    var before = try initParallelScan(work, "/w", "/w", files, "x", false, .matches);
    before.outcomes[0] = .{ .matches = many[0..10] };
    before.out_of_memory_from = batch_files;
    var partial: std.ArrayList(Match) = .empty;
    try std.testing.expectError(error.OutOfMemory, mergeMatches(work, &before, &partial));
}

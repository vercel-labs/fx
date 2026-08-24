const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const glob_pattern = @import("glob_pattern.zig");
const ignored_dirs = @import("ignored_dirs.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("pathing.zig");
const text_utils = @import("../shared/text_utils.zig");
const workspace_files = @import("workspace_files.zig");

const Allocator = std.mem.Allocator;

/// Maximum number of matches rendered to model-visible output.
pub const output_cap: usize = 200;

/// Maximum number of matching lines collected before grep stops scanning.
pub const collection_cap: usize = 2000;

const file_byte_cap: usize = 50 * 1024 * 4;
const git_grep_stdout_limit: usize = 8 * 1024 * 1024;

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
    candidate_cap: usize = workspace_files.default_candidate_cap,
    candidate_incomplete: bool = false,
    skipped_overlong: usize = 0,
};

/// Owned-in-arena summary of a grep search count pass.
pub const CountResult = struct {
    matching_lines: usize = 0,
    matching_files: usize = 0,
    candidate_count: usize = 0,
    candidate_cap: usize = workspace_files.default_candidate_cap,
    candidate_incomplete: bool = false,
    skipped_overlong: usize = 0,
};

/// Collects literal line matches below a directory root. Returned slices are owned by arena.
pub fn collectDirectoryMatches(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
) !Result {
    return collectDirectoryMatchesWithIgnored(arena, workspace_root, absolute_root, pattern, case_insensitive, ignored_dirs.ignored_directory_names, include);
}

pub fn collectDirectoryMatchesWithIgnored(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
) !Result {
    return collectDirectoryMatchesWithOptions(arena, workspace_root, absolute_root, pattern, case_insensitive, ignored_names, include, .{}, workspace_files.trustedGitExecutable());
}

pub fn countDirectoryMatchesWithIgnored(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
) !CountResult {
    return countDirectoryMatchesWithOptions(arena, workspace_root, absolute_root, pattern, case_insensitive, ignored_names, include, .{}, workspace_files.trustedGitExecutable());
}

fn collectDirectoryMatchesWithOptions(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
    workspace_options: workspace_files.Options,
    git_executable_override: ?[]const u8,
) !Result {
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(arena);

    var truncated_reason: ?TruncatedReason = null;
    var stats: CandidateStats = .{ .cap = workspace_options.candidate_cap };

    if (!workspace_options.force_fallback) git: {
        const git_executable = git_executable_override orelse {
            debug_trace.logf("core", "grep_files trusted Git unavailable; falling back root={s}", .{absolute_root});
            break :git;
        };
        if (gitIgnoresRoot(arena, absolute_root, git_executable)) break :git;
        const tracked = gitGrepTrackedMatches(arena, workspace_root, absolute_root, pattern, case_insensitive, include, &matches, git_executable) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("core", "grep_files git grep fallback root={s} err={s}", .{ absolute_root, @errorName(err) });
            break :git;
        };
        stats.count += tracked.candidate_count;
        truncated_reason = tracked.truncated_reason;

        if (truncated_reason == null) {
            const untracked = workspaceFileCandidates(arena, absolute_root, ignored_names, .{
                .candidate_cap = workspace_options.candidate_cap,
                .git_stdout_limit = workspace_options.git_stdout_limit,
                .only_untracked = true,
            }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                debug_trace.logf("core", "grep_files untracked fallback skipped root={s} err={s}", .{ absolute_root, @errorName(err) });
                return finishMatches(arena, &matches, truncated_reason, stats);
            };
            stats.add(untracked.result);
            truncated_reason = try scanCandidateList(arena, workspace_root, untracked.provider_root, untracked.result.files, pattern, case_insensitive, include, &matches);
        }

        return finishMatches(arena, &matches, truncated_reason, stats);
    }

    var discovery_options = workspace_options;
    discovery_options.include_untracked = true;
    const candidates = try workspaceFileCandidates(arena, absolute_root, ignored_names, discovery_options);
    stats.add(candidates.result);
    truncated_reason = try scanCandidateList(arena, workspace_root, candidates.provider_root, candidates.result.files, pattern, case_insensitive, include, &matches);

    return finishMatches(arena, &matches, truncated_reason, stats);
}

fn countDirectoryMatchesWithOptions(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    ignored_names: []const []const u8,
    include: ?glob_pattern.Pattern,
    workspace_options: workspace_files.Options,
    git_executable_override: ?[]const u8,
) !CountResult {
    var count_result: CountResult = .{ .candidate_cap = workspace_options.candidate_cap };
    var stats: CandidateStats = .{ .cap = workspace_options.candidate_cap };

    if (!workspace_options.force_fallback) git: {
        const git_executable = git_executable_override orelse {
            debug_trace.logf("core", "grep_files trusted Git unavailable; falling back root={s}", .{absolute_root});
            break :git;
        };
        if (gitIgnoresRoot(arena, absolute_root, git_executable)) break :git;
        const tracked = gitGrepTrackedCounts(arena, workspace_root, absolute_root, pattern, case_insensitive, include, git_executable) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("core", "grep_files git grep count fallback root={s} err={s}", .{ absolute_root, @errorName(err) });
            break :git;
        };
        count_result.matching_lines += tracked.matching_lines;
        count_result.matching_files += tracked.matching_files;
        stats.count += tracked.candidate_count;

        const untracked = workspaceFileCandidates(arena, absolute_root, ignored_names, .{
            .candidate_cap = workspace_options.candidate_cap,
            .git_stdout_limit = workspace_options.git_stdout_limit,
            .only_untracked = true,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("core", "grep_files untracked count fallback skipped root={s} err={s}", .{ absolute_root, @errorName(err) });
            return finishCount(count_result, stats);
        };
        stats.add(untracked.result);
        try countCandidateList(arena, workspace_root, untracked.provider_root, untracked.result.files, pattern, case_insensitive, include, &count_result);

        return finishCount(count_result, stats);
    }

    var discovery_options = workspace_options;
    discovery_options.include_untracked = true;
    const candidates = try workspaceFileCandidates(arena, absolute_root, ignored_names, discovery_options);
    stats.add(candidates.result);
    try countCandidateList(arena, workspace_root, candidates.provider_root, candidates.result.files, pattern, case_insensitive, include, &count_result);

    return finishCount(count_result, stats);
}

fn gitIgnoresRoot(arena: Allocator, absolute_root: []const u8, git_executable: []const u8) bool {
    const argv = [_][]const u8{ git_executable, "--no-optional-locks", "check-ignore", "-q", "--", "." };
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = &argv,
        .cwd = .{ .path = absolute_root },
        .stdout_limit = std.Io.Limit.limited(1024),
        .stderr_limit = std.Io.Limit.limited(1024),
    }) catch return false;
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
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
                .cap = workspace_files.default_candidate_cap,
            });
        }
    }

    const truncated_reason = try scanFile(arena, absolute_path, pattern, case_insensitive, &matches);

    return finishMatches(arena, &matches, truncated_reason, .{
        .count = 1,
        .cap = workspace_files.default_candidate_cap,
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
            return finishCount(.{}, .{ .cap = workspace_files.default_candidate_cap });
        }
    }

    const file_count = try countFile(arena, absolute_path, pattern, case_insensitive);
    return finishCount(.{
        .matching_lines = file_count.matching_lines,
        .matching_files = if (file_count.matching_lines > 0) 1 else 0,
    }, .{
        .count = 1,
        .cap = workspace_files.default_candidate_cap,
    });
}

const CandidateStats = struct {
    count: usize = 0,
    cap: usize = workspace_files.default_candidate_cap,
    incomplete: bool = false,
    skipped_overlong: usize = 0,

    fn add(self: *CandidateStats, result: workspace_files.Result) void {
        self.count += result.files.len;
        self.cap = result.candidate_cap;
        self.incomplete = self.incomplete or result.incomplete;
        self.skipped_overlong += result.skipped_overlong;
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

const WorkspaceCandidates = struct {
    result: workspace_files.Result,
    provider_root: []const u8,
};

const CandidateFile = struct {
    display_path: []const u8,
    read_path: []const u8,
};

fn workspaceFileCandidates(arena: Allocator, absolute_root: []const u8, ignored_names: []const []const u8, options: workspace_files.Options) !WorkspaceCandidates {
    var discover_options = options;
    discover_options.ignored_names = ignored_names;

    return .{
        .result = try workspace_files.discover(arena, absolute_root, discover_options),
        .provider_root = absolute_root,
    };
}

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

fn scanCandidateList(
    arena: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    candidates: []const []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
    matches: *std.ArrayList(Match),
) !?TruncatedReason {
    for (candidates) |candidate| {
        if (include) |include_pattern| {
            if (!include_pattern.matchesPath(candidate)) continue;
        }

        var absolute_match_buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate_file = try resolveCandidateFile(arena, workspace_root, provider_root, candidate, absolute_match_buf[0..]) orelse continue;
        const scan_result = scanFileAt(arena, candidate_file.display_path, candidate_file.read_path, pattern, case_insensitive, matches) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ candidate_file.display_path, @errorName(err) });
            continue;
        };
        if (scan_result) |reason| return reason;
    }
    return null;
}

fn countCandidateList(
    arena: Allocator,
    workspace_root: []const u8,
    provider_root: []const u8,
    candidates: []const []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
    count_result: *CountResult,
) !void {
    for (candidates) |candidate| {
        if (include) |include_pattern| {
            if (!include_pattern.matchesPath(candidate)) continue;
        }

        var absolute_match_buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate_file = try resolveCandidateFile(arena, workspace_root, provider_root, candidate, absolute_match_buf[0..]) orelse continue;
        const file_count = countFileAt(candidate_file.display_path, candidate_file.read_path, pattern, case_insensitive) catch |err| {
            debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ candidate_file.display_path, @errorName(err) });
            continue;
        };
        if (file_count.matching_lines == 0) continue;
        count_result.matching_files += 1;
        count_result.matching_lines += file_count.matching_lines;
    }
}

pub fn gitGrepArgvForTest(git_executable: []const u8) [9][]const u8 {
    return .{ git_executable, "--no-optional-locks", "grep", "-n", "-I", "-F", "-z", "-e", "needle" };
}

const GitGrepMatchesResult = struct {
    candidate_count: usize = 0,
    truncated_reason: ?TruncatedReason = null,
};

const FileCount = struct {
    matching_lines: usize = 0,
};

fn gitGrepTrackedMatches(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
    matches: *std.ArrayList(Match),
    git_executable: []const u8,
) !GitGrepMatchesResult {
    if (pattern.len == 0) return error.GitGrepUnsupported;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(arena);
    try argv.appendSlice(arena, &.{ git_executable, "--no-optional-locks", "grep", "-n", "-I", "-F", "-z" });
    if (case_insensitive) try argv.append(arena, "-i");
    try argv.appendSlice(arena, &.{ "-e", pattern, "--" });
    if (safeGitIncludePathspec(include)) |pathspec| {
        try argv.append(arena, pathspec);
    } else {
        try argv.append(arena, ".");
    }

    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = absolute_root },
        .stdout_limit = std.Io.Limit.limited(git_grep_stdout_limit),
        .stderr_limit = std.Io.Limit.limited(1024),
    }) catch return error.GitGrepFailed;
    defer arena.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return parseGitGrepMatches(arena, workspace_root, absolute_root, result.stdout, include, matches);
            arena.free(result.stdout);
            if (code == 1) return .{};
            return error.GitGrepFailed;
        },
        else => {
            arena.free(result.stdout);
            return error.GitGrepFailed;
        },
    }
}

fn gitGrepTrackedCounts(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    include: ?glob_pattern.Pattern,
    git_executable: []const u8,
) !CountResult {
    if (pattern.len == 0) return error.GitGrepUnsupported;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(arena);
    try argv.appendSlice(arena, &.{ git_executable, "--no-optional-locks", "grep", "--count", "-I", "-F", "-z" });
    if (case_insensitive) try argv.append(arena, "-i");
    try argv.appendSlice(arena, &.{ "-e", pattern, "--" });
    if (safeGitIncludePathspec(include)) |pathspec| {
        try argv.append(arena, pathspec);
    } else {
        try argv.append(arena, ".");
    }

    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = absolute_root },
        .stdout_limit = std.Io.Limit.limited(git_grep_stdout_limit),
        .stderr_limit = std.Io.Limit.limited(1024),
    }) catch return error.GitGrepFailed;
    defer arena.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return parseGitGrepCounts(arena, workspace_root, absolute_root, result.stdout, include);
            arena.free(result.stdout);
            if (code == 1) return .{};
            return error.GitGrepFailed;
        },
        else => {
            arena.free(result.stdout);
            return error.GitGrepFailed;
        },
    }
}

fn parseGitGrepMatches(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    raw: []const u8,
    include: ?glob_pattern.Pattern,
    matches: *std.ArrayList(Match),
) !GitGrepMatchesResult {
    var result: GitGrepMatchesResult = .{};
    var display_paths = std.StringHashMap([]const u8).init(arena);
    defer display_paths.deinit();
    var skipped_paths = std.StringHashMap(void).init(arena);
    defer skipped_paths.deinit();

    var index: usize = 0;
    while (index < raw.len) {
        const path_end = findScalarFrom(raw, index, 0) orelse break;
        const path = raw[index..path_end];
        const line_start = path_end + 1;
        const line_end = findScalarFrom(raw, line_start, 0) orelse break;
        const content_start = line_end + 1;
        const content_end = findScalarFrom(raw, content_start, '\n') orelse raw.len;
        index = if (content_end < raw.len) content_end + 1 else raw.len;

        if (path.len == 0 or path.len > workspace_files.max_relative_path_bytes) continue;
        if (include) |include_pattern| {
            if (!include_pattern.matchesPath(path)) continue;
        }
        if (skipped_paths.contains(path)) continue;

        const line_number = std.fmt.parseInt(usize, raw[line_start..line_end], 10) catch continue;
        const line = raw[content_start..content_end];
        if (!text_utils.isModelSafeText(line)) {
            debug_trace.logf("core", "grep_files skipped non-text git grep line root={s} path={s}", .{ absolute_root, path });
            try skipped_paths.put(path, {});
            continue;
        }

        const display_path = display_paths.get(path) orelse blk: {
            const absolute_match = try validateMatchedGitFile(arena, workspace_root, absolute_root, path) orelse {
                try skipped_paths.put(path, {});
                continue;
            };
            result.candidate_count += 1;
            try display_paths.put(path, absolute_match);
            break :blk absolute_match;
        };

        if (matches.items.len >= collection_cap) {
            result.truncated_reason = .collection_cap;
            break;
        }
        var retained_path: ?[]const u8 = null;
        try appendMatch(arena, matches, &retained_path, display_path, line_number, line);
        if (matches.items.len >= collection_cap) {
            result.truncated_reason = .collection_cap;
            break;
        }
    }

    return result;
}

fn parseGitGrepCounts(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    raw: []const u8,
    include: ?glob_pattern.Pattern,
) !CountResult {
    var result: CountResult = .{};
    var skipped_paths = std.StringHashMap(void).init(arena);
    defer skipped_paths.deinit();

    var index: usize = 0;
    while (index < raw.len) {
        const path_end = findScalarFrom(raw, index, 0) orelse break;
        const path = raw[index..path_end];
        const count_start = path_end + 1;
        const count_end = findScalarFrom(raw, count_start, '\n') orelse raw.len;
        index = if (count_end < raw.len) count_end + 1 else raw.len;

        if (path.len == 0 or path.len > workspace_files.max_relative_path_bytes) continue;
        if (include) |include_pattern| {
            if (!include_pattern.matchesPath(path)) continue;
        }
        if (skipped_paths.contains(path)) continue;

        const raw_count = std.mem.trimEnd(u8, raw[count_start..count_end], "\r");
        const line_count = std.fmt.parseInt(usize, raw_count, 10) catch continue;
        if (line_count == 0) continue;
        if ((try validateMatchedGitFile(arena, workspace_root, absolute_root, path)) == null) {
            try skipped_paths.put(path, {});
            continue;
        }
        result.candidate_count += 1;
        result.matching_files += 1;
        result.matching_lines += line_count;
    }

    return result;
}

fn validateMatchedGitFile(
    arena: Allocator,
    workspace_root: []const u8,
    absolute_root: []const u8,
    path: []const u8,
) !?[]const u8 {
    const absolute_match = std.fs.path.join(arena, &.{ absolute_root, path }) catch return error.OutOfMemory;
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute_match, .{ .follow_symlinks = false }) catch |err| {
        debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ absolute_match, @errorName(err) });
        return null;
    };
    if (stat.kind != .file and stat.kind != .sym_link) return null;
    if (stat.size > file_byte_cap) {
        logOversizedFile(absolute_match);
        return null;
    }
    const resolved_match = if (stat.kind == .sym_link)
        resolveDirectoryEntryTarget(arena, workspace_root, absolute_match, stat.kind) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("core", "grep_files scan skipped path={s} err={s}", .{ absolute_match, @errorName(err) });
            return null;
        } orelse return null
    else
        absolute_match;
    var content_buf: [file_byte_cap + 1]u8 = undefined;
    if ((try readModelSafeContent(absolute_match, resolved_match, &content_buf)) == null) return null;
    return absolute_match;
}

fn safeGitIncludePathspec(include: ?glob_pattern.Pattern) ?[]const u8 {
    const raw = if (include) |pattern| pattern.raw else return null;
    if (raw.len == 0 or std.mem.findScalar(u8, raw, '/') != null) return null;
    for (raw) |ch| {
        switch (ch) {
            '\\', '{', '}' => return null,
            else => {},
        }
    }
    return raw;
}

fn findScalarFrom(haystack: []const u8, start: usize, needle: u8) ?usize {
    var index = start;
    while (index < haystack.len) : (index += 1) {
        if (haystack[index] == needle) return index;
    }
    return null;
}

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

fn runGitForTest(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    // Test setup resolves Git the same way production does, so this file holds
    // no bare executable name for the argv guard below to have to except.
    try argv.append(alloc, workspace_files.trustedGitExecutable() orelse return error.SkipZigTest);
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

test "grep search git grep argv uses literal fixed-string flags" {
    const argv = gitGrepArgvForTest("/usr/bin/git");

    try std.testing.expectEqualStrings("/usr/bin/git", argv[0]);
    try std.testing.expectEqualStrings("--no-optional-locks", argv[1]);
    try std.testing.expectEqualStrings("grep", argv[2]);
    try std.testing.expectEqualStrings("-n", argv[3]);
    try std.testing.expectEqualStrings("-I", argv[4]);
    try std.testing.expectEqualStrings("-F", argv[5]);
    try std.testing.expectEqualStrings("-z", argv[6]);
    try std.testing.expectEqualStrings("-e", argv[7]);
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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, try io_mod.dirRealpathAlloc(arena_state.allocator(), tmp.dir, "node_modules/pkg"), "needle", false, null);

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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, workspace, "needle", false, null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(result.truncated_reason == null);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "src/file.txt"));
}

/// The argv of every spawn the injected executable received, one per line.
/// A site that resolves its own name through PATH runs the real Git instead
/// and leaves nothing here, so the caller asserts on content rather than a
/// count: a tally cannot tell a missing spawn from an unrecorded one.
fn recordedSpawns(alloc: Allocator, marker_path: []const u8) ![]u8 {
    return readFileToEndForTest(alloc, marker_path, 4096) catch |err| switch (err) {
        error.FileNotFound => return alloc.alloc(u8, 0),
        else => return err,
    };
}

fn writeExecutableScript(tmp: *std.testing.TmpDir, sub_path: []const u8, body: []const u8) !void {
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), body);
    try file.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o755));
}

test "grep search spawns the selected Git executable rather than resolving one from PATH" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const tracked = try writeTempFile(alloc, &tmp, "tracked.txt", "needle tracked\n");
    defer alloc.free(tracked);

    const marker = try std.fs.path.join(alloc, &.{ workspace, "spawned.log" });
    defer alloc.free(marker);
    const script = try std.fmt.allocPrint(alloc, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{s}\"\nexit 1\n", .{marker});
    defer alloc.free(script);
    try writeExecutableScript(&tmp, "fake-git", script);
    const fake_git = try std.fs.path.join(alloc, &.{ workspace, "fake-git" });
    defer alloc.free(fake_git);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try collectDirectoryMatchesWithOptions(
        arena_state.allocator(),
        workspace,
        workspace,
        "needle",
        false,
        ignored_dirs.ignored_directory_names,
        null,
        .{},
        fake_git,
    );

    // Assert what the selection was asked to run, not how often it ran. A
    // bare argv0 at either site resolves through PATH to the real Git and
    // records nothing, so a missing line is the regression this catches.
    const spawns = try recordedSpawns(alloc, marker);
    defer alloc.free(spawns);
    try std.testing.expect(std.mem.find(u8, spawns, "check-ignore") != null);
    try std.testing.expect(std.mem.find(u8, spawns, "grep -n") != null);
}

test "grep search count path spawns the selected Git executable rather than resolving one from PATH" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const tracked = try writeTempFile(alloc, &tmp, "tracked.txt", "needle tracked\n");
    defer alloc.free(tracked);

    const marker = try std.fs.path.join(alloc, &.{ workspace, "spawned.log" });
    defer alloc.free(marker);
    const script = try std.fmt.allocPrint(alloc, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{s}\"\nexit 1\n", .{marker});
    defer alloc.free(script);
    try writeExecutableScript(&tmp, "fake-git", script);
    const fake_git = try std.fs.path.join(alloc, &.{ workspace, "fake-git" });
    defer alloc.free(fake_git);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try countDirectoryMatchesWithOptions(
        arena_state.allocator(),
        workspace,
        workspace,
        "needle",
        false,
        ignored_dirs.ignored_directory_names,
        null,
        .{},
        fake_git,
    );

    const spawns = try recordedSpawns(alloc, marker);
    defer alloc.free(spawns);
    try std.testing.expect(std.mem.find(u8, spawns, "check-ignore") != null);
    try std.testing.expect(std.mem.find(u8, spawns, "grep --count") != null);
}

test "grep search refuses to resolve Git when no trusted executable is available" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const tracked = try writeTempFile(alloc, &tmp, "tracked.txt", "needle tracked\n");
    defer alloc.free(tracked);
    const trace_path = try std.fs.path.join(alloc, &.{ workspace, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try collectDirectoryMatchesWithOptions(
        arena_state.allocator(),
        workspace,
        workspace,
        "needle",
        false,
        ignored_dirs.ignored_directory_names,
        null,
        .{},
        null,
    );

    // The trace line is what separates a refusal from a fallback reached by
    // some other route: substituting a name for the missing executable would
    // still land in the scanner, but never emits this.
    const trace = try readTrace(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "trusted Git unavailable") != null);

    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expect(std.mem.endsWith(u8, result.matches[0].absolute_path, "tracked.txt"));
}

test "grep search builds no Git argv from a bare executable name" {
    const alloc = std.testing.allocator;
    var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), "src/core/workspace/grep_search.zig", .{});
    defer file.close(io_mod.getIo());
    const source = try io_mod.readFileToEnd(alloc, &file, 256 * 1024);
    defer alloc.free(source);

    // No argv in this file may name the executable instead of resolving it.
    // Keyed on the bare literal, not on any argv shape, so a future spawn
    // that skips the usual flags cannot slip past. Split so the needle does
    // not match itself in this test's own source.
    const bare = "\"gi" ++ "t\"";
    try std.testing.expect(std.mem.find(u8, source, bare) == null);
}

test "workspace grep only ever selects an absolute Git executable" {
    const executable = workspace_files.trustedGitExecutable() orelse return error.SkipZigTest;
    try std.testing.expect(std.fs.path.isAbsolute(executable));
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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, workspace, "needle", false, null);

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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, workspace, "needle", false, null);

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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, workspace, "needle", false, null);

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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, workspace, "needle", false, pattern);
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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, links_root, "needle", false, null);

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
    const result = try collectDirectoryMatches(retained_fba.allocator(), workspace, workspace, "needle", false, null);

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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, workspace, "needle", false, null);
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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, workspace, "needle", false, null);

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
        arena_state.allocator(),
        workspace,
        narrowed_root,
        "needle",
        false,
        ignored_dirs.ignored_directory_names,
        null,
        .{
            .candidate_cap = 1,
            .force_fallback = true,
        },
        workspace_files.trustedGitExecutable(),
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
    const result = try collectDirectoryMatches(arena_state.allocator(), workspace, workspace, "needle", false, null);

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

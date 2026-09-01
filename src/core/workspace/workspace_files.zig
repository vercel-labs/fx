const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const ignored_dirs = @import("ignored_dirs.zig");
const io_mod = @import("../shared/io.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

pub const default_candidate_cap: usize = 100_000;
pub const default_git_stdout_limit: usize = 32 * 1024 * 1024;
pub const max_relative_path_bytes: usize = 2048;

pub const Source = enum {
    git,
    recursive,
};

pub const CapReason = enum {
    candidate_cap,
};

pub const Options = struct {
    candidate_cap: usize = default_candidate_cap,
    git_stdout_limit: usize = default_git_stdout_limit,
    ignored_names: []const []const u8 = ignored_dirs.ignored_directory_names,
    force_fallback: bool = false,
    include_untracked: bool = false,
    only_untracked: bool = false,
    include_hidden: bool = false,
    sort_paths: bool = false,
    git_worktree_is_authoritative: bool = false,
};

pub const Result = struct {
    files: []const []const u8,
    source: Source,
    candidate_cap: usize,
    incomplete: bool = false,
    cap_reason: ?CapReason = null,
    skipped_overlong: usize = 0,
};

pub const DirectoryResult = struct {
    directories: []const []const u8,
    source: Source,
    candidate_cap: usize,
    incomplete: bool = false,
    cap_reason: ?CapReason = null,
    skipped_overlong: usize = 0,
};

pub fn discover(arena: Allocator, workspace_root: []const u8, options: Options) !Result {
    return discoverWithStop(arena, workspace_root, options, null, trustedGitExecutable());
}

pub fn discoverCancellable(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: *std.atomic.Value(bool),
) !Result {
    return discoverWithStop(arena, workspace_root, options, stop_requested, trustedGitExecutable());
}

pub fn discoverDirectoriesCancellable(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: *std.atomic.Value(bool),
) !DirectoryResult {
    return discoverDirectoriesWithStop(arena, workspace_root, options, stop_requested, trustedGitExecutable());
}

fn discoverWithStop(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    git_executable: ?[]const u8,
) !Result {
    try checkCanceled(stop_requested);
    if (workspace_root.len == 0) {
        return .{
            .files = &.{},
            .source = .recursive,
            .candidate_cap = options.candidate_cap,
        };
    }

    if (!options.force_fallback) git: {
        const executable = git_executable orelse {
            debug_trace.logf("core", "workspace file discovery trusted Git unavailable; falling back root={s}", .{workspace_root});
            break :git;
        };
        if (gitRawList(arena, workspace_root, options, stop_requested, executable)) |raw| {
            const parsed = try parseRawList(arena, raw, .git, options);
            if (options.only_untracked or
                options.git_worktree_is_authoritative or
                parsed.files.len > 0 or
                parsed.incomplete or
                parsed.skipped_overlong > 0)
            {
                return parsed;
            }
            debug_trace.logf("core", "workspace file discovery git returned no candidates; falling back root={s}", .{workspace_root});
        } else |err| {
            if (err == error.Canceled) return error.Canceled;
            if (options.git_worktree_is_authoritative and try hasGitMetadata(arena, workspace_root)) {
                return error.GitFileListFailed;
            }
            debug_trace.logf("core", "workspace file discovery falling back root={s} err={s}", .{ workspace_root, @errorName(err) });
        }
    }

    return walkWorkspace(arena, workspace_root, options, stop_requested);
}

fn discoverDirectoriesWithStop(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    git_executable: ?[]const u8,
) !DirectoryResult {
    try checkCanceled(stop_requested);
    if (workspace_root.len == 0) {
        return .{
            .directories = &.{},
            .source = .recursive,
            .candidate_cap = options.candidate_cap,
        };
    }

    if (!options.force_fallback) git: {
        const executable = git_executable orelse {
            debug_trace.logf("core", "workspace directory discovery trusted Git unavailable; falling back root={s}", .{workspace_root});
            break :git;
        };
        if (gitRawIgnoredDirectoryList(arena, workspace_root, options, stop_requested, executable)) |raw| {
            var ignored_paths = try parseRawIgnoredDirectories(arena, raw);
            defer ignored_paths.deinit(arena);
            var git_options = options;
            git_options.ignored_names = &.{".git"};
            return walkWorkspaceDirectories(arena, workspace_root, git_options, stop_requested, &ignored_paths, .git);
        } else |err| {
            if (err == error.Canceled) return error.Canceled;
            if (options.git_worktree_is_authoritative and try hasGitMetadata(arena, workspace_root)) {
                return error.GitFileListFailed;
            }
            debug_trace.logf("core", "workspace directory discovery falling back root={s} err={s}", .{ workspace_root, @errorName(err) });
        }
    }

    return walkWorkspaceDirectories(arena, workspace_root, options, stop_requested, null, .recursive);
}

fn hasGitMetadata(alloc: Allocator, workspace_root: []const u8) !bool {
    var current = workspace_root;
    while (current.len > 0) {
        const found = found: {
            const marker = try std.fs.path.join(alloc, &.{ current, ".git" });
            defer alloc.free(marker);
            _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), marker, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => break :found false,
                else => |e| return e,
            };
            break :found true;
        };
        if (found) return true;

        const parent = std.fs.path.dirname(current) orelse return false;
        if (std.mem.eql(u8, parent, current)) return false;
        current = parent;
    }
    return false;
}

fn gitTrackedFilesArgv(git_executable: []const u8) [5][]const u8 {
    return .{ git_executable, "--no-optional-locks", "ls-files", "-z", "--cached" };
}

fn gitTrackedAndOtherFilesArgv(git_executable: []const u8) [7][]const u8 {
    return .{ git_executable, "--no-optional-locks", "ls-files", "-z", "--cached", "--others", "--exclude-standard" };
}

fn gitOtherFilesArgv(git_executable: []const u8) [6][]const u8 {
    return .{ git_executable, "--no-optional-locks", "ls-files", "-z", "--others", "--exclude-standard" };
}

fn gitIgnoredDirectoriesArgv(git_executable: []const u8) [8][]const u8 {
    return .{ git_executable, "--no-optional-locks", "ls-files", "-z", "--others", "--ignored", "--directory", "--exclude-standard" };
}

fn gitRawList(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    git_executable: []const u8,
) ![]u8 {
    const tracked_argv = gitTrackedFilesArgv(git_executable);
    const tracked_and_other_argv = gitTrackedAndOtherFilesArgv(git_executable);
    const other_argv = gitOtherFilesArgv(git_executable);
    const argv: []const []const u8 = if (options.only_untracked)
        &other_argv
    else if (options.include_untracked)
        &tracked_and_other_argv
    else
        &tracked_argv;
    return runGitRawList(arena, workspace_root, argv, options.git_stdout_limit, stop_requested);
}

fn gitRawIgnoredDirectoryList(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    git_executable: []const u8,
) ![]u8 {
    const argv = gitIgnoredDirectoriesArgv(git_executable);
    return runGitRawList(arena, workspace_root, &argv, options.git_stdout_limit, stop_requested);
}

fn runGitRawList(
    arena: Allocator,
    workspace_root: []const u8,
    argv: []const []const u8,
    stdout_limit: usize,
    stop_requested: ?*std.atomic.Value(bool),
) ![]u8 {
    const run_options: std.process.RunOptions = .{
        .argv = argv,
        .cwd = .{ .path = workspace_root },
        .stdout_limit = std.Io.Limit.limited(stdout_limit),
        .stderr_limit = std.Io.Limit.limited(1024),
    };
    const result = if (stop_requested) |stop|
        runCancellable(arena, run_options, stop) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.GitFileListFailed,
        }
    else
        std.process.run(arena, io_mod.getIo(), run_options) catch return error.GitFileListFailed;
    defer arena.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return result.stdout;
            arena.free(result.stdout);
            return error.GitFileListFailed;
        },
        else => {
            arena.free(result.stdout);
            return error.GitFileListFailed;
        },
    }
}

/// The Git binary the workspace layer is willing to run, or null when none of
/// the known-good absolute paths exist. Never falls back to a PATH lookup, so a
/// `git` planted earlier on PATH cannot stand in for the real one.
pub fn trustedGitExecutable() ?[]const u8 {
    const candidates = switch (builtin.os.tag) {
        .windows => &[_][]const u8{
            "C:\\Program Files\\Git\\cmd\\git.exe",
            "C:\\Program Files\\Git\\bin\\git.exe",
        },
        else => &[_][]const u8{
            "/usr/bin/git",
            "/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git",
            "/opt/local/bin/git",
            "/run/current-system/sw/bin/git",
        },
    };
    for (candidates) |candidate| {
        const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), candidate, .{ .follow_symlinks = true }) catch continue;
        if (stat.kind == .file) return candidate;
    }
    return null;
}

fn runCancellable(
    alloc: Allocator,
    options: std.process.RunOptions,
    stop_requested: *std.atomic.Value(bool),
) !std.process.RunResult {
    try checkCanceled(stop_requested);

    const zio = io_mod.getIo();
    debug_trace.logf("core", "workspace file discovery process spawning thread={d}", .{std.Thread.getCurrentId()});
    var child = try std.process.spawn(zio, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .expand_arg0 = options.expand_arg0,
        .progress_node = options.progress_node,
        .create_no_window = options.create_no_window,
        .disable_aslr = options.disable_aslr,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(zio);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, zio, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const poll_timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .{ .nanoseconds = 8_000_000 }, .clock = .awake },
    };
    while (true) {
        try checkCanceled(stop_requested);
        const keep_reading = if (multi_reader.fill(options.reserve_amount, poll_timeout))
            true
        else |err| switch (err) {
            error.EndOfStream => false,
            error.Timeout => true,
            else => |e| return e,
        };
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit) return error.StreamTooLong;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit) return error.StreamTooLong;
        }
        if (!keep_reading) break;
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(zio);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer alloc.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer alloc.free(stderr);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn checkCanceled(stop_requested: ?*std.atomic.Value(bool)) !void {
    if (stop_requested) |stop| {
        if (stop.load(.seq_cst)) return error.Canceled;
    }
}

fn parseRawList(arena: Allocator, raw: []const u8, source: Source, options: Options) !Result {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(arena);

    var incomplete = false;
    var skipped_overlong: usize = 0;
    const sep: u8 = if (std.mem.findScalar(u8, raw, 0) != null) 0 else '\n';
    var iter = std.mem.splitScalar(u8, raw, sep);
    while (iter.next()) |entry| {
        const trimmed = if (sep == '\n') std.mem.trimEnd(u8, entry, "\r") else entry;
        if (trimmed.len == 0) continue;
        if (!options.include_hidden and pathContainsHiddenDirectoryComponent(trimmed)) continue;
        if (source != .git and pathContainsIgnoredDir(options.ignored_names, trimmed)) continue;
        if (trimmed.len > max_relative_path_bytes) {
            skipped_overlong += 1;
            continue;
        }
        if (files.items.len >= options.candidate_cap) {
            incomplete = true;
            break;
        }

        try files.append(arena, try arena.dupe(u8, trimmed));
    }
    if (options.sort_paths) sortPathList(files.items);

    return .{
        .files = try files.toOwnedSlice(arena),
        .source = source,
        .candidate_cap = options.candidate_cap,
        .incomplete = incomplete,
        .cap_reason = if (incomplete) .candidate_cap else null,
        .skipped_overlong = skipped_overlong,
    };
}

const PathSet = std.StringHashMapUnmanaged(void);

fn parseRawIgnoredDirectories(arena: Allocator, raw: []const u8) !PathSet {
    var ignored: PathSet = .empty;
    errdefer ignored.deinit(arena);
    const separator: u8 = if (std.mem.findScalar(u8, raw, 0) != null) 0 else '\n';
    var entries = std.mem.splitScalar(u8, raw, separator);
    while (entries.next()) |entry| {
        const trimmed = if (separator == '\n') std.mem.trimEnd(u8, entry, "\r") else entry;
        if (trimmed.len == 0 or !std.fs.path.isSep(trimmed[trimmed.len - 1])) continue;

        var path_end = trimmed.len;
        while (path_end > 0 and std.fs.path.isSep(trimmed[path_end - 1])) : (path_end -= 1) {}
        if (path_end == 0) continue;
        const path = trimmed[0..path_end];
        if (ignored.contains(path)) continue;
        const owned = try arena.dupe(u8, path);
        errdefer arena.free(owned);
        try ignored.put(arena, owned, {});
    }
    return ignored;
}

fn walkWorkspace(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
) !Result {
    const walked = try walkWorkspacePaths(arena, workspace_root, options, stop_requested, .files, null);
    return .{
        .files = walked.paths,
        .source = .recursive,
        .candidate_cap = options.candidate_cap,
        .incomplete = walked.incomplete,
        .cap_reason = if (walked.incomplete) .candidate_cap else null,
        .skipped_overlong = walked.skipped_overlong,
    };
}

fn walkWorkspaceDirectories(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    ignored_paths: ?*const PathSet,
    source: Source,
) !DirectoryResult {
    const walked = try walkWorkspacePaths(arena, workspace_root, options, stop_requested, .directories, ignored_paths);
    return .{
        .directories = walked.paths,
        .source = source,
        .candidate_cap = options.candidate_cap,
        .incomplete = walked.incomplete,
        .cap_reason = if (walked.incomplete) .candidate_cap else null,
        .skipped_overlong = walked.skipped_overlong,
    };
}

const WalkTarget = enum {
    files,
    directories,
};

const WalkResult = struct {
    paths: []const []const u8,
    incomplete: bool,
    skipped_overlong: usize,
};

fn walkWorkspacePaths(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    target: WalkTarget,
    ignored_paths: ?*const PathSet,
) !WalkResult {
    try checkCanceled(stop_requested);
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(arena);

    var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), workspace_root, .{ .iterate = true }) catch {
        return .{
            .paths = try paths.toOwnedSlice(arena),
            .incomplete = false,
            .skipped_overlong = 0,
        };
    };

    var stack: std.ArrayList(FrameEntry) = .empty;
    defer {
        for (stack.items) |*entry| {
            entry.dir.close(io_mod.getIo());
            if (!entry.retain_prefix) arena.free(entry.prefix);
        }
        stack.deinit(arena);
    }

    {
        errdefer root.close(io_mod.getIo());
        const initial_prefix = try arena.dupe(u8, "");
        errdefer arena.free(initial_prefix);
        try stack.append(arena, .{ .dir = root, .prefix = initial_prefix, .iter = root.iterate() });
    }

    var incomplete = false;
    var skipped_overlong: usize = 0;
    while (stack.items.len > 0) {
        try checkCanceled(stop_requested);
        var top = &stack.items[stack.items.len - 1];
        const maybe_entry = top.iter.next(io_mod.getIo()) catch {
            var popped = stack.pop().?;
            popped.dir.close(io_mod.getIo());
            if (!popped.retain_prefix) arena.free(popped.prefix);
            continue;
        };

        if (maybe_entry) |entry| {
            try checkCanceled(stop_requested);
            switch (entry.kind) {
                .file, .sym_link => {
                    if (target != .files) continue;
                    if (isIgnoredName(options.ignored_names, entry.name)) continue;
                    if (paths.items.len >= options.candidate_cap) {
                        incomplete = true;
                        break;
                    }
                    const rel = try joinRelative(arena, top.prefix, entry.name);
                    if (rel.len > max_relative_path_bytes) {
                        arena.free(rel);
                        skipped_overlong += 1;
                        continue;
                    }
                    try paths.append(arena, rel);
                },
                .directory => {
                    if (!options.include_hidden and isHiddenName(entry.name)) continue;
                    if (isIgnoredName(options.ignored_names, entry.name)) continue;
                    const new_prefix = try joinRelative(arena, top.prefix, entry.name);
                    errdefer arena.free(new_prefix);
                    if (ignored_paths) |ignored| {
                        if (ignored.contains(new_prefix)) {
                            arena.free(new_prefix);
                            continue;
                        }
                    }
                    if (target == .directories and paths.items.len >= options.candidate_cap) {
                        arena.free(new_prefix);
                        incomplete = true;
                        break;
                    }
                    if (target == .directories and new_prefix.len > max_relative_path_bytes) {
                        arena.free(new_prefix);
                        skipped_overlong += 1;
                        continue;
                    }
                    const retain_prefix = target == .directories;
                    if (retain_prefix) try paths.append(arena, new_prefix);
                    var sub = top.dir.openDir(io_mod.getIo(), entry.name, .{ .iterate = true }) catch {
                        if (!retain_prefix) arena.free(new_prefix);
                        continue;
                    };
                    errdefer sub.close(io_mod.getIo());
                    try stack.append(arena, .{
                        .dir = sub,
                        .prefix = new_prefix,
                        .iter = sub.iterate(),
                        .retain_prefix = retain_prefix,
                    });
                },
                else => {},
            }
        } else {
            var popped = stack.pop().?;
            popped.dir.close(io_mod.getIo());
            if (!popped.retain_prefix) arena.free(popped.prefix);
        }
    }

    if (options.sort_paths) sortPathList(paths.items);

    return .{
        .paths = try paths.toOwnedSlice(arena),
        .incomplete = incomplete,
        .skipped_overlong = skipped_overlong,
    };
}

fn sortPathList(paths: [][]const u8) void {
    sort_utils.sort([]const u8, paths, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

const FrameEntry = struct {
    dir: std.Io.Dir,
    prefix: []u8,
    iter: std.Io.Dir.Iterator,
    retain_prefix: bool = false,
};

fn joinRelative(arena: Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return arena.dupe(u8, name);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
}

pub fn pathContainsIgnoredDir(ignored: []const []const u8, path: []const u8) bool {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (isIgnoredName(ignored, component.name)) return true;
    }
    return false;
}

pub fn pathContainsHiddenDirectoryComponent(path: []const u8) bool {
    var rest = path;
    while (std.mem.findScalar(u8, rest, '/')) |slash| {
        const component = rest[0..slash];
        if (isHiddenName(component)) return true;
        rest = rest[slash + 1 ..];
    }
    return false;
}

pub fn isHiddenName(name: []const u8) bool {
    return name.len > 1 and name[0] == '.';
}

fn isIgnoredName(ignored: []const []const u8, name: []const u8) bool {
    for (ignored) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(std.testing.io, path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn containsPath(files: []const []const u8, needle: []const u8) bool {
    for (files) |path| {
        if (std.mem.eql(u8, path, needle)) return true;
    }
    return false;
}

test "workspace file provider tracked git argv uses nul-separated cached files" {
    const argv = gitTrackedFilesArgv("git");

    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("--no-optional-locks", argv[1]);
    try std.testing.expectEqualStrings("ls-files", argv[2]);
    try std.testing.expectEqualStrings("-z", argv[3]);
    try std.testing.expectEqualStrings("--cached", argv[4]);
}

test "workspace file provider optional untracked git argv includes exclude-standard" {
    const argv = gitTrackedAndOtherFilesArgv("git");

    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("--no-optional-locks", argv[1]);
    try std.testing.expectEqualStrings("ls-files", argv[2]);
    try std.testing.expectEqualStrings("-z", argv[3]);
    try std.testing.expectEqualStrings("--cached", argv[4]);
    try std.testing.expectEqualStrings("--others", argv[5]);
    try std.testing.expectEqualStrings("--exclude-standard", argv[6]);
}

test "workspace file provider untracked git argv uses others exclude-standard" {
    const argv = gitOtherFilesArgv("git");

    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("--no-optional-locks", argv[1]);
    try std.testing.expectEqualStrings("ls-files", argv[2]);
    try std.testing.expectEqualStrings("-z", argv[3]);
    try std.testing.expectEqualStrings("--others", argv[4]);
    try std.testing.expectEqualStrings("--exclude-standard", argv[5]);
}

test "workspace directory provider asks Git only for ignored directory roots" {
    const argv = gitIgnoredDirectoriesArgv("git");

    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("--no-optional-locks", argv[1]);
    try std.testing.expectEqualStrings("ls-files", argv[2]);
    try std.testing.expectEqualStrings("-z", argv[3]);
    try std.testing.expectEqualStrings("--others", argv[4]);
    try std.testing.expectEqualStrings("--ignored", argv[5]);
    try std.testing.expectEqualStrings("--directory", argv[6]);
    try std.testing.expectEqualStrings("--exclude-standard", argv[7]);
}

test "workspace directory provider parses only ignored directory entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var ignored = try parseRawIgnoredDirectories(
        arena_state.allocator(),
        "ignored-dir/\x00ignored.txt\x00nested/ignored/\x00",
    );
    defer ignored.deinit(arena_state.allocator());

    try std.testing.expect(ignored.contains("ignored-dir"));
    try std.testing.expect(ignored.contains("nested/ignored"));
    try std.testing.expect(!ignored.contains("ignored.txt"));
}

test "workspace file provider caps candidates and reports incomplete status" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const raw = "a.zig\x00b.zig\x00c.zig\x00";
    const result = try parseRawList(arena_state.allocator(), raw, .git, .{ .candidate_cap = 2 });

    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expect(result.incomplete);
    try std.testing.expectEqual(CapReason.candidate_cap, result.cap_reason.?);
    try std.testing.expectEqualStrings("a.zig", result.files[0]);
    try std.testing.expectEqualStrings("b.zig", result.files[1]);
}

test "workspace file provider applies bytewise ordering to Git results when requested" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try parseRawList(arena_state.allocator(), "z.zig\x00a.zig\x00m.zig\x00", .git, .{ .sort_paths = true });

    try std.testing.expectEqualStrings("a.zig", result.files[0]);
    try std.testing.expectEqualStrings("m.zig", result.files[1]);
    try std.testing.expectEqualStrings("z.zig", result.files[2]);
}

test "workspace file provider git discovery includes tracked build files and skips hidden directories" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const raw = "build/script.ts\x00.eslint-plugin-local/rule.ts\x00src/.esbuild.ts\x00src/main.ts\x00";
    const result = try parseRawList(arena_state.allocator(), raw, .git, .{});

    try std.testing.expectEqual(@as(usize, 3), result.files.len);
    try std.testing.expect(containsPath(result.files, "build/script.ts"));
    try std.testing.expect(containsPath(result.files, "src/.esbuild.ts"));
    try std.testing.expect(containsPath(result.files, "src/main.ts"));
    try std.testing.expect(!containsPath(result.files, ".eslint-plugin-local/rule.ts"));
}

test "workspace file provider recursive fallback skips ignored directories and includes nested files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "src/main.zig", "main\n");
    try writeTestFile(tmp.dir, "src/nested/lib.zig", "lib\n");
    try writeTestFile(tmp.dir, "node_modules/pkg/ignored.zig", "ignored\n");
    try writeTestFile(tmp.dir, ".zig-cache/o/ignored.o", "ignored\n");

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try discover(arena_state.allocator(), root, .{ .force_fallback = true });

    try std.testing.expectEqual(Source.recursive, result.source);
    try std.testing.expect(containsPath(result.files, "src/main.zig"));
    try std.testing.expect(containsPath(result.files, "src/nested/lib.zig"));
    try std.testing.expect(!containsPath(result.files, "node_modules/pkg/ignored.zig"));
    try std.testing.expect(!containsPath(result.files, ".zig-cache/o/ignored.o"));
}

test "workspace directory provider fallback includes nested empty directories and skips ignored roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "empty/deep");
    try tmp.dir.createDirPath(std.testing.io, ".hidden/empty");
    try tmp.dir.createDirPath(std.testing.io, "ignored-dir/deep");

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try discoverDirectoriesWithStop(
        arena_state.allocator(),
        root,
        .{
            .force_fallback = true,
            .include_hidden = true,
            .ignored_names = &.{"ignored-dir"},
        },
        null,
        null,
    );

    try std.testing.expectEqual(Source.recursive, result.source);
    try std.testing.expect(containsPath(result.directories, ".hidden"));
    try std.testing.expect(containsPath(result.directories, ".hidden/empty"));
    try std.testing.expect(containsPath(result.directories, "empty"));
    try std.testing.expect(containsPath(result.directories, "empty/deep"));
    try std.testing.expect(!containsPath(result.directories, "ignored-dir"));
}

test "workspace directory provider honors its cap and cancellation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "first", .default_dir);
    try tmp.dir.createDir(std.testing.io, "second", .default_dir);

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try discoverDirectoriesWithStop(
        arena_state.allocator(),
        root,
        .{ .candidate_cap = 1, .force_fallback = true },
        null,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), result.directories.len);
    try std.testing.expect(result.incomplete);
    try std.testing.expectEqual(CapReason.candidate_cap, result.cap_reason.?);

    var stop_requested = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Canceled,
        discoverDirectoriesWithStop(arena_state.allocator(), root, .{ .force_fallback = true }, &stop_requested, null),
    );
}

test "workspace file provider recursive fallback does not recurse symlink directories" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "real/inside.txt", "inside\n");
    try tmp.dir.symLink(std.testing.io, "real", "linked", .{ .is_directory = true });

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try discover(arena_state.allocator(), root, .{ .force_fallback = true });

    try std.testing.expect(containsPath(result.files, "linked"));
    try std.testing.expect(!containsPath(result.files, "linked/inside.txt"));
}

test "workspace file provider overlong paths are skipped without aborting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const long_path = try std.testing.allocator.alloc(u8, max_relative_path_bytes + 1);
    defer std.testing.allocator.free(long_path);
    @memset(long_path, 'a');
    const raw = try std.mem.concat(std.testing.allocator, u8, &.{ "kept.zig\x00", long_path, "\x00also-kept.zig\x00" });
    defer std.testing.allocator.free(raw);

    const result = try parseRawList(arena_state.allocator(), raw, .git, .{});

    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expectEqual(@as(usize, 1), result.skipped_overlong);
    try std.testing.expect(containsPath(result.files, "kept.zig"));
    try std.testing.expect(containsPath(result.files, "also-kept.zig"));
}

test "workspace file provider falls back when git is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "nested/file.txt", "file\n");

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try discover(arena_state.allocator(), root, .{ .force_fallback = true });

    try std.testing.expectEqual(Source.recursive, result.source);
    try std.testing.expect(containsPath(result.files, "nested/file.txt"));
}

test "workspace file provider treats empty successful git result as authoritative" {
    if (comptime @import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "untracked.txt", "not tracked\n");

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try runGitForTest(alloc, root, &.{ "git", "init", "--quiet" });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try discoverWithStop(
        arena_state.allocator(),
        root,
        .{ .git_worktree_is_authoritative = true },
        null,
        "git",
    );

    try std.testing.expectEqual(Source.git, result.source);
    try std.testing.expectEqual(@as(usize, 0), result.files.len);
}

test "workspace file provider walks a Git worktree when no trusted Git executable is available" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".git", .default_dir);
    try writeTestFile(tmp.dir, "fallback.txt", "fallback\n");

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try discoverWithStop(
        arena_state.allocator(),
        root,
        .{ .git_worktree_is_authoritative = true },
        null,
        null,
    );

    try std.testing.expectEqual(Source.recursive, result.source);
    try std.testing.expect(containsPath(result.files, "fallback.txt"));
}

test "workspace file provider does not recurse after a selected Git executable fails" {
    if (comptime builtin.os.tag == .wasi) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, ".git", "gitdir: /missing\n");
    try writeTestFile(tmp.dir, "untracked.txt", "not tracked\n");

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.GitFileListFailed,
        discoverWithStop(
            arena_state.allocator(),
            root,
            .{ .git_worktree_is_authoritative = true },
            null,
            "/definitely/missing/fx-git",
        ),
    );
}

test "workspace file provider git result contains tracked files only" {
    if (comptime @import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, ".gitignore", "ignored.txt\n");
    try writeTestFile(tmp.dir, "tracked.txt", "tracked\n");
    try writeTestFile(tmp.dir, ".hidden/tracked.txt", "hidden\n");
    try writeTestFile(tmp.dir, "ignored.txt", "ignored\n");
    try writeTestFile(tmp.dir, "untracked.txt", "untracked\n");

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try runGitForTest(alloc, root, &.{ "git", "init", "--quiet" });
    try runGitForTest(alloc, root, &.{ "git", "add", ".gitignore", "tracked.txt", ".hidden/tracked.txt" });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try discoverWithStop(arena_state.allocator(), root, .{ .include_hidden = true }, null, "git");

    try std.testing.expectEqual(Source.git, result.source);
    try std.testing.expect(containsPath(result.files, ".gitignore"));
    try std.testing.expect(containsPath(result.files, "tracked.txt"));
    try std.testing.expect(containsPath(result.files, ".hidden/tracked.txt"));
    try std.testing.expect(!containsPath(result.files, "ignored.txt"));
    try std.testing.expect(!containsPath(result.files, "untracked.txt"));
}

test "workspace directory provider uses Git ignores without collapsing nested empty directories" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, ".gitignore", "ignored-dir/\n");
    try tmp.dir.createDirPath(std.testing.io, "empty-dir");
    try tmp.dir.createDirPath(std.testing.io, "nested-empty/deep");
    try tmp.dir.createDirPath(std.testing.io, ".hidden/empty");
    try tmp.dir.createDirPath(std.testing.io, "ignored-dir/deep");
    try writeTestFile(tmp.dir, "build/tracked.txt", "tracked\n");

    const alloc = std.testing.allocator;
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try runGitForTest(alloc, root, &.{ "git", "init", "--quiet" });
    try runGitForTest(alloc, root, &.{ "git", "add", "build/tracked.txt" });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try discoverDirectoriesWithStop(
        arena_state.allocator(),
        root,
        .{ .include_hidden = true },
        null,
        "git",
    );

    try std.testing.expectEqual(Source.git, result.source);
    try std.testing.expect(containsPath(result.directories, ".hidden"));
    try std.testing.expect(containsPath(result.directories, ".hidden/empty"));
    try std.testing.expect(containsPath(result.directories, "empty-dir"));
    try std.testing.expect(containsPath(result.directories, "nested-empty"));
    try std.testing.expect(containsPath(result.directories, "nested-empty/deep"));
    try std.testing.expect(containsPath(result.directories, "build"));
    try std.testing.expect(!containsPath(result.directories, "ignored-dir"));
}

test "workspace file provider cancellable fallback stops before traversal" {
    var stop_requested = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Canceled,
        discoverCancellable(std.testing.allocator, "/unused", .{ .force_fallback = true }, &stop_requested),
    );
}

test "workspace file provider cancellation terminates an active child" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    var stop_requested = std.atomic.Value(bool).init(false);
    const RequestStop = struct {
        fn run(stop: *std.atomic.Value(bool)) void {
            sleepBlocking(20);
            stop.store(true, .seq_cst);
        }
    };
    const stop_thread = try std.Thread.spawn(.{}, RequestStop.run, .{&stop_requested});
    defer stop_thread.join();

    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    try std.testing.expectError(
        error.Canceled,
        runCancellable(
            std.testing.allocator,
            .{
                .argv = &.{ "/bin/sleep", "60" },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            },
            &stop_requested,
        ),
    );
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();
    try std.testing.expect(elapsed_ms < 1000);
}

fn sleepBlocking(milliseconds: u64) void {
    var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
    sleep_io_backend.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
}

fn runGitForTest(alloc: Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

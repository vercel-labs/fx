//! Git steps on this machine for a workspace sandbox. They read the working
//! copy as `git add -A` sees it, through a temporary index, so the user's
//! index, HEAD, and branches never change.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const sync_plan = @import("sync_plan.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ NotARepository, GitFailed, OutOfMemory };

const max_stdout_bytes = 64 * 1024 * 1024;
const max_stderr_bytes = 1024 * 1024;
/// Paths per `git hash-object` run, so one run stays well inside argv limits.
const max_hash_batch = 200;
const object_id_len = 40;
/// What `localBlobs` reports for a symbolic link, and for any other non-file kind.
/// Neither is a blob id, so the 3-way rule holds such a path as a conflict.
const link_marker = "link";
const other_marker = "other";
const temp_index_prefix = "fx-sandbox-index-";
const identity_env: []const [2][]const u8 = &.{
    .{ "GIT_AUTHOR_NAME", "fx" },
    .{ "GIT_AUTHOR_EMAIL", "fx@localhost" },
    .{ "GIT_COMMITTER_NAME", "fx" },
    .{ "GIT_COMMITTER_EMAIL", "fx@localhost" },
    .{ "GIT_AUTHOR_DATE", "1970-01-01T00:00:00Z" },
    .{ "GIT_COMMITTER_DATE", "1970-01-01T00:00:00Z" },
};
const no_extra_env: []const [2][]const u8 = &.{};

/// Gives each temporary index in this process its own name.
var temp_index_counter = std.atomic.Value(u64).init(0);

/// The repository's top folder for `path`.
pub fn topLevel(arena: Allocator, path: []const u8) Error![]const u8 {
    const run = try runGit(arena, path, "rev-parse", &.{ "rev-parse", "--show-toplevel" }, no_extra_env);
    if (run.code == 128) return error.NotARepository;
    if (run.code != 0) {
        debug_trace.logf("sandbox", "git rev-parse failed exit={d}", .{run.code});
        return error.GitFailed;
    }
    const top = trimLine(run.stdout);
    if (top.len == 0) return error.NotARepository;
    return top;
}

/// The tree id of the working copy, as `git add -A` would stage it. The
/// user's index is only read, never written.
pub fn snapshotTree(arena: Allocator, top: []const u8) Error![]const u8 {
    const index_rel = trimLine(try runGitOk(arena, top, "rev-parse", &.{ "rev-parse", "--git-path", "index" }, no_extra_env));
    const index_path = try absoluteUnder(arena, top, index_rel);
    const temp = try tempIndexPath(arena);
    const temp_lock = try arena.print("{s}.lock", .{temp});
    defer removeTempIndex(temp, temp_lock);

    // A missing index is fine: git then adds from an empty index.
    io_mod.copyFileAtomic(arena, index_path, temp) catch |err| {
        if (err != error.FileNotFound) return copyFailure(err);
    };
    const index_env = [_][2][]const u8{.{ "GIT_INDEX_FILE", temp }};
    _ = try runGitOk(arena, top, "add", &.{ "add", "-A" }, &index_env);
    const tree = trimLine(try runGitOk(arena, top, "write-tree", &.{"write-tree"}, &index_env));
    if (!isObjectId(tree)) return error.GitFailed;
    return tree;
}

/// Keeps `tree` reachable under `refs/fx/sandbox/<name>`, so `git gc` keeps
/// it. `name` uses only `a-z`, `0-9`, and `-`. The commit has a fixed date,
/// so the same tree always gives the same commit.
pub fn keepTree(arena: Allocator, top: []const u8, name: []const u8, tree: []const u8) Error!void {
    if (!isSafeName(name) or !isObjectId(tree)) return error.GitFailed;
    const commit = trimLine(try runGitOk(
        arena,
        top,
        "commit-tree",
        &.{ "-c", "commit.gpgSign=false", "commit-tree", tree, "-m", "fx sandbox sync" },
        identity_env,
    ));
    if (!isObjectId(commit)) return error.GitFailed;
    const ref = try arena.print("refs/fx/sandbox/{s}", .{name});
    _ = try runGitOk(arena, top, "update-ref", &.{ "update-ref", ref, commit }, no_extra_env);
}

/// True when git holds `tree`. Any failure to ask counts as not held.
pub fn hasTree(arena: Allocator, top: []const u8, tree: []const u8) bool {
    if (!isObjectId(tree)) return false;
    const target = arena.print("{s}^{{tree}}", .{tree}) catch return false;
    const run = runGit(arena, top, "cat-file", &.{ "cat-file", "-e", target }, no_extra_env) catch return false;
    return run.code == 0;
}

/// `git diff-tree -r -z --no-renames --name-status <old> <new>` output, for
/// `sync_plan.planUpload`.
pub fn diffTrees(arena: Allocator, top: []const u8, old_tree: []const u8, new_tree: []const u8) Error![]const u8 {
    if (!isObjectId(old_tree) or !isObjectId(new_tree)) return error.GitFailed;
    return runGitOk(
        arena,
        top,
        "diff-tree",
        &.{ "-c", "core.quotepath=off", "diff-tree", "-r", "-z", "--no-renames", "--name-status", old_tree, new_tree },
        no_extra_env,
    );
}

/// Every file path in `tree`, for a first sync.
pub fn listTree(arena: Allocator, top: []const u8, tree: []const u8) Error![]const []const u8 {
    if (!isObjectId(tree)) return error.GitFailed;
    const out = try runGitOk(
        arena,
        top,
        "ls-tree",
        &.{ "-c", "core.quotepath=off", "ls-tree", "-r", "-z", "--name-only", tree },
        no_extra_env,
    );
    var paths: std.ArrayList([]const u8) = .empty;
    var rest = out;
    while (rest.len > 0) {
        const end = std.mem.findScalar(u8, rest, 0) orelse return error.GitFailed;
        try paths.append(arena, rest[0..end]);
        rest = rest[end + 1 ..];
    }
    return paths.toOwnedSlice(arena);
}

/// True when `tree` holds a submodule entry (mode 160000).
pub fn hasGitlinks(arena: Allocator, top: []const u8, tree: []const u8) Error!bool {
    if (!isObjectId(tree)) return error.GitFailed;
    const out = try runGitOk(
        arena,
        top,
        "ls-tree",
        &.{ "-c", "core.quotepath=off", "ls-tree", "-r", "-z", tree },
        no_extra_env,
    );
    var rest = out;
    while (rest.len > 0) {
        const end = std.mem.findScalar(u8, rest, 0) orelse return error.GitFailed;
        if (std.mem.startsWith(u8, rest[0..end], "160000 ")) return true;
        rest = rest[end + 1 ..];
    }
    return false;
}

/// The blob id each path has here now, as `git add` would compute it. Null
/// for a missing path, `link` for a symbolic link. Paths are hashed without
/// `-w`, so nothing is written to the object store.
pub fn localBlobs(arena: Allocator, top: []const u8, paths: []const []const u8) Error![]const ?[]const u8 {
    const zio = io_mod.getIo();
    const result = try arena.alloc(?[]const u8, paths.len);
    var to_hash: std.ArrayList([]const u8) = .empty;
    var hash_slots: std.ArrayList(usize) = .empty;
    for (paths, 0..) |path, slot| {
        if (!sync_plan.safeRelativePath(path)) {
            result[slot] = other_marker;
            continue;
        }
        const full = try arena.print("{s}/{s}", .{ top, path });
        const stat = std.Io.Dir.cwd().statFile(zio, full, .{ .follow_symlinks = false }) catch |err| {
            result[slot] = if (err == error.FileNotFound) null else other_marker;
            continue;
        };
        switch (stat.kind) {
            .file => {
                try to_hash.append(arena, path);
                try hash_slots.append(arena, slot);
            },
            .sym_link => result[slot] = link_marker,
            else => result[slot] = other_marker,
        }
    }

    var start: usize = 0;
    while (start < to_hash.items.len) {
        const end = @min(start + max_hash_batch, to_hash.items.len);
        var args: std.ArrayList([]const u8) = .empty;
        try args.append(arena, "hash-object");
        try args.append(arena, "--");
        try args.appendSlice(arena, to_hash.items[start..end]);
        const out = try runGitOk(arena, top, "hash-object", args.items, no_extra_env);
        var lines = std.mem.splitScalar(u8, out, '\n');
        for (hash_slots.items[start..end]) |slot| {
            const line = lines.next() orelse return error.GitFailed;
            if (!isObjectId(line)) return error.GitFailed;
            result[slot] = line;
        }
        start = end;
    }
    return result;
}

const Run = struct {
    code: i64,
    stdout: []u8,
};

/// Runs `git` in `cwd` and returns its exit code and stdout. A run that
/// cannot start is logged by name and fails.
fn runGit(
    arena: Allocator,
    cwd: []const u8,
    name: []const u8,
    args: []const []const u8,
    extra: []const [2][]const u8,
) Error!Run {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "git");
    try argv.appendSlice(arena, args);
    var environment = try environmentWith(arena, extra);
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
        .stdout_limit = .limited(max_stdout_bytes),
        .stderr_limit = .limited(max_stderr_bytes),
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("sandbox", "git {s} could not start err={s}", .{ name, @errorName(err) });
        return error.GitFailed;
    };
    const code: i64 = switch (result.term) {
        .exited => |exit_code| exit_code,
        else => -1,
    };
    return .{ .code = code, .stdout = result.stdout };
}

/// Like `runGit`, but a non-zero exit fails. The log names the subcommand only.
fn runGitOk(
    arena: Allocator,
    cwd: []const u8,
    name: []const u8,
    args: []const []const u8,
    extra: []const [2][]const u8,
) Error![]u8 {
    const run = try runGit(arena, cwd, name, args, extra);
    if (run.code != 0) {
        debug_trace.logf("sandbox", "git {s} failed exit={d}", .{ name, run.code });
        return error.GitFailed;
    }
    return run.stdout;
}

/// A copy of this process's environment with `extra` added or replaced.
fn environmentWith(arena: Allocator, extra: []const [2][]const u8) Error!std.process.Environ.Map {
    var environment = io_mod.cloneEnvironMap(arena) catch |err| return failureFrom(err);
    for (extra) |pair| try environment.put(pair[0], pair[1]);
    return environment;
}

/// Keeps out-of-memory as itself. Every other failure is a git failure.
fn failureFrom(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.GitFailed;
}

fn copyFailure(err: anyerror) Error {
    debug_trace.logf("sandbox", "could not copy the git index err={s}", .{@errorName(err)});
    return failureFrom(err);
}

/// `<TMPDIR or /tmp>/fx-sandbox-index-<pid>-<counter>`.
fn tempIndexPath(arena: Allocator) Allocator.Error![]const u8 {
    const dir = std.mem.trimEnd(u8, io_mod.getenv("TMPDIR") orelse "/tmp", "/");
    const count = temp_index_counter.fetchAdd(1, .monotonic);
    return arena.print("{s}/{s}{d}-{d}", .{ dir, temp_index_prefix, processId(), count });
}

/// Removes the temporary index and its lock. A file that is already gone is fine.
fn removeTempIndex(temp: []const u8, temp_lock: []const u8) void {
    const zio = io_mod.getIo();
    std.Io.Dir.deleteFileAbsolute(zio, temp) catch {};
    std.Io.Dir.deleteFileAbsolute(zio, temp_lock) catch {};
}

fn processId() u64 {
    return @intCast(std.c.getpid());
}

fn absoluteUnder(arena: Allocator, top: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, path, "/")) return path;
    return arena.print("{s}/{s}", .{ top, path });
}

fn trimLine(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn isObjectId(text: []const u8) bool {
    if (text.len != object_id_len) return false;
    for (text) |byte| {
        const hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!hex) return false;
    }
    return true;
}

fn isSafeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        const allowed = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-';
        if (!allowed) return false;
    }
    return true;
}

// ---- tests ----

/// False when `git` cannot run here. The tests then skip.
fn gitAvailable() bool {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const run = runGit(arena_state.allocator(), ".", "version", &.{"--version"}, no_extra_env) catch return false;
    return run.code == 0;
}

/// A repository in `tmp` with `a.txt` committed as `one`. Returns its top folder.
fn makeRepo(arena: Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    const top = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    _ = try runGitOk(arena, top, "init", &.{ "init", "-q" }, no_extra_env);
    _ = try runGitOk(arena, top, "config", &.{ "config", "user.email", "t@t" }, no_extra_env);
    _ = try runGitOk(arena, top, "config", &.{ "config", "user.name", "t" }, no_extra_env);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "a.txt", .data = "one\n" });
    _ = try runGitOk(arena, top, "add", &.{ "add", "a.txt" }, no_extra_env);
    _ = try runGitOk(arena, top, "commit", &.{ "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init" }, no_extra_env);
    return top;
}

fn revParse(arena: Allocator, top: []const u8, rev: []const u8) ![]const u8 {
    return trimLine(try runGitOk(arena, top, "rev-parse", &.{ "rev-parse", rev }, no_extra_env));
}

fn readIndexBytes(arena: Allocator, top: []const u8) ![]u8 {
    const path = try absoluteUnder(arena, top, ".git/index");
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{});
    defer file.close(zio);
    return io_mod.readFileToEnd(arena, &file, 16 * 1024 * 1024);
}

fn listContains(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, needle)) return true;
    }
    return false;
}

fn expectPaths(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

/// Fails when a temporary index from this process is still in the temp folder.
fn expectNoTempIndex(arena: Allocator) !void {
    const zio = io_mod.getIo();
    const dir_path = std.mem.trimEnd(u8, io_mod.getenv("TMPDIR") orelse "/tmp", "/");
    const prefix = try arena.print("{s}{d}-", .{ temp_index_prefix, processId() });
    var dir = try std.Io.Dir.openDirAbsolute(zio, dir_path, .{ .iterate = true });
    defer dir.close(zio);
    var it = dir.iterate();
    while (try it.next(zio)) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) return error.TempIndexLeaked;
    }
}

fn removeAbsoluteFolder(parent_path: []const u8, name: []const u8) void {
    const zio = io_mod.getIo();
    var parent = std.Io.Dir.openDirAbsolute(zio, parent_path, .{}) catch return;
    defer parent.close(zio);
    parent.deleteTree(zio, name) catch {};
}

test "snapshotTree sees untracked files and leaves the index alone" {
    if (!gitAvailable()) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try makeRepo(arena, &tmp);

    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "b.txt", .data = "two\n" });
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "a.txt", .data = "uno\n" });
    const index_before = try readIndexBytes(arena, top);
    const tree = try snapshotTree(arena, top);
    const index_after = try readIndexBytes(arena, top);
    try std.testing.expectEqualSlices(u8, index_before, index_after);

    const listed = try listTree(arena, top, tree);
    try std.testing.expect(listContains(listed, "a.txt"));
    try std.testing.expect(listContains(listed, "b.txt"));
    try expectNoTempIndex(arena);

    const status = try runGitOk(arena, top, "status", &.{ "status", "--porcelain" }, no_extra_env);
    try std.testing.expectEqualStrings(" M a.txt\n?? b.txt\n", status);
}

test "snapshotTree respects .gitignore" {
    if (!gitAvailable()) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try makeRepo(arena, &tmp);

    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = ".gitignore", .data = "zig-out/\n" });
    try tmp.dir.createDir(io_mod.getIo(), "zig-out", std.Io.File.Permissions.fromMode(0o700));
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "zig-out/x", .data = "built\n" });

    const tree = try snapshotTree(arena, top);
    const listed = try listTree(arena, top, tree);
    try std.testing.expect(listContains(listed, "a.txt"));
    try std.testing.expect(!listContains(listed, "zig-out/x"));
}

test "keepTree makes a fixed commit and a ref" {
    if (!gitAvailable()) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try makeRepo(arena, &tmp);

    const tree = try snapshotTree(arena, top);
    const head_before = try revParse(arena, top, "HEAD");
    const branches_before = try runGitOk(arena, top, "for-each-ref", &.{ "for-each-ref", "refs/heads" }, no_extra_env);

    try keepTree(arena, top, "fx-ws-1", tree);
    const first = try revParse(arena, top, "refs/fx/sandbox/fx-ws-1");
    try keepTree(arena, top, "fx-ws-1", tree);
    const second = try revParse(arena, top, "refs/fx/sandbox/fx-ws-1");
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(hasTree(arena, top, tree));

    try std.testing.expectError(error.GitFailed, keepTree(arena, top, "bad/name", tree));

    try std.testing.expectEqualStrings(head_before, try revParse(arena, top, "HEAD"));
    try std.testing.expectEqualStrings(
        branches_before,
        try runGitOk(arena, top, "for-each-ref", &.{ "for-each-ref", "refs/heads" }, no_extra_env),
    );
}

test "hasGitlinks is false for a plain tree and true with a submodule entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!gitAvailable()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try makeRepo(arena, &tmp);

    const plain = try snapshotTree(arena, top);
    try std.testing.expect(!(try hasGitlinks(arena, top, plain)));

    _ = try runGitOk(arena, top, "update-index", &.{ "update-index", "--add", "--cacheinfo", "160000,0123456789abcdef0123456789abcdef01234567,sub" }, no_extra_env);
    const with_sub = trimLine(try runGitOk(arena, top, "write-tree", &.{"write-tree"}, no_extra_env));
    try std.testing.expect(try hasGitlinks(arena, top, with_sub));
}

test "diffTrees lists sends and removes" {
    if (!gitAvailable()) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try makeRepo(arena, &tmp);

    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "c.txt", .data = "c\n" });
    const first_tree = try snapshotTree(arena, top);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "a.txt", .data = "uno\n" });
    try tmp.dir.deleteFile(io_mod.getIo(), "c.txt");
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "d.txt", .data = "d\n" });
    const second_tree = try snapshotTree(arena, top);

    const diff = try diffTrees(arena, top, first_tree, second_tree);
    const none_paths: []const []const u8 = &.{};
    const none_flags: []const bool = &.{};
    const plan = try sync_plan.planUpload(arena, diff, none_paths, none_flags);
    try expectPaths(&.{ "a.txt", "d.txt" }, plan.send);
    try expectPaths(&.{"c.txt"}, plan.remove);
}

test "localBlobs match git and mark missing files and links" {
    if (!gitAvailable()) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try makeRepo(arena, &tmp);

    try tmp.dir.symLink(io_mod.getIo(), "a.txt", "l", .{ .is_directory = false });
    const expected = try runGitOk(arena, top, "hash-object", &.{ "hash-object", "a.txt" }, no_extra_env);
    const blobs = try localBlobs(arena, top, &.{ "a.txt", "missing.txt", "l" });
    try std.testing.expectEqual(@as(usize, 3), blobs.len);
    try std.testing.expectEqualStrings(trimLine(expected), blobs[0].?);
    try std.testing.expect(blobs[1] == null);
    try std.testing.expectEqualStrings("link", blobs[2].?);
}

test "topLevel finds the top and refuses a plain folder" {
    if (!gitAvailable()) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try makeRepo(arena, &tmp);

    try tmp.dir.createDir(io_mod.getIo(), "sub", std.Io.File.Permissions.fromMode(0o700));
    const sub = try arena.print("{s}/sub", .{top});
    try std.testing.expectEqualStrings(top, try topLevel(arena, sub));

    // The test folder sits inside this worktree's own repository, so the
    // plain folder is made under the system temp folder instead.
    const system_tmp = std.mem.trimEnd(u8, io_mod.getenv("TMPDIR") orelse "/tmp", "/");
    const plain_name = try arena.print("fx-local-git-plain-{d}-{d}", .{ processId(), temp_index_counter.fetchAdd(1, .monotonic) });
    const plain = try arena.print("{s}/{s}", .{ system_tmp, plain_name });
    try std.Io.Dir.createDirAbsolute(io_mod.getIo(), plain, std.Io.File.Permissions.fromMode(0o700));
    defer removeAbsoluteFolder(system_tmp, plain_name);
    try std.testing.expectError(error.NotARepository, topLevel(arena, plain));
}

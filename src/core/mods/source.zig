//! Where a mod comes from: a local folder, or a git URL with an optional
//! `@<ref>`. `parse` is pure. `fetch` clones a git source into a temp folder
//! through an `Ops` table, so the front door supplies the process runner, and
//! the runner owns the deadline and the cancel flag. Imports only `std`.

const std = @import("std");

pub const clone_deadline_ms: u64 = 60_000;
pub const max_source_bytes: usize = 1024;
pub const max_ref_bytes: usize = 200;
pub const commit_hex_bytes: usize = 40;
pub const token_hex_bytes: usize = 16;

const clone_folder_name = "mod";
const hooks_off_config = "core.hooksPath=/dev/null";

pub const Git = struct {
    url: []const u8,
    /// Null when no `@<ref>` was given, which means the default branch.
    ref: ?[]const u8,
};

pub const Problem = enum { empty, too_long, bad_characters, bad_ref };

pub const Parsed = union(enum) {
    git: Git,
    /// Not a URL: the caller must find a folder at this path.
    local: []const u8,
    invalid: Problem,
};

/// Classifies the argument of `fx mod add` or `fx mod update`. A URL starts
/// with `https://`, `ssh://`, `file://` or `git@host:`; any other argument is
/// a local path. The ref is the text after the last `@` that comes after the
/// path's start, so `git@host:org/repo` has no ref and `git@host:org/repo@v1`
/// has `v1`.
pub fn parse(arg: []const u8) Parsed {
    if (arg.len == 0) return .{ .invalid = .empty };
    if (arg.len > max_source_bytes) return .{ .invalid = .too_long };
    if (hasControlByte(arg)) return .{ .invalid = .bad_characters };
    if (!isUrl(arg)) return .{ .local = arg };
    if (std.mem.findScalar(u8, arg, ' ') != null) return .{ .invalid = .bad_characters };
    const split = splitRef(arg);
    if (split.ref) |ref| {
        if (!isValidRef(ref)) return .{ .invalid = .bad_ref };
    }
    return .{ .git = .{ .url = split.url, .ref = split.ref } };
}

fn hasControlByte(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

fn isUrl(text: []const u8) bool {
    const schemes = [_][]const u8{ "https://", "ssh://", "file://" };
    for (schemes) |scheme| {
        if (std.mem.startsWith(u8, text, scheme)) return true;
    }
    return std.mem.startsWith(u8, text, "git@") and std.mem.findScalar(u8, text, ':') != null;
}

const Split = struct {
    url: []const u8,
    ref: ?[]const u8,
};

fn splitRef(arg: []const u8) Split {
    const path_start = pathStart(arg) orelse return .{ .url = arg, .ref = null };
    const last_slash = std.mem.findScalarLast(u8, arg, '/') orelse 0;
    const search_from = @max(path_start, last_slash);
    const at = std.mem.findScalarPos(u8, arg, search_from, '@') orelse return .{ .url = arg, .ref = null };
    return .{ .url = arg[0..at], .ref = arg[at + 1 ..] };
}

/// Where the path starts: the first `:` of `git@host:path`, or the first `/`
/// after `scheme://host`. A URL with no path has no ref.
fn pathStart(arg: []const u8) ?usize {
    if (std.mem.startsWith(u8, arg, "git@")) return std.mem.findScalar(u8, arg, ':');
    const scheme_end = (std.mem.find(u8, arg, "://") orelse return null) + 3;
    return std.mem.findScalarPos(u8, arg, scheme_end, '/');
}

fn isValidRef(ref: []const u8) bool {
    if (ref.len == 0 or ref.len > max_ref_bytes) return false;
    if (ref[0] == '-' or ref[0] == '/') return false;
    if (std.mem.find(u8, ref, "..") != null) return false;
    for (ref) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-' or byte == '/' or byte == '+';
        if (!ok) return false;
    }
    return true;
}

fn isCommit(text: []const u8) bool {
    if (text.len != commit_hex_bytes) return false;
    for (text) |byte| {
        const ok = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!ok) return false;
    }
    return true;
}

/// The `.fx-mod-source.json` the store writes into each version folder.
pub const Record = struct {
    source: []const u8,
    ref: ?[]const u8,
    commit: ?[]const u8,
    pinned: bool,
};

pub const RecordError = error{ BadRecord, OutOfMemory };

pub fn encodeRecord(alloc: std.mem.Allocator, record: Record) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("source") catch return error.OutOfMemory;
    jw.write(record.source) catch return error.OutOfMemory;
    jw.objectField("ref") catch return error.OutOfMemory;
    jw.write(record.ref) catch return error.OutOfMemory;
    jw.objectField("commit") catch return error.OutOfMemory;
    jw.write(record.commit) catch return error.OutOfMemory;
    jw.objectField("pinned") catch return error.OutOfMemory;
    jw.write(record.pinned) catch return error.OutOfMemory;
    jw.endObject() catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Every slice of the result lives in `arena`. A record whose fields break
/// their limits is refused, so a decoded record always obeys them.
pub fn decodeRecord(arena: std.mem.Allocator, bytes: []const u8) RecordError!Record {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadRecord,
    };
    if (root != .object) return error.BadRecord;
    const fields = root.object;
    if (fields.count() != 4) return error.BadRecord;
    const source_val = fields.get("source") orelse return error.BadRecord;
    const ref_val = fields.get("ref") orelse return error.BadRecord;
    const commit_val = fields.get("commit") orelse return error.BadRecord;
    const pinned_val = fields.get("pinned") orelse return error.BadRecord;
    if (source_val != .string or pinned_val != .bool) return error.BadRecord;
    const ref = switch (ref_val) {
        .null => null,
        .string => |s| s,
        else => return error.BadRecord,
    };
    const commit = switch (commit_val) {
        .null => null,
        .string => |s| s,
        else => return error.BadRecord,
    };
    const record: Record = .{
        .source = source_val.string,
        .ref = ref,
        .commit = commit,
        .pinned = pinned_val.bool,
    };
    if (!recordWithinLimits(record)) return error.BadRecord;
    return record;
}

fn recordWithinLimits(record: Record) bool {
    if (record.source.len == 0 or record.source.len > max_source_bytes) return false;
    if (hasControlByte(record.source)) return false;
    if (record.ref) |ref| {
        if (!isValidRef(ref)) return false;
    }
    if (record.commit) |commit| {
        if (!isCommit(commit)) return false;
    }
    return record.pinned == (record.ref != null);
}

pub fn folderRecord(alloc: std.mem.Allocator, folder: []const u8) std.mem.Allocator.Error![]u8 {
    return encodeRecord(alloc, .{ .source = folder, .ref = null, .commit = null, .pinned = false });
}

pub const Request = struct {
    argv: []const []const u8,
    /// Time left for this command, in ms. The runner stops the command at it.
    timeout_ms: u64,
    /// When set and true, the runner stops the command.
    cancel: ?*const std.atomic.Value(bool),
};

pub const Run = union(enum) {
    /// `stdout` and `stderr` belong to the caller, who frees them with the
    /// allocator the runner was given.
    exited: Exited,
    timed_out,
    cancelled,
    signaled,
    too_large,
    spawn_failed,

    pub const Exited = struct {
        code: u8,
        stdout: []u8,
        stderr: []u8,
    };
};

pub const Ops = struct {
    io: std.Io,
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, request: Request) anyerror!Run,
    fill_token: *const fn (ctx: ?*anyopaque, io: std.Io, out_hex: *[token_hex_bytes]u8) void,
};

pub const Failure = enum { timed_out, cancelled, signaled, too_large, spawn_failed, git_failed, bad_commit };

pub const Failed = struct {
    kind: Failure,
    /// The first line git printed, when git failed. Plain text: the caller
    /// makes it terminal-safe before it is drawn.
    detail: []const u8,
};

pub const Fetched = struct {
    /// The clone without `.git`: the folder to install from.
    dir: []const u8,
    /// The temp folder that holds `dir`. Pass it to `discard` when done.
    temp: []const u8,
    commit: []const u8,
    /// The encoded source record for this clone.
    record: []const u8,
};

pub const FetchResult = union(enum) {
    ok: Fetched,
    failed: Failed,
};

/// Clones `git` into a fresh temp folder under `scratch_root`, checks out the
/// ref, and records the commit. The whole fetch shares one deadline of
/// `clone_deadline_ms`. Every slice of the result lives in `alloc`. A failed
/// fetch leaves no temp folder behind.
pub fn fetch(
    alloc: std.mem.Allocator,
    ops: Ops,
    git: Git,
    scratch_root: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !FetchResult {
    var token: [token_hex_bytes]u8 = undefined;
    ops.fill_token(ops.ctx, ops.io, &token);
    const token_text: []const u8 = &token;
    const temp = try std.Io.Dir.path.join(alloc, &.{ scratch_root, token_text });
    try std.Io.Dir.cwd().createDirPath(ops.io, temp);
    const result = try cloneInto(alloc, ops, git, temp, cancel);
    switch (result) {
        .ok => {},
        .failed => discard(ops.io, temp),
    }
    return result;
}

/// Deletes a temp folder that `fetch` made. The copy holds only a clone, and
/// the caller has already reported its result, so a failed delete is ignored.
pub fn discard(io: std.Io, temp: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, temp) catch {};
}

const Step = union(enum) {
    done: Run.Exited,
    failed: Failed,
};

fn cloneInto(
    alloc: std.mem.Allocator,
    ops: Ops,
    git: Git,
    temp: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !FetchResult {
    const started_ns = std.Io.Clock.awake.now(ops.io).nanoseconds;
    const dir = try std.Io.Dir.path.join(alloc, &.{ temp, clone_folder_name });
    const commit_ref: ?[]const u8 = if (git.ref) |ref| (if (isCommit(ref)) ref else null) else null;

    var clone_args: std.ArrayList([]const u8) = .empty;
    defer clone_args.deinit(alloc);
    try clone_args.appendSlice(alloc, &.{ "clone", "--depth", "1" });
    if (git.ref) |ref| {
        if (commit_ref == null) try clone_args.appendSlice(alloc, &.{ "--branch", ref });
    }
    try clone_args.appendSlice(alloc, &.{ git.url, dir });
    if (try runQuiet(alloc, ops, null, clone_args.items, cancel, started_ns)) |step_failed| {
        return .{ .failed = step_failed };
    }

    if (commit_ref) |commit| {
        if (try runQuiet(alloc, ops, dir, &.{ "fetch", "--depth", "1", "origin", commit }, cancel, started_ns)) |step_failed| {
            return .{ .failed = step_failed };
        }
        if (try runQuiet(alloc, ops, dir, &.{ "checkout", "--detach", commit }, cancel, started_ns)) |step_failed| {
            return .{ .failed = step_failed };
        }
    }

    const head = switch (try runGit(alloc, ops, dir, &.{ "rev-parse", "HEAD" }, cancel, started_ns)) {
        .done => |out| out,
        .failed => |step_failed| return .{ .failed = step_failed },
    };
    defer freeOutput(alloc, head);
    const commit = std.mem.trim(u8, head.stdout, " \t\r\n");
    if (!isCommit(commit)) return .{ .failed = try failed(alloc, .bad_commit, "") };

    try removeGitFolder(ops.io, dir);
    const kept_commit = try alloc.dupe(u8, commit);
    const record = try encodeRecord(alloc, .{
        .source = git.url,
        .ref = git.ref,
        .commit = kept_commit,
        .pinned = git.ref != null,
    });
    return .{ .ok = .{ .dir = dir, .temp = temp, .commit = kept_commit, .record = record } };
}

/// Runs one git command that needs no output. Returns null on success.
fn runQuiet(
    alloc: std.mem.Allocator,
    ops: Ops,
    dir: ?[]const u8,
    args: []const []const u8,
    cancel: ?*const std.atomic.Value(bool),
    started_ns: i96,
) !?Failed {
    switch (try runGit(alloc, ops, dir, args, cancel, started_ns)) {
        .done => |out| {
            freeOutput(alloc, out);
            return null;
        },
        .failed => |failed_step| return failed_step,
    }
}

fn runGit(
    alloc: std.mem.Allocator,
    ops: Ops,
    dir: ?[]const u8,
    args: []const []const u8,
    cancel: ?*const std.atomic.Value(bool),
    started_ns: i96,
) !Step {
    if (cancel) |flag| {
        if (flag.load(.acquire)) return .{ .failed = try failed(alloc, .cancelled, "") };
    }
    const left_ms = remainingMs(ops.io, started_ns);
    if (left_ms == 0) return .{ .failed = try failed(alloc, .timed_out, "") };

    const argv = try gitArgv(alloc, dir, args);
    defer alloc.free(argv);
    const run = try ops.run(ops.ctx, alloc, .{ .argv = argv, .timeout_ms = left_ms, .cancel = cancel });
    return switch (run) {
        .exited => |out| if (out.code == 0) .{ .done = out } else gitFailed(alloc, out),
        .timed_out => .{ .failed = try failed(alloc, .timed_out, "") },
        .cancelled => .{ .failed = try failed(alloc, .cancelled, "") },
        .signaled => .{ .failed = try failed(alloc, .signaled, "") },
        .too_large => .{ .failed = try failed(alloc, .too_large, "") },
        .spawn_failed => .{ .failed = try failed(alloc, .spawn_failed, "") },
    };
}

fn gitArgv(alloc: std.mem.Allocator, dir: ?[]const u8, args: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "-c", hooks_off_config });
    if (dir) |path| try argv.appendSlice(alloc, &.{ "-C", path });
    try argv.appendSlice(alloc, args);
    return argv.toOwnedSlice(alloc);
}

fn remainingMs(io: std.Io, started_ns: i96) u64 {
    const elapsed_ns = std.Io.Clock.awake.now(io).nanoseconds - started_ns;
    const budget_ns = @as(i96, clone_deadline_ms) * std.time.ns_per_ms;
    if (elapsed_ns >= budget_ns) return 0;
    return @intCast(@divFloor(budget_ns - elapsed_ns, std.time.ns_per_ms));
}

fn gitFailed(alloc: std.mem.Allocator, out: Run.Exited) !Step {
    defer freeOutput(alloc, out);
    return .{ .failed = try failed(alloc, .git_failed, firstLine(out.stderr)) };
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t\r");
}

fn failed(alloc: std.mem.Allocator, kind: Failure, detail: []const u8) !Failed {
    return .{ .kind = kind, .detail = try alloc.dupe(u8, detail) };
}

fn freeOutput(alloc: std.mem.Allocator, out: Run.Exited) void {
    alloc.free(out.stdout);
    alloc.free(out.stderr);
}

fn removeGitFolder(io: std.Io, dir_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    try dir.deleteTree(io, ".git");
}

// ---- tests ----

fn expectGit(arg: []const u8, url: []const u8, ref: ?[]const u8) !void {
    const parsed = parse(arg);
    try std.testing.expect(parsed == .git);
    try std.testing.expectEqualStrings(url, parsed.git.url);
    if (ref) |want| {
        try std.testing.expectEqualStrings(want, parsed.git.ref.?);
    } else {
        try std.testing.expect(parsed.git.ref == null);
    }
}

test "parse reads folders, URLs and refs" {
    try std.testing.expectEqualStrings("./glm", parse("./glm").local);
    try std.testing.expectEqualStrings("/Users/me/My Mods/glm", parse("/Users/me/My Mods/glm").local);
    try std.testing.expectEqualStrings("http://example.com/glm", parse("http://example.com/glm").local);
    try expectGit("https://example.com/org/glm.git", "https://example.com/org/glm.git", null);
    try expectGit("https://example.com/org/glm@v1.2.0", "https://example.com/org/glm", "v1.2.0");
    try expectGit("ssh://git@example.com/org/glm@main", "ssh://git@example.com/org/glm", "main");
    try expectGit("ssh://git@example.com", "ssh://git@example.com", null);
    try expectGit("git@github.com:org/repo", "git@github.com:org/repo", null);
    try expectGit("git@host:org/repo@v1", "git@host:org/repo", "v1");
    try expectGit("git@host:repo@v1", "git@host:repo", "v1");
    try expectGit("file:///tmp/a@b/repo", "file:///tmp/a@b/repo", null);
    try expectGit("file:///tmp/glm@v1", "file:///tmp/glm", "v1");
    try expectGit("https://example.com:8443/org/glm@deadbeef", "https://example.com:8443/org/glm", "deadbeef");
}

test "parse refuses bad refs, control bytes, spaces and long arguments" {
    try std.testing.expectEqual(Problem.empty, parse("").invalid);
    try std.testing.expectEqual(Problem.bad_ref, parse("https://example.com/org/glm@").invalid);
    try std.testing.expectEqual(Problem.bad_ref, parse("https://example.com/org/glm@-x").invalid);
    try std.testing.expectEqual(Problem.bad_ref, parse("https://example.com/org/glm@a..b").invalid);
    try std.testing.expectEqual(Problem.bad_ref, parse("git@host:org/repo@v1@v2").invalid);
    try std.testing.expectEqual(Problem.bad_characters, parse("https://example.com/org/glm@v1 x").invalid);
    try std.testing.expectEqual(Problem.bad_characters, parse("https://example.com/org/glm\n").invalid);
    try std.testing.expectEqual(Problem.bad_characters, parse("./glm\x1b[31m").invalid);

    var long: [max_source_bytes + 1]u8 = undefined;
    @memcpy(long[0.."https://".len], "https://");
    @memset(long["https://".len..], 'a');
    try std.testing.expectEqual(Problem.too_long, parse(&long).invalid);
}

const test_commit = "0123456789abcdef0123456789abcdef01234567";

fn hasArg(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn fakeOutput(alloc: std.mem.Allocator, stdout: []const u8) !Run {
    return .{ .exited = .{
        .code = 0,
        .stdout = try alloc.dupe(u8, stdout),
        .stderr = try alloc.dupe(u8, ""),
    } };
}

/// Stands in for git: a clone writes a `.git` folder and a `mod.json`, and
/// rev-parse prints `commit`. The test sees every call, and nothing runs.
const FakeGit = struct {
    io: std.Io,
    commit: []const u8,
    calls: usize = 0,
    last_timeout_ms: u64 = 0,
    stall: bool = false,
    stderr: []const u8 = "",
    saw_branch: bool = false,
    saw_fetch: bool = false,
    saw_checkout: bool = false,

    fn run(ctx: ?*anyopaque, alloc: std.mem.Allocator, request: Request) anyerror!Run {
        const self: *FakeGit = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.last_timeout_ms = request.timeout_ms;
        if (self.stall) return .timed_out;
        if (self.stderr.len > 0) {
            return .{ .exited = .{
                .code = 128,
                .stdout = try alloc.dupe(u8, ""),
                .stderr = try alloc.dupe(u8, self.stderr),
            } };
        }
        if (hasArg(request.argv, "clone")) {
            self.saw_branch = hasArg(request.argv, "--branch");
            try writeFakeClone(self.io, request.argv[request.argv.len - 1]);
            return fakeOutput(alloc, "");
        }
        if (hasArg(request.argv, "fetch")) self.saw_fetch = true;
        if (hasArg(request.argv, "checkout")) self.saw_checkout = true;
        if (hasArg(request.argv, "rev-parse")) {
            return fakeOutput(alloc, try alloc.print("{s}\n", .{self.commit}));
        }
        return fakeOutput(alloc, "");
    }
};

fn writeFakeClone(io: std.Io, dir_path: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, ".git");
    try dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try dir.writeFile(io, .{ .sub_path = "mod.json", .data = "{\"name\":\"glm\",\"version\":\"1.0.0\"}" });
}

fn fillTestToken(_: ?*anyopaque, _: std.Io, out_hex: *[token_hex_bytes]u8) void {
    out_hex.* = @splat('a');
}

fn testOps(fake: *FakeGit) Ops {
    return .{
        .io = std.testing.io,
        .ctx = fake,
        .run = FakeGit.run,
        .fill_token = fillTestToken,
    };
}

fn scratchPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![:0]u8 {
    try tmp.dir.createDirPath(std.testing.io, "scratch");
    return tmp.dir.realPathFileAlloc(std.testing.io, "scratch", alloc);
}

fn countEntries(path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |_| count += 1;
    return count;
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(std.testing.io, path, .{}) catch return false;
    return true;
}

test "a tag ref clones with --branch, drops .git and records the commit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try scratchPath(alloc, &tmp);

    var fake: FakeGit = .{ .io = std.testing.io, .commit = test_commit };
    const result = try fetch(alloc, testOps(&fake), .{ .url = "file:///repo", .ref = "v1" }, scratch, null);
    const fetched = switch (result) {
        .ok => |f| f,
        .failed => return error.TestUnexpectedResult,
    };
    defer discard(std.testing.io, fetched.temp);

    try std.testing.expect(fake.saw_branch);
    try std.testing.expect(fake.last_timeout_ms > 0 and fake.last_timeout_ms <= clone_deadline_ms);
    try std.testing.expectEqualStrings(test_commit, fetched.commit);
    try std.testing.expect(!pathExists(try alloc.print("{s}/.git", .{fetched.dir})));
    try std.testing.expect(pathExists(try alloc.print("{s}/mod.json", .{fetched.dir})));

    const record = try decodeRecord(alloc, fetched.record);
    try std.testing.expectEqualStrings("file:///repo", record.source);
    try std.testing.expectEqualStrings("v1", record.ref.?);
    try std.testing.expectEqualStrings(test_commit, record.commit.?);
    try std.testing.expect(record.pinned);
}

test "a full commit ref is fetched and checked out, not cloned with --branch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try scratchPath(alloc, &tmp);

    var fake: FakeGit = .{ .io = std.testing.io, .commit = test_commit };
    const result = try fetch(alloc, testOps(&fake), .{ .url = "file:///repo", .ref = test_commit }, scratch, null);
    const fetched = switch (result) {
        .ok => |f| f,
        .failed => return error.TestUnexpectedResult,
    };
    defer discard(std.testing.io, fetched.temp);

    try std.testing.expect(!fake.saw_branch);
    try std.testing.expect(fake.saw_fetch);
    try std.testing.expect(fake.saw_checkout);
    const record = try decodeRecord(alloc, fetched.record);
    try std.testing.expect(record.pinned);
    try std.testing.expectEqualStrings(test_commit, record.ref.?);
}

test "a clone that runs past the deadline leaves no temp folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try scratchPath(alloc, &tmp);

    var fake: FakeGit = .{ .io = std.testing.io, .commit = test_commit, .stall = true };
    const result = try fetch(alloc, testOps(&fake), .{ .url = "file:///repo", .ref = null }, scratch, null);
    try std.testing.expectEqual(Failure.timed_out, result.failed.kind);
    try std.testing.expectEqual(@as(usize, 0), try countEntries(scratch));
}

test "a cancel before a git command runs starts no command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try scratchPath(alloc, &tmp);

    var cancel = std.atomic.Value(bool).init(true);
    var fake: FakeGit = .{ .io = std.testing.io, .commit = test_commit };
    const result = try fetch(alloc, testOps(&fake), .{ .url = "file:///repo", .ref = null }, scratch, &cancel);
    try std.testing.expectEqual(Failure.cancelled, result.failed.kind);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), try countEntries(scratch));
}

test "a git failure keeps its first stderr line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try scratchPath(alloc, &tmp);

    var fake: FakeGit = .{ .io = std.testing.io, .commit = test_commit, .stderr = "fatal: repository not found\nmore" };
    const result = try fetch(alloc, testOps(&fake), .{ .url = "file:///repo", .ref = null }, scratch, null);
    try std.testing.expectEqual(Failure.git_failed, result.failed.kind);
    try std.testing.expectEqualStrings("fatal: repository not found", result.failed.detail);
}

test "a clone that prints no commit is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try scratchPath(alloc, &tmp);

    var fake: FakeGit = .{ .io = std.testing.io, .commit = "not-a-commit" };
    const result = try fetch(alloc, testOps(&fake), .{ .url = "file:///repo", .ref = null }, scratch, null);
    try std.testing.expectEqual(Failure.bad_commit, result.failed.kind);
    try std.testing.expectEqual(@as(usize, 0), try countEntries(scratch));
}

test "source records round trip, with and without a ref or commit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const pinned = try encodeRecord(alloc, .{
        .source = "https://example.com/org/\"glm\"",
        .ref = "v1",
        .commit = test_commit,
        .pinned = true,
    });
    const back = try decodeRecord(alloc, pinned);
    try std.testing.expectEqualStrings("https://example.com/org/\"glm\"", back.source);
    try std.testing.expectEqualStrings("v1", back.ref.?);
    try std.testing.expect(back.pinned);

    const folder = try folderRecord(alloc, "/Users/me/glm");
    const folder_back = try decodeRecord(alloc, folder);
    try std.testing.expectEqualStrings("/Users/me/glm", folder_back.source);
    try std.testing.expect(folder_back.ref == null);
    try std.testing.expect(folder_back.commit == null);
    try std.testing.expect(!folder_back.pinned);

    try std.testing.expectError(error.BadRecord, decodeRecord(alloc, "{\"source\":1}"));
}

test "records that break a limit are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try std.testing.expectError(error.BadRecord, decodeRecord(alloc, "{\"source\":\"\\u001b[31m\",\"ref\":null,\"commit\":null,\"pinned\":false}"));
    try std.testing.expectError(error.BadRecord, decodeRecord(alloc, "{\"source\":\"x\",\"ref\":null,\"commit\":\"XYZ\",\"pinned\":false}"));
    try std.testing.expectError(error.BadRecord, decodeRecord(alloc, "{\"source\":\"x\",\"ref\":\"-v1\",\"commit\":null,\"pinned\":true}"));
    try std.testing.expectError(error.BadRecord, decodeRecord(alloc, "{\"source\":\"x\",\"ref\":null,\"commit\":null,\"pinned\":true}"));
    try std.testing.expectError(error.BadRecord, decodeRecord(alloc, "{\"source\":\"\",\"ref\":null,\"commit\":null,\"pinned\":false}"));
    try std.testing.expectError(error.BadRecord, decodeRecord(alloc, "{\"source\":\"x\",\"ref\":null,\"commit\":null,\"pinned\":false,\"extra\":1}"));
}

test "a source record decodes or is refused on fuzzed bytes, and its fields obey their limits" {
    try std.testing.fuzz({}, fuzzRecord, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"source\":\"/Users/example/glm\",\"ref\":null,\"commit\":null,\"pinned\":false}",
            "{\"source\":\"https://example.com/org/glm\",\"ref\":\"v1.2.0\",\"commit\":\"0123456789abcdef0123456789abcdef01234567\",\"pinned\":true}",
            "{\"source\":\"https://example.com/org/glm\",\"ref\":null,\"commit\":null,\"pinned\":true}",
            "{\"source\":\"\\u001b[31m\",\"ref\":null,\"commit\":null,\"pinned\":false}",
            "{\"source\":\"x\",\"ref\":null,\"commit\":\"XYZ\",\"pinned\":false}",
            "[]",
        }) ++ @import("fuzz_corpus").mod_source_record.*),
    });
}

fn fuzzRecord(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    const record = decodeRecord(arena_state.allocator(), bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.BadRecord => return,
    };
    try std.testing.expect(record.source.len > 0 and record.source.len <= max_source_bytes);
    try std.testing.expect(!hasControlByte(record.source));
    try std.testing.expect(record.pinned == (record.ref != null));
    if (record.ref) |ref| try std.testing.expect(isValidRef(ref));
    if (record.commit) |commit| try std.testing.expect(isCommit(commit));
}

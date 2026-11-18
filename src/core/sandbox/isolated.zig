//! A fresh sandbox for one command: no keys, the profile's network rules, a
//! one-way copy of the command's folder, and outputs only into a run folder.
const std = @import("std");
const api = @import("api.zig");
const archive = @import("archive.zig");
const client_mod = @import("client.zig");
const config = @import("config.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const executor = @import("executor.zig");
const io_mod = @import("../shared/io.zig");
const sync_plan = @import("sync_plan.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;

/// The helper the isolated sandbox runs, as shell text.
pub const remote_helper: []const u8 = @embedFile("remote_isolated.sh");

/// The helper's script and the name it runs under.
const isolated_helper: workspace.Helper = .{ .script = remote_helper, .name = "fx-iso" };

const name_prefix = "fx-iso-";
/// The name prefix of the recipe builders that `snapshots.zig` makes.
pub const build_name_prefix = "fx-build-";
const hex_digits = "0123456789abcdef";
const max_tag_bytes = 64;
const seconds_per_day = 86400;
const isolated_name_len = 23;
const mib = 1024 * 1024;
const max_batch_archive_bytes = 48 * mib;
/// Added to the profile's minutes, so the server's own stop comes after the command's.
const grace_minutes = 5;
const ms_per_minute = 60_000;

/// What a run needs from the sandbox runtime.
pub const Env = struct {
    client: client_mod.Client,
    /// Prefix for every path in the sandbox. Empty means the same absolute paths.
    remote_root: []const u8,
    /// `$FX_HOME/sandbox`.
    sandbox_dir: []const u8,
    host: []const u8,
    pid: u32,
    random: u32,
    now_s: i64,
    resolver: workspace.SourceResolver,
    /// Most bytes of the folder's files fx copies into one isolated sandbox.
    max_upload_bytes: u64 = 200 * mib,
    /// Most bytes of new and changed files fx brings back from one run.
    max_output_bytes: u64 = 256 * mib,
};

/// One command to run, with the files that go into its sandbox.
pub const Request = struct {
    command: []const u8,
    /// The command's folder on this machine.
    cwd: []const u8,
    /// The folder's files to copy, relative to `cwd`. The caller lists them.
    files: []const []const u8,
    /// Absolute files outside `cwd` that the command names, copied to the same paths.
    inputs: []const []const u8 = &.{},
    profile: config.IsolatedProfile,
};

/// What a run did. Every path is in the caller's arena.
pub const Result = struct {
    outcome: executor.Outcome,
    sandbox: []const u8,
    /// Null when the command made no new or changed files.
    run_folder: ?[]const u8 = null,
    outputs: []const []const u8 = &.{},
    /// Deleted in the sandbox. Nothing changed here.
    deleted: []const []const u8 = &.{},
    refused: []const []const u8 = &.{},
    outputs_too_large: bool = false,
    /// True once fx deleted the sandbox.
    removed: bool = false,
};

pub const Error = error{ FolderTooLarge, SandboxApiFailed, LocalFailed, OutOfMemory };

/// `fx-iso-` and 16 hex digits: 8 of the process id and 8 random.
pub fn sandboxName(buf: *[isolated_name_len]u8, pid: u32, random: u32) []const u8 {
    @memcpy(buf[0..name_prefix.len], name_prefix);
    writeHex(buf[name_prefix.len..][0..8], pid);
    writeHex(buf[name_prefix.len + 8 ..][0..8], random);
    return buf;
}

fn writeHex(out: []u8, value: u32) void {
    for (out, 0..) |*byte, index| {
        const shift: u5 = @intCast(28 - 4 * index);
        byte.* = hex_digits[(value >> shift) & 0xf];
    }
}

/// `<host>:<pid>`, with every byte outside `A-Z a-z 0-9 . _ -` in the host
/// replaced by `-`. The whole tag is at most 64 bytes, so a long host is cut.
pub fn ownerTag(arena: Allocator, host: []const u8, pid: u32) Allocator.Error![]u8 {
    const pid_text = try arena.print("{d}", .{pid});
    const room = max_tag_bytes - 1 - pid_text.len;
    const kept = try arena.dupe(u8, host[0..@min(host.len, room)]);
    for (kept) |*byte| {
        if (!isTagByte(byte.*)) byte.* = '-';
    }
    return arena.print("{s}:{s}", .{ kept, pid_text });
}

fn isTagByte(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '.' or byte == '_' or byte == '-';
}

/// `<sandbox_dir>/runs/<YYYYMMDD-HHMMSS>-<name>`, in UTC from `now_s`.
pub fn runFolder(arena: Allocator, sandbox_dir: []const u8, now_s: i64, name: []const u8) Allocator.Error![]u8 {
    const date = civilDate(@divFloor(now_s, seconds_per_day));
    // Unsigned, so the padded fields print without a sign.
    const day_s: u64 = @intCast(@mod(now_s, seconds_per_day));
    return arena.print("{s}/runs/{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{s}", .{
        sandbox_dir,
        @as(u64, @intCast(date.year)),
        @as(u64, @intCast(date.month)),
        @as(u64, @intCast(date.day)),
        day_s / 3600,
        (day_s % 3600) / 60,
        day_s % 60,
        name,
    });
}

const CivilDate = struct {
    year: i64,
    month: i64,
    day: i64,
};

/// The civil date of a day count from 1970-01-01, by Howard Hinnant's algorithm.
fn civilDate(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const day_of_era = z - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_index + 2, 5) + 1;
    const month = if (month_index < 10) month_index + 3 else month_index - 9;
    const year = year_of_era + era * 400;
    return .{ .year = if (month <= 2) year + 1 else year, .month = month, .day = day };
}

/// Shell text that runs the isolated helper with `args`, quoted like the workspace helper.
pub fn helperCommand(arena: Allocator, args: []const []const u8) Allocator.Error![]u8 {
    return workspace.shellCommand(arena, remote_helper, "fx-iso", args);
}

/// Runs `request.command` in a new sandbox, and deletes that sandbox before
/// `run` returns on every path after it exists. New and changed files of the
/// folder come back to a run folder here. Nothing else on this machine changes.
pub fn run(
    env: Env,
    arena: Allocator,
    request: Request,
    controls: executor.Controls,
    output: ?executor.Output,
    failure: *client_mod.Failure,
) Error!Result {
    try checkUploadSize(env, arena, request, failure);
    var name_buf: [isolated_name_len]u8 = undefined;
    const name = try arena.dupe(u8, sandboxName(&name_buf, env.pid, env.random));
    const owner = try ownerTag(arena, env.host, env.pid);
    const session = try createSandbox(env, arena, request.profile, name, owner, failure);
    var result = runInSandbox(env, arena, request, name, session, controls, output, failure) catch |err| {
        _ = workspace.deleteSandboxLogged(env.client, arena, name, "isolated sandbox");
        return err;
    };
    result.removed = workspace.deleteSandboxLogged(env.client, arena, name, "isolated sandbox");
    return result;
}

/// Refuses a folder that is too large before any sandbox exists. Each named
/// input must be a regular file.
fn checkUploadSize(env: Env, arena: Allocator, request: Request, failure: *client_mod.Failure) Error!void {
    var total: u64 = 0;
    for (request.files) |file| total += try workspace.fileSize(arena, request.cwd, file);
    for (request.inputs) |input| {
        const size = workspace.regularFileSize(input) orelse {
            failure.message = try arena.print("the input {s} is not a regular file", .{input});
            return error.LocalFailed;
        };
        total += size;
    }
    if (total > env.max_upload_bytes) {
        failure.message = try arena.print("{s} holds {d:.1} MiB, more than the {d:.1} MiB fx copies into an isolated sandbox. Run the command from a smaller folder.", .{
            request.cwd,
            mebibytes(total),
            mebibytes(env.max_upload_bytes),
        });
        return error.FolderTooLarge;
    }
}

/// Creates the run's sandbox and returns its session. A failed create is not
/// deleted here, because the answer may be lost and the name may belong to
/// another run. The startup sweep removes a sandbox that is left behind.
fn createSandbox(env: Env, arena: Allocator, profile: config.IsolatedProfile, name: []const u8, owner: []const u8, failure: *client_mod.Failure) Error![]const u8 {
    const source = env.resolver.resolve(env.resolver.context, arena, profile.source, failure) catch |err| return workspace.resolveFailure(err, failure);
    const tags = [_]api.Pair{ .{ .name = "fx", .value = "isolated" }, .{ .name = "owner", .value = owner } };
    const created = env.client.createSandbox(arena, .{
        .name = name,
        .project = env.client.project,
        .persistent = false,
        .timeout_ms = (@as(u64, profile.timeout_minutes) + grace_minutes) * ms_per_minute,
        .source = source,
        .network = profile.network,
        .vcpus = profile.vcpus,
        .tags = &tags,
    }, failure) catch |err| {
        if (err == error.AnswerLost) {
            // The answer was lost after the sandbox may have been made. The name has a
            // random part and this run chose it, so the sandbox is ours to delete.
            const removed = workspace.deleteSandboxLogged(env.client, arena, name, "isolated sandbox");
            debug_trace.logf("sandbox", "isolated create answer was lost, sandbox {s} deleted={}", .{ name, removed });
        }
        return workspace.clientFailure(err);
    };
    return created.session_id;
}

/// The sandboxes this module makes: the tag each one carries, the name it
/// starts with, and how its removal is logged.
const SweepKind = struct {
    tag: []const u8,
    prefix: []const u8,
    what: []const u8,
};

const sweep_kinds = [_]SweepKind{
    .{ .tag = "isolated", .prefix = name_prefix, .what = "isolated sandbox" },
    .{ .tag = "build", .prefix = build_name_prefix, .what = "recipe builder" },
};

/// Removes isolated sandboxes and recipe builders that an fx process on this
/// host left behind when it ended without deleting them. A sandbox whose owner
/// process still runs, or that another host owns, stays. Returns how many it removed.
pub fn sweep(
    client: client_mod.Client,
    arena: Allocator,
    host: []const u8,
    own_pid: u32,
    is_alive: *const fn (pid: u32) bool,
    failure: *client_mod.Failure,
) client_mod.Error!usize {
    var removed: usize = 0;
    for (sweep_kinds) |kind| {
        const listed = try client.listByTag(arena, .{ .name = "fx", .value = kind.tag }, failure);
        for (listed) |entry| {
            // Only names this module makes are candidates, even under the tag.
            if (!std.mem.startsWith(u8, entry.name, kind.prefix)) continue;
            const owner = entry.owner orelse continue;
            const owner_pid = (try ownerPid(arena, host, owner)) orelse continue;
            if (owner_pid == own_pid or is_alive(owner_pid)) continue;
            if (!workspace.deleteSandboxLogged(client, arena, entry.name, kind.what)) continue;
            debug_trace.logf("sandbox", "removed {s} {s} left by dead pid {d}", .{ kind.what, entry.name, owner_pid });
            removed += 1;
        }
    }
    return removed;
}

/// The pid in `owner` when `owner` is `ownerTag(host, pid)`, the form this
/// host's processes write. Null for another host's tag or a malformed one.
fn ownerPid(arena: Allocator, host: []const u8, owner: []const u8) Allocator.Error!?u32 {
    const colon = std.mem.findScalarLast(u8, owner, ':') orelse return null;
    const pid = std.fmt.parseInt(u32, owner[colon + 1 ..], 10) catch return null;
    const expected = try ownerTag(arena, host, pid);
    if (!std.mem.eql(u8, expected, owner)) return null;
    return pid;
}

/// True when a process with `pid` exists. A process that another user owns
/// still exists, so a permission error counts as alive.
pub fn processAlive(pid: u32) bool {
    const target = std.math.cast(std.c.pid_t, pid) orelse return false;
    // Signal zero checks that the process exists and sends nothing.
    const rc = std.c.kill(target, @fromBackingInt(0));
    if (rc == 0) return true;
    return std.c.errno(rc) == .PERM;
}

fn runInSandbox(
    env: Env,
    arena: Allocator,
    request: Request,
    name: []const u8,
    session: []const u8,
    controls: executor.Controls,
    output: ?executor.Output,
    failure: *client_mod.Failure,
) Error!Result {
    const remote_cwd = try workspace.remotePath(arena, env.remote_root, request.cwd);
    const state = try arena.print("{s}/tmp/fx-iso-state-{s}", .{ env.remote_root, name });
    const packed_path = try arena.print("{s}.tgz", .{state});

    var prepare_args: std.ArrayList([]const u8) = .empty;
    try prepare_args.appendSlice(arena, &.{ "prepare", remote_cwd, state });
    for (try inputParents(arena, request.inputs)) |parent| {
        try prepare_args.append(arena, try workspace.remotePath(arena, env.remote_root, parent));
    }
    _ = try runHelper(env, arena, session, prepare_args.items, failure);

    try uploadTree(env, arena, session, request.cwd, remote_cwd, request.files, failure);
    for (request.inputs) |input| {
        const parent = std.Io.Dir.path.dirname(input) orelse return error.LocalFailed;
        const remote_parent = try workspace.remotePath(arena, env.remote_root, parent);
        try uploadTree(env, arena, session, parent, remote_parent, &.{std.Io.Dir.path.basename(input)}, failure);
    }
    _ = try runHelper(env, arena, session, &.{ "baseline", remote_cwd, state }, failure);

    const outcome = try executor.execute(env.client, arena, .{
        .session = session,
        .command = request.command,
        .remote_cwd = remote_cwd,
    }, controls, output);
    var result: Result = .{ .outcome = outcome, .sandbox = name };
    // A command that never started changed nothing. A lost connection leaves
    // its effects unknown, so nothing is brought back from it.
    if (!outcome.started or outcome.connection_lost) return result;
    try collectOutputs(env, arena, session, name, remote_cwd, state, packed_path, failure, &result);
    return result;
}

fn runHelper(env: Env, arena: Allocator, session: []const u8, args: []const []const u8, failure: *client_mod.Failure) Error![]const u8 {
    return workspace.runRemoteHelper(env.client, workspace.helper_deadline_ms, isolated_helper, arena, session, args, failure);
}

/// Packs `paths` under `root` in batches, and writes each batch into `remote_dir`.
fn uploadTree(
    env: Env,
    arena: Allocator,
    session: []const u8,
    root: []const u8,
    remote_dir: []const u8,
    paths: []const []const u8,
    failure: *client_mod.Failure,
) Error!void {
    var start: usize = 0;
    while (start < paths.len) {
        const end = try workspace.batchEnd(arena, root, paths, start);
        const bytes = archive.build(arena, root, paths[start..end], .{
            .max_bytes = max_batch_archive_bytes,
            .links = false,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return workspace.localFailure(failure, "the folder could not be packed for the sandbox"),
        };
        env.client.writeArchive(arena, session, bytes, remote_dir, failure) catch |err| return workspace.clientFailure(err);
        start = end;
    }
}

/// The folder of each input, each listed once.
fn inputParents(arena: Allocator, inputs: []const []const u8) Error![]const []const u8 {
    var parents: std.ArrayList([]const u8) = .empty;
    for (inputs) |input| {
        try parents.append(arena, std.Io.Dir.path.dirname(input) orelse return error.LocalFailed);
    }
    return workspace.uniquePaths(arena, parents.items);
}

/// Reads what the command changed in the sandbox. A new or changed file goes
/// to a run folder, a deletion is listed, and anything else is refused.
fn collectOutputs(
    env: Env,
    arena: Allocator,
    session: []const u8,
    name: []const u8,
    remote_cwd: []const u8,
    state: []const u8,
    packed_path: []const u8,
    failure: *client_mod.Failure,
    result: *Result,
) Error!void {
    const listed = try runHelper(env, arena, session, &.{ "outputs", remote_cwd, state, packed_path }, failure);
    const changes = sync_plan.parseRawDiff(arena, listed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            failure.message = "the sandbox changed-files list could not be read";
            return error.SandboxApiFailed;
        },
    };
    var outputs: std.ArrayList([]const u8) = .empty;
    var deleted: std.ArrayList([]const u8) = .empty;
    var refused: std.ArrayList([]const u8) = .empty;
    for (changes) |change| {
        if (change.new_blob == null) {
            try deleted.append(arena, change.path);
        } else if ((change.new_mode == .file or change.new_mode == .executable) and sync_plan.safeRelativePath(change.path)) {
            try outputs.append(arena, change.path);
        } else {
            try refused.append(arena, change.path);
        }
    }
    result.deleted = try deleted.toOwnedSlice(arena);
    result.outputs = try outputs.toOwnedSlice(arena);
    if (result.outputs.len > 0) {
        try extractOutputs(env, arena, session, name, packed_path, failure, result, &refused);
    }
    result.refused = try refused.toOwnedSlice(arena);
}

/// Brings the packed outputs into a run folder here. An output set over the
/// limit is listed but not copied.
fn extractOutputs(
    env: Env,
    arena: Allocator,
    session: []const u8,
    name: []const u8,
    packed_path: []const u8,
    failure: *client_mod.Failure,
    result: *Result,
    refused: *std.ArrayList([]const u8),
) Error!void {
    const packed_bytes = (env.client.readFile(arena, session, packed_path, failure) catch |err| return workspace.clientFailure(err)) orelse {
        failure.message = "the sandbox did not pack the outputs";
        return error.SandboxApiFailed;
    };
    const total = archive.regularFileBytes(arena, packed_bytes, result.outputs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            failure.message = "the sandbox packed outputs that cannot be read";
            return error.SandboxApiFailed;
        },
    };
    if (total > env.max_output_bytes) {
        result.outputs_too_large = true;
        return;
    }

    const folder = try runFolder(arena, env.sandbox_dir, env.now_s, name);
    io_mod.makeDirRecursive(folder) catch return workspace.localFailure(failure, "could not make the run folder");
    const extracted = archive.extract(arena, packed_bytes, folder, result.outputs, limitOf(env.max_output_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArchive => {
            failure.message = "the sandbox packed outputs that cannot be read";
            return error.SandboxApiFailed;
        },
        else => return workspace.localFailure(failure, "an output could not be written to the run folder"),
    };
    result.run_folder = folder;
    result.outputs = extracted.written;
    for (extracted.refused) |path| {
        if (!containsPath(refused.items, path)) try refused.append(arena, path);
    }
}

fn containsPath(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, needle)) return true;
    }
    return false;
}

/// A byte count in MiB, for messages.
fn mebibytes(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / @as(f64, mib);
}

/// The output limit as the `usize` that `archive.extract` takes.
fn limitOf(bytes: u64) usize {
    return std.math.cast(usize, bytes) orelse std.math.maxInt(usize);
}

// ---- tests ----

const testing = std.testing;
const test_sandbox = @import("test_sandbox.zig");

const FakeSandbox = test_sandbox.FakeSandbox;
const folder_mode = std.Io.File.Permissions.fromMode(0o755);

/// Runs the isolated helper with `args`: the command, the folder, and their arguments.
fn runIsolated(arena: Allocator, args: []const []const u8) !test_sandbox.Ran {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "bash", "-c", remote_helper, "fx-iso" });
    try argv.appendSlice(arena, args);
    return test_sandbox.runCommand(arena, ".", argv.items);
}

fn existsUnder(dir: std.Io.Dir, sub_path: []const u8) bool {
    _ = dir.statFile(io_mod.getIo(), sub_path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn absoluteExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn readAt(arena: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    const zio = io_mod.getIo();
    var file = try dir.openFile(zio, sub_path, .{});
    defer file.close(zio);
    return io_mod.readFileToEnd(arena, &file, 1 << 20);
}

fn readAbsoluteText(arena: Allocator, path: []const u8) ![]u8 {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{});
    defer file.close(zio);
    return io_mod.readFileToEnd(arena, &file, 1 << 20);
}

fn findChange(changes: []const sync_plan.Change, path: []const u8) ?sync_plan.Change {
    for (changes) |change| {
        if (std.mem.eql(u8, change.path, path)) return change;
    }
    return null;
}

fn listContains(names: []const []const u8, needle: []const u8) bool {
    return containsPath(names, needle);
}

/// True when `key` is an object field name anywhere in `value`.
fn hasKey(value: std.json.Value, key: []const u8) bool {
    switch (value) {
        .object => |map| {
            for (map.keys(), map.values()) |name, child| {
                if (std.mem.eql(u8, name, key) or hasKey(child, key)) return true;
            }
            return false;
        },
        .array => |array| {
            for (array.items) |item| {
                if (hasKey(item, key)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn identityResolve(context: *anyopaque, arena: Allocator, source: config.Source, failure: *client_mod.Failure) anyerror!config.Source {
    _ = context;
    _ = arena;
    _ = failure;
    return source;
}

/// The folders one run test uses: the command's folder, an input folder,
/// the sandbox state folder, and the disk that stands in for the sandbox.
const Fixture = struct {
    cwd: []const u8,
    inputs: []const u8,
    sandbox_dir: []const u8,
    disk: []const u8,
};

fn makeFixture(arena: Allocator, tmp: *std.testing.TmpDir) !Fixture {
    const zio = io_mod.getIo();
    try tmp.dir.createDir(zio, "work", folder_mode);
    try tmp.dir.createDir(zio, "inputs", folder_mode);
    try tmp.dir.createDir(zio, "state", folder_mode);
    try tmp.dir.createDir(zio, "disk", folder_mode);
    const base = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    return .{
        .cwd = try arena.print("{s}/work", .{base}),
        .inputs = try arena.print("{s}/inputs", .{base}),
        .sandbox_dir = try arena.print("{s}/state", .{base}),
        .disk = try arena.print("{s}/disk", .{base}),
    };
}

/// An env for one run in a test. `fake` answers for the sandbox API.
fn testEnv(fake: *FakeSandbox, fixture: Fixture) Env {
    return .{
        .client = test_sandbox.fakeClient(fake),
        .remote_root = fixture.disk,
        .sandbox_dir = fixture.sandbox_dir,
        .host = "host.test",
        .pid = 42,
        .random = 0x1234abcd,
        .now_s = 1794920709,
        .resolver = .{ .context = fake, .resolve = identityResolve },
    };
}

const test_controls: executor.Controls = .{ .max_output_bytes = 1 << 20 };

test "isolated names and owner tags are well formed" {
    var buf: [23]u8 = undefined;
    const name = sandboxName(&buf, 42, 0xdeadbeef);
    try testing.expectEqual(@as(usize, 23), name.len);
    try testing.expect(std.mem.startsWith(u8, name, name_prefix));
    for (name[name_prefix.len..]) |byte| {
        const allowed = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-';
        try testing.expect(allowed);
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("my-host-:42", try ownerTag(arena, "my host!", 42));
}

test "run folders use UTC time and the name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("/s/runs/19700101-000000-fx-iso-1", try runFolder(arena, "/s", 0, "fx-iso-1"));
    // 2026-11-17 13:05:09 UTC.
    try testing.expectEqualStrings("/s/runs/20261117-130509-fx-iso-2", try runFolder(arena, "/s", 1794920709, "fx-iso-2"));
}

test "isolated helper commands quote every argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try helperCommand(arena, &.{ "prepare", "it's" });
    try testing.expect(std.mem.startsWith(u8, text, "bash -c '"));
    try testing.expect(std.mem.endsWith(u8, text, " fx-iso 'prepare' 'it'\\''s'"));
}

test "the isolated helper finds new and changed files only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const folder = try arena.print("{s}/F", .{base});
    const state = try arena.print("{s}/S", .{base});
    const packed_path = try arena.print("{s}/changes.tgz", .{base});

    try tmp.dir.createDir(zio, "F", folder_mode);
    try tmp.dir.writeFile(zio, .{ .sub_path = "F/a.txt", .data = "one\n" });
    try tmp.dir.writeFile(zio, .{ .sub_path = "F/keep.txt", .data = "keep\n" });
    try tmp.dir.writeFile(zio, .{ .sub_path = "F/.gitignore", .data = "out/\n" });
    const baseline = try runIsolated(arena, &.{ "baseline", folder, state });
    try testing.expectEqual(@as(i64, 0), baseline.code);

    try tmp.dir.writeFile(zio, .{ .sub_path = "F/a.txt", .data = "uno\n" });
    try tmp.dir.createDir(zio, "F/out", folder_mode);
    try tmp.dir.writeFile(zio, .{ .sub_path = "F/out/result.png", .data = "png\n" });
    try tmp.dir.deleteFile(zio, "F/keep.txt");

    const outputs = try runIsolated(arena, &.{ "outputs", folder, state, packed_path });
    try testing.expectEqual(@as(i64, 0), outputs.code);
    const changes = try sync_plan.parseRawDiff(arena, outputs.stdout);
    try testing.expectEqual(@as(usize, 3), changes.len);
    const edited = findChange(changes, "a.txt") orelse return error.TestUnexpectedResult;
    try testing.expect(edited.old_blob != null and edited.new_blob != null);
    const added = findChange(changes, "out/result.png") orelse return error.TestUnexpectedResult;
    try testing.expect(added.old_blob == null);
    const removed = findChange(changes, "keep.txt") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(sync_plan.Mode.absent, removed.new_mode);

    // The archive holds the ignored output too, and the folder keeps no repository.
    const packed_bytes = try readAt(arena, tmp.dir, "changes.tgz");
    try tmp.dir.createDir(zio, "D", folder_mode);
    const result = try archive.extract(arena, packed_bytes, try arena.print("{s}/D", .{base}), null, 1 << 20);
    try testing.expectEqual(@as(usize, 2), result.written.len);
    try testing.expect(listContains(result.written, "a.txt"));
    try testing.expect(listContains(result.written, "out/result.png"));
    try testing.expectEqual(@as(usize, 0), result.refused.len);
    try testing.expect(!existsUnder(tmp.dir, "F/.git"));
}

test "the isolated helper makes extra folders" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const folder = try arena.print("{s}/F1", .{base});
    const extra = try arena.print("{s}/E", .{base});
    const state = try arena.print("{s}/S", .{base});

    const made = try runIsolated(arena, &.{ "prepare", folder, state, extra });
    try testing.expectEqual(@as(i64, 0), made.code);
    try testing.expect(existsUnder(tmp.dir, "F1"));
    try testing.expect(existsUnder(tmp.dir, "E"));
}

test "an isolated run brings outputs to a run folder and changes nothing here" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try tmp.dir.writeFile(zio, .{ .sub_path = "work/in.txt", .data = "hi\n" });
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var failure: client_mod.Failure = .{};

    const result = try run(testEnv(&fake, fixture), arena, .{
        .command = "cp in.txt out.txt && echo more >> in.txt",
        .cwd = fixture.cwd,
        .files = &.{"in.txt"},
        .profile = .{ .name = "default" },
    }, test_controls, null, &failure);

    try testing.expectEqual(@as(?i64, 0), result.outcome.exit_code);
    try testing.expect(result.removed);
    try testing.expectEqual(@as(usize, 1), fake.deletes);
    try testing.expectEqual(@as(usize, 2), result.outputs.len);
    const folder = result.run_folder orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("hi\nmore\n", try readAbsoluteText(arena, try arena.print("{s}/in.txt", .{folder})));
    try testing.expectEqualStrings("hi\n", try readAbsoluteText(arena, try arena.print("{s}/out.txt", .{folder})));
    try testing.expectEqualStrings("hi\n", try readAbsoluteText(arena, try arena.print("{s}/in.txt", .{fixture.cwd})));
    try testing.expect(!absoluteExists(try arena.print("{s}/out.txt", .{fixture.cwd})));
}

test "the create request has the network rules and no keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var failure: client_mod.Failure = .{};
    const profile: config.IsolatedProfile = .{ .name = "media", .network = .{ .allow = &.{"registry.npmjs.org"} } };

    _ = try run(testEnv(&fake, fixture), arena, .{
        .command = "true",
        .cwd = fixture.cwd,
        .files = &.{},
        .profile = profile,
    }, test_controls, null, &failure);

    try testing.expectEqual(@as(usize, 1), fake.creates);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, fake.create_bodies[0].get(), .{});
    const root = body.object;
    try testing.expectEqual(false, root.get("persistent").?.bool);
    const policy = root.get("networkPolicy").?.object;
    try testing.expectEqualStrings("custom", policy.get("mode").?.string);
    try testing.expectEqualStrings("registry.npmjs.org", policy.get("allowedDomains").?.array.items[0].string);
    const tags = root.get("tags").?.object;
    try testing.expectEqualStrings("isolated", tags.get("fx").?.string);
    try testing.expectEqualStrings("host.test:42", tags.get("owner").?.string);
    try testing.expect(!hasKey(body, "env"));
}

test "named inputs reach their own paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try tmp.dir.writeFile(zio, .{ .sub_path = "inputs/data.txt", .data = "payload\n" });
    const input = try arena.print("{s}/data.txt", .{fixture.inputs});
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var failure: client_mod.Failure = .{};

    // The command runs in the sandbox folder, so `..` reaches the input's copy.
    const result = try run(testEnv(&fake, fixture), arena, .{
        .command = "cat ../inputs/data.txt",
        .cwd = fixture.cwd,
        .files = &.{},
        .inputs = &.{input},
        .profile = .{ .name = "default" },
    }, test_controls, null, &failure);

    try testing.expectEqualStrings("payload\n", result.outcome.stdout);
}

test "a folder over the copy limit fails before any sandbox" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    const big: [1024]u8 = @splat('x');
    try tmp.dir.writeFile(zio, .{ .sub_path = "work/big.bin", .data = &big });
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var env = testEnv(&fake, fixture);
    env.max_upload_bytes = 10;
    var failure: client_mod.Failure = .{};

    try testing.expectError(error.FolderTooLarge, run(env, arena, .{
        .command = "true",
        .cwd = fixture.cwd,
        .files = &.{"big.bin"},
        .profile = .{ .name = "default" },
    }, test_controls, null, &failure));
    try testing.expect(std.mem.find(u8, failure.message, "more than the") != null);
    try testing.expectEqual(@as(usize, 0), fake.creates);
}

test "the sandbox is deleted when the command cannot start" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    // The prepare and baseline helpers are commands 0 and 1. The user's command is 2.
    var fake: FakeSandbox = .{ .disk = fixture.disk, .fail_after = 2 };
    var failure: client_mod.Failure = .{};

    const result = try run(testEnv(&fake, fixture), arena, .{
        .command = "echo hi",
        .cwd = fixture.cwd,
        .files = &.{},
        .profile = .{ .name = "default" },
    }, test_controls, null, &failure);

    try testing.expect(!result.outcome.started);
    try testing.expect(result.outcome.failure != null);
    try testing.expect(result.run_folder == null);
    try testing.expect(result.removed);
    try testing.expectEqual(@as(usize, 1), fake.deletes);
}

test "outputs over the limit are listed, not copied" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var env = testEnv(&fake, fixture);
    env.max_output_bytes = 10;
    var failure: client_mod.Failure = .{};

    const result = try run(env, arena, .{
        .command = "head -c 1024 /dev/zero > big.bin",
        .cwd = fixture.cwd,
        .files = &.{},
        .profile = .{ .name = "default" },
    }, test_controls, null, &failure);

    try testing.expect(result.outputs_too_large);
    try testing.expect(result.run_folder == null);
    try testing.expectEqual(@as(usize, 1), result.outputs.len);
    try testing.expectEqualStrings("big.bin", result.outputs[0]);
    try testing.expect(!absoluteExists(try arena.print("{s}/runs", .{fixture.sandbox_dir})));
}

test "deleted files are reported and nothing here changes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try tmp.dir.writeFile(zio, .{ .sub_path = "work/in.txt", .data = "hi\n" });
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var failure: client_mod.Failure = .{};

    const result = try run(testEnv(&fake, fixture), arena, .{
        .command = "rm in.txt",
        .cwd = fixture.cwd,
        .files = &.{"in.txt"},
        .profile = .{ .name = "default" },
    }, test_controls, null, &failure);

    try testing.expectEqual(@as(usize, 1), result.deleted.len);
    try testing.expectEqualStrings("in.txt", result.deleted[0]);
    try testing.expect(result.run_folder == null);
    try testing.expectEqualStrings("hi\n", try readAbsoluteText(arena, try arena.print("{s}/in.txt", .{fixture.cwd})));
}

test "an ignored output still comes back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    try tmp.dir.writeFile(zio, .{ .sub_path = "work/.gitignore", .data = "out/\n" });
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var failure: client_mod.Failure = .{};

    const result = try run(testEnv(&fake, fixture), arena, .{
        .command = "mkdir -p out && echo x > out/r.txt",
        .cwd = fixture.cwd,
        .files = &.{".gitignore"},
        .profile = .{ .name = "default" },
    }, test_controls, null, &failure);

    try testing.expectEqual(@as(usize, 1), result.outputs.len);
    try testing.expectEqualStrings("out/r.txt", result.outputs[0]);
    const folder = result.run_folder orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("x\n", try readAbsoluteText(arena, try arena.print("{s}/out/r.txt", .{folder})));
}

/// Creates a sandbox in the fake with `tags`, as an earlier run would have.
fn seedSandbox(client: client_mod.Client, arena: Allocator, name: []const u8, tags: []const api.Pair) !void {
    var failure: client_mod.Failure = .{};
    _ = try client.createSandbox(arena, .{
        .name = name,
        .project = client.project,
        .persistent = false,
        .timeout_ms = 60_000,
        .tags = tags,
    }, &failure);
}

fn onlyTwoTwentyTwoAlive(pid: u32) bool {
    return pid == 222;
}

test "sweep removes only dead owners on this host" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeSandbox = .{ .disk = "" };
    const client = test_sandbox.fakeClient(&fake);
    var buf: [isolated_name_len]u8 = undefined;
    // Each name is copied before the buffer is reused for the next one.
    const dead_here = try arena.dupe(u8, sandboxName(&buf, 111, 1));
    const alive_here = try arena.dupe(u8, sandboxName(&buf, 222, 2));
    const dead_other = try arena.dupe(u8, sandboxName(&buf, 111, 3));
    const own = try arena.dupe(u8, sandboxName(&buf, 900, 4));
    const isolated_tag: api.Pair = .{ .name = "fx", .value = "isolated" };
    try seedSandbox(client, arena, dead_here, &.{ isolated_tag, .{ .name = "owner", .value = "h:111" } });
    try seedSandbox(client, arena, alive_here, &.{ isolated_tag, .{ .name = "owner", .value = "h:222" } });
    try seedSandbox(client, arena, dead_other, &.{ isolated_tag, .{ .name = "owner", .value = "other:111" } });
    try seedSandbox(client, arena, own, &.{ isolated_tag, .{ .name = "owner", .value = "h:900" } });
    const build_tag: api.Pair = .{ .name = "fx", .value = "build" };
    const dead_build = "fx-build-0000006f00000001";
    const alive_build = "fx-build-000000de00000002";
    try seedSandbox(client, arena, dead_build, &.{ build_tag, .{ .name = "owner", .value = "h:111" } });
    try seedSandbox(client, arena, alive_build, &.{ build_tag, .{ .name = "owner", .value = "h:222" } });
    try seedSandbox(client, arena, "fx-ws-0000000000000001", &.{.{ .name = "fx", .value = "workspace" }});

    var failure: client_mod.Failure = .{};
    const removed = try sweep(client, arena, "h", 900, &onlyTwoTwentyTwoAlive, &failure);
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 2), fake.deletes);
    try testing.expectEqualStrings(dead_here, fake.deleted_names[0].get());
    try testing.expectEqualStrings(dead_build, fake.deleted_names[1].get());

    // The live owner's builder is still listed, so the sweep left it alone.
    const builders = try client.listByTag(arena, build_tag, &failure);
    try testing.expectEqual(@as(usize, 1), builders.len);
    try testing.expectEqualStrings(alive_build, builders[0].name);
}

test "processAlive knows this process" {
    try testing.expect(processAlive(@intCast(std.c.getpid())));
    try testing.expect(!processAlive(0x7ffffff0));
}

test "a helper that fails before the command still deletes the sandbox" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    // Command 0 is the prepare helper. It exits 1.
    var fake: FakeSandbox = .{ .disk = fixture.disk, .fail_exit = 0 };
    var failure: client_mod.Failure = .{};

    try testing.expectError(error.SandboxApiFailed, run(testEnv(&fake, fixture), arena, .{
        .command = "true",
        .cwd = fixture.cwd,
        .files = &.{},
        .profile = .{ .name = "default" },
    }, test_controls, null, &failure));
    try testing.expect(std.mem.find(u8, failure.message, "prepare") != null);
    try testing.expectEqual(@as(usize, 1), fake.deletes);
}

test "a lost create answer deletes the name it chose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk, .lose_create_answer = true };
    var failure: client_mod.Failure = .{};

    try testing.expectError(error.SandboxApiFailed, run(testEnv(&fake, fixture), arena, .{
        .command = "true",
        .cwd = fixture.cwd,
        .files = &.{},
        .profile = .{ .name = "default" },
    }, test_controls, null, &failure));
    try testing.expect(std.mem.find(u8, failure.message, "may have taken effect") != null);
    try testing.expectEqual(@as(usize, 1), fake.creates);
    try testing.expectEqual(@as(usize, 1), fake.deletes);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, fake.create_bodies[0].get(), .{});
    try testing.expectEqualStrings(body.object.get("name").?.string, fake.deleted_names[0].get());
}

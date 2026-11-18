//! Snapshots built from recipes in this user's own folder. fx runs a recipe
//! once in a fresh sandbox, saves a snapshot, and reuses it until the script
//! changes or the snapshot is gone.
const std = @import("std");
const api = @import("api.zig");
const archive = @import("archive.zig");
const client_mod = @import("client.zig");
const config = @import("config.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const executor = @import("executor.zig");
const io_mod = @import("../shared/io.zig");
const isolated = @import("isolated.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Env = struct {
    client: client_mod.Client,
    remote_root: []const u8,
    /// `$FX_HOME/sandbox`.
    sandbox_dir: []const u8,
    host: []const u8,
    pid: u32,
    random: u32,
    /// Receives the recipe's output while it runs.
    output: ?executor.Output = null,
    expiration_ms: u64 = 30 * 24 * 60 * 60 * 1000,
    max_recipe_bytes: usize = 1024 * 1024,
};

pub const Error = error{ RecipeFailed, SandboxApiFailed, LocalFailed, OutOfMemory };

/// The builder's timeout, and the deadline for the recipe's run.
const build_limit_ms = 60 * 60 * 1000;
/// Most output fx keeps from one recipe run. Only its tail reaches an error.
const max_build_output_bytes = 1024 * 1024;
const max_failure_tail_bytes = 500;
const max_records_bytes = 1024 * 1024;
const build_prefix = isolated.build_name_prefix;
const hex_digits = "0123456789abcdef";
const announce_format = "fx: building a snapshot from {s}; this runs once until the script changes.\n";
/// The helper that makes the builder's folder: the isolated helper, under its own name.
const prepare_helper: workspace.Helper = .{ .script = isolated.remote_helper, .name = "fx-iso" };

/// The source a create request takes. A recipe becomes the snapshot built from it.
pub fn resolve(env: Env, arena: Allocator, source: config.Source, failure: *client_mod.Failure) Error!config.Source {
    return switch (source) {
        .default, .image, .snapshot => source,
        .recipe => |path| .{ .snapshot = try snapshotFor(env, arena, path, failure) },
    };
}

/// The snapshot for the recipe at `path`: the saved one when its script is
/// unchanged and the snapshot still exists, otherwise a new build.
fn snapshotFor(env: Env, arena: Allocator, path: []const u8, failure: *client_mod.Failure) Error![]const u8 {
    const script = try readRecipe(env, arena, path, failure);
    const digest = try sha256Hex(arena, script);
    io_mod.makeDirRecursive(env.sandbox_dir) catch return workspace.localFailure(failure, "the sandbox folder cannot be created");
    // The lock is `snapshots.lock`, and the records are `snapshots.json`, in the same folder.
    const lock_path = try arena.print("{s}/snapshots", .{env.sandbox_dir});
    var lock = workspace.Lock.acquire(arena, lock_path) catch return workspace.localFailure(failure, "the snapshot records cannot be locked");
    defer lock.release();

    const records_path = try arena.print("{s}/snapshots.json", .{env.sandbox_dir});
    const records = try loadRecords(arena, records_path);
    if (findRecord(records, path)) |record| {
        if (std.mem.eql(u8, record.sha256, digest)) {
            const exists = env.client.snapshotExists(arena, record.snapshot, failure) catch |err| return workspace.clientFailure(err);
            if (exists) return record.snapshot;
            debug_trace.logf("sandbox", "recipe {s} has snapshot {s}, which is gone; building again", .{ path, record.snapshot });
        }
    }

    const id = try build(env, arena, path, script, failure);
    const next = try withRecord(arena, records, .{
        .path = path,
        .sha256 = digest,
        .snapshot = id,
        .built_s = @divFloor(io_mod.milliTimestamp(), 1000),
    });
    try saveRecords(arena, records_path, next, failure);
    return id;
}

/// Reads the recipe. A recipe that is missing, unreadable, or too large fails
/// here, before any sandbox exists.
fn readRecipe(env: Env, arena: Allocator, path: []const u8, failure: *client_mod.Failure) Error![]u8 {
    const zio = io_mod.getIo();
    var file = std.Io.Dir.cwd().openFile(zio, path, .{}) catch return unreadable(arena, path, failure);
    defer file.close(zio);
    return io_mod.readFileToEnd(arena, &file, env.max_recipe_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return unreadable(arena, path, failure),
    };
}

fn unreadable(arena: Allocator, path: []const u8, failure: *client_mod.Failure) Error {
    failure.message = arena.print("the recipe {s} cannot be read", .{path}) catch return error.OutOfMemory;
    return error.LocalFailed;
}

fn sha256Hex(arena: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const out = try arena.alloc(u8, digest.len * 2);
    for (digest, 0..) |byte, index| {
        out[2 * index] = hex_digits[byte >> 4];
        out[2 * index + 1] = hex_digits[byte & 0xf];
    }
    return out;
}

/// Runs the recipe once in a fresh sandbox and returns the snapshot of the
/// result. The builder is always deleted, because the snapshot outlives it.
fn build(env: Env, arena: Allocator, path: []const u8, script: []const u8, failure: *client_mod.Failure) Error![]const u8 {
    const name = try arena.print("{s}{x:0>8}{x:0>8}", .{ build_prefix, env.pid, env.random });
    const owner = try isolated.ownerTag(arena, env.host, env.pid);
    const session = try createBuilder(env, arena, name, owner, failure);
    const id = runBuilder(env, arena, session, name, path, script, failure) catch |err| {
        _ = workspace.deleteSandboxLogged(env.client, arena, name, "recipe builder");
        return err;
    };
    _ = workspace.deleteSandboxLogged(env.client, arena, name, "recipe builder");
    return id;
}

/// Creates the builder sandbox. A create whose answer was lost may have made
/// it, so its chosen name is deleted once.
fn createBuilder(env: Env, arena: Allocator, name: []const u8, owner: []const u8, failure: *client_mod.Failure) Error![]const u8 {
    const tags = [_]api.Pair{ .{ .name = "fx", .value = "build" }, .{ .name = "owner", .value = owner } };
    const created = env.client.createSandbox(arena, .{
        .name = name,
        .project = env.client.project,
        .persistent = false,
        .timeout_ms = build_limit_ms,
        .tags = &tags,
    }, failure) catch |err| {
        if (err == error.AnswerLost) {
            const removed = workspace.deleteSandboxLogged(env.client, arena, name, "recipe builder");
            debug_trace.logf("sandbox", "recipe builder answer was lost, sandbox {s} deleted={}", .{ name, removed });
        }
        return workspace.clientFailure(err);
    };
    return created.session_id;
}

/// Uploads the recipe, runs it, and takes the snapshot when it exits 0.
fn runBuilder(
    env: Env,
    arena: Allocator,
    session: []const u8,
    name: []const u8,
    path: []const u8,
    script: []const u8,
    failure: *client_mod.Failure,
) Error![]const u8 {
    const remote_dir = try arena.print("{s}/tmp/fx-recipe-{s}", .{ env.remote_root, name });
    const script_name = try arena.print("{s}.sh", .{name});
    _ = try workspace.runRemoteHelper(env.client, workspace.helper_deadline_ms, prepare_helper, arena, session, &.{ "prepare", remote_dir, remote_dir }, failure);
    try uploadScript(env, arena, session, remote_dir, script_name, script, failure);
    try announce(env, arena, path, failure);
    const outcome = try executor.execute(env.client, arena, .{
        .session = session,
        .command = try arena.print("bash {s}", .{script_name}),
        .remote_cwd = remote_dir,
        .login = true,
    }, .{
        .max_output_bytes = max_build_output_bytes,
        .deadline_ms = io_mod.milliTimestamp() + build_limit_ms,
    }, env.output);
    return finish(env, arena, session, path, outcome, failure);
}

/// Stages the script's bytes in fx's own folder and uploads them from there, so
/// the sandbox runs the bytes that were hashed, even if the file changed since.
fn uploadScript(
    env: Env,
    arena: Allocator,
    session: []const u8,
    remote_dir: []const u8,
    script_name: []const u8,
    script: []const u8,
    failure: *client_mod.Failure,
) Error!void {
    const zio = io_mod.getIo();
    const staging = try arena.print("{s}/build", .{env.sandbox_dir});
    io_mod.makeDirRecursive(staging) catch return workspace.localFailure(failure, "the build folder cannot be created");
    const staged = try arena.print("{s}/{s}", .{ staging, script_name });
    io_mod.writeFileAtomic(arena, staged, script) catch return workspace.localFailure(failure, "the recipe cannot be staged");
    defer std.Io.Dir.deleteFileAbsolute(zio, staged) catch {};
    const bytes = archive.build(arena, staging, &.{script_name}, .{ .max_bytes = env.max_recipe_bytes }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return workspace.localFailure(failure, "the recipe cannot be packed for the sandbox"),
    };
    env.client.writeArchive(arena, session, bytes, remote_dir, failure) catch |err| return workspace.clientFailure(err);
}

/// Tells the output relay, before the script runs, what is being built.
fn announce(env: Env, arena: Allocator, path: []const u8, failure: *client_mod.Failure) Error!void {
    const output = env.output orelse return;
    const line = try arena.print(announce_format, .{path});
    output.on_line(output.context, .stdout, line) catch return workspace.localFailure(failure, "the recipe output could not be shown");
}

/// Turns the run's outcome into the snapshot's id, or into the error that says why there is none.
fn finish(
    env: Env,
    arena: Allocator,
    session: []const u8,
    path: []const u8,
    outcome: executor.Outcome,
    failure: *client_mod.Failure,
) Error![]const u8 {
    if (outcome.failure) |detail| return sandboxFailed(failure, detail);
    if (!outcome.started) return sandboxFailed(failure, "the recipe did not start");
    if (outcome.connection_lost) return sandboxFailed(failure, "the connection ended before the recipe finished");
    if (outcome.stop == .timed_out) {
        failure.message = try arena.print("the recipe {s} took longer than 60 minutes", .{path});
        return error.RecipeFailed;
    }
    const code = outcome.exit_code orelse return sandboxFailed(failure, "the recipe did not report an exit code");
    if (code != 0) {
        const combined = try arena.alloc(u8, outcome.stdout.len + outcome.stderr.len);
        @memcpy(combined[0..outcome.stdout.len], outcome.stdout);
        @memcpy(combined[outcome.stdout.len..], outcome.stderr);
        const tail = try workspace.outputTail(arena, combined, max_failure_tail_bytes);
        failure.message = try arena.print("the recipe {s} failed with exit {d}: {s}", .{ path, code, tail });
        return error.RecipeFailed;
    }
    return env.client.snapshot(arena, session, env.expiration_ms, failure) catch |err| return workspace.clientFailure(err);
}

fn sandboxFailed(failure: *client_mod.Failure, message: []const u8) error{SandboxApiFailed} {
    failure.message = message;
    return error.SandboxApiFailed;
}

/// One saved snapshot: the recipe's path, the SHA-256 of its script, the
/// snapshot it made, and when it was built.
const Record = struct {
    path: []const u8,
    sha256: []const u8,
    snapshot: []const u8,
    built_s: i64,
};

/// Reads the saved records. A missing file means none. A file that cannot be
/// read or parsed counts as empty, and each drop is logged.
fn loadRecords(arena: Allocator, records_path: []const u8) Error![]const Record {
    const zio = io_mod.getIo();
    var file = std.Io.Dir.cwd().openFile(zio, records_path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            debug_trace.logf("sandbox", "snapshot records {s} cannot be opened, err={s}; they start over", .{ records_path, @errorName(err) });
        }
        return &.{};
    };
    defer file.close(zio);
    const bytes = io_mod.readFileToEnd(arena, &file, max_records_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("sandbox", "snapshot records {s} cannot be read, err={s}; they start over", .{ records_path, @errorName(err) });
            return &.{};
        },
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("sandbox", "snapshot records {s} are not JSON, err={s}; they start over", .{ records_path, @errorName(err) });
            return &.{};
        },
    };
    const object = switch (root) {
        .object => |map| map,
        else => {
            debug_trace.logf("sandbox", "snapshot records {s} are not an object; they start over", .{records_path});
            return &.{};
        },
    };
    var found: std.ArrayList(Record) = .empty;
    var entries = object.iterator();
    while (entries.next()) |entry| {
        const record = parseRecord(entry.key_ptr.*, entry.value_ptr.*) orelse {
            debug_trace.logf("sandbox", "snapshot record for {s} is malformed and is dropped", .{entry.key_ptr.*});
            continue;
        };
        try found.append(arena, record);
    }
    return found.items;
}

/// One record, or null when it is malformed. A null record counts as missing
/// for its recipe, so the recipe builds again.
fn parseRecord(path: []const u8, value: std.json.Value) ?Record {
    const fields = switch (value) {
        .object => |map| map,
        else => return null,
    };
    const sha256 = textField(fields, "sha256") orelse return null;
    const snapshot = textField(fields, "snapshot") orelse return null;
    const built_s = switch (fields.get("built_s") orelse return null) {
        .integer => |seconds| seconds,
        else => return null,
    };
    if (!isSha256Hex(sha256) or !isSnapshotId(snapshot)) return null;
    return .{ .path = path, .sha256 = sha256, .snapshot = snapshot, .built_s = built_s };
}

/// True for `snap_` and 1 to 64 letters or digits, the ids the API makes.
fn isSnapshotId(text: []const u8) bool {
    const prefix = "snap_";
    if (!std.mem.startsWith(u8, text, prefix)) return false;
    const rest = text[prefix.len..];
    if (rest.len == 0 or rest.len > 64) return false;
    for (rest) |byte| {
        const letter_or_digit = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9');
        if (!letter_or_digit) return false;
    }
    return true;
}

/// True for exactly 64 lowercase hex digits, the SHA-256 this module writes.
fn isSha256Hex(text: []const u8) bool {
    if (text.len != Sha256.digest_length * 2) return false;
    for (text) |byte| {
        const lower_hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!lower_hex) return false;
    }
    return true;
}

fn textField(fields: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = fields.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn findRecord(records: []const Record, path: []const u8) ?Record {
    for (records) |record| {
        if (std.mem.eql(u8, record.path, path)) return record;
    }
    return null;
}

/// The records with `next` in place of any record for the same recipe.
fn withRecord(arena: Allocator, records: []const Record, next: Record) Allocator.Error![]const Record {
    var out: std.ArrayList(Record) = .empty;
    for (records) |record| {
        if (!std.mem.eql(u8, record.path, next.path)) try out.append(arena, record);
    }
    try out.append(arena, next);
    return out.items;
}

/// Writes the records as one JSON object keyed by recipe path, through a temporary file.
fn saveRecords(arena: Allocator, records_path: []const u8, records: []const Record, failure: *client_mod.Failure) Error!void {
    const bytes = encodeRecords(arena, records) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return workspace.localFailure(failure, "the snapshot records cannot be written"),
    };
    io_mod.writeFileAtomic(arena, records_path, bytes) catch return workspace.localFailure(failure, "the snapshot records cannot be saved");
}

fn encodeRecords(arena: Allocator, records: []const Record) ![]const u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(arena, 256);
    try out.writer.writeAll("{");
    for (records, 0..) |record, index| {
        if (index > 0) try out.writer.writeAll(",");
        try std.json.Stringify.value(record.path, .{}, &out.writer);
        try out.writer.writeAll(":");
        try std.json.Stringify.value(.{
            .sha256 = record.sha256,
            .snapshot = record.snapshot,
            .built_s = record.built_s,
        }, .{}, &out.writer);
    }
    try out.writer.writeAll("}\n");
    return out.written();
}

// ---- tests ----

const testing = std.testing;
const test_sandbox = @import("test_sandbox.zig");
const FakeSandbox = test_sandbox.FakeSandbox;
const test_folder_mode = std.Io.File.Permissions.fromMode(0o755);

/// The folders one test uses. `disk` stands in for the sandbox disk.
const Fixture = struct {
    recipe: []const u8,
    sandbox_dir: []const u8,
    records: []const u8,
    disk: []const u8,
};

/// Makes the folders a test uses and writes the recipe with `script`.
fn makeFixture(arena: Allocator, tmp: *testing.TmpDir, script: []const u8) !Fixture {
    const zio = io_mod.getIo();
    try tmp.dir.createDir(zio, "recipes", test_folder_mode);
    try tmp.dir.createDir(zio, "state", test_folder_mode);
    try tmp.dir.createDir(zio, "disk", test_folder_mode);
    const base = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const fixture: Fixture = .{
        .recipe = try arena.print("{s}/recipes/build.sh", .{base}),
        .sandbox_dir = try arena.print("{s}/state", .{base}),
        .records = try arena.print("{s}/state/snapshots.json", .{base}),
        .disk = try arena.print("{s}/disk", .{base}),
    };
    try writeText(fixture.recipe, script);
    return fixture;
}

fn writeText(path: []const u8, text: []const u8) !void {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.createFileAbsolute(zio, path, .{});
    defer file.close(zio);
    try file.writeStreamingAll(zio, text);
}

fn testEnv(fake: *FakeSandbox, fixture: Fixture) Env {
    return .{
        .client = test_sandbox.fakeClient(fake),
        .remote_root = fixture.disk,
        .sandbox_dir = fixture.sandbox_dir,
        .host = "host.test",
        .pid = 42,
        .random = 0x1234abcd,
    };
}

fn snapshotId(source: config.Source) ![]const u8 {
    return switch (source) {
        .snapshot => |id| id,
        else => error.TestUnexpectedResult,
    };
}

fn readJson(arena: Allocator, path: []const u8) !std.json.Value {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{});
    defer file.close(zio);
    const bytes = try io_mod.readFileToEnd(arena, &file, 1 << 20);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
}

fn fileExists(path: []const u8) bool {
    const zio = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch return false;
    file.close(zio);
    return true;
}

fn hasLine(lines: []const []const u8, text: []const u8) bool {
    for (lines) |line| {
        if (std.mem.eql(u8, line, text)) return true;
    }
    return false;
}

fn hasLineStarting(lines: []const []const u8, prefix: []const u8) bool {
    for (lines) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

/// Collects the live output a recipe run relays.
const Collector = struct {
    arena: Allocator,
    lines: std.ArrayList([]const u8) = .empty,

    fn onLine(context: *anyopaque, stream: api.Stream, line: []const u8) anyerror!void {
        _ = stream;
        const self: *Collector = @ptrCast(@alignCast(context));
        try self.lines.append(self.arena, try self.arena.dupe(u8, line));
    }
};

test "other sources pass through untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp, "echo unused\n");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture);
    var failure: client_mod.Failure = .{};

    const image = try resolve(env, arena, .{ .image = "node:22" }, &failure);
    try testing.expectEqualStrings("node:22", image.image);
    const snapshot = try resolve(env, arena, .{ .snapshot = "snap_x" }, &failure);
    try testing.expectEqualStrings("snap_x", snapshot.snapshot);
    const plain = try resolve(env, arena, .default, &failure);
    try testing.expectEqual(std.meta.Tag(config.Source).default, std.meta.activeTag(plain));
    try testing.expectEqual(@as(usize, 0), fake.creates + fake.deletes + fake.commands + fake.gets + fake.writes + fake.reads + fake.snapshot_count);
}

test "a recipe builds once and is reused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = "echo built > /dev/null\n";
    const fixture = try makeFixture(arena, &tmp, script);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture);
    var failure: client_mod.Failure = .{};

    const first = try snapshotId(try resolve(env, arena, .{ .recipe = fixture.recipe }, &failure));
    const second = try snapshotId(try resolve(env, arena, .{ .recipe = fixture.recipe }, &failure));
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.startsWith(u8, first, "snap_"));
    try testing.expectEqual(@as(usize, 1), fake.creates);
    try testing.expectEqual(@as(usize, 1), fake.snapshot_count);
    try testing.expectEqual(@as(usize, 1), fake.deletes);
    try testing.expect(std.mem.startsWith(u8, fake.deleted_names[0].get(), build_prefix));

    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, fake.create_bodies[0].get(), .{});
    const tags = body.object.get("tags").?.object;
    try testing.expectEqualStrings("build", tags.get("fx").?.string);

    const saved = (try readJson(arena, fixture.records)).object.get(fixture.recipe).?.object;
    try testing.expectEqualStrings(try sha256Hex(arena, script), saved.get("sha256").?.string);
    try testing.expectEqualStrings(first, saved.get("snapshot").?.string);
}

test "a changed recipe builds again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp, "echo one > /dev/null\n");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture);
    var failure: client_mod.Failure = .{};

    const first = try snapshotId(try resolve(env, arena, .{ .recipe = fixture.recipe }, &failure));
    const changed = "echo two > /dev/null\n";
    try writeText(fixture.recipe, changed);
    const second = try snapshotId(try resolve(env, arena, .{ .recipe = fixture.recipe }, &failure));
    try testing.expect(!std.mem.eql(u8, first, second));
    try testing.expectEqual(@as(usize, 2), fake.creates);

    const saved = (try readJson(arena, fixture.records)).object.get(fixture.recipe).?.object;
    try testing.expectEqualStrings(try sha256Hex(arena, changed), saved.get("sha256").?.string);
    try testing.expectEqualStrings(second, saved.get("snapshot").?.string);
}

test "a snapshot that is gone builds again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp, "echo built > /dev/null\n");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture);
    var failure: client_mod.Failure = .{};

    const first = try snapshotId(try resolve(env, arena, .{ .recipe = fixture.recipe }, &failure));
    fake.markSnapshotGone(first);
    const second = try snapshotId(try resolve(env, arena, .{ .recipe = fixture.recipe }, &failure));
    try testing.expect(!std.mem.eql(u8, first, second));
    try testing.expectEqual(@as(usize, 2), fake.creates);
}

test "a failing recipe says why and leaves no builder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp, "echo nope; exit 3\n");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture);
    var failure: client_mod.Failure = .{};

    try testing.expectError(error.RecipeFailed, resolve(env, arena, .{ .recipe = fixture.recipe }, &failure));
    try testing.expect(std.mem.find(u8, failure.message, "exit 3") != null);
    try testing.expect(std.mem.find(u8, failure.message, "nope") != null);
    try testing.expectEqual(@as(usize, 1), fake.creates);
    try testing.expectEqual(@as(usize, 1), fake.deletes);
    try testing.expectEqual(@as(usize, 0), fake.snapshot_count);
    try testing.expect(!fileExists(fixture.records));
}

test "the recipe's output reaches the output relay" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp, "echo built\n");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var collector: Collector = .{ .arena = arena };
    var env = testEnv(&fake, fixture);
    env.output = .{ .context = &collector, .on_line = Collector.onLine };
    var failure: client_mod.Failure = .{};

    _ = try resolve(env, arena, .{ .recipe = fixture.recipe }, &failure);
    try testing.expect(hasLineStarting(collector.lines.items, "fx: building a snapshot from "));
    try testing.expect(hasLine(collector.lines.items, "built\n"));
}

test "an unreadable recipe fails before any sandbox" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try makeFixture(arena, &tmp, "echo unused\n");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture);
    var failure: client_mod.Failure = .{};
    const missing = try arena.print("{s}.missing", .{fixture.recipe});

    try testing.expectError(error.LocalFailed, resolve(env, arena, .{ .recipe = missing }, &failure));
    try testing.expect(std.mem.find(u8, failure.message, "cannot be read") != null);
    try testing.expectEqual(@as(usize, 0), fake.creates);
}

test "a record with a bad snapshot id is treated as missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = "echo built > /dev/null\n";
    const fixture = try makeFixture(arena, &tmp, script);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture);
    var failure: client_mod.Failure = .{};

    // A record for this exact script, but with a snapshot id the API does not make.
    const bad = try arena.print("{{\"{s}\":{{\"sha256\":\"{s}\",\"snapshot\":\"bad id\",\"built_s\":1}}}}", .{
        fixture.recipe,
        try sha256Hex(arena, script),
    });
    try writeText(fixture.records, bad);

    const id = try snapshotId(try resolve(env, arena, .{ .recipe = fixture.recipe }, &failure));
    try testing.expectEqualStrings("snap_1", id);
    try testing.expectEqual(@as(usize, 1), fake.creates);
    try testing.expectEqual(@as(usize, 1), fake.snapshot_count);
    const saved = (try readJson(arena, fixture.records)).object.get(fixture.recipe).?.object;
    try testing.expectEqualStrings("snap_1", saved.get("snapshot").?.string);
}

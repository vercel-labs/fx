//! Pure decisions that keep a workspace sandbox in step with this machine.
//! The machine is the source of truth: a file that changed here since the
//! last sync is never overwritten by the sandbox's copy.
const std = @import("std");

const max_path_bytes = 4096;
const sha_len = 40;
const null_blob = "0000000000" ++ "0000000000" ++ "0000000000" ++ "0000000000";
const git_dir = ".git";

/// A path that may move between this machine and a sandbox: relative, at
/// most 4096 bytes, no empty, `.` or `..` part, not `.git` or inside it, and
/// no byte below 0x20 or 0x7f.
pub fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes) return false;
    for (path) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        // macOS folds case, so `.GIT` names the same folder as `.git`.
        if (std.ascii.eqlIgnoreCase(part, git_dir)) return false;
    }
    return true;
}

/// The file mode of one side of a change. `absent` means the side has no file.
pub const Mode = enum { file, executable, symlink, other, absent };

/// One path that a command changed in the sandbox, from `git diff --raw`.
pub const Change = struct {
    path: []const u8,
    /// Null when the command added the path.
    old_blob: ?[]const u8,
    /// Null when the command deleted the path.
    new_blob: ?[]const u8,
    new_mode: Mode,
};

pub const ParseError = error{ InvalidDiff, OutOfMemory };

/// Parses `git diff --cached --raw -z --no-renames --abbrev=40 <base>` output.
/// Slices may point into `bytes`.
pub fn parseRawDiff(arena: std.mem.Allocator, bytes: []const u8) ParseError![]const Change {
    var changes: std.ArrayList(Change) = .empty;
    var rest = bytes;
    while (rest.len > 0) {
        if (rest[0] != ':') return error.InvalidDiff;
        const header_end = std.mem.findScalar(u8, rest, 0) orelse return error.InvalidDiff;
        const header = try parseHeader(rest[1..header_end]);
        rest = rest[header_end + 1 ..];
        const path_end = std.mem.findScalar(u8, rest, 0) orelse return error.InvalidDiff;
        const path = rest[0..path_end];
        if (path.len == 0) return error.InvalidDiff;
        rest = rest[path_end + 1 ..];
        try changes.append(arena, .{
            .path = path,
            .old_blob = header.old_blob,
            .new_blob = header.new_blob,
            .new_mode = header.new_mode,
        });
    }
    return changes.toOwnedSlice(arena);
}

const Header = struct {
    old_blob: ?[]const u8,
    new_blob: ?[]const u8,
    new_mode: Mode,
};

/// Reads `<old mode> <new mode> <old sha> <new sha> <status>`.
fn parseHeader(text: []const u8) ParseError!Header {
    var fields: [5][]const u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, ' ');
    while (parts.next()) |part| {
        if (count == fields.len) return error.InvalidDiff;
        fields[count] = part;
        count += 1;
    }
    if (count != fields.len) return error.InvalidDiff;
    if (parseMode(fields[0]) == null) return error.InvalidDiff;
    const new_mode = parseMode(fields[1]) orelse return error.InvalidDiff;
    if (!isSha(fields[2]) or !isSha(fields[3])) return error.InvalidDiff;
    const status = fields[4];
    if (status.len != 1 or std.mem.findScalar(u8, "ADMT", status[0]) == null) {
        return error.InvalidDiff;
    }
    return .{
        .old_blob = blobOrNull(fields[2]),
        .new_blob = blobOrNull(fields[3]),
        .new_mode = new_mode,
    };
}

fn parseMode(text: []const u8) ?Mode {
    if (std.mem.eql(u8, text, "100644")) return .file;
    if (std.mem.eql(u8, text, "100755")) return .executable;
    if (std.mem.eql(u8, text, "120000")) return .symlink;
    if (std.mem.eql(u8, text, "160000")) return .other;
    if (std.mem.eql(u8, text, "000000")) return .absent;
    return null;
}

fn isSha(text: []const u8) bool {
    if (text.len != sha_len) return false;
    for (text) |byte| {
        const hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!hex) return false;
    }
    return true;
}

fn blobOrNull(sha: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, sha, null_blob)) null else sha;
}

/// What to do with one change when the sandbox's copy comes back.
pub const Action = enum {
    /// Write the sandbox's version here.
    take,
    /// This machine already has the sandbox's version.
    already_same,
    /// Both sides changed the file. This machine's version stays.
    conflict,
    /// Never brought back: an unsafe path, a link, or a submodule.
    refuse,
};

/// Decides one change by the 3-way rule. `local_blob` is the blob id of the
/// file here now, or null when it is missing.
pub fn decide(change: Change, local_blob: ?[]const u8) Action {
    if (!safeRelativePath(change.path)) return .refuse;
    if (change.new_mode == .symlink or change.new_mode == .other) return .refuse;
    if (sameBlob(local_blob, change.new_blob)) return .already_same;
    if (sameBlob(local_blob, change.old_blob)) return .take;
    return .conflict;
}

/// Two blob ids match when both are null or both hold the same id.
fn sameBlob(a: ?[]const u8, b: ?[]const u8) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return std.mem.eql(u8, left, right);
}

pub const Upload = struct {
    /// Paths to copy from this machine.
    send: []const []const u8,
    /// Paths to delete in the sandbox.
    remove: []const []const u8,
};

/// Parses `git diff-tree -r -z --no-renames --name-status <old> <new>` output
/// and adds `forced` paths, which the last bring-back touched. A forced path
/// is sent when `exists` says it is in the new tree, else removed. A path the
/// diff already lists keeps the diff's action. Each path appears once.
/// Unsafe paths, repeated paths, and mismatched lists fail with `InvalidDiff`.
pub fn planUpload(
    arena: std.mem.Allocator,
    name_status: []const u8,
    forced: []const []const u8,
    exists: []const bool,
) ParseError!Upload {
    if (forced.len != exists.len) return error.InvalidDiff;
    var send: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;
    var seen: std.array_hash_map.String(void) = .empty;
    var rest = name_status;
    while (rest.len > 0) {
        if (rest.len < 2 or rest[1] != 0) return error.InvalidDiff;
        const status = rest[0];
        rest = rest[2..];
        const path_end = std.mem.findScalar(u8, rest, 0) orelse return error.InvalidDiff;
        const path = rest[0..path_end];
        rest = rest[path_end + 1 ..];
        if (!safeRelativePath(path)) return error.InvalidDiff;
        const slot = try seen.getOrPut(arena, path);
        if (slot.found_existing) return error.InvalidDiff;
        switch (status) {
            'A', 'M', 'T' => try send.append(arena, path),
            'D' => try remove.append(arena, path),
            else => return error.InvalidDiff,
        }
    }
    var forced_seen: std.array_hash_map.String(void) = .empty;
    for (forced, exists) |path, present| {
        if (!safeRelativePath(path)) return error.InvalidDiff;
        const repeated = try forced_seen.getOrPut(arena, path);
        if (repeated.found_existing) return error.InvalidDiff;
        const slot = try seen.getOrPut(arena, path);
        if (slot.found_existing) continue;
        if (present) {
            try send.append(arena, path);
        } else {
            try remove.append(arena, path);
        }
    }
    return .{
        .send = try send.toOwnedSlice(arena),
        .remove = try remove.toOwnedSlice(arena),
    };
}

const sha_a = "aaaaaaaaaa" ++ "aaaaaaaaaa" ++ "aaaaaaaaaa" ++ "aaaaaaaaaa";
const sha_b = "bbbbbbbbbb" ++ "bbbbbbbbbb" ++ "bbbbbbbbbb" ++ "bbbbbbbbbb";
const sha_c = "cccccccccc" ++ "cccccccccc" ++ "cccccccccc" ++ "cccccccccc";
const sha_d = "dddddddddd" ++ "dddddddddd" ++ "dddddddddd" ++ "dddddddddd";

fn expectPaths(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "safe paths stay inside the repository" {
    const safe = [_][]const u8{ "src/a.zig", "a", "dir/.gitignore", ".github/x.yml" };
    for (safe) |path| try std.testing.expect(safeRelativePath(path));

    const unsafe = [_][]const u8{
        "",
        "/etc/passwd",
        "../x",
        "a/../b",
        "a//b",
        "./a",
        ".git",
        ".git/config",
        "sub/.git/HEAD",
        ".GIT/config",
        "a\x00b",
        "a\nb",
    };
    for (unsafe) |path| try std.testing.expect(!safeRelativePath(path));

    const longest: [4096]u8 = @splat('a');
    try std.testing.expect(safeRelativePath(&longest));
    const too_long: [4097]u8 = @splat('a');
    try std.testing.expect(!safeRelativePath(&too_long));
}

test "raw diffs parse adds, edits, deletes, and modes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = ":000000 100644 " ++ null_blob ++ " " ++ sha_a ++ " A\x00src/new.zig\x00" ++
        ":100644 100755 " ++ sha_a ++ " " ++ sha_b ++ " M\x00tool.sh\x00" ++
        ":100644 000000 " ++ sha_c ++ " " ++ null_blob ++ " D\x00gone.txt\x00" ++
        ":000000 120000 " ++ null_blob ++ " " ++ sha_d ++ " A\x00link\x00";

    const changes = try parseRawDiff(arena, bytes);
    try std.testing.expectEqual(@as(usize, 4), changes.len);

    try std.testing.expectEqualStrings("src/new.zig", changes[0].path);
    try std.testing.expect(changes[0].old_blob == null);
    try std.testing.expectEqualStrings(sha_a, changes[0].new_blob.?);
    try std.testing.expectEqual(Mode.file, changes[0].new_mode);

    try std.testing.expectEqualStrings("tool.sh", changes[1].path);
    try std.testing.expectEqualStrings(sha_a, changes[1].old_blob.?);
    try std.testing.expectEqualStrings(sha_b, changes[1].new_blob.?);
    try std.testing.expectEqual(Mode.executable, changes[1].new_mode);

    try std.testing.expectEqualStrings("gone.txt", changes[2].path);
    try std.testing.expectEqualStrings(sha_c, changes[2].old_blob.?);
    try std.testing.expect(changes[2].new_blob == null);
    try std.testing.expectEqual(Mode.absent, changes[2].new_mode);

    try std.testing.expectEqualStrings("link", changes[3].path);
    try std.testing.expect(changes[3].old_blob == null);
    try std.testing.expectEqualStrings(sha_d, changes[3].new_blob.?);
    try std.testing.expectEqual(Mode.symlink, changes[3].new_mode);

    const none = try parseRawDiff(arena, "");
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "bad raw diffs are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = [_][]const u8{
        // No NUL after the header.
        ":000000 100644 " ++ null_blob ++ " " ++ sha_a ++ " A",
        // A mode outside the five git writes.
        ":100600 100644 " ++ null_blob ++ " " ++ sha_a ++ " A\x00a\x00",
        // A 39-character sha.
        ":000000 100644 " ++ null_blob ++ " " ++ sha_a[0..39] ++ " A\x00a\x00",
        // A status this module does not handle.
        ":000000 100644 " ++ null_blob ++ " " ++ sha_a ++ " R\x00a\x00",
        // A record with no path.
        ":000000 100644 " ++ null_blob ++ " " ++ sha_a ++ " A\x00\x00",
        // A path with no NUL after it.
        ":000000 100644 " ++ null_blob ++ " " ++ sha_a ++ " A\x00a",
    };
    for (bad) |bytes| {
        try std.testing.expectError(error.InvalidDiff, parseRawDiff(arena, bytes));
    }
}

test "the 3-way rule never overwrites a local edit" {
    const modify: Change = .{ .path = "a.txt", .old_blob = sha_a, .new_blob = sha_b, .new_mode = .file };
    try std.testing.expectEqual(Action.take, decide(modify, sha_a));
    try std.testing.expectEqual(Action.already_same, decide(modify, sha_b));
    try std.testing.expectEqual(Action.conflict, decide(modify, sha_c));

    const add: Change = .{ .path = "new.txt", .old_blob = null, .new_blob = sha_b, .new_mode = .file };
    try std.testing.expectEqual(Action.take, decide(add, null));
    try std.testing.expectEqual(Action.conflict, decide(add, sha_c));

    const delete: Change = .{ .path = "gone.txt", .old_blob = sha_a, .new_blob = null, .new_mode = .absent };
    try std.testing.expectEqual(Action.take, decide(delete, sha_a));
    try std.testing.expectEqual(Action.already_same, decide(delete, null));
    try std.testing.expectEqual(Action.conflict, decide(delete, sha_c));
}

test "links, submodules, and unsafe paths never come back" {
    const link: Change = .{ .path = "link", .old_blob = null, .new_blob = sha_d, .new_mode = .symlink };
    const submodule: Change = .{ .path = "vendor/lib", .old_blob = null, .new_blob = sha_d, .new_mode = .other };
    const hook: Change = .{ .path = ".git/hooks/pre-commit", .old_blob = sha_a, .new_blob = sha_b, .new_mode = .file };
    for ([_]?[]const u8{ null, sha_a, sha_b, sha_d }) |local| {
        try std.testing.expectEqual(Action.refuse, decide(link, local));
        try std.testing.expectEqual(Action.refuse, decide(submodule, local));
        try std.testing.expectEqual(Action.refuse, decide(hook, local));
    }
}

test "uploads join the diff with forced paths once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const forced = [_][]const u8{ "a", "d", "e" };
    const exists = [_]bool{ true, false, true };

    const plan = try planUpload(arena, "M\x00a\x00D\x00b\x00A\x00c\x00", &forced, &exists);
    try expectPaths(&.{ "a", "c", "e" }, plan.send);
    try expectPaths(&.{ "b", "d" }, plan.remove);
}

test "uploads refuse unsafe paths and mismatched lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none_paths: []const []const u8 = &.{};
    const none_flags: []const bool = &.{};

    try std.testing.expectError(error.InvalidDiff, planUpload(arena, "M\x00../x\x00", none_paths, none_flags));

    const forced = [_][]const u8{"a"};
    try std.testing.expectError(error.InvalidDiff, planUpload(arena, "", &forced, none_flags));

    // A path listed twice in the diff, or twice in the forced list, fails.
    try std.testing.expectError(error.InvalidDiff, planUpload(arena, "M\x00a\x00M\x00a\x00", none_paths, none_flags));
    const twice = [_][]const u8{ "b", "b" };
    const twice_flags = [_]bool{ true, false };
    try std.testing.expectError(error.InvalidDiff, planUpload(arena, "", &twice, &twice_flags));
}

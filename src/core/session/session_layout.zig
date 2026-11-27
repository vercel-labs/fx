const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const session_id_random_bytes: usize = 9;
const session_id_encoded_bytes = std.base64.url_safe_no_pad.Encoder.calcSize(session_id_random_bytes);
const terminal_session_id_prefix = "shell-";
const terminal_session_id_random_bytes: usize = 16;

pub fn sessionDirPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    try validateSessionId(session_id);
    return std.Io.Dir.path.join(alloc, &.{ sessions_dir, session_id });
}

/// The sessions v2 root inside the v1 sessions folder. No v1 id can take
/// this name in any case (macOS folders are case-insensitive by default),
/// so every scan of the v1 folder skips it and no v1 path reaches it.
pub const sessions_v2_dir = "v2";

pub fn validateSessionId(session_id: []const u8) !void {
    if (session_id.len == 0 or session_id.len > 255 or
        std.mem.eql(u8, session_id, ".") or std.mem.eql(u8, session_id, "..") or
        std.ascii.eqlIgnoreCase(session_id, sessions_v2_dir))
    {
        return error.InvalidSessionId;
    }
    for (session_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidSessionId;
        }
    }
}

/// The ID of the session a folder names, for `--resume <folder>`. The folder
/// must sit directly in `sessions_v2_root`. Both paths are resolved first, so
/// a symlink or `..` that leaves that folder is refused. The caller owns the ID.
pub fn sessionIdFromFolder(alloc: Allocator, sessions_v2_root: []const u8, folder: []const u8) error{ NotSessionFolder, OutOfMemory }![]u8 {
    const root = io_mod.realpathAlloc(alloc, sessions_v2_root) catch |err| return mapRealpathError(err);
    defer alloc.free(root);
    const real = io_mod.realpathAlloc(alloc, folder) catch |err| return mapRealpathError(err);
    defer alloc.free(real);
    const parent = std.Io.Dir.path.dirname(real) orelse return error.NotSessionFolder;
    if (!std.mem.eql(u8, parent, root)) return error.NotSessionFolder;
    const id = std.Io.Dir.path.basename(real);
    validateSessionId(id) catch return error.NotSessionFolder;
    return alloc.dupe(u8, id);
}

fn mapRealpathError(err: anyerror) error{ NotSessionFolder, OutOfMemory } {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.NotSessionFolder;
}

/// A fresh id: 9 random bytes as base64url. It never starts with `-`, so no
/// command reads it as a flag, as `fx session` reads an id that starts with
/// `--`. The caller owns the id.
pub fn generateSessionId(alloc: Allocator) ![]u8 {
    var random_bytes: [session_id_random_bytes]u8 = undefined;
    const id = try alloc.alloc(u8, session_id_encoded_bytes);
    while (true) {
        io_mod.getIo().random(&random_bytes);
        _ = std.base64.url_safe_no_pad.Encoder.encode(id, &random_bytes);
        if (id[0] != '-') return id;
    }
}

pub fn generateTerminalSessionId(alloc: Allocator) ![]u8 {
    var random_bytes: [terminal_session_id_random_bytes]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len);
    const id = try alloc.alloc(u8, terminal_session_id_prefix.len + encoded_len);
    @memcpy(id[0..terminal_session_id_prefix.len], terminal_session_id_prefix);
    _ = std.base64.url_safe_no_pad.Encoder.encode(
        id[terminal_session_id_prefix.len..],
        &random_bytes,
    );
    return id;
}

test "generated session id is a compact url-safe token" {
    const id = try generateSessionId(std.testing.allocator);
    defer std.testing.allocator.free(id);

    try std.testing.expectEqual(@as(usize, 12), id.len);
    try validateSessionId(id);
    for (id) |byte| {
        try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_');
    }

    try validateSessionId("1786460757753-1786460757753277000-ef75d8fd94fdab1");
}

test "a generated session id never starts with a dash" {
    // One random id in 64 would start with `-`.
    for (0..4096) |_| {
        const id = try generateSessionId(std.testing.allocator);
        defer std.testing.allocator.free(id);
        try std.testing.expect(id[0] != '-');
    }
}

test "generated terminal session id is compact and path safe" {
    const id = try generateTerminalSessionId(std.testing.allocator);
    defer std.testing.allocator.free(id);

    try std.testing.expectEqual(terminal_session_id_prefix.len + 22, id.len);
    try std.testing.expect(std.mem.startsWith(u8, id, terminal_session_id_prefix));
    try validateSessionId(id);
}

test "session directory path rejects unsafe ids" {
    const alloc = std.testing.allocator;
    inline for (.{ "", ".", "..", "../outside", "/tmp/outside", "nested/session", "nested\\session" }) |id| {
        try std.testing.expectError(error.InvalidSessionId, sessionDirPath(alloc, "/tmp/sessions", id));
    }

    const unsupported = [_]u8{ 0xff, 'a' };
    try std.testing.expectError(
        error.InvalidSessionId,
        sessionDirPath(alloc, "/tmp/sessions", &unsupported),
    );

    var too_long: [256]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expectError(
        error.InvalidSessionId,
        sessionDirPath(alloc, "/tmp/sessions", &too_long),
    );

    const dotted = try sessionDirPath(alloc, "/tmp/sessions", "session.v3");
    defer alloc.free(dotted);
    try std.testing.expectEqualStrings("/tmp/sessions/session.v3", dotted);
    inline for (.{
        ".hidden-session",
        "session..branch",
        "last",
        "resume",
    }) |id| {
        const valid = try sessionDirPath(alloc, "/tmp/sessions", id);
        alloc.free(valid);
    }

    const nul_id = [_]u8{ 'a', 0, 'b' };
    try std.testing.expectError(
        error.InvalidSessionId,
        sessionDirPath(alloc, "/tmp/sessions", &nul_id),
    );

    var max_id: [255]u8 = undefined;
    @memset(&max_id, 'a');
    const maximum = try sessionDirPath(alloc, "/tmp/sessions", &max_id);
    defer alloc.free(maximum);
    try std.testing.expect(std.mem.endsWith(u8, maximum, &max_id));
}

test "the sessions v2 root is never a v1 session id" {
    try std.testing.expectError(error.InvalidSessionId, validateSessionId(sessions_v2_dir));
    try std.testing.expectError(error.InvalidSessionId, validateSessionId("V2"));
    try validateSessionId("v2x");
}

test "a session folder gives its id, with or without a trailing slash" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "sessions/v2/session-123");
    const v2 = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "sessions/v2");
    defer alloc.free(v2);
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "sessions/v2/session-123");
    defer alloc.free(folder);

    const id = try sessionIdFromFolder(alloc, v2, folder);
    defer alloc.free(id);
    try std.testing.expectEqualStrings("session-123", id);

    const with_slash = try alloc.print("{s}/", .{folder});
    defer alloc.free(with_slash);
    const slashed = try sessionIdFromFolder(alloc, v2, with_slash);
    defer alloc.free(slashed);
    try std.testing.expectEqualStrings("session-123", slashed);
}

test "a folder that is not a session folder in the profile is refused" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "sessions/v2/session-123");
    try tmp.dir.createDirPath(io_mod.getIo(), "sessions/v2/bad name");
    try tmp.dir.createDirPath(io_mod.getIo(), "sessions/v1/session-456");
    try tmp.dir.createDirPath(io_mod.getIo(), "outside/session-789");
    tmp.dir.symLink(io_mod.getIo(), "../../outside/session-789", "sessions/v2/escape", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    const v2 = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "sessions/v2");
    defer alloc.free(v2);
    const sibling = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "sessions/v1/session-456");
    defer alloc.free(sibling);
    const outside = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outside/session-789");
    defer alloc.free(outside);
    const bad_name = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "sessions/v2/bad name");
    defer alloc.free(bad_name);
    const escape = try alloc.print("{s}/escape", .{v2});
    defer alloc.free(escape);
    const dotdot = try alloc.print("{s}/session-123/../../../outside/session-789", .{v2});
    defer alloc.free(dotdot);
    const missing = try alloc.print("{s}/missing-123", .{v2});
    defer alloc.free(missing);

    try std.testing.expectError(error.NotSessionFolder, sessionIdFromFolder(alloc, v2, v2));
    try std.testing.expectError(error.NotSessionFolder, sessionIdFromFolder(alloc, v2, sibling));
    try std.testing.expectError(error.NotSessionFolder, sessionIdFromFolder(alloc, v2, outside));
    try std.testing.expectError(error.NotSessionFolder, sessionIdFromFolder(alloc, v2, escape));
    try std.testing.expectError(error.NotSessionFolder, sessionIdFromFolder(alloc, v2, dotdot));
    try std.testing.expectError(error.NotSessionFolder, sessionIdFromFolder(alloc, v2, missing));
    try std.testing.expectError(error.NotSessionFolder, sessionIdFromFolder(alloc, v2, bad_name));
}

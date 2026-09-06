const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const session_id_random_bytes: usize = 9;
const session_id_encoded_bytes = std.base64.url_safe_no_pad.Encoder.calcSize(session_id_random_bytes);
const terminal_session_id_prefix = "shell-";
const terminal_session_id_random_bytes: usize = 16;

pub fn sessionDirPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    try validateSessionId(session_id);
    return std.fs.path.join(alloc, &.{ sessions_dir, session_id });
}

pub fn validateSessionId(session_id: []const u8) !void {
    if (session_id.len == 0 or session_id.len > 255 or
        std.mem.eql(u8, session_id, ".") or std.mem.eql(u8, session_id, ".."))
    {
        return error.InvalidSessionId;
    }
    for (session_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidSessionId;
        }
    }
}

pub fn generateSessionId(alloc: Allocator) ![]u8 {
    var random_bytes: [session_id_random_bytes]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const id = try alloc.alloc(u8, session_id_encoded_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(id, &random_bytes);
    return id;
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

const std = @import("std");
const shell_snapshot = @import("../terminal/shell_snapshot.zig");

const Allocator = std.mem.Allocator;

/// The notice of a shell run's result JSON, such as the reason line and the
/// host's timeout line, joined by newlines. The shell snapshot warning is left
/// out, since the TUI and `fx ask` already show it through their own notice.
/// The caller owns the text. Null when the result has no such line, or is not
/// a JSON object with a string `notice`.
pub fn visibleNotice(alloc: Allocator, result_json: []const u8) Allocator.Error!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, result_json, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const notice = switch (object.get("notice") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var any = false;
    var lines = std.mem.splitScalar(u8, notice, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, shell_snapshot.fallback_notice_prefix)) continue;
        if (any) out.writer.writeByte('\n') catch return error.OutOfMemory;
        out.writer.writeAll(line) catch return error.OutOfMemory;
        any = true;
    }
    if (!any) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

test "visibleNotice keeps the reason line of a notice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = (try visibleNotice(
        arena.allocator(),
        "{\"state\":\"completed\",\"notice\":\"fx: ran on local because of your rule for uname -s*\"}",
    )).?;
    try std.testing.expectEqualStrings("fx: ran on local because of your rule for uname -s*", text);
}

test "visibleNotice drops the snapshot warning and keeps the reason and host lines in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        "{\"state\":\"stopped\",\"notice\":\"shell snapshot unavailable (timed out); startup files run for every command\\n" ++
        "fx: ran on remote because of your rule for make*\\nfx: timed out after 1000 ms\"}";
    const text = (try visibleNotice(arena.allocator(), json)).?;
    try std.testing.expectEqualStrings("fx: ran on remote because of your rule for make*\nfx: timed out after 1000 ms", text);
}

test "visibleNotice gives nothing for a result with no notice, or with only the snapshot warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try visibleNotice(arena.allocator(), "{\"state\":\"completed\",\"output_delta\":\"hi\\n\"}")) == null);
    try std.testing.expect((try visibleNotice(
        arena.allocator(),
        "{\"notice\":\"shell snapshot unavailable (timed out); startup files run for every command\"}",
    )) == null);
}

test "visibleNotice gives nothing for a malformed result, and never fails on one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const malformed = [_][]const u8{ "", "not json", "{\"notice\":", "[\"notice\"]", "{\"notice\":5}", "{\"notice\":[]}" };
    for (malformed) |json| {
        try std.testing.expect((try visibleNotice(arena.allocator(), json)) == null);
    }
}

//! The last answer AI Gateway gave about each team's Token Pass, saved in the
//! profile as `token-pass.json`, so a session knows it from its first frame.
//! A team is named by `token_pass.identity`, a hash that holds no secret.
//! fx checks the answer again as each session starts and saves it when it
//! changes. A missing or unreadable file means fx knows nothing yet.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const token_pass = @import("token_pass.zig");

const Allocator = std.mem.Allocator;

const file_name = "token-pass.json";
const max_file_bytes: usize = 16 * 1024;
/// The most teams the file remembers. A new team past this drops the one
/// saved longest ago.
const max_teams: usize = 16;

/// The answer saved for `id`, or null when fx has none or cannot read it.
pub fn load(alloc: Allocator, home: []const u8, id: []const u8) ?token_pass.Answer {
    const path = profile_paths.rootPath(alloc, home, &.{file_name}) catch return null;
    defer alloc.free(path);
    const bytes = readFile(alloc, path) orelse return null;
    defer alloc.free(bytes);
    return answerIn(alloc, bytes, id);
}

/// Saves `answer` for `id`, keeping the other teams' answers. Writes nothing
/// when the file already holds that answer.
pub fn save(alloc: Allocator, home: []const u8, id: []const u8, answer: token_pass.Answer) !void {
    const path = try profile_paths.rootPath(alloc, home, &.{file_name});
    defer alloc.free(path);
    const existing = readFile(alloc, path);
    defer if (existing) |bytes| alloc.free(bytes);
    if (existing) |bytes| {
        if (answerIn(alloc, bytes, id) == answer) return;
    }
    const text = try encodeWith(alloc, existing, id, answer);
    defer alloc.free(text);
    const root = try profile_paths.rootDir(alloc, home);
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), root);
    try io_mod.writeFileAtomic(alloc, path, text);
}

fn readFile(alloc: Allocator, path: []const u8) ?[]u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| {
        if (err != error.FileNotFound) debug_trace.logf("token_pass", "saved answers unreadable err={s}", .{@errorName(err)});
        return null;
    };
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch |err| {
        debug_trace.logf("token_pass", "saved answers unreadable err={s}", .{@errorName(err)});
        return null;
    };
}

fn parseAnswer(text: []const u8) ?token_pass.Answer {
    return std.meta.stringToEnum(token_pass.Answer, text);
}

/// The answer `bytes` holds for `id`, or null when it holds none or is not
/// a saved-answers file.
fn answerIn(alloc: Allocator, bytes: []const u8, id: []const u8) ?token_pass.Answer {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch {
        debug_trace.logf("token_pass", "saved answers ignored reason=malformed", .{});
        return null;
    };
    defer parsed.deinit();
    const teams = teamsOf(parsed.value) orelse return null;
    const value = teams.get(id) orelse return null;
    if (value != .string) return null;
    return parseAnswer(value.string);
}

fn teamsOf(value: std.json.Value) ?std.json.ObjectMap {
    if (value != .object) return null;
    const teams = value.object.get("teams") orelse return null;
    if (teams != .object) return null;
    return teams.object;
}

/// The file text with `id` set to `answer`, after the answers `existing`
/// holds for other teams, oldest first. Caller owns the result.
fn encodeWith(alloc: Allocator, existing: ?[]const u8, id: []const u8, answer: token_pass.Answer) ![]u8 {
    var kept: std.ArrayList(struct { id: []const u8, answer: token_pass.Answer }) = .empty;
    defer kept.deinit(alloc);
    var parsed: ?std.json.Parsed(std.json.Value) = if (existing) |bytes|
        std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch null
    else
        null;
    defer if (parsed) |*value| value.deinit();
    if (parsed) |value| if (teamsOf(value.value)) |teams| {
        var it = teams.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, id)) continue;
            if (entry.key_ptr.len != token_pass.identity_len) continue;
            if (entry.value_ptr.* != .string) continue;
            const saved = parseAnswer(entry.value_ptr.string) orelse continue;
            try kept.append(alloc, .{ .id = entry.key_ptr.*, .answer = saved });
        }
    };
    const drop = (kept.items.len + 1) -| max_teams;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("teams");
    try json.beginObject();
    for (kept.items[drop..]) |entry| {
        try json.objectField(entry.id);
        try json.write(@tagName(entry.answer));
    }
    try json.objectField(id);
    try json.write(@tagName(answer));
    try json.endObject();
    try json.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn testHome(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

test "token pass memory: an answer saved for a team loads back for that team only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(alloc, &tmp);
    defer alloc.free(home);

    var first_buf: [token_pass.identity_len]u8 = undefined;
    var second_buf: [token_pass.identity_len]u8 = undefined;
    const first = token_pass.identity(&first_buf, .api_key, "vck_example_first", null);
    const second = token_pass.identity(&second_buf, .login, "account_example", "example-team");

    try std.testing.expect(load(alloc, home, first) == null);
    try save(alloc, home, first, .has_pass);
    try std.testing.expectEqual(token_pass.Answer.has_pass, load(alloc, home, first).?);
    try std.testing.expect(load(alloc, home, second) == null);

    try save(alloc, home, second, .no_pass);
    try std.testing.expectEqual(token_pass.Answer.no_pass, load(alloc, home, second).?);
    try std.testing.expectEqual(token_pass.Answer.has_pass, load(alloc, home, first).?);

    // A later answer replaces the team's earlier one.
    try save(alloc, home, first, .no_pass);
    try std.testing.expectEqual(token_pass.Answer.no_pass, load(alloc, home, first).?);
    try std.testing.expectEqual(token_pass.Answer.no_pass, load(alloc, home, second).?);
}

test "token pass memory: the file holds no secret and keeps the newest teams" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(alloc, &tmp);
    defer alloc.free(home);

    var ids: [max_teams + 2][token_pass.identity_len]u8 = undefined;
    for (&ids, 0..) |*buf, index| {
        var key_buf: [32]u8 = undefined;
        const key = try std.mem.print(&key_buf, "vck_example_key_{d}", .{index});
        _ = token_pass.identity(buf, .api_key, key, null);
        try save(alloc, home, buf, .has_pass);
    }
    // The two teams saved first make room for the newest.
    try std.testing.expect(load(alloc, home, &ids[0]) == null);
    try std.testing.expect(load(alloc, home, &ids[1]) == null);
    for (ids[2..]) |*id| try std.testing.expectEqual(token_pass.Answer.has_pass, load(alloc, home, id).?);

    const path = try profile_paths.rootPath(alloc, home, &.{file_name});
    defer alloc.free(path);
    const bytes = readFile(alloc, path).?;
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "vck_example_key") == null);
}

test "token pass memory: a malformed file reads as no answer and is replaced" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(alloc, &tmp);
    defer alloc.free(home);

    const root = try profile_paths.rootDir(alloc, home);
    defer alloc.free(root);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), root);
    const path = try profile_paths.rootPath(alloc, home, &.{file_name});
    defer alloc.free(path);
    var id_buf: [token_pass.identity_len]u8 = undefined;
    const id = token_pass.identity(&id_buf, .api_key, "vck_example_key", null);

    for ([_][]const u8{ "not json", "[]", "{\"teams\":[]}", "{\"teams\":{\"x\":\"has_pass\"}}" }) |text| {
        try io_mod.writeFileAtomic(alloc, path, text);
        try std.testing.expect(load(alloc, home, id) == null);
    }
    const unknown_answer = try alloc.print("{{\"teams\":{{\"{s}\":\"maybe\"}}}}", .{id});
    defer alloc.free(unknown_answer);
    try io_mod.writeFileAtomic(alloc, path, unknown_answer);
    try std.testing.expect(load(alloc, home, id) == null);

    try save(alloc, home, id, .has_pass);
    try std.testing.expectEqual(token_pass.Answer.has_pass, load(alloc, home, id).?);
}

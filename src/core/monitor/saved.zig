//! The monitors a session had running, saved in the profile as
//! `monitors/<session-id>.json`, so a restart that kills them, Ctrl+G or a
//! crash, can tell the agent which ones to start again. fx never runs a
//! saved command by itself: starting a command is the agent's action and goes
//! through the permission rules, so the saved record only builds the note
//! the agent reads. A normal quit removes the record. A missing or damaged
//! file means no monitors were running.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

const folder_name = "monitors";
const max_file_bytes: usize = 64 * 1024;
const max_entries: usize = 16;
const max_text_bytes: usize = 4096;

/// The longest command a monitor may start with, so the record holds it whole.
pub const max_command_bytes: usize = max_text_bytes;

pub const Entry = struct {
    label: []const u8,
    command: []const u8,
};

/// Monitors read back from a record. Strings live in `arena`.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

/// The record's path, or an error when `session_id` is not a plain id, so a
/// session id can never name another folder.
fn recordPath(alloc: Allocator, home: []const u8, session_id: []const u8) ![]u8 {
    if (session_id.len == 0 or session_id.len > 64) return error.InvalidSessionId;
    for (session_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidSessionId;
    }
    const name = try alloc.print("{s}.json", .{session_id});
    defer alloc.free(name);
    return profile_paths.rootPath(alloc, home, &.{ folder_name, name });
}

/// Saves `entries` as the session's record, or removes the record when there
/// are none.
pub fn save(alloc: Allocator, home: []const u8, session_id: []const u8, entries: []const Entry) !void {
    const path = try recordPath(alloc, home, session_id);
    defer alloc.free(path);
    if (entries.len == 0) return remove(path);
    const text = try encode(alloc, entries);
    defer alloc.free(text);
    const folder = try profile_paths.rootPath(alloc, home, &.{folder_name});
    defer alloc.free(folder);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), folder);
    try io_mod.writeFileAtomic(alloc, path, text);
}

/// Removes the session's record. A record that is already gone is fine.
pub fn clear(alloc: Allocator, home: []const u8, session_id: []const u8) void {
    const path = recordPath(alloc, home, session_id) catch return;
    defer alloc.free(path);
    remove(path) catch |err| debug_trace.logf("monitor", "event=record_clear_failed err={s}", .{@errorName(err)});
}

fn remove(path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io_mod.getIo(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// The monitors the session's record holds, or null when it holds none or
/// cannot be read.
pub fn load(alloc: Allocator, home: []const u8, session_id: []const u8) ?Loaded {
    const path = recordPath(alloc, home, session_id) catch return null;
    defer alloc.free(path);
    // A FIFO or device in its place must not stall the restart, so only an
    // existing regular file opens.
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), path, .no_follow) catch |err| {
        if (err != error.FileNotFound) debug_trace.logf("monitor", "event=record_unreadable err={s}", .{@errorName(err)});
        return null;
    };
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch |err| {
        debug_trace.logf("monitor", "event=record_unreadable err={s}", .{@errorName(err)});
        return null;
    };
    defer alloc.free(bytes);
    return decode(alloc, bytes);
}

/// The record's text. Caller owns the result.
fn encode(alloc: Allocator, entries: []const Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("monitors");
    try json.beginArray();
    for (entries[0..@min(entries.len, max_entries)]) |entry| {
        try json.beginObject();
        try json.objectField("label");
        try json.write(entry.label[0..@min(entry.label.len, max_text_bytes)]);
        try json.objectField("command");
        try json.write(entry.command[0..@min(entry.command.len, max_text_bytes)]);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    return out.toOwnedSlice();
}

/// The monitors `bytes` holds, or null when it holds none or is not a
/// record. An entry without a command is skipped.
fn decode(alloc: Allocator, bytes: []const u8) ?Loaded {
    var loaded: Loaded = .{ .arena = .init(alloc), .entries = &.{} };
    const arena = loaded.arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
        debug_trace.logf("monitor", "event=record_ignored reason=malformed", .{});
        loaded.arena.deinit();
        return null;
    };
    if (root != .object) return discard(&loaded);
    const list = root.object.get("monitors") orelse return discard(&loaded);
    if (list != .array) return discard(&loaded);
    var entries: std.ArrayList(Entry) = .empty;
    for (list.array.items) |item| {
        if (entries.items.len >= max_entries) break;
        if (item != .object) continue;
        const command = textField(item.object, "command") orelse continue;
        if (command.len == 0) continue;
        entries.append(arena, .{ .label = textField(item.object, "label") orelse "", .command = command }) catch return discard(&loaded);
    }
    if (entries.items.len == 0) return discard(&loaded);
    loaded.entries = entries.items;
    return loaded;
}

fn discard(loaded: *Loaded) ?Loaded {
    loaded.arena.deinit();
    return null;
}

fn textField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string[0..@min(value.string.len, max_text_bytes)];
}

/// What the agent reads after a restart: which monitors ended with it, and
/// that it may start them again. The commands are quoted as data in one JSON
/// string, never as instructions. Caller owns the result.
pub fn note(alloc: Allocator, entries: []const Entry) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll("fx restarted, and these monitors ended with it. After a crash a command may still run, so check before you start one again. Start them again with the monitor tool if you still need them:\n") catch return error.OutOfMemory;
    for (entries) |entry| {
        out.writer.writeAll("- ") catch return error.OutOfMemory;
        std.json.Stringify.value(.{ .label = entry.label, .command = entry.command }, .{}, &out.writer) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

test "a record reads back what was saved" {
    const text = try encode(std.testing.allocator, &.{
        .{ .label = "ci", .command = "gh pr checks 9 --watch" },
        .{ .label = "log \"a\"", .command = "tail -f build.log" },
    });
    defer std.testing.allocator.free(text);
    var loaded = decode(std.testing.allocator, text).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.entries.len);
    try std.testing.expectEqualStrings("ci", loaded.entries[0].label);
    try std.testing.expectEqualStrings("tail -f build.log", loaded.entries[1].command);
    try std.testing.expectEqualStrings("log \"a\"", loaded.entries[1].label);
}

test "a damaged record means no monitors" {
    for ([_][]const u8{ "", "not json", "[]", "{}", "{\"monitors\":3}", "{\"monitors\":[]}", "{\"monitors\":[{\"label\":\"x\"}]}", "{\"monitors\":[7,null]}" }) |bytes| {
        try std.testing.expect(decode(std.testing.allocator, bytes) == null);
    }
}

test "a record keeps at most the cap and skips an entry with no command" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "{\"monitors\":[{\"label\":\"none\"}");
    for (0..40) |index| try text.print(std.testing.allocator, ",{{\"label\":\"m{d}\",\"command\":\"true\"}}", .{index});
    try text.appendSlice(std.testing.allocator, "]}");
    var loaded = decode(std.testing.allocator, text.items).?;
    defer loaded.deinit();
    try std.testing.expectEqual(max_entries, loaded.entries.len);
    try std.testing.expectEqualStrings("m0", loaded.entries[0].label);
}

test "a session id that is not a plain id names no record" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidSessionId, recordPath(alloc, "/Users/example", ""));
    try std.testing.expectError(error.InvalidSessionId, recordPath(alloc, "/Users/example", "../sessions"));
    try std.testing.expectError(error.InvalidSessionId, recordPath(alloc, "/Users/example", "a/b"));
    const path = try recordPath(alloc, "/Users/example", "Ab-12_xyz");
    defer alloc.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/monitors/Ab-12_xyz.json"));
}

test "the note quotes each command as data" {
    const text = try note(std.testing.allocator, &.{.{ .label = "ci", .command = "echo \"hi\"\nrm -rf x" }});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "Start them again") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"command\":\"echo \\\"hi\\\"\\nrm -rf x\"") != null);
    // One line for the lead and one for the entry.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
}

test "a saved record is loaded, then cleared when the monitors end" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try save(alloc, home, "abc123", &.{.{ .label = "ci", .command = "true" }});
    var loaded = load(alloc, home, "abc123").?;
    loaded.deinit();
    try std.testing.expect(load(alloc, home, "other") == null);
    try save(alloc, home, "abc123", &.{});
    try std.testing.expect(load(alloc, home, "abc123") == null);
    // Clearing what is gone is fine.
    clear(alloc, home, "abc123");
}

test "a monitor record reads on fuzzed bytes and what it saves reads back" {
    try std.testing.fuzz({}, fuzzRecord, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"monitors\":[{\"label\":\"ci\",\"command\":\"gh pr checks 1 --watch\"}]}",
            "{\"monitors\":[{\"label\":3,\"command\":\"x\"},{\"command\":\"\"}]}",
            "{\"monitors\":{}}",
            "not json",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").monitor_record.*),
    });
}

fn fuzzRecord(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var buffer: [max_file_bytes]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var loaded = decode(alloc, bytes) orelse return;
    defer loaded.deinit();
    try std.testing.expect(loaded.entries.len >= 1 and loaded.entries.len <= max_entries);
    const text = try encode(alloc, loaded.entries);
    defer alloc.free(text);
    var again = decode(alloc, text).?;
    defer again.deinit();
    try std.testing.expectEqual(loaded.entries.len, again.entries.len);
    for (loaded.entries, again.entries) |first, second| {
        try std.testing.expectEqualStrings(first.command, second.command);
        try std.testing.expectEqualStrings(first.label, second.label);
    }
    const reminder = try note(alloc, loaded.entries);
    defer alloc.free(reminder);
}

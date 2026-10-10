//! `~/.fx/mcp.json` and `.mcp.json` edited in place. `add` and
//! `remove` change one entry of the file's JSON tree, so keys fx doesn't
//! know, the other top-level keys, the order, the spelling, and the text of
//! numbers all stay as written.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const json = std.json;

/// Which file is edited: the profile reads `mcp` or `mcpServers`, a
/// project's `.mcp.json` only `mcpServers`.
pub const File = enum { profile, project };

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Entry = union(enum) {
    stdio: struct { command: []const u8, args: []const []const u8 = &.{}, env: []const Pair = &.{} },
    http: struct { url: []const u8, headers: []const Pair = &.{} },
};

pub const Error = Allocator.Error || error{
    /// The file isn't JSON, or repeats a key.
    Unreadable,
    /// The file's top level, or its server list, isn't an object.
    NotAnObject,
    /// A profile with both `mcp` and `mcpServers`.
    BothKeys,
    /// `add`: the name is already in the file.
    Exists,
};

/// The file with `name` added. `text` is null when the file doesn't exist yet.
pub fn add(alloc: Allocator, file: File, text: ?[]const u8, name: []const u8, entry: Entry) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a, text);
    const servers = (try serversOf(a, file, &root, true)).?;
    if (servers.contains(name)) return error.Exists;
    try servers.put(a, name, try entryValue(a, entry));
    return render(alloc, root);
}

pub const Removed = struct {
    text: []u8,
    /// The entry's `url`, which keys an HTTP server's token.
    url: ?[]u8,

    pub fn deinit(r: *Removed, alloc: Allocator) void {
        alloc.free(r.text);
        if (r.url) |url| alloc.free(url);
        r.* = undefined;
    }
};

/// The file without `name`, or null when `name` isn't in it.
pub fn remove(alloc: Allocator, file: File, text: []const u8, name: []const u8) Error!?Removed {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try parse(a, text);
    const servers = (try serversOf(a, file, &root, false)) orelse return null;
    const old = servers.get(name) orelse return null;
    const url: ?[]u8 = if (old == .object) if (old.object.get("url")) |u| switch (u) {
        .string => |s| try alloc.dupe(u8, s),
        else => null,
    } else null else null;
    errdefer if (url) |u| alloc.free(u);
    _ = servers.orderedRemove(name);
    return .{ .text = try render(alloc, root), .url = url };
}

/// Whether the file defines `name`; false for a file that can't be read.
pub fn has(alloc: Allocator, file: File, text: []const u8, name: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var root = parse(arena.allocator(), text) catch return false;
    const servers = (serversOf(arena.allocator(), file, &root, false) catch return false) orelse return false;
    return servers.contains(name);
}

pub const Change = union(enum) {
    add: struct { name: []const u8, entry: Entry },
    remove: []const u8,
};

pub const Updated = union(enum) {
    added,
    /// The removed entry's `url`, owned by the caller's allocator.
    removed: ?[]u8,
    missing,
};

/// Applies `change` to the file at `path`. Every MCP config write holds the
/// profile's lock, next to `profile_path`, so two fx processes can't lose
/// each other's change.
pub fn update(alloc: Allocator, profile_path: []const u8, file: File, path: []const u8, change: Change) !Updated {
    var lock = try lockProfile(profile_path);
    defer lock.release();
    const text = try read(alloc, path);
    defer if (text) |t| alloc.free(t);
    switch (change) {
        .add => |a| {
            const next = try add(alloc, file, text, a.name, a.entry);
            defer alloc.free(next);
            try write(alloc, file, path, next);
            return .added;
        },
        .remove => |name| {
            const removed = (try remove(alloc, file, text orelse return .missing, name)) orelse return .missing;
            defer alloc.free(removed.text);
            errdefer if (removed.url) |u| alloc.free(u);
            try write(alloc, file, path, removed.text);
            return .{ .removed = removed.url };
        },
    }
}

/// The file's text, or null when it doesn't exist; owned by `alloc`.
pub fn read(alloc: Allocator, path: []const u8) !?[]u8 {
    var f = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &f, 1024 * 1024);
}

const profile_lock_deadline_ms: u64 = 2_000;

/// The lock every MCP config write holds, in the profile directory.
pub fn lockProfile(profile_path: []const u8) !io_mod.TimedAdvisoryLock {
    var dir = try profileDir(profile_path);
    defer dir.close();
    return io_mod.acquireTimedAdvisoryLock(&dir, "mcp.lock", profile_lock_deadline_ms);
}

/// Replaces the profile file durably, readable only by its owner.
pub fn replaceProfile(alloc: Allocator, profile_path: []const u8, text: []const u8) !void {
    var dir = try profileDir(profile_path);
    defer dir.close();
    try io_mod.durableReplaceVerified(alloc, &dir, std.fs.path.basename(profile_path), text);
}

fn profileDir(profile_path: []const u8) !io_mod.VerifiedDir {
    const parent = std.fs.path.dirname(profile_path) orelse return error.McpConfigPathInvalid;
    const grandparent = std.fs.path.dirname(parent) orelse return error.McpConfigPathInvalid;
    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    return io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.fs.path.basename(parent));
}

/// A project's `.mcp.json` is shared, so it keeps its mode.
fn write(alloc: Allocator, file: File, path: []const u8, text: []const u8) !void {
    switch (file) {
        .profile => try replaceProfile(alloc, path, text),
        .project => try io_mod.writeFileAtomic(alloc, path, text),
    }
}

fn parse(a: Allocator, text: ?[]const u8) Error!json.Value {
    const t = text orelse return .{ .object = .empty };
    if (std.mem.trim(u8, t, " \t\r\n").len == 0) return .{ .object = .empty };
    return json.parseFromSliceLeaky(json.Value, a, t, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreadable,
    };
}

fn serversOf(a: Allocator, file: File, root: *json.Value, create: bool) Error!?*json.ObjectMap {
    if (root.* != .object) return error.NotAnObject;
    const top = &root.object;
    const current = top.getPtr("mcpServers");
    const old = if (file == .profile) top.getPtr("mcp") else null;
    if (current != null and old != null) return error.BothKeys;
    const value = current orelse old orelse {
        if (!create) return null;
        try top.put(a, "mcpServers", .{ .object = .empty });
        return &top.getPtr("mcpServers").?.object;
    };
    if (value.* != .object) return error.NotAnObject;
    return &value.object;
}

fn entryValue(a: Allocator, entry: Entry) Allocator.Error!json.Value {
    var object: json.ObjectMap = .empty;
    switch (entry) {
        .stdio => |s| {
            try object.put(a, "command", .{ .string = s.command });
            if (s.args.len > 0) {
                var args: json.Array = .init(a);
                for (s.args) |arg| try args.append(.{ .string = arg });
                try object.put(a, "args", .{ .array = args });
            }
            if (s.env.len > 0) try object.put(a, "env", try pairs(a, s.env));
        },
        .http => |h| {
            try object.put(a, "type", .{ .string = "http" });
            try object.put(a, "url", .{ .string = h.url });
            if (h.headers.len > 0) try object.put(a, "headers", try pairs(a, h.headers));
        },
    }
    return .{ .object = object };
}

fn pairs(a: Allocator, list: []const Pair) Allocator.Error!json.Value {
    var object: json.ObjectMap = .empty;
    for (list) |p| try object.put(a, p.key, .{ .string = p.value });
    return .{ .object = object };
}

fn render(alloc: Allocator, root: json.Value) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    json.Stringify.value(root, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const testing = std.testing;

test "add keeps every key it doesn't know, in order, with numbers as written" {
    const before =
        \\{"theme":"dark","mcpServers":{"a":{"command":"x","environment":{"K":"v"},"startup_timeout_ms":1.50,"extra":[1,2]}},"zz":true}
    ;
    const after = try add(testing.allocator, .profile, before, "web", .{ .http = .{ .url = "https://mcp.example/mcp", .headers = &.{.{ .key = "X-Key", .value = "${KEY}" }} } });
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(
        \\{
        \\  "theme": "dark",
        \\  "mcpServers": {
        \\    "a": {
        \\      "command": "x",
        \\      "environment": {
        \\        "K": "v"
        \\      },
        \\      "startup_timeout_ms": 1.50,
        \\      "extra": [
        \\        1,
        \\        2
        \\      ]
        \\    },
        \\    "web": {
        \\      "type": "http",
        \\      "url": "https://mcp.example/mcp",
        \\      "headers": {
        \\        "X-Key": "${KEY}"
        \\      }
        \\    }
        \\  },
        \\  "zz": true
        \\}
        \\
    , after);
}

test "add writes a stdio server, into a new file under mcpServers" {
    const after = try add(testing.allocator, .project, null, "local", .{ .stdio = .{ .command = "node", .args = &.{ "server.js", "--x" }, .env = &.{.{ .key = "A", .value = "1" }} } });
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(
        \\{
        \\  "mcpServers": {
        \\    "local": {
        \\      "command": "node",
        \\      "args": [
        \\        "server.js",
        \\        "--x"
        \\      ],
        \\      "env": {
        \\        "A": "1"
        \\      }
        \\    }
        \\  }
        \\}
        \\
    , after);
}

test "an older profile keeps its mcp key; a project file never uses it" {
    const old_profile = "{\"mcp\":{\"a\":{\"command\":\"x\"}}}";
    const profile = try add(testing.allocator, .profile, old_profile, "b", .{ .stdio = .{ .command = "y" } });
    defer testing.allocator.free(profile);
    try testing.expect(std.mem.indexOf(u8, profile, "\"mcpServers\"") == null);
    try testing.expect(has(testing.allocator, .profile, profile, "b"));

    const project = try add(testing.allocator, .project, old_profile, "b", .{ .stdio = .{ .command = "y" } });
    defer testing.allocator.free(project);
    try testing.expect(has(testing.allocator, .project, project, "b"));
    try testing.expect(!has(testing.allocator, .project, project, "a"));
    try testing.expect(std.mem.indexOf(u8, project, "\"mcp\": {") != null);
}

test "add refuses what it can't edit safely" {
    const a = testing.allocator;
    const entry: Entry = .{ .stdio = .{ .command = "y" } };
    try testing.expectError(error.Exists, add(a, .profile, "{\"mcpServers\":{\"b\":{}}}", "b", entry));
    try testing.expectError(error.BothKeys, add(a, .profile, "{\"mcp\":{},\"mcpServers\":{}}", "b", entry));
    try testing.expectError(error.Unreadable, add(a, .profile, "{\"mcpServers\":{},\"mcpServers\":{}}", "b", entry));
    try testing.expectError(error.Unreadable, add(a, .profile, "{nope", "b", entry));
    try testing.expectError(error.NotAnObject, add(a, .profile, "[]", "b", entry));
    try testing.expectError(error.NotAnObject, add(a, .profile, "{\"mcpServers\":[]}", "b", entry));
    const blank = try add(a, .profile, " \n", "b", entry);
    defer a.free(blank);
    try testing.expect(has(a, .profile, blank, "b"));
}

test "remove drops one entry, keeps the rest in order, and returns its url" {
    const a = testing.allocator;
    const before = "{\"x\":1,\"mcpServers\":{\"a\":{\"command\":\"x\"},\"web\":{\"type\":\"http\",\"url\":\"https://w/mcp\"},\"c\":{\"command\":\"z\"}}}";
    var removed = (try remove(a, .profile, before, "web")).?;
    defer removed.deinit(a);
    try testing.expectEqualStrings("https://w/mcp", removed.url.?);
    try testing.expect(!has(a, .profile, removed.text, "web"));
    const order_a = std.mem.indexOf(u8, removed.text, "\"a\"").?;
    const order_c = std.mem.indexOf(u8, removed.text, "\"c\"").?;
    try testing.expect(order_a < order_c);
    try testing.expect(std.mem.indexOf(u8, removed.text, "\"x\": 1") != null);

    var stdio = (try remove(a, .profile, before, "a")).?;
    defer stdio.deinit(a);
    try testing.expect(stdio.url == null);
    try testing.expect(try remove(a, .profile, before, "missing") == null);
    try testing.expect(try remove(a, .project, "{\"mcp\":{\"a\":{}}}", "a") == null);
}

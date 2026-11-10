//! `~/.fx/mcp.json` and `.mcp.json` edited in place. `add` and
//! `remove` change one entry of the file's JSON tree, so keys fx doesn't
//! know, the other top-level keys, the order, the spelling, and the text of
//! numbers all stay as written. `update` writes only what fx's own reader
//! then loads, and never a profile whose servers key looks misspelled
//! (`tests/tla/mcp_host/ConfigEdit.tla` `AddedIsLoaded`, `NoRewriteOfMisspelled`).

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const project_config = @import("../mcp/project_config.zig");

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
    /// Nothing was written.
    refused: Refusal,
};

/// Why an edit isn't made. Both carry bounded text only, never an entry's URL or headers.
pub const Refusal = union(enum) {
    /// The reader would skip the new entry.
    entry: project_config.EntryProblem,
    /// The profile has a key that looks like a misspelling of its servers key.
    misspelled: project_config.MisspelledKey,
};

/// Whether adding `name` to `file`, which held `before` and would hold `after`,
/// is refused: the profile's servers key looks misspelled, or the reader would
/// skip the new entry. Null for a file the reader loads the entry from. It runs
/// the reader on the text as it will be written, so the rules stay the reader's.
pub fn refusalOf(alloc: Allocator, file: File, before: ?[]const u8, after: []const u8, name: []const u8) Allocator.Error!?Refusal {
    if (file == .profile) {
        if (try misspelledIn(alloc, file, before)) |key| return .{ .misspelled = key };
    }
    if (try project_config.entryProblemIn(alloc, file == .profile, after, name)) |problem| return .{ .entry = problem };
    return null;
}

/// The profile's misspelled servers key, found by reading every key; null for
/// `.mcp.json`, whose keys fx doesn't check, and for a file that isn't there.
fn misspelledIn(alloc: Allocator, file: File, text: ?[]const u8) Allocator.Error!?project_config.MisspelledKey {
    if (file != .profile) return null;
    return project_config.misspelledKey(alloc, text orelse return null);
}

/// Applies `change` to the file at `path`. Every MCP config write holds the
/// profile's lock, next to `profile_path`, so two fx processes can't lose
/// each other's change. The reader's check reads the file under that lock, as
/// it is then, so a key that appears between two commands is found by the
/// next one. A refused change writes nothing.
pub fn update(alloc: Allocator, profile_path: []const u8, file: File, path: []const u8, change: Change) !Updated {
    var lock = try lockProfile(profile_path);
    defer lock.release();
    const text = try read(alloc, path);
    defer if (text) |t| alloc.free(t);
    switch (change) {
        .add => |a| {
            const next = try add(alloc, file, text, a.name, a.entry);
            defer alloc.free(next);
            if (try refusalOf(alloc, file, text, next, a.name)) |refusal| return .{ .refused = refusal };
            try write(alloc, file, path, next);
            return .added;
        },
        .remove => |name| {
            const removed = (try remove(alloc, file, text orelse return .missing, name)) orelse return .missing;
            defer alloc.free(removed.text);
            errdefer if (removed.url) |u| alloc.free(u);
            if (try misspelledIn(alloc, file, text)) |key| {
                if (removed.url) |u| alloc.free(u);
                return .{ .refused = .{ .misspelled = key } };
            }
            try write(alloc, file, path, removed.text);
            return .{ .removed = removed.url };
        },
    }
}

/// The most of an MCP config file `read` takes; a larger one fails with
/// StreamTooLong.
pub const max_read_bytes: usize = 1024 * 1024;

/// The file's text, or null when it doesn't exist; owned by `alloc`. A path
/// that isn't a regular file, such as a fifo, fails with DurablePathUnsafe
/// instead of waiting for a writer.
pub fn read(alloc: Allocator, path: []const u8) !?[]u8 {
    var f = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), path, .follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &f, max_read_bytes);
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
    try io_mod.durableReplaceVerified(alloc, &dir, std.Io.Dir.path.basename(profile_path), text);
}

fn profileDir(profile_path: []const u8) !io_mod.VerifiedDir {
    const parent = std.Io.Dir.path.dirname(profile_path) orelse return error.McpConfigPathInvalid;
    const grandparent = std.Io.Dir.path.dirname(parent) orelse return error.McpConfigPathInvalid;
    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    return io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.Io.Dir.path.basename(parent));
}

/// A project's `.mcp.json` is shared, so it keeps its mode.
fn write(alloc: Allocator, file: File, path: []const u8, text: []const u8) !void {
    switch (file) {
        .profile => try replaceProfile(alloc, path, text),
        .project => {
            // A link isn't replaced, which forks the file it points to, nor
            // followed, which could write outside the project.
            // The profile's own replace refuses one too.
            if (std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false })) |stat| {
                if (stat.kind == .sym_link or stat.nlink > 1) return error.Linked;
            } else |err| if (err != error.FileNotFound) return err;
            try io_mod.writeFileAtomic(alloc, path, text);
        },
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
    try testing.expect(std.mem.find(u8, profile, "\"mcpServers\"") == null);
    try testing.expect(has(testing.allocator, .profile, profile, "b"));

    const project = try add(testing.allocator, .project, old_profile, "b", .{ .stdio = .{ .command = "y" } });
    defer testing.allocator.free(project);
    try testing.expect(has(testing.allocator, .project, project, "b"));
    try testing.expect(!has(testing.allocator, .project, project, "a"));
    try testing.expect(std.mem.find(u8, project, "\"mcp\": {") != null);
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
    const order_a = std.mem.find(u8, removed.text, "\"a\"").?;
    const order_c = std.mem.find(u8, removed.text, "\"c\"").?;
    try testing.expect(order_a < order_c);
    try testing.expect(std.mem.find(u8, removed.text, "\"x\": 1") != null);

    var stdio = (try remove(a, .profile, before, "a")).?;
    defer stdio.deinit(a);
    try testing.expect(stdio.url == null);
    try testing.expect(try remove(a, .profile, before, "missing") == null);
    try testing.expect(try remove(a, .project, "{\"mcp\":{\"a\":{}}}", "a") == null);
}

test "a linked config file is never edited, whether a symlink or a hard link" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "shared.json", .data = "{}" });
    try tmp.dir.symLink(io, "shared.json", "soft.json", .{});
    try tmp.dir.hardLink("shared.json", tmp.dir, "hard.json", io, .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.json", .data = "{}" });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const Case = struct { name: []const u8, want: enum { linked, written, no_dir } };
    for ([_]Case{
        .{ .name = "soft.json", .want = .linked },
        .{ .name = "hard.json", .want = .linked },
        .{ .name = "plain.json", .want = .written },
        .{ .name = "missing.json", .want = .written },
        .{ .name = "no-dir/mcp.json", .want = .no_dir },
    }) |case| {
        const path = try std.Io.Dir.path.join(alloc, &.{ root, case.name });
        defer alloc.free(path);
        const text = "{\"mcpServers\":{}}";
        switch (case.want) {
            .linked => try testing.expectError(error.Linked, write(alloc, .project, path, text)),
            .written => {
                try write(alloc, .project, path, text);
                const got = try tmp.dir.readFileAlloc(io, case.name, alloc, .limited(64));
                defer alloc.free(got);
                try testing.expectEqualStrings(text, got);
            },
            .no_dir => try testing.expectError(error.FileNotFound, write(alloc, .project, path, text)),
        }
    }
    // The file the links point to is as it was.
    const shared = try tmp.dir.readFileAlloc(io, "shared.json", alloc, .limited(64));
    defer alloc.free(shared);
    try testing.expectEqualStrings("{}", shared);
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "read returns a file's text, follows a symlink, and refuses a fifo without blocking" {
    if (comptime @import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .wasi) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.json", .data = "{\"mcp\":{}}" });
    try tmp.dir.symLink(io, "plain.json", "soft.json", .{});
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    for ([_][]const u8{ "plain.json", "soft.json" }) |name| {
        const path = try std.Io.Dir.path.join(alloc, &.{ root, name });
        defer alloc.free(path);
        const text = (try read(alloc, path)).?;
        defer alloc.free(text);
        try testing.expectEqualStrings("{\"mcp\":{}}", text);
    }

    const missing = try std.Io.Dir.path.join(alloc, &.{ root, "missing.json" });
    defer alloc.free(missing);
    try testing.expect(try read(alloc, missing) == null);

    // Opening a fifo for reading waits for a writer that never comes.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fifo = try std.mem.printSentinel(&path_buf, "{s}/{s}", .{ root, "fifo.json" }, 0);
    if (mkfifo(fifo, 0o600) != 0) return error.SkipZigTest;
    try testing.expectError(error.DurablePathUnsafe, read(alloc, fifo));
}

test "the profile's first write creates ~/.fx readable only by its owner" {
    const alloc = testing.allocator;
    const io = io_mod.getIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const path = try std.Io.Dir.path.join(alloc, &.{ home, ".fx", "mcp.json" });
    defer alloc.free(path);
    try write(alloc, .profile, path, "{\"mcpServers\":{}}");
    const dir = try tmp.dir.statFile(io, ".fx", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir.permissions.toMode() & 0o777);
    const file = try tmp.dir.statFile(io, ".fx/mcp.json", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), file.permissions.toMode() & 0o777);
}

const bad_entry: Entry = .{ .http = .{ .url = "http://example.com/mcp" } };
const good_entry: Entry = .{ .http = .{ .url = "https://mcp.example/mcp" } };
const authorized: Entry = .{ .http = .{ .url = "https://mcp.example/mcp", .headers = &.{.{ .key = "authorization", .value = "Bearer x" }} } };

test "update writes what the reader loads, and a refused change writes nothing" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const profile = try std.Io.Dir.path.join(alloc, &.{ home, ".fx", "mcp.json" });
    defer alloc.free(profile);
    const project = try std.Io.Dir.path.join(alloc, &.{ home, ".mcp.json" });
    defer alloc.free(project);

    // A missing profile stays missing when the first add is refused.
    const refused = try update(alloc, profile, .profile, profile, .{ .add = .{ .name = "web", .entry = bad_entry } });
    try testing.expectEqual(project_config.EntryProblem.url_insecure, refused.refused.entry);
    try testing.expect(try read(alloc, profile) == null);

    const added = try update(alloc, profile, .profile, profile, .{ .add = .{ .name = "web", .entry = good_entry } });
    try testing.expect(added == .added);
    const before = (try read(alloc, profile)).?;
    defer alloc.free(before);

    // An Authorization header is the profile's to refuse and .mcp.json's to take.
    const auth = try update(alloc, profile, .profile, profile, .{ .add = .{ .name = "authd", .entry = authorized } });
    try testing.expectEqual(project_config.EntryProblem.authorization, auth.refused.entry);
    try testing.expect(try update(alloc, profile, .project, project, .{ .add = .{ .name = "authd", .entry = authorized } }) == .added);
    const after = (try read(alloc, profile)).?;
    defer alloc.free(after);
    try testing.expectEqualStrings(before, after);
}

test "update never rewrites a profile whose servers key looks misspelled, and reads every key to find it" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const profile = try std.Io.Dir.path.join(alloc, &.{ home, ".fx", "mcp.json" });
    defer alloc.free(profile);

    // 70 other keys first, and the misspelled one last: the scan fx runs at load gives up on this file.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try text.append(alloc, '{');
    for (0..70) |i| try text.print(alloc, "\"note{d}\":{d},", .{ i, i });
    try text.appendSlice(alloc, "\"mcpServers\":{\"a\":{\"command\":\"x\"}},\"mcp_servers\":{\"b\":{\"command\":\"y\"}}}");
    try write(alloc, .profile, profile, text.items);

    const add_refused = try update(alloc, profile, .profile, profile, .{ .add = .{ .name = "web", .entry = good_entry } });
    try testing.expectEqualStrings("mcp_servers", add_refused.refused.misspelled.key());
    try testing.expectEqualStrings("mcpServers", add_refused.refused.misspelled.real());
    const remove_refused = try update(alloc, profile, .profile, profile, .{ .remove = "a" });
    try testing.expectEqualStrings("mcp_servers", remove_refused.refused.misspelled.key());
    const same = (try read(alloc, profile)).?;
    defer alloc.free(same);
    try testing.expectEqualStrings(text.items, same);

    // A name that is not under the real key is not found, so there is nothing to refuse.
    try testing.expect(try update(alloc, profile, .profile, profile, .{ .remove = "b" }) == .missing);

    // The key the file already uses is the one the fix names.
    const old = "{\"mcp\":{\"a\":{\"command\":\"x\"}},\"MCP-Servers\":{\"b\":{\"command\":\"y\"}}}";
    try write(alloc, .profile, profile, old);
    const named = try update(alloc, profile, .profile, profile, .{ .add = .{ .name = "web", .entry = good_entry } });
    try testing.expectEqualStrings("MCP-Servers", named.refused.misspelled.key());
    try testing.expectEqualStrings("mcp", named.refused.misspelled.real());

    // .mcp.json has no such check.
    const project = try std.Io.Dir.path.join(alloc, &.{ home, ".mcp.json" });
    defer alloc.free(project);
    try write(alloc, .project, project, "{\"servers\":{\"b\":{\"command\":\"y\"}}}");
    try testing.expect(try update(alloc, profile, .project, project, .{ .add = .{ .name = "web", .entry = good_entry } }) == .added);
}

// The entries and files a fuzzed add draws from: addresses that load, that the
// reader skips for each reason it has, and headers and variables of every class.
const fuzz_schemes = [_][]const u8{ "https", "https", "http", "HTTP", "ftp", "" };
const fuzz_hosts = [_][]const u8{ "x.example", "localhost", "localhost.", "127.0.0.1", "127.0.0.2", "[::1]", "", "x y", "u:p@x.example", "u@localhost" };
const fuzz_ports = [_][]const u8{ "", "", ":80", ":8080", ":0", ":99999", ":" };
const fuzz_tails = [_][]const u8{ "/mcp", "/mcp", "", "/mcp#part", "?a=1" };
const fuzz_header_names = [_][]const u8{ "X-A", "x-a", "Authorization", "authorization", "Host", "Mcp-Param-X", "Bad Header", "" };
const fuzz_values = [_][]const u8{ "1", "", "${X}", "${", "${1X}", "${X:-d}", "a\x01b" };
const fuzz_commands = [_][]const u8{ "node", "", "x y", "${C}", "${" };
const fuzz_env_names = [_][]const u8{ "K", "1X", "BAD NAME", "" };
const fuzz_names = [_][]const u8{ "a", "web", "x-1", "s_2" };
const fuzz_typo_keys = [_][]const u8{ "servers", "mcp_servers", "MCP-Servers", "mcpserver", "ModelContextProtocol", "notes", "mcp" };

/// A profile or `.mcp.json` text: some unrelated top-level keys, the real
/// servers key (or none), and a key that may or may not be a misspelling.
fn fuzzBefore(a: Allocator, smith: *std.testing.Smith) Allocator.Error!?[]const u8 {
    if (smith.valueRangeAtMost(u8, 0, 5) == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '{');
    var first = true;
    const fillers = smith.valueRangeAtMost(u8, 0, 80);
    for (0..fillers) |i| {
        if (!first) try out.append(a, ',');
        first = false;
        try out.print(a, "\"note{d}\":{d}", .{ i, i });
    }
    const real = smith.valueRangeAtMost(u8, 0, 3);
    if (real != 0) {
        if (!first) try out.append(a, ',');
        first = false;
        const key: []const u8 = if (real == 3) "mcp" else "mcpServers";
        try out.print(a, "\"{s}\":{{\"old\":{{\"command\":\"x\"}}}}", .{key});
    }
    if (smith.value(bool)) {
        if (!first) try out.append(a, ',');
        const key = fuzz_typo_keys[smith.index(fuzz_typo_keys.len)];
        // Servers, or entries that aren't servers first: the load scan gives up on a wide one.
        const junk = smith.valueRangeAtMost(u8, 0, 70);
        try out.print(a, "\"{s}\":{{", .{key});
        for (0..junk) |i| try out.print(a, "\"n{d}\":{d},", .{ i, i });
        try out.appendSlice(a, "\"real\":{\"command\":\"y\"}}");
    }
    try out.append(a, '}');
    return out.items;
}

fn fuzzEntry(a: Allocator, smith: *std.testing.Smith) Allocator.Error!Entry {
    if (smith.value(bool)) {
        const url = try a.print("{s}://{s}{s}{s}", .{
            fuzz_schemes[smith.index(fuzz_schemes.len)],
            fuzz_hosts[smith.index(fuzz_hosts.len)],
            fuzz_ports[smith.index(fuzz_ports.len)],
            fuzz_tails[smith.index(fuzz_tails.len)],
        });
        const count = smith.valueRangeAtMost(u8, 0, 3);
        const headers = try a.alloc(Pair, count);
        for (headers) |*h| h.* = .{
            .key = fuzz_header_names[smith.index(fuzz_header_names.len)],
            .value = fuzz_values[smith.index(fuzz_values.len)],
        };
        return .{ .http = .{ .url = url, .headers = headers } };
    }
    const args = try a.alloc([]const u8, smith.valueRangeAtMost(u8, 0, 2));
    for (args) |*arg| arg.* = fuzz_values[smith.index(fuzz_values.len)];
    const env = try a.alloc(Pair, smith.valueRangeAtMost(u8, 0, 2));
    for (env) |*pair| pair.* = .{
        .key = fuzz_env_names[smith.index(fuzz_env_names.len)],
        .value = fuzz_values[smith.index(fuzz_values.len)],
    };
    return .{ .stdio = .{ .command = fuzz_commands[smith.index(fuzz_commands.len)], .args = args, .env = env } };
}

/// Whether the reader's own entry points load `name` from `text`, as they do
/// when fx starts. A server held back only for a variable that isn't set counts
/// as loaded: the reader says why in a note, and `add` saves such a server.
fn readerLoads(a: Allocator, file: File, text: []const u8, name: []const u8) !bool {
    var environment = std.process.Environ.Map.init(a);
    switch (file) {
        .profile => {
            var diagnostics: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty;
            var configs = project_config.parseProfileServers(a, text, &diagnostics) catch return false;
            try project_config.expandProfileConfigs(a, &configs, &diagnostics, &environment);
            return loadedOrHeld(configs.items, diagnostics.items, name);
        },
        .project => {
            var approved = [_][]u8{@constCast(name)};
            const result = try project_config.parseWorkspaceJsonWithEnvironment(a, text, .workspace, .{ .approved = &approved }, &environment);
            return loadedOrHeld(result.configs.items, result.diagnostics.items, name);
        },
    }
}

/// `configs` are the reader's servers and `diagnostics` its notes.
fn loadedOrHeld(configs: anytype, diagnostics: []const project_config.WorkspaceDiagnostic, name: []const u8) bool {
    for (configs) |c| if (std.mem.eql(u8, c.name, name)) return true;
    for (diagnostics) |d| {
        const named = if (d.server_name) |n| std.mem.eql(u8, n, name) else false;
        if (named and d.cause == .missing_environment_variable) return true;
    }
    return false;
}

fn fuzzAddReaderAgree(_: void, smith: *std.testing.Smith) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file: File = if (smith.value(bool)) .profile else .project;
    const name = fuzz_names[smith.index(fuzz_names.len)];
    const before = try fuzzBefore(a, smith);
    const entry = try fuzzEntry(a, smith);
    // A file add refuses on its own (not JSON, both keys, a name that is there) has nothing to check.
    const after = add(a, file, before, name, entry) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    // Whatever add writes is JSON, and it keeps what was there.
    const written = try std.json.parseFromSliceLeaky(std.json.Value, a, after, .{});
    try testing.expect(written == .object);
    if (before) |text| {
        const old = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        var keys = old.object.iterator();
        while (keys.next()) |key| try testing.expect(written.object.contains(key.key_ptr.*));
    }

    // The reader's check: a text it accepts is loaded by the reader's own entry points.
    const refusal = try refusalOf(a, file, before, after, name);
    if (refusal == null) {
        try testing.expect(try readerLoads(a, file, after, name));
        // No misspelled key is left for the next edit to find.
        if (file == .profile) try testing.expect(try project_config.misspelledKey(a, after) == null);
    }
    // The load path's bounded scan never finds a misspelling the edit's complete scan misses.
    if (before) |text| {
        var bounded = project_config.parseProfileDocument(a, text) catch return;
        defer bounded.deinit(a);
        if (bounded.diagnostic) |d| {
            if (d.cause == .suspicious_server_key) try testing.expect(try project_config.misspelledKey(a, text) != null);
        }
    }
}

test "an add the reader's check accepts is loaded by the reader's own entry points, for fuzzed entries and files" {
    try std.testing.fuzz({}, fuzzAddReaderAgree, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
            "garbage!garbage!garbage!",
        }) ++ @import("fuzz_corpus").mcp_add_reader_agree.*),
    });
}

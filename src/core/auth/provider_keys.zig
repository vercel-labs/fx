//! Keys `/login` saved for configured providers such as OpenRouter and
//! OpenCode, in one private profile file: `{"<provider>": "<key>"}`. The file
//! sits beside the Codex and Grok sessions, mode 0600 in the 0700 profile
//! directory, and is replaced atomically under the same rules (D147).
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");
const Allocator = std.mem.Allocator;

pub const file_name = "provider-keys.json";
const max_file_bytes = 256 * 1024;
pub const max_key_bytes = 16 * 1024;

/// A key is printable ASCII without spaces, as an HTTP header needs.
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_bytes) return false;
    for (key) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

/// The saved key for `provider`, or null. Caller owns and zeroes it.
pub fn load(alloc: Allocator, provider: []const u8) !?[]u8 {
    const home = io_mod.homeDir() orelse return null;
    return loadFromHome(alloc, home, provider);
}

pub fn loadFromHome(alloc: Allocator, home: []const u8, provider: []const u8) !?[]u8 {
    const bytes = (try readFile(alloc, home)) orelse return null;
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return error.InvalidProviderKeysFile;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProviderKeysFile;
    const value = parsed.value.object.get(provider) orelse return null;
    if (value != .string or !validKey(value.string)) return error.InvalidProviderKeysFile;
    return try alloc.dupe(u8, value.string);
}

/// Saves `key` for `provider`, keeping the other providers' keys.
pub fn save(alloc: Allocator, provider: []const u8, key: []const u8) !void {
    const home = io_mod.homeDir() orelse return error.HomeNotSet;
    _ = try update(alloc, home, provider, key);
}

/// Removes `provider`'s key. Returns whether one was saved.
pub fn delete(alloc: Allocator, provider: []const u8) !bool {
    const home = io_mod.homeDir() orelse return false;
    return update(alloc, home, provider, null);
}

/// Sets (`key` non-null) or removes `provider`'s entry. Returns whether an
/// entry existed before.
pub fn update(alloc: Allocator, home: []const u8, provider: []const u8, key: ?[]const u8) !bool {
    if (key) |value| if (!validKey(value)) return error.InvalidProviderKey;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var object: std.json.ObjectMap = .empty;
    if (try readFile(arena, home)) |bytes| {
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return error.InvalidProviderKeysFile;
        if (root != .object) return error.InvalidProviderKeysFile;
        object = root.object;
    }
    const existed = object.orderedRemove(provider);
    if (key) |value| try object.put(arena, provider, .{ .string = value });
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(out.writer.buffer, 0);
        out.deinit();
    }
    try std.json.Stringify.value(std.json.Value{ .object = object }, .{}, &out.writer);
    var home_dir = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{}) };
    defer home_dir.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    defer fx_dir.close();
    try io_mod.durableReplaceVerified(alloc, &fx_dir, file_name, out.written());
    return existed;
}

fn readFile(alloc: Allocator, home: []const u8) !?[]u8 {
    var fx_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{}) catch return null;
    defer fx_dir.close(io_mod.getIo());
    var dir = fx_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io_mod.getIo());
    var file = dir.openFile(io_mod.getIo(), file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    // Keys are refused from a file other users can read or that is linked.
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) return error.InsecureAuthFile;
    return try io_mod.readFileToEnd(alloc, &file, max_file_bytes);
}

test "provider keys round trip per provider in a private file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try std.testing.expect(try loadFromHome(alloc, home, "openrouter") == null);
    try std.testing.expect(!try update(alloc, home, "openrouter", "sk-or-v1-abc"));
    try std.testing.expect(!try update(alloc, home, "opencode-zen", "zen-key"));
    const router = (try loadFromHome(alloc, home, "openrouter")).?;
    defer alloc.free(router);
    try std.testing.expectEqualStrings("sk-or-v1-abc", router);
    try std.testing.expect(try update(alloc, home, "openrouter", null));
    try std.testing.expect(try loadFromHome(alloc, home, "openrouter") == null);
    const zen = (try loadFromHome(alloc, home, "opencode-zen")).?;
    defer alloc.free(zen);
    try std.testing.expectEqualStrings("zen-key", zen);
    try std.testing.expectError(error.InvalidProviderKey, update(alloc, home, "openrouter", "has space"));
    const path = try std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, file_name });
    defer alloc.free(path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    try std.testing.expectEqual(@as(u32, 0o600), (try file.stat(io_mod.getIo())).permissions.toMode() & 0o777);
}

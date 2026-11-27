//! Reads only the profile's top-level `shortcuts` object, for the turn-end
//! reload. It opens the profile through the same store the settings load uses,
//! and never reads the rest of the configuration. `stampOf` is one stat, so a
//! turn that left the profile alone costs no read.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const settings_store = @import("settings_store.zig");
const shortcut_rules = @import("../shortcuts/shortcuts.zig");

/// The identity of the profile's settings file. Atomic saves replace the
/// inode; an in-place edit changes the size or the times.
pub const Stamp = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime: std.Io.Timestamp,
    ctime: std.Io.Timestamp,
};

/// Why a readable profile gave no valid map. The chord is copied out of the
/// parsed JSON and sanitized to printable ASCII, so it is safe to show.
pub const Invalid = struct {
    chord_bytes: [shortcut_rules.max_key_bytes]u8 = undefined,
    chord_len: u8 = 0,

    /// The failing chord as written in the profile; empty when none is known.
    pub fn chord(self: *const Invalid) []const u8 {
        return self.chord_bytes[0..self.chord_len];
    }
};

pub const Load = union(enum) {
    /// The profile sets no `shortcuts` key, or has no settings file.
    absent,
    loaded: shortcut_rules.Map,
    /// The file exists but cannot give a valid map: the caller keeps its last one.
    invalid: Invalid,
};

fn invalidFrom(problem: shortcut_rules.Problem) Invalid {
    var invalid: Invalid = .{};
    const len = @min(problem.chord.len, invalid.chord_bytes.len);
    for (problem.chord[0..len], 0..) |byte, index| {
        invalid.chord_bytes[index] = if (byte >= 0x20 and byte < 0x7f) byte else '?';
    }
    invalid.chord_len = @intCast(len);
    return invalid;
}

/// The stamp of the settings file, or null when the profile has none. An error
/// means the profile could not be inspected, so the caller keeps its last map.
pub fn stampOf(alloc: std.mem.Allocator, home_dir: []const u8) !?Stamp {
    var store = try settings_store.Store.initFromHome(alloc, home_dir, .read_only);
    defer store.deinit(alloc);
    const home = store.durable_home orelse return null;
    const stat = home.dir.statFile(io_mod.getIo(), "settings.json", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime, .ctime = stat.ctime };
}

/// Parses only the `shortcuts` key. An I/O error is returned; a readable file
/// whose content is malformed, oversized, or not a valid map is `invalid`.
pub fn read(alloc: std.mem.Allocator, home_dir: []const u8) !Load {
    var store = try settings_store.Store.initFromHome(alloc, home_dir, .read_only);
    defer store.deinit(alloc);
    var primary = try store.loadPrimary(alloc);
    defer primary.deinit(alloc);
    const bytes = switch (primary) {
        .absent => return .absent,
        .invalid, .oversized => return .{ .invalid = .{} },
        .valid => |text| text,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return .{ .invalid = .{} };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .invalid = .{} };
    const value = parsed.value.object.get("shortcuts") orelse return .absent;
    var problem: shortcut_rules.Problem = .{};
    const map = shortcut_rules.parseJsonObjectChecked(value, &problem) catch return .{ .invalid = invalidFrom(problem) };
    return .{ .loaded = map };
}

fn writeProfile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn tempHome(tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    return io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
}

test "profile shortcuts are absent without a settings file or key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tempHome(&tmp);
    defer std.testing.allocator.free(home);

    try std.testing.expectEqual(@as(?Stamp, null), try stampOf(std.testing.allocator, home));
    try std.testing.expectEqual(std.meta.Tag(Load).absent, std.meta.activeTag(try read(std.testing.allocator, home)));

    try writeProfile(tmp.dir, "home/.fx/settings.json", "{\"theme\":\"dark\"}");
    try std.testing.expectEqual(std.meta.Tag(Load).absent, std.meta.activeTag(try read(std.testing.allocator, home)));
}

test "profile shortcuts load the valid map and report malformed content as invalid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tempHome(&tmp);
    defer std.testing.allocator.free(home);

    try writeProfile(tmp.dir, "home/.fx/settings.json",
        \\{"shortcuts":{"ctrl+1":"/model"}}
    );
    const loaded = try read(std.testing.allocator, home);
    try std.testing.expectEqual(std.meta.Tag(Load).loaded, std.meta.activeTag(loaded));
    try std.testing.expect(loaded.loaded.find(shortcut_rules.Chord.parse("ctrl+1").?) != null);
    try std.testing.expect(loaded.loaded.find(shortcut_rules.Chord.parse("alt+m").?) == null);

    try writeProfile(tmp.dir, "home/.fx/settings.json", "{\"shortcuts\":");
    const malformed = try read(std.testing.allocator, home);
    try std.testing.expectEqual(std.meta.Tag(Load).invalid, std.meta.activeTag(malformed));
    try std.testing.expectEqualStrings("", malformed.invalid.chord());

    try writeProfile(tmp.dir, "home/.fx/settings.json",
        \\{"shortcuts":{"ctrl+not-a-key":"/model"}}
    );
    const bad_chord = try read(std.testing.allocator, home);
    try std.testing.expectEqual(std.meta.Tag(Load).invalid, std.meta.activeTag(bad_chord));
    try std.testing.expectEqualStrings("ctrl+not-a-key", bad_chord.invalid.chord());
}

test "profile stamp changes on atomic replace and on a resized edit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tempHome(&tmp);
    defer std.testing.allocator.free(home);

    try writeProfile(tmp.dir, "home/.fx/settings.json", "{}");
    const first = (try stampOf(std.testing.allocator, home)).?;

    try writeProfile(tmp.dir, "home/.fx/settings-next.json", "{\"shortcuts\":{}}");
    try tmp.dir.rename("home/.fx/settings-next.json", tmp.dir, "home/.fx/settings.json", io_mod.getIo());
    const replaced = (try stampOf(std.testing.allocator, home)).?;
    try std.testing.expect(replaced.inode != first.inode);

    try writeProfile(tmp.dir, "home/.fx/settings.json", "{\"shortcuts\":{\"alt+m\":\"/model\"}}");
    const edited = (try stampOf(std.testing.allocator, home)).?;
    try std.testing.expect(edited.size != replaced.size);
}

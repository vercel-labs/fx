//! Reads only the profile's top-level `shortcuts` object, for the turn-end
//! reload. It opens the profile through the same store the settings load uses,
//! and never reads the rest of the configuration. `stampOf` is one stat, so a
//! turn that left the profile alone costs no read.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const settings_store = @import("settings_store.zig");
const shortcut_map = @import("shortcut_map.zig");

/// The identity of the profile's settings file. Atomic saves replace the
/// inode; an in-place edit changes the size or the times.
pub const Stamp = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime: std.Io.Timestamp,
    ctime: std.Io.Timestamp,
};

pub const Load = union(enum) {
    /// The profile sets no `shortcuts` key, or has no settings file.
    absent,
    loaded: shortcut_map.Map,
    /// The file exists but cannot give a valid map: the caller keeps its last one.
    invalid,
};

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
        .invalid, .oversized => return .invalid,
        .valid => |text| text,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return .invalid;
    defer parsed.deinit();
    if (parsed.value != .object) return .invalid;
    const value = parsed.value.object.get("shortcuts") orelse return .absent;
    const map = shortcut_map.parseJsonObject(value) catch return .invalid;
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
    try std.testing.expect((try read(std.testing.allocator, home)) == .absent);

    try writeProfile(tmp.dir, "home/.fx/settings.json", "{\"theme\":\"dark\"}");
    try std.testing.expect((try read(std.testing.allocator, home)) == .absent);
}

test "profile shortcuts load the valid map and report malformed content as invalid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tempHome(&tmp);
    defer std.testing.allocator.free(home);

    try writeProfile(tmp.dir, "home/.fx/settings.json",
        \\{"shortcuts":{"ctrl+1":{"action":"open_model_picker"}}}
    );
    const loaded = try read(std.testing.allocator, home);
    try std.testing.expect(loaded == .loaded);
    try std.testing.expect(loaded.loaded.find(shortcut_map.Chord.parse("ctrl+1").?) != null);
    try std.testing.expect(loaded.loaded.find(shortcut_map.Chord.parse("alt+m").?) == null);

    try writeProfile(tmp.dir, "home/.fx/settings.json", "{\"shortcuts\":");
    try std.testing.expect((try read(std.testing.allocator, home)) == .invalid);

    try writeProfile(tmp.dir, "home/.fx/settings.json",
        \\{"shortcuts":{"ctrl+not-a-key":{"action":"open_model_picker"}}}
    );
    try std.testing.expect((try read(std.testing.allocator, home)) == .invalid);
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

    try writeProfile(tmp.dir, "home/.fx/settings.json", "{\"shortcuts\":{\"alt+m\":{\"action\":\"open_model_picker\"}}}");
    const edited = (try stampOf(std.testing.allocator, home)).?;
    try std.testing.expect(edited.size != replaced.size);
}

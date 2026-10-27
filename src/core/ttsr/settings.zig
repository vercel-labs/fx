//! The `ttsr` settings group, read from the profile's `settings.json`: the
//! top-level `ttsr` object, then `workspaces["<root>"].ttsr` over it.
//! `PROTO_FX_TTSR=0` turns rules off for one run.
//!
//!   "ttsr": {
//!     "enabled": true,
//!     "context_mode": "discard",      // or "keep": the interrupted partial stays
//!     "interrupt_mode": "always",     // never | prose-only | tool-only | always
//!     "repeat_mode": "once",          // or "after-gap"
//!     "repeat_gap": 10,               // assistant messages before a rule may fire again
//!     "builtin_rules": true,
//!     "disabled_rules": ["ts-no-any"]
//!   }
const std = @import("std");
const rule_mod = @import("rule.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const ContextMode = enum { discard, keep };
pub const RepeatMode = enum { once, after_gap };

pub const Settings = struct {
    enabled: bool = true,
    context_mode: ContextMode = .discard,
    interrupt_mode: rule_mod.InterruptMode = .always,
    repeat_mode: RepeatMode = .once,
    repeat_gap: usize = 10,
    builtin_rules: bool = true,
    disabled_rules: []const []const u8 = &.{},

    pub fn isDisabled(self: Settings, name: []const u8) bool {
        for (self.disabled_rules) |disabled| if (std.mem.eql(u8, disabled, name)) return true;
        return false;
    }
};

/// Reads the settings for `workspace_root`. Strings live in `arena`; a
/// missing or unreadable file gives the defaults.
pub fn load(arena: Allocator, home: ?[]const u8, workspace_root: []const u8) Settings {
    var settings: Settings = .{};
    if (home) |dir| read(arena, dir, workspace_root, &settings) catch {};
    if (io_mod.getenv("PROTO_FX_TTSR")) |raw| {
        if (std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "off") or std.ascii.eqlIgnoreCase(raw, "false")) settings.enabled = false;
    }
    return settings;
}

fn read(arena: Allocator, home: []const u8, workspace_root: []const u8, settings: *Settings) !void {
    const path = try profile_paths.settingsPath(arena, home);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(arena, &file, 1 << 20);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (root != .object) return;
    if (root.object.get("ttsr")) |group| apply(arena, group, settings);
    const workspaces = root.object.get("workspaces") orelse return;
    if (workspaces != .object) return;
    const entry = workspaces.object.get(workspace_root) orelse return;
    if (entry != .object) return;
    if (entry.object.get("ttsr")) |group| apply(arena, group, settings);
}

/// Applies one `ttsr` object over `settings`; unknown or ill-typed fields
/// are ignored.
pub fn apply(arena: Allocator, group: std.json.Value, settings: *Settings) void {
    if (group != .object) return;
    const fields = group.object;
    if (fields.get("enabled")) |v| if (v == .bool) {
        settings.enabled = v.bool;
    };
    if (fields.get("context_mode")) |v| if (v == .string) {
        if (std.meta.stringToEnum(ContextMode, v.string)) |mode| settings.context_mode = mode;
    };
    if (fields.get("interrupt_mode")) |v| if (v == .string) {
        if (rule_mod.InterruptMode.parse(v.string)) |mode| settings.interrupt_mode = mode;
    };
    if (fields.get("repeat_mode")) |v| if (v == .string) {
        if (std.mem.eql(u8, v.string, "once")) settings.repeat_mode = .once;
        if (std.mem.eql(u8, v.string, "after-gap")) settings.repeat_mode = .after_gap;
    };
    if (fields.get("repeat_gap")) |v| if (v == .integer and v.integer > 0) {
        settings.repeat_gap = @intCast(v.integer);
    };
    if (fields.get("builtin_rules")) |v| if (v == .bool) {
        settings.builtin_rules = v.bool;
    };
    if (fields.get("disabled_rules")) |v| if (v == .array) {
        var names: std.ArrayList([]const u8) = .empty;
        for (v.array.items) |item| if (item == .string) {
            const name = std.mem.trim(u8, item.string, " ");
            if (name.len > 0) names.append(arena, name) catch return;
        };
        settings.disabled_rules = names.items;
    };
}

test "settings apply the ttsr group and ignore ill-typed fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const group = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"enabled":false,"context_mode":"keep","interrupt_mode":"prose-only","repeat_mode":"after-gap",
        \\ "repeat_gap":3,"builtin_rules":false,"disabled_rules":["a"," b "],"bogus":1,"repeat_gap_x":"x"}
    , .{});
    var settings: Settings = .{};
    apply(arena, group, &settings);
    try std.testing.expect(!settings.enabled);
    try std.testing.expectEqual(ContextMode.keep, settings.context_mode);
    try std.testing.expectEqual(rule_mod.InterruptMode.prose_only, settings.interrupt_mode);
    try std.testing.expectEqual(RepeatMode.after_gap, settings.repeat_mode);
    try std.testing.expectEqual(@as(usize, 3), settings.repeat_gap);
    try std.testing.expect(!settings.builtin_rules);
    try std.testing.expect(settings.isDisabled("b"));
    var unchanged: Settings = .{};
    apply(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"repeat_gap\":0,\"context_mode\":\"wild\"}", .{}), &unchanged);
    try std.testing.expectEqual(@as(usize, 10), unchanged.repeat_gap);
    try std.testing.expectEqual(ContextMode.discard, unchanged.context_mode);
}

//! The documented `FX_*` variables that override a setting for the whole
//! process, read the way fx reads them, so `fx config list` and `get` can show
//! the value fx uses and where it came from.

const std = @import("std");
const agent_steps = @import("agent_steps.zig");
const compactor = @import("../compactor/compactor.zig");
const config_runtime = @import("config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("model_provider.zig");
const settings_store = @import("settings_store.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Override = struct {
    /// The variable, such as `FX_MAX_AGENT_STEPS`.
    variable: []const u8,
    /// The dotted setting it overrides, such as `max_agent_steps`.
    key: []const u8,
    /// The value fx uses, in settings-file form.
    value: std.json.Value,
};

/// `FX_SOUND` is a preset for the whole `sound` group.
pub const SoundPreset = enum {
    /// Every sound off.
    off,
    /// Turn-end and attention sounds on, `max` off.
    on,
    /// Every sound on.
    max,
};

/// The preset `FX_SOUND` names: `max`, or `0`, `false`, or `off` for off.
/// Any other non-blank value turns sounds on.
pub fn soundPreset(raw: []const u8) ?SoundPreset {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "max")) return .max;
    const off = std.mem.eql(u8, trimmed, "0") or
        std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "off");
    return if (off) .off else .on;
}

/// True when `FX_AUTO_UPGRADE` turns automatic upgrades off: `0` or `false`.
/// No value turns them on.
pub fn autoUpgradeOff(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "false");
}

/// Every documented `FX_*` setting override set in this process, in a fixed
/// order, with the value fx uses. A value fx ignores or rejects, such as
/// `FX_MAX_AGENT_STEPS=many`, is left out. `FX_MODEL` overrides the model of
/// `provider`, the provider fx would use without it. Everything, including
/// the returned slice, is allocated with `arena`.
pub fn collect(arena: Allocator, provider: model_provider.ProviderId) ![]Override {
    var list: std.ArrayList(Override) = .empty;
    const getenv = io_mod.getenv;

    var model_provider_id = provider;
    if (config_runtime.providerEnvOverride()) |raw| {
        if (model_provider.parse(std.mem.trim(u8, raw, " \t\r\n"))) |parsed| {
            model_provider_id = parsed;
            try list.append(arena, .{ .variable = "FX_PROVIDER", .key = "provider", .value = .{ .string = try arena.dupe(u8, parsed.label()) } });
        }
    }
    if (config_runtime.modelEnvOverride()) |model| {
        const key = try std.mem.concat(arena, u8, &.{ "models.", model_provider.NameKey.fromProvider(model_provider_id).label() });
        try list.append(arena, .{ .variable = "FX_MODEL", .key = key, .value = .{ .string = model } });
    }
    if (config_runtime.ultrafastModeEnvOverride() catch null) |enabled| {
        try list.append(arena, .{ .variable = "FX_ULTRAFAST", .key = "ultrafast_mode", .value = .{ .bool = enabled } });
    }
    if (getenv("FX_REVIEW_MODEL")) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            if (settings_store.validateModel(trimmed)) |_| {
                try list.append(arena, .{ .variable = "FX_REVIEW_MODEL", .key = "review_model", .value = .{ .string = trimmed } });
            } else |_| {}
        }
    }
    if (getenv("FX_PROVIDER_ORDER")) |raw| {
        switch (config_runtime.parseProviderOrderList(arena, raw)) {
            .ok => |maybe_order| if (maybe_order) |order| {
                var array: std.json.Array = .init(arena);
                for (order) |slug| try array.append(.{ .string = slug });
                try list.append(arena, .{ .variable = "FX_PROVIDER_ORDER", .key = "provider_order", .value = .{ .array = array } });
            },
            .invalid => {},
        }
    }
    if (getenv("FX_PROVIDER_STRICT")) |raw| {
        if (config_runtime.parseEnvBool(std.mem.trim(u8, raw, " \t\r\n"))) |strict| {
            try list.append(arena, .{ .variable = "FX_PROVIDER_STRICT", .key = "provider_strict", .value = .{ .bool = strict } });
        }
    }
    if (getenv("FX_PERMISSION_MODE")) |raw| {
        if (types.PermissionMode.parse(raw)) |mode| {
            try list.append(arena, .{ .variable = "FX_PERMISSION_MODE", .key = "permission_mode", .value = .{ .string = mode.label() } });
        }
    }
    if (agent_steps.parseMaxAgentSteps(getenv("FX_MAX_AGENT_STEPS"))) |steps| {
        // fx accepts any usize, which can exceed a JSON integer.
        const value: std.json.Value = if (std.math.cast(i64, steps)) |fits|
            .{ .integer = fits }
        else
            .{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{steps}) };
        try list.append(arena, .{ .variable = "FX_MAX_AGENT_STEPS", .key = "max_agent_steps", .value = value });
    }
    if (compactor.parsePercent(getenv("FX_AUTO_COMPACT_PERCENT"))) |percent| {
        try list.append(arena, .{ .variable = "FX_AUTO_COMPACT_PERCENT", .key = "auto_compact_percent", .value = .{ .integer = percent } });
    }
    if (getenv("FX_THEME")) |raw| {
        if (raw.len > 0) try list.append(arena, .{ .variable = "FX_THEME", .key = "theme", .value = .{ .string = raw } });
    }
    if (getenv("FX_SOUND")) |raw| {
        if (soundPreset(raw)) |preset| {
            const values = [_]struct { key: []const u8, on: bool }{
                .{ .key = "sound.turn_end", .on = preset != .off },
                .{ .key = "sound.attention_required", .on = preset != .off },
                .{ .key = "sound.max", .on = preset == .max },
            };
            for (values) |entry| try list.append(arena, .{ .variable = "FX_SOUND", .key = entry.key, .value = .{ .bool = entry.on } });
        }
    }
    if (getenv("FX_AUTO_UPGRADE")) |raw| {
        if (autoUpgradeOff(raw)) try list.append(arena, .{ .variable = "FX_AUTO_UPGRADE", .key = "auto_upgrade", .value = .{ .bool = false } });
    }
    return list.toOwnedSlice(arena);
}

test "FX_SOUND presets and FX_AUTO_UPGRADE read the words fx accepts" {
    try std.testing.expectEqual(SoundPreset.max, soundPreset(" MAX\n").?);
    try std.testing.expectEqual(SoundPreset.off, soundPreset("0").?);
    try std.testing.expectEqual(SoundPreset.off, soundPreset("Off").?);
    try std.testing.expectEqual(SoundPreset.on, soundPreset("yes").?);
    try std.testing.expect(soundPreset("  ") == null);
    try std.testing.expect(autoUpgradeOff("0") and autoUpgradeOff("FALSE"));
    try std.testing.expect(!autoUpgradeOff("1") and !autoUpgradeOff("no"));
}

var test_empty_environ: ?*std.process.Environ.Map = null;

/// An empty environment that outlives every test, for a test that installs
/// its own to restore afterwards.
pub fn emptyTestEnviron() !*const std.process.Environ.Map {
    if (test_empty_environ) |map| return map;
    const map = try std.heap.page_allocator.create(std.process.Environ.Map);
    map.* = .init(std.heap.page_allocator);
    test_empty_environ = map;
    return map;
}

test "collect shows each set override as the setting fx uses, and skips ignored values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const restore = io_mod.environMap() orelse try emptyTestEnviron();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    for ([_][2][]const u8{
        .{ "FX_PROVIDER", "codex" },
        .{ "FX_MODEL", " gpt-test " },
        .{ "FX_MAX_AGENT_STEPS", "12" },
        // Out of range, so fx ignores it.
        .{ "FX_AUTO_COMPACT_PERCENT", "5" },
        .{ "FX_PERMISSION_MODE", "yolo" },
        .{ "FX_SOUND", "max" },
        // Only `0` and `false` mean anything.
        .{ "FX_AUTO_UPGRADE", "1" },
    }) |entry| try env.put(entry[0], entry[1]);
    io_mod.setEnvironMap(&env);
    defer io_mod.setEnvironMap(restore);

    const found = try collect(arena.allocator(), .gateway);
    const expected = [_]struct { variable: []const u8, key: []const u8 }{
        .{ .variable = "FX_PROVIDER", .key = "provider" },
        .{ .variable = "FX_MODEL", .key = "models.codex" },
        .{ .variable = "FX_PERMISSION_MODE", .key = "permission_mode" },
        .{ .variable = "FX_MAX_AGENT_STEPS", .key = "max_agent_steps" },
        .{ .variable = "FX_SOUND", .key = "sound.turn_end" },
        .{ .variable = "FX_SOUND", .key = "sound.attention_required" },
        .{ .variable = "FX_SOUND", .key = "sound.max" },
    };
    try std.testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| {
        try std.testing.expectEqualStrings(want.variable, got.variable);
        try std.testing.expectEqualStrings(want.key, got.key);
    }
    try std.testing.expectEqualStrings("gpt-test", found[1].value.string);
    try std.testing.expectEqualStrings("full-access", found[2].value.string);
    try std.testing.expectEqual(@as(i64, 12), found[3].value.integer);
    try std.testing.expect(found[6].value.bool);
}

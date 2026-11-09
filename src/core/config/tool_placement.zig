//! Where each of fx's built-in tools is offered: sent with the tools
//! (`direct`), or listed in the toolbox menu and run through toolbox
//! (`toolbox`). The `tool_placement` setting and the launch-wide
//! `--tool-placement` flag set it. fx resolves it once at startup, so a
//! conversation's tools never change while it runs.
const std = @import("std");
const toolbox = @import("../tooling/toolbox.zig");

pub const Placement = enum {
    toolbox,
    direct,

    /// `toolbox` or `direct`, in any case.
    pub fn parse(text: []const u8) ?Placement {
        inline for (@typeInfo(Placement).@"enum".field_names) |name| {
            if (std.ascii.eqlIgnoreCase(text, name)) return @field(Placement, name);
        }
        return null;
    }
};

/// The built-in tools whose placement can change. Three kinds keep theirs:
/// toolbox itself; the tools it replaces (`toolbox.replaced`); and vision,
/// which fx calls by name while attached images wait.
pub const Tool = enum {
    glob_files,
    grep_files,
    read_file,
    write_file,
    edit_file,
    web_fetch,
    web_search,
    shell,
    install_skill,
    subagent,
    ask_user_question,
    read_tool_result,

    pub fn parse(name: []const u8) ?Tool {
        return std.meta.stringToEnum(Tool, name);
    }
};

pub const tool_count = @typeInfo(Tool).@"enum".field_names.len;

/// The tools that can move, comma-separated, for messages.
pub const movable_list = blk: {
    var out: []const u8 = "";
    for (@typeInfo(Tool).@"enum".field_names, 0..) |name, index| {
        out = out ++ (if (index > 0) ", " else "") ++ name;
    }
    break :blk out;
};

/// Each tool's setting key, such as `tool_placement.web_search`.
pub const setting_keys = blk: {
    var keys: [tool_count][]const u8 = undefined;
    for (@typeInfo(Tool).@"enum".field_names, 0..) |name, index| keys[index] = "tool_placement." ++ name;
    break :blk keys;
};

/// The tool a `tool_placement.<tool>` key names, or null for any other key.
pub fn toolOfKey(key: []const u8) ?Tool {
    const prefix = "tool_placement.";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    return Tool.parse(key[prefix.len..]);
}

/// Where `tool` goes: what `settings` says, or its default.
pub fn placementOf(settings: Overrides, tool: Tool) Placement {
    if (settings.get(tool)) |placement| return placement;
    for (toolbox.default_behind) |name| {
        if (std.mem.eql(u8, name, @tagName(tool))) return .toolbox;
    }
    return .direct;
}

/// One `--tool-placement <tool>=<toolbox|direct>`.
pub const Override = struct {
    tool: Tool,
    placement: Placement,
};

/// What a settings layer says, by tool; null where it says nothing.
pub const Overrides = struct {
    placements: [tool_count]?Placement = @splat(null),

    pub fn set(self: *Overrides, tool: Tool, placement: Placement) void {
        self.placements[@backingInt(tool)] = placement;
    }

    pub fn get(self: Overrides, tool: Tool) ?Placement {
        return self.placements[@backingInt(tool)];
    }

    /// A later layer, such as this folder's entry over the profile, wins for
    /// each tool it names.
    pub fn merge(self: *Overrides, incoming: Overrides) void {
        for (&self.placements, incoming.placements) |*current, value| {
            if (value) |placement| current.* = placement;
        }
    }
};

pub const ParseError = error{
    InvalidToolPlacementOverride,
    UnknownToolPlacementTool,
    InvalidToolPlacementValue,
    InvalidToolPlacementType,
};

/// Parses `<tool>=<toolbox|direct>`, as `--tool-placement` takes it.
pub fn parseOverride(raw: []const u8) ParseError!Override {
    const separator = std.mem.findScalar(u8, raw, '=') orelse return error.InvalidToolPlacementOverride;
    const name = std.mem.trim(u8, raw[0..separator], " \t\r\n");
    const value = std.mem.trim(u8, raw[separator + 1 ..], " \t\r\n");
    if (name.len == 0 or value.len == 0) return error.InvalidToolPlacementOverride;
    return .{
        .tool = Tool.parse(name) orelse return error.UnknownToolPlacementTool,
        .placement = Placement.parse(value) orelse return error.InvalidToolPlacementValue,
    };
}

/// Parses the `tool_placement` object of a settings file.
pub fn parseJsonObject(value: std.json.Value) ParseError!Overrides {
    if (value != .object) return error.InvalidToolPlacementType;
    var result: Overrides = .{};
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const tool = Tool.parse(entry.key_ptr.*) orelse return error.UnknownToolPlacementTool;
        if (entry.value_ptr.* != .string) return error.InvalidToolPlacementValue;
        result.set(tool, Placement.parse(entry.value_ptr.string) orelse return error.InvalidToolPlacementValue);
    }
    return result;
}

/// The built-in tools offered through toolbox, in `Tool` order.
pub const Behind = struct {
    names: [tool_count][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Behind) []const []const u8 {
        return self.names[0..self.len];
    }
};

/// The tools behind toolbox: `toolbox.default_behind`, then `settings` (the
/// profile with this folder's entry merged over it), then `command_line`,
/// whose last value for a tool wins.
pub fn behindToolbox(settings: Overrides, command_line: []const Override) Behind {
    var placements = settings;
    for (command_line) |override| placements.set(override.tool, override.placement);
    var behind: Behind = .{};
    inline for (@typeInfo(Tool).@"enum".field_names) |name| {
        if (placementOf(placements, @field(Tool, name)) == .toolbox) {
            behind.names[behind.len] = name;
            behind.len += 1;
        }
    }
    return behind;
}

test "the defaults put install_skill behind toolbox and leave the rest direct" {
    const behind = behindToolbox(.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), behind.len);
    try std.testing.expectEqualStrings("install_skill", behind.slice()[0]);
}

test "settings move tools either way, and the command line wins over them" {
    var settings: Overrides = .{};
    settings.set(.web_search, .toolbox);
    settings.set(.install_skill, .direct);
    var behind = behindToolbox(settings, &.{});
    try std.testing.expectEqual(@as(usize, 1), behind.len);
    try std.testing.expectEqualStrings("web_search", behind.slice()[0]);

    behind = behindToolbox(settings, &.{
        .{ .tool = .web_search, .placement = .direct },
        .{ .tool = .shell, .placement = .toolbox },
        .{ .tool = .shell, .placement = .direct },
        .{ .tool = .glob_files, .placement = .toolbox },
    });
    try std.testing.expectEqual(@as(usize, 1), behind.len);
    try std.testing.expectEqualStrings("glob_files", behind.slice()[0]);
}

test "setting keys name each movable tool" {
    try std.testing.expectEqual(Tool.web_search, toolOfKey("tool_placement.web_search").?);
    try std.testing.expectEqual(@as(?Tool, null), toolOfKey("tool_placement.vision"));
    try std.testing.expectEqual(@as(?Tool, null), toolOfKey("context_limits.web_search"));
    try std.testing.expectEqualStrings("tool_placement.glob_files", setting_keys[0]);
    try std.testing.expect(std.mem.startsWith(u8, movable_list, "glob_files, grep_files, "));
    try std.testing.expectEqual(Placement.toolbox, placementOf(.{}, .install_skill));
    try std.testing.expectEqual(Placement.direct, placementOf(.{}, .shell));
}

test "a folder's entry wins over the profile for the tools it names" {
    var profile: Overrides = .{};
    profile.set(.web_fetch, .toolbox);
    profile.set(.web_search, .toolbox);
    var folder: Overrides = .{};
    folder.set(.web_search, .direct);
    profile.merge(folder);
    try std.testing.expectEqual(Placement.toolbox, profile.get(.web_fetch).?);
    try std.testing.expectEqual(Placement.direct, profile.get(.web_search).?);
}

test "overrides and settings name a movable tool and a placement" {
    try std.testing.expectEqual(Override{ .tool = .web_search, .placement = .toolbox }, try parseOverride(" web_search = Toolbox "));
    try std.testing.expectEqual(Override{ .tool = .install_skill, .placement = .direct }, try parseOverride("install_skill=direct"));
    try std.testing.expectError(error.InvalidToolPlacementOverride, parseOverride("web_search"));
    try std.testing.expectError(error.InvalidToolPlacementOverride, parseOverride("=toolbox"));
    try std.testing.expectError(error.UnknownToolPlacementTool, parseOverride("toolbox=direct"));
    try std.testing.expectError(error.UnknownToolPlacementTool, parseOverride("vision=toolbox"));
    try std.testing.expectError(error.UnknownToolPlacementTool, parseOverride("capability_search=toolbox"));
    try std.testing.expectError(error.InvalidToolPlacementValue, parseOverride("shell=hidden"));

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"web_fetch\":\"toolbox\",\"install_skill\":\"DIRECT\"}", .{});
    defer parsed.deinit();
    const overrides = try parseJsonObject(parsed.value);
    try std.testing.expectEqual(Placement.toolbox, overrides.get(.web_fetch).?);
    try std.testing.expectEqual(Placement.direct, overrides.get(.install_skill).?);
    try std.testing.expectEqual(@as(?Placement, null), overrides.get(.shell));

    const wrong = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"shell\":true}", .{});
    defer wrong.deinit();
    try std.testing.expectError(error.InvalidToolPlacementValue, parseJsonObject(wrong.value));
}

const fuzz_names = [_][]const u8{ "shell", "install_skill", "read_tool_result", " web_search\t", "Shell", "toolbox", "skill", "vision", "mcp_x", "" };
const fuzz_values = [_][]const u8{ "toolbox", "direct", "DIRECT", " Toolbox\n", "toolboxx", "", "\"direct\"", "true" };
const fuzz_separators = [_][]const u8{ "=", " = ", "==", "" };

/// Byte triples pick a tool name, a separator, and a value, built into one
/// `--tool-placement` value and a settings object; a first byte of 0xff
/// takes the rest as both texts.
fn fuzzParse(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [48]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var flag: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer flag.deinit();
    var object: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer object.deinit();
    if (bytes.len > 0 and bytes[0] == 0xff) {
        try flag.writer.writeAll(bytes[1..]);
        try object.writer.writeAll(bytes[1..]);
    } else {
        try object.writer.writeByte('{');
        var index: usize = 0;
        while (index + 2 < bytes.len) : (index += 3) {
            const name = fuzz_names[bytes[index] % fuzz_names.len];
            const value = fuzz_values[bytes[index + 2] % fuzz_values.len];
            if (index == 0) try flag.writer.print("{s}{s}{s}", .{ name, fuzz_separators[bytes[index + 1] % fuzz_separators.len], value });
            if (index > 0) try object.writer.writeByte(',');
            try std.json.Stringify.value(name, .{}, &object.writer);
            try object.writer.writeByte(':');
            if (bytes[index + 1] % 2 == 0) try std.json.Stringify.value(value, .{}, &object.writer) else try object.writer.writeAll(value);
        }
        try object.writer.writeByte('}');
    }

    // A flag value reads as a tool and placement only when both parts name
    // one, and what it reads writes back to the same override.
    if (parseOverride(flag.written())) |override| {
        var text: [64]u8 = undefined;
        const again = try std.fmt.bufPrint(&text, "{s}={s}", .{ @tagName(override.tool), @tagName(override.placement) });
        try std.testing.expectEqual(override, try parseOverride(again));
    } else |_| {}

    // A settings object reads only when every entry names a movable tool and
    // a placement, and then each tool's placement is its entry's.
    const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, object.written(), .{}) catch return;
    defer parsed.deinit();
    const overrides = parseJsonObject(parsed.value) catch return;
    var entries = parsed.value.object.iterator();
    while (entries.next()) |entry| {
        const tool = Tool.parse(entry.key_ptr.*) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(Placement.parse(entry.value_ptr.string), overrides.get(tool));
    }
}

test "tool placement parsing reads a placement or an error from any text" {
    try std.testing.fuzz({}, fuzzParse, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "\x00\x00\x00",
            "\x01\x01\x01\x02\x00\x03",
            "\xff{\"shell\":\"toolbox\",\"shell\":\"direct\"}",
        }) ++ @import("fuzz_corpus").tool_placement_parse.*),
    });
}

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const schema_version: u8 = 1;
pub const default_timeout_ms: u32 = 5_000;
pub const max_timeout_ms: u32 = 60_000;
pub const max_handlers_per_event: usize = 32;
pub const max_command_arguments: usize = 64;
pub const max_command_argument_bytes: usize = 4 * 1024;
pub const max_environment_names: usize = 32;
pub const max_environment_name_bytes: usize = 128;

pub const Source = enum {
    user,
    workspace,
};

pub const Handler = struct {
    command: [][]u8,
    timeout_ms: u32 = default_timeout_ms,
    environment: [][]u8 = &.{},
    source: Source = .user,

    pub fn deinit(self: *Handler, alloc: Allocator) void {
        freeStrings(alloc, self.command);
        freeStrings(alloc, self.environment);
        self.* = undefined;
    }
};

/// Each non-null event list is a complete layer value. A workspace list in
/// the private user profile replaces the corresponding user-global list;
/// an explicit empty list disables that event for the workspace.
pub const Config = struct {
    pre_tool_use: ?[]Handler = null,
    stop: ?[]Handler = null,
    post_turn_end: ?[]Handler = null,
    attention_required: ?[]Handler = null,

    pub fn deinit(self: *Config, alloc: Allocator) void {
        deinitHandlers(alloc, self.pre_tool_use);
        deinitHandlers(alloc, self.stop);
        deinitHandlers(alloc, self.post_turn_end);
        deinitHandlers(alloc, self.attention_required);
        self.* = .{};
    }

    pub fn mergeMove(self: *Config, alloc: Allocator, incoming: *Config) void {
        replaceHandlers(alloc, &self.pre_tool_use, &incoming.pre_tool_use);
        replaceHandlers(alloc, &self.stop, &incoming.stop);
        replaceHandlers(alloc, &self.post_turn_end, &incoming.post_turn_end);
        replaceHandlers(alloc, &self.attention_required, &incoming.attention_required);
    }

    pub fn retag(self: *Config, source: Source) void {
        retagHandlers(self.pre_tool_use, source);
        retagHandlers(self.stop, source);
        retagHandlers(self.post_turn_end, source);
        retagHandlers(self.attention_required, source);
    }

    pub fn count(self: Config) usize {
        return handlerCount(self.pre_tool_use) +
            handlerCount(self.stop) +
            handlerCount(self.post_turn_end) +
            handlerCount(self.attention_required);
    }
};

pub fn parse(alloc: Allocator, value: std.json.Value) !Config {
    if (value != .object) return error.InvalidHooksType;

    var keys = value.object.iterator();
    while (keys.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "PreToolUse") or
            std.mem.eql(u8, entry.key_ptr.*, "Stop") or
            std.mem.eql(u8, entry.key_ptr.*, "PostTurnEnd") or
            std.mem.eql(u8, entry.key_ptr.*, "AttentionRequired"))
        {
            continue;
        }
        return error.UnknownHookEvent;
    }

    var result = Config{};
    errdefer result.deinit(alloc);
    if (value.object.get("PreToolUse")) |handlers| {
        result.pre_tool_use = try parseHandlers(alloc, handlers);
    }
    if (value.object.get("Stop")) |handlers| {
        result.stop = try parseHandlers(alloc, handlers);
    }
    if (value.object.get("PostTurnEnd")) |handlers| {
        result.post_turn_end = try parseHandlers(alloc, handlers);
    }
    if (value.object.get("AttentionRequired")) |handlers| {
        result.attention_required = try parseHandlers(alloc, handlers);
    }
    return result;
}

fn parseHandlers(alloc: Allocator, value: std.json.Value) ![]Handler {
    if (value != .array) return error.InvalidHookHandlersType;
    if (value.array.items.len > max_handlers_per_event) return error.TooManyHookHandlers;
    if (value.array.items.len == 0) return @constCast(&.{});

    const handlers = try alloc.alloc(Handler, value.array.items.len);
    var parsed: usize = 0;
    errdefer {
        for (handlers[0..parsed]) |*handler| handler.deinit(alloc);
        alloc.free(handlers);
    }
    for (value.array.items, 0..) |item, index| {
        handlers[index] = try parseHandler(alloc, item);
        parsed += 1;
    }
    return handlers;
}

fn parseHandler(alloc: Allocator, value: std.json.Value) !Handler {
    if (value != .object) return error.InvalidHookHandlerType;
    const command_value = value.object.get("command") orelse return error.MissingHookCommand;
    const command = try parseStringArray(
        alloc,
        command_value,
        1,
        max_command_arguments,
        max_command_argument_bytes,
        false,
    );
    errdefer freeStrings(alloc, command);

    const timeout_ms = if (value.object.get("timeout_ms")) |timeout_value| blk: {
        if (timeout_value != .integer or timeout_value.integer < 1) {
            return error.InvalidHookTimeout;
        }
        const parsed = std.math.cast(u32, timeout_value.integer) orelse
            return error.InvalidHookTimeout;
        if (parsed > max_timeout_ms) return error.InvalidHookTimeout;
        break :blk parsed;
    } else default_timeout_ms;

    const environment = if (value.object.get("environment")) |environment_value|
        try parseStringArray(
            alloc,
            environment_value,
            0,
            max_environment_names,
            max_environment_name_bytes,
            true,
        )
    else
        @constCast(&.{});

    return .{
        .command = command,
        .timeout_ms = timeout_ms,
        .environment = environment,
    };
}

fn parseStringArray(
    alloc: Allocator,
    value: std.json.Value,
    minimum: usize,
    maximum: usize,
    maximum_string_bytes: usize,
    validate_environment_names: bool,
) ![][]u8 {
    if (value != .array) return error.InvalidHookStringArray;
    if (value.array.items.len < minimum or value.array.items.len > maximum) {
        return error.InvalidHookStringArray;
    }
    if (value.array.items.len == 0) return @constCast(&.{});

    const strings = try alloc.alloc([]u8, value.array.items.len);
    var parsed: usize = 0;
    errdefer {
        for (strings[0..parsed]) |string| alloc.free(string);
        alloc.free(strings);
    }
    for (value.array.items, 0..) |item, index| {
        if (item != .string or item.string.len == 0 or
            item.string.len > maximum_string_bytes or
            std.mem.findScalar(u8, item.string, 0) != null)
        {
            return error.InvalidHookString;
        }
        if (validate_environment_names and !validEnvironmentName(item.string)) {
            return error.InvalidHookEnvironmentName;
        }
        if (validate_environment_names) {
            for (strings[0..parsed]) |previous| {
                if (std.mem.eql(u8, previous, item.string)) return error.DuplicateHookEnvironmentName;
            }
        }
        strings[index] = try alloc.dupe(u8, item.string);
        parsed += 1;
    }
    return strings;
}

fn validEnvironmentName(name: []const u8) bool {
    if (!std.process.Environ.Map.validateKeyForPut(name)) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_') continue;
        return false;
    }
    return true;
}

fn replaceHandlers(alloc: Allocator, target: *?[]Handler, incoming: *?[]Handler) void {
    const replacement = incoming.* orelse return;
    deinitHandlers(alloc, target.*);
    target.* = replacement;
    incoming.* = null;
}

fn deinitHandlers(alloc: Allocator, handlers: ?[]Handler) void {
    const values = handlers orelse return;
    for (values) |*handler| handler.deinit(alloc);
    if (values.len > 0) alloc.free(values);
}

fn retagHandlers(handlers: ?[]Handler, source: Source) void {
    const values = handlers orelse return;
    for (values) |*handler| handler.source = source;
}

fn handlerCount(handlers: ?[]Handler) usize {
    return if (handlers) |values| values.len else 0;
}

fn freeStrings(alloc: Allocator, strings: [][]u8) void {
    for (strings) |string| alloc.free(string);
    if (strings.len > 0) alloc.free(strings);
}

test "hook config parses canonical events and bounded process policy" {
    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{
        \\  "PreToolUse": [{"command":["/usr/bin/tool","wrap"],"timeout_ms":250,"environment":["LAT_API_KEY"]}],
        \\  "Stop": [],
        \\  "AttentionRequired": [{"command":["notify"]}]
        \\}
    ,
        .{},
    );
    defer parsed_json.deinit();
    var config = try parse(std.testing.allocator, parsed_json.value);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), config.count());
    try std.testing.expectEqualStrings("/usr/bin/tool", config.pre_tool_use.?[0].command[0]);
    try std.testing.expectEqual(@as(u32, 250), config.pre_tool_use.?[0].timeout_ms);
    try std.testing.expectEqualStrings("LAT_API_KEY", config.pre_tool_use.?[0].environment[0]);
    try std.testing.expectEqual(@as(usize, 0), config.stop.?.len);
    try std.testing.expectEqual(default_timeout_ms, config.attention_required.?[0].timeout_ms);
}

test "workspace event lists replace matching user lists without clearing others" {
    var user_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"PreToolUse\":[{\"command\":[\"global-pre\"]}],\"Stop\":[{\"command\":[\"global-stop\"]}]}",
        .{},
    );
    defer user_json.deinit();
    var workspace_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"PreToolUse\":[{\"command\":[\"workspace-pre\"]}]}",
        .{},
    );
    defer workspace_json.deinit();

    var user = try parse(std.testing.allocator, user_json.value);
    defer user.deinit(std.testing.allocator);
    var workspace = try parse(std.testing.allocator, workspace_json.value);
    defer workspace.deinit(std.testing.allocator);
    workspace.retag(.workspace);
    user.mergeMove(std.testing.allocator, &workspace);

    try std.testing.expectEqualStrings("workspace-pre", user.pre_tool_use.?[0].command[0]);
    try std.testing.expectEqual(Source.workspace, user.pre_tool_use.?[0].source);
    try std.testing.expectEqualStrings("global-stop", user.stop.?[0].command[0]);
    try std.testing.expect(workspace.pre_tool_use == null);
}

test "hook config rejects shell strings invalid limits and invalid environment names" {
    const cases = [_][]const u8{
        "{\"PreToolUse\":[{\"command\":\"echo unsafe\"}]}",
        "{\"PreToolUse\":[{\"command\":[]}]}",
        "{\"PreToolUse\":[{\"command\":[\"ok\"],\"timeout_ms\":0}]}",
        "{\"PreToolUse\":[{\"command\":[\"ok\"],\"timeout_ms\":60001}]}",
        "{\"PreToolUse\":[{\"command\":[\"ok\"],\"environment\":[\"BAD-NAME\"]}]}",
        "{\"PostToolUse\":[{\"command\":[\"not-supported\"]}]}",
    };
    for (cases) |json| {
        var parsed_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed_json.deinit();
        if (parse(std.testing.allocator, parsed_json.value)) |config_value| {
            var config = config_value;
            config.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

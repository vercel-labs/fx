const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// One configured ACP agent CLI in ~/.fx/acp.json. Owns every field;
/// `deinit` releases them.
pub const AcpAgentConfig = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    enabled: bool = true,
    /// Model value ids the agent reported (session/new configOptions).
    /// Cached so the model picker can list them without spawning the agent.
    models: []const []const u8 = &.{},
    /// Reasoning-effort value ids the agent reported, cached for the same
    /// reason: the effort picker stage needs them before a session exists.
    efforts: []const []const u8 = &.{},

    pub fn deinit(self: *AcpAgentConfig, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.command);
        freeOwnedStrings(alloc, self.args);
        freeOwnedStrings(alloc, self.env);
        freeOwnedStrings(alloc, self.models);
        freeOwnedStrings(alloc, self.efforts);
        self.* = undefined;
    }
};

pub fn freeConfigs(alloc: Allocator, configs: *std.ArrayList(AcpAgentConfig)) void {
    for (configs.items) |*config| config.deinit(alloc);
    configs.deinit(alloc);
}

fn freeOwnedStrings(alloc: Allocator, strings: []const []const u8) void {
    for (strings) |string| alloc.free(string);
    alloc.free(strings);
}

pub fn isValidAgentName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const allowed = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!allowed) return false;
    }
    return true;
}

pub fn loadConfigFromPath(alloc: Allocator, path: []const u8) !std.ArrayList(AcpAgentConfig) {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| {
        if (err == error.FileNotFound) return .empty;
        debug_trace.logf("acp", "failed to open config {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer file.close(io_mod.getIo());

    const json_text = io_mod.readFileToEnd(alloc, &file, 1024 * 1024) catch |err| {
        debug_trace.logf("acp", "failed to read config {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer alloc.free(json_text);

    return loadConfigFromJson(alloc, json_text) catch |err| {
        debug_trace.logf("acp", "failed to load config {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
}

pub fn loadConfigFromJson(alloc: Allocator, json_text: []const u8) !std.ArrayList(AcpAgentConfig) {
    var configs: std.ArrayList(AcpAgentConfig) = .empty;
    errdefer freeConfigs(alloc, &configs);

    if (std.mem.trim(u8, json_text, " \t\r\n").len == 0) return configs;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
        return error.AcpConfigInvalidJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.AcpConfigRootMustBeObject;

    const agents_value = root.object.get("agents") orelse return configs;
    if (agents_value != .array) return error.AcpConfigAgentsMustBeArray;

    for (agents_value.array.items) |agent_value| {
        if (agent_value != .object) return error.AcpConfigAgentMustBeObject;
        const object = agent_value.object;

        const name_value = object.get("name") orelse return error.AcpConfigMissingName;
        if (name_value != .string) return error.AcpConfigInvalidName;
        if (!isValidAgentName(name_value.string)) return error.AcpConfigInvalidName;

        const command_value = object.get("command") orelse return error.AcpConfigMissingCommand;
        if (command_value != .string) return error.AcpConfigInvalidCommand;
        if (command_value.string.len == 0) return error.AcpConfigInvalidCommand;

        const enabled = if (object.get("enabled")) |enabled_value|
            (if (enabled_value == .bool) enabled_value.bool else return error.AcpConfigInvalidEnabled)
        else
            true;

        var args: std.ArrayList([]const u8) = .empty;
        var args_owned = false;
        errdefer if (!args_owned) args.deinit(alloc);
        if (object.get("args")) |args_value| {
            if (args_value != .array) return error.AcpConfigInvalidArgs;
            for (args_value.array.items) |arg_value| {
                if (arg_value != .string) return error.AcpConfigInvalidArgs;
                try args.append(alloc, try alloc.dupe(u8, arg_value.string));
            }
        }

        var env: std.ArrayList([]const u8) = .empty;
        var env_owned = false;
        errdefer if (!env_owned) env.deinit(alloc);
        if (object.get("env")) |env_value| {
            if (env_value != .array) return error.AcpConfigInvalidEnv;
            for (env_value.array.items) |pair_value| {
                if (pair_value != .string) return error.AcpConfigInvalidEnv;
                if (std.mem.indexOfScalar(u8, pair_value.string, '=') == null) {
                    return error.AcpConfigInvalidEnv;
                }
                try env.append(alloc, try alloc.dupe(u8, pair_value.string));
            }
        }

        var models: std.ArrayList([]const u8) = .empty;
        var models_owned = false;
        errdefer if (!models_owned) models.deinit(alloc);
        if (object.get("models")) |models_value| {
            if (models_value != .array) return error.AcpConfigInvalidModels;
            for (models_value.array.items) |model_value| {
                if (model_value != .string) return error.AcpConfigInvalidModels;
                try models.append(alloc, try alloc.dupe(u8, model_value.string));
            }
        }

        var efforts: std.ArrayList([]const u8) = .empty;
        var efforts_owned = false;
        errdefer if (!efforts_owned) efforts.deinit(alloc);
        if (object.get("efforts")) |efforts_value| {
            if (efforts_value != .array) return error.AcpConfigInvalidModels;
            for (efforts_value.array.items) |effort_value| {
                if (effort_value != .string) return error.AcpConfigInvalidModels;
                try efforts.append(alloc, try alloc.dupe(u8, effort_value.string));
            }
        }

        const args_slice = try args.toOwnedSlice(alloc);
        args_owned = true;
        const env_slice = try env.toOwnedSlice(alloc);
        env_owned = true;
        const models_slice = try models.toOwnedSlice(alloc);
        models_owned = true;
        const efforts_slice = try efforts.toOwnedSlice(alloc);
        efforts_owned = true;

        var entry = AcpAgentConfig{
            .name = try alloc.dupe(u8, name_value.string),
            .command = try alloc.dupe(u8, command_value.string),
            .args = args_slice,
            .env = env_slice,
            .enabled = enabled,
            .models = models_slice,
            .efforts = efforts_slice,
        };
        var entry_moved = false;
        errdefer if (!entry_moved) entry.deinit(alloc);
        try configs.append(alloc, entry);
        entry_moved = true;
    }

    return configs;
}

pub fn saveConfigsToPath(alloc: Allocator, path: []const u8, configs: []const AcpAgentConfig) !void {
    const json = try renderConfigJson(alloc, configs);
    defer alloc.free(json);

    if (std.fs.path.dirname(path)) |parent| ensureDir(parent);
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), json);
}

pub fn renderConfigJson(alloc: Allocator, configs: []const AcpAgentConfig) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\n  \"agents\": [");
    for (configs, 0..) |config, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("\n    {\n      \"name\": ");
        try std.json.Stringify.value(config.name, .{}, &out.writer);
        try out.writer.writeAll(",\n      \"command\": ");
        try std.json.Stringify.value(config.command, .{}, &out.writer);
        try out.writer.writeAll(",\n      \"args\": [");
        for (config.args, 0..) |arg, j| {
            if (j > 0) try out.writer.writeAll(", ");
            try std.json.Stringify.value(arg, .{}, &out.writer);
        }
        try out.writer.writeAll("],\n      \"env\": [");
        for (config.env, 0..) |pair, j| {
            if (j > 0) try out.writer.writeAll(", ");
            try std.json.Stringify.value(pair, .{}, &out.writer);
        }
        try out.writer.writeAll("],\n      \"models\": [");
        for (config.models, 0..) |model, j| {
            if (j > 0) try out.writer.writeAll(", ");
            try std.json.Stringify.value(model, .{}, &out.writer);
        }
        try out.writer.writeAll("],\n      \"efforts\": [");
        for (config.efforts, 0..) |effort, j| {
            if (j > 0) try out.writer.writeAll(", ");
            try std.json.Stringify.value(effort, .{}, &out.writer);
        }
        try out.writer.writeAll("],\n      \"enabled\": ");
        try std.json.Stringify.value(config.enabled, .{}, &out.writer);
        try out.writer.writeAll("\n    }");
    }
    if (configs.len > 0) try out.writer.writeAll("\n  ");
    try out.writer.writeAll("]\n}\n");

    return out.toOwnedSlice();
}

pub fn addOrReplaceAgent(
    alloc: Allocator,
    path: []const u8,
    name: []const u8,
    command: []const u8,
    args: []const []const u8,
    env: []const []const u8,
) !void {
    if (command.len == 0) return error.AcpConfigInvalidCommand;
    if (!isValidAgentName(name)) return error.AcpConfigInvalidName;

    var configs = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &configs);

    var next = AcpAgentConfig{
        .name = try alloc.dupe(u8, name),
        .command = try alloc.dupe(u8, command),
        .args = try dupeStringSlice(alloc, args),
        .env = try dupeStringSlice(alloc, env),
        .enabled = true,
    };
    var moved = false;
    errdefer if (!moved) next.deinit(alloc);

    for (configs.items) |*existing| {
        if (!std.ascii.eqlIgnoreCase(existing.name, name)) continue;
        // Keep the cached model and effort lists across re-adds.
        next.models = existing.models;
        existing.models = &.{};
        next.efforts = existing.efforts;
        existing.efforts = &.{};
        existing.deinit(alloc);
        existing.* = next;
        moved = true;
        try saveConfigsToPath(alloc, path, configs.items);
        return;
    }

    try configs.append(alloc, next);
    moved = true;
    try saveConfigsToPath(alloc, path, configs.items);
}

/// Replaces the cached model and effort lists for `name`. No-op when the
/// agent is absent.
pub fn updateAgentModels(
    alloc: Allocator,
    path: []const u8,
    name: []const u8,
    models: []const []const u8,
    efforts: []const []const u8,
) !void {
    var configs = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &configs);

    for (configs.items) |*existing| {
        if (!std.mem.eql(u8, existing.name, name)) continue;
        const next_models = try dupeStringSlice(alloc, models);
        freeOwnedStrings(alloc, existing.models);
        existing.models = next_models;
        const next_efforts = try dupeStringSlice(alloc, efforts);
        freeOwnedStrings(alloc, existing.efforts);
        existing.efforts = next_efforts;
        try saveConfigsToPath(alloc, path, configs.items);
        return;
    }
}

pub fn removeAgentFromPath(alloc: Allocator, path: []const u8, name: []const u8) !bool {
    var configs = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &configs);

    for (configs.items, 0..) |config, i| {
        if (!std.ascii.eqlIgnoreCase(config.name, name)) continue;
        var mutable = configs.orderedRemove(i);
        mutable.deinit(alloc);
        try saveConfigsToPath(alloc, path, configs.items);
        return true;
    }
    return false;
}

fn dupeStringSlice(alloc: Allocator, strings: []const []const u8) ![]const []const u8 {
    const dupes = try alloc.alloc([]const u8, strings.len);
    errdefer alloc.free(dupes);
    for (strings, 0..) |string, i| {
        dupes[i] = try alloc.dupe(u8, string);
    }
    return dupes;
}

fn ensureDir(path: []const u8) void {
    std.Io.Dir.createDirAbsolute(io_mod.getIo(), path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            if (std.fs.path.dirname(path)) |parent| {
                ensureDir(parent);
                std.Io.Dir.createDirAbsolute(io_mod.getIo(), path, .default_dir) catch {};
            }
        },
    };
}

test "config round-trips save and load" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home_path);
    const config_path = try std.fs.path.join(alloc, &.{ home_path, "acp.json" });
    defer alloc.free(config_path);

    var configs = [_]AcpAgentConfig{
        .{
            .name = "claude-acp",
            .command = "/usr/local/bin/claude-agent-acp",
            .args = &.{ "--flag", "value" },
            .env = &.{"KEY=VALUE"},
            .enabled = true,
        },
        .{
            .name = "gemini",
            .command = "npx",
            .args = &.{ "-y", "@google/gemini-cli", "--acp" },
            .env = &.{},
            .enabled = false,
        },
    };
    try saveConfigsToPath(alloc, config_path, &configs);

    var loaded = try loadConfigFromPath(alloc, config_path);
    defer freeConfigs(alloc, &loaded);
    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
    try std.testing.expectEqualStrings("claude-acp", loaded.items[0].name);
    try std.testing.expectEqualStrings("/usr/local/bin/claude-agent-acp", loaded.items[0].command);
    try std.testing.expectEqual(@as(usize, 2), loaded.items[0].args.len);
    try std.testing.expectEqualStrings("--flag", loaded.items[0].args[0]);
    try std.testing.expectEqualStrings("value", loaded.items[0].args[1]);
    try std.testing.expectEqualStrings("KEY=VALUE", loaded.items[0].env[0]);
    try std.testing.expect(loaded.items[0].enabled);
    try std.testing.expect(!loaded.items[1].enabled);
}

test "addOrReplaceAgent replaces an existing entry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home_path);
    const config_path = try std.fs.path.join(alloc, &.{ home_path, "acp.json" });
    defer alloc.free(config_path);

    try addOrReplaceAgent(alloc, config_path, "claude-acp", "claude-agent-acp", &.{}, &.{});
    try addOrReplaceAgent(alloc, config_path, "claude-acp", "/new/path/claude", &.{"--acp"}, &.{});

    var loaded = try loadConfigFromPath(alloc, config_path);
    defer freeConfigs(alloc, &loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("/new/path/claude", loaded.items[0].command);
    try std.testing.expectEqual(@as(usize, 1), loaded.items[0].args.len);
}

test "removeAgentFromPath reports whether an entry was removed" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home_path);
    const config_path = try std.fs.path.join(alloc, &.{ home_path, "acp.json" });
    defer alloc.free(config_path);

    try addOrReplaceAgent(alloc, config_path, "gemini", "gemini", &.{"--acp"}, &.{});
    try std.testing.expect(try removeAgentFromPath(alloc, config_path, "gemini"));
    try std.testing.expect(!(try removeAgentFromPath(alloc, config_path, "gemini")));

    var loaded = try loadConfigFromPath(alloc, config_path);
    defer freeConfigs(alloc, &loaded);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
}

test "model cache round-trips and survives re-add" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home_path);
    const config_path = try std.fs.path.join(alloc, &.{ home_path, "acp.json" });
    defer alloc.free(config_path);

    try addOrReplaceAgent(alloc, config_path, "claude-acp", "claude-agent-acp", &.{}, &.{});
    try updateAgentModels(alloc, config_path, "claude-acp", &.{ "default", "opus[1m]" }, &.{ "low", "high" });

    var loaded = try loadConfigFromPath(alloc, config_path);
    defer freeConfigs(alloc, &loaded);
    try std.testing.expectEqual(@as(usize, 2), loaded.items[0].models.len);
    try std.testing.expectEqualStrings("opus[1m]", loaded.items[0].models[1]);

    // Re-adding the agent keeps the cached models.
    try addOrReplaceAgent(alloc, config_path, "claude-acp", "/new/claude", &.{}, &.{});
    var reloaded = try loadConfigFromPath(alloc, config_path);
    defer freeConfigs(alloc, &reloaded);
    try std.testing.expectEqual(@as(usize, 2), reloaded.items[0].models.len);

    // Unknown agents are a no-op.
    try updateAgentModels(alloc, config_path, "missing", &.{"x"}, &.{});
}

test "invalid config shapes produce specific errors" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(
        error.AcpConfigRootMustBeObject,
        loadConfigFromJson(alloc, "[]"),
    );
    try std.testing.expectError(
        error.AcpConfigAgentsMustBeArray,
        loadConfigFromJson(alloc, "{\"agents\":{}}"),
    );
    try std.testing.expectError(
        error.AcpConfigAgentMustBeObject,
        loadConfigFromJson(alloc, "{\"agents\":[\"nope\"]}"),
    );
    try std.testing.expectError(
        error.AcpConfigMissingName,
        loadConfigFromJson(alloc, "{\"agents\":[{\"command\":\"x\"}]}"),
    );
    try std.testing.expectError(
        error.AcpConfigMissingCommand,
        loadConfigFromJson(alloc, "{\"agents\":[{\"name\":\"x\"}]}"),
    );
    try std.testing.expectError(
        error.AcpConfigInvalidEnv,
        loadConfigFromJson(alloc, "{\"agents\":[{\"name\":\"x\",\"command\":\"c\",\"env\":[\"no-equals\"]}]}"),
    );
}

test "agent names are validated" {
    try std.testing.expect(isValidAgentName("claude-acp"));
    try std.testing.expect(isValidAgentName("my_agent.2"));
    try std.testing.expect(!isValidAgentName(""));
    try std.testing.expect(!isValidAgentName("has space"));
    try std.testing.expect(!isValidAgentName("bad/slash"));
}

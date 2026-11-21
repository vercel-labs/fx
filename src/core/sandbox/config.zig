//! The private sandbox config, `~/.fx/sandbox/config.json`, and the placement
//! it gives a shell command. The caller reads the file and passes its text and
//! the home folder. Parsing and deciding are pure: no I/O and no clock.
const std = @import("std");
const command_environment = @import("../execution/command_environment.zig");
const wildcard = @import("../shared/wildcard.zig");

/// Where a command runs. `profile` applies to `.isolated` only. Null means the
/// profile named `default`.
pub const Target = struct {
    placement: command_environment.Placement,
    profile: ?[]const u8 = null,
};

/// Set by a failed `parse`. The message names the field that failed, such as
/// `rules[2].placement: unknown placement "sandbox"`. Its text lives in the
/// arena that `parse` was given.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const ParseError = error{ InvalidSandboxConfig, OutOfMemory };

const Rule = struct {
    /// The command pattern with surrounding whitespace removed. `wildcard.match`
    /// compares it with the trimmed command.
    pattern: []const u8,
    target: Target,
};

const Workspace = struct {
    /// Absolute and normalized: no trailing slash, no `.` or empty segments.
    folder: []const u8,
    target: Target,
};

const Profile = struct {
    name: []const u8,
    args: []const []const u8,
};

pub const Config = struct {
    /// The provider program and its first arguments, with `~/` expanded. Null
    /// means the built-in provider.
    provider: ?[]const []const u8 = null,
    /// Passed to the provider before its subcommand.
    provider_args: []const []const u8 = &.{},
    /// How long fx waits after SIGTERM before SIGKILL for a provider run.
    grace_ms: u32 = default_grace_ms,
    /// Checked in order. The first rule that matches wins.
    rules: []const Rule = &.{},
    /// The default target for each folder. The longest folder that contains
    /// the workspace root wins.
    workspaces: []const Workspace = &.{},
    /// Variables passed to workspace runs.
    env: []const []const u8 = &.{},
    /// Extra provider arguments for isolated runs, by profile name.
    profiles: []const Profile = &.{},
};

const default_grace_ms: u32 = 5000;
const min_grace_ms: i64 = 1000;
const max_grace_ms: i64 = 60000;
const max_env_name_len = 64;
const max_profile_name_len = 40;
const known_keys = [_][]const u8{ "provider", "provider_args", "grace_ms", "rules", "workspaces", "env", "profiles" };

/// Parses the config text. On failure, `diagnostic` names the field that is
/// wrong and the error is `InvalidSandboxConfig`. `home` expands `~/`. The
/// strings in the result live in `arena`.
pub fn parse(
    arena: std.mem.Allocator,
    text: []const u8,
    home: []const u8,
    diagnostic: *Diagnostic,
) ParseError!Config {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(diagnostic, "config: not valid JSON"),
    };
    const object = switch (root) {
        .object => |fields| fields,
        else => return fail(diagnostic, "config: must be a JSON object"),
    };
    var keys = object.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!contains(&known_keys, key)) return failFmt(arena, diagnostic, "{s}: unknown key", .{key});
    }

    // Profiles come first, because a target must name a profile that is defined.
    const profiles: []const Profile = if (object.get("profiles")) |value|
        try parseProfiles(arena, diagnostic, value)
    else
        &.{};
    const provider: ?[]const []const u8 = if (object.get("provider")) |value|
        try parseProvider(arena, diagnostic, home, value)
    else
        null;
    const provider_args: []const []const u8 = if (object.get("provider_args")) |value|
        try stringArray(arena, diagnostic, value, "provider_args")
    else
        &.{};
    const grace_ms: u32 = if (object.get("grace_ms")) |value|
        try parseGraceMs(diagnostic, value)
    else
        default_grace_ms;
    const rules: []const Rule = if (object.get("rules")) |value|
        try parseRules(arena, diagnostic, profiles, value)
    else
        &.{};
    const workspaces: []const Workspace = if (object.get("workspaces")) |value|
        try parseWorkspaces(arena, diagnostic, home, profiles, value)
    else
        &.{};
    const env: []const []const u8 = if (object.get("env")) |value|
        try parseEnv(arena, diagnostic, value)
    else
        &.{};

    return .{
        .provider = provider,
        .provider_args = provider_args,
        .grace_ms = grace_ms,
        .rules = rules,
        .workspaces = workspaces,
        .env = env,
        .profiles = profiles,
    };
}

/// The target for `command` run in `workspace_root`. The default is the target
/// of the longest `workspaces` folder that contains the root, or `local`. When
/// that default is isolated, only rules that choose an isolated target apply,
/// so a rule never makes a command less isolated. Otherwise the first matching
/// rule wins. Leading and trailing whitespace in the command does not count.
pub fn decide(cfg: *const Config, workspace_root: []const u8, command: []const u8) Target {
    const default = defaultTarget(cfg.workspaces, workspace_root);
    const trimmed = std.mem.trim(u8, command, &std.ascii.whitespace);
    for (cfg.rules) |rule| {
        if (default.placement == .isolated and rule.target.placement != .isolated) continue;
        if (wildcard.match(rule.pattern, trimmed)) return rule.target;
    }
    return default;
}

fn defaultTarget(workspaces: []const Workspace, workspace_root: []const u8) Target {
    var best: ?Workspace = null;
    for (workspaces) |workspace| {
        if (!covers(workspace.folder, workspace_root)) continue;
        if (best) |current| {
            if (current.folder.len >= workspace.folder.len) continue;
        }
        best = workspace;
    }
    const fallback: Target = .{ .placement = .local };
    return if (best) |workspace| workspace.target else fallback;
}

/// True when `workspace_root` is `folder` or lies inside it. The folder is
/// normalized. The workspace root is expected to be an absolute path.
fn covers(folder: []const u8, workspace_root: []const u8) bool {
    if (std.mem.eql(u8, folder, "/")) return std.mem.startsWith(u8, workspace_root, "/");
    if (!std.mem.startsWith(u8, workspace_root, folder)) return false;
    return workspace_root.len == folder.len or workspace_root[folder.len] == '/';
}

fn parseProfiles(arena: std.mem.Allocator, diagnostic: *Diagnostic, value: std.json.Value) ParseError![]const Profile {
    const fields = switch (value) {
        .object => |map| map,
        else => return fail(diagnostic, "profiles: must be an object"),
    };
    const profiles = try arena.alloc(Profile, fields.count());
    var keys = fields.iterator();
    var index: usize = 0;
    while (keys.next()) |entry| : (index += 1) {
        const name = entry.key_ptr.*;
        const label = try arena.print("profiles[\"{s}\"]", .{name});
        if (!isProfileName(name)) {
            return failFmt(arena, diagnostic, "{s}: name must be 1 to 40 characters of a-z, 0-9, _, or -", .{label});
        }
        const args = try stringArray(arena, diagnostic, entry.value_ptr.*, label);
        profiles[index] = .{ .name = name, .args = args };
    }
    return profiles;
}

fn parseProvider(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    value: std.json.Value,
) ParseError![]const []const u8 {
    const argv = try stringArray(arena, diagnostic, value, "provider");
    if (argv.len == 0) return fail(diagnostic, "provider: must name a program");
    for (argv, 0..) |arg, index| {
        if (arg.len == 0) return failFmt(arena, diagnostic, "provider[{d}]: must not be empty", .{index});
    }
    argv[0] = try parseProgram(arena, diagnostic, home, argv[0]);
    return argv;
}

/// The provider program: an absolute path, a bare program name, or a `~/`
/// path that `home` expands. A name that contains `/` must be absolute.
fn parseProgram(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    text: []const u8,
) ParseError![]const u8 {
    const program = try expandHome(arena, diagnostic, home, text, "provider[0]");
    if (std.mem.endsWith(u8, program, "/")) return fail(diagnostic, "provider[0]: must name a program");
    if (std.mem.findScalar(u8, program, '/') != null and !std.mem.startsWith(u8, program, "/")) {
        return fail(diagnostic, "provider[0]: must be an absolute path or a bare program name");
    }
    return program;
}

fn parseGraceMs(diagnostic: *Diagnostic, value: std.json.Value) ParseError!u32 {
    const number: i64 = switch (value) {
        .integer => |int| int,
        else => return fail(diagnostic, "grace_ms: must be an integer"),
    };
    if (number < min_grace_ms or number > max_grace_ms) {
        return fail(diagnostic, "grace_ms: must be from 1000 to 60000");
    }
    return @intCast(number);
}

fn parseRules(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    profiles: []const Profile,
    value: std.json.Value,
) ParseError![]const Rule {
    const items = switch (value) {
        .array => |array| array.items,
        else => return fail(diagnostic, "rules: must be an array"),
    };
    const rules = try arena.alloc(Rule, items.len);
    for (items, 0..) |item, index| {
        const label = try arena.print("rules[{d}]", .{index});
        rules[index] = try parseRule(arena, diagnostic, profiles, item, label);
    }
    return rules;
}

fn parseRule(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    profiles: []const Profile,
    value: std.json.Value,
    label: []const u8,
) ParseError!Rule {
    const fields = switch (value) {
        .object => |map| map,
        else => return failFmt(arena, diagnostic, "{s}: must be an object", .{label}),
    };
    var keys = fields.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "command") and !std.mem.eql(u8, key, "placement")) {
            return failFmt(arena, diagnostic, "{s}.{s}: unknown key", .{ label, key });
        }
    }
    const command = try requiredString(arena, diagnostic, fields, label, "command");
    const pattern = std.mem.trim(u8, command, &std.ascii.whitespace);
    if (pattern.len == 0) return failFmt(arena, diagnostic, "{s}.command: must not be empty", .{label});
    const placement_text = try requiredString(arena, diagnostic, fields, label, "placement");
    const placement_label = try arena.print("{s}.placement", .{label});
    return .{
        .pattern = pattern,
        .target = try parseTarget(arena, diagnostic, profiles, placement_text, placement_label),
    };
}

fn parseWorkspaces(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    profiles: []const Profile,
    value: std.json.Value,
) ParseError![]const Workspace {
    const fields = switch (value) {
        .object => |map| map,
        else => return fail(diagnostic, "workspaces: must be an object"),
    };
    const workspaces = try arena.alloc(Workspace, fields.count());
    var folders: std.array_hash_map.String(void) = .empty;
    var keys = fields.iterator();
    var index: usize = 0;
    while (keys.next()) |entry| : (index += 1) {
        const raw = entry.key_ptr.*;
        const label = try arena.print("workspaces[\"{s}\"]", .{raw});
        const folder = try normalizeFolder(arena, diagnostic, home, raw, label);
        const slot = try folders.getOrPut(arena, folder);
        if (slot.found_existing) return failFmt(arena, diagnostic, "{s}: duplicate folder", .{label});
        const text = switch (entry.value_ptr.*) {
            .string => |string| string,
            else => return failFmt(arena, diagnostic, "{s}: must be a placement string", .{label}),
        };
        workspaces[index] = .{
            .folder = folder,
            .target = try parseTarget(arena, diagnostic, profiles, text, label),
        };
    }
    return workspaces;
}

/// An absolute, normalized folder. `~/` expands with `home`. Empty and `.`
/// segments are dropped, and a `..` segment is an error.
fn normalizeFolder(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    raw: []const u8,
    label: []const u8,
) ParseError![]const u8 {
    const expanded = try expandHome(arena, diagnostic, home, raw, label);
    if (!std.mem.startsWith(u8, expanded, "/")) {
        return failFmt(arena, diagnostic, "{s}: folder must be absolute or start with ~/", .{label});
    }
    var folder: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, expanded, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            return failFmt(arena, diagnostic, "{s}: folder must not contain .. segments", .{label});
        }
        try folder.append(arena, '/');
        try folder.appendSlice(arena, part);
    }
    if (folder.items.len == 0) return "/";
    return folder.items;
}

/// A placement string: `local`, `workspace`, `isolated`, or `isolated:<profile>`.
/// `isolated:default` means the default profile, which is null in the target.
fn parseTarget(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    profiles: []const Profile,
    text: []const u8,
    label: []const u8,
) ParseError!Target {
    if (std.mem.eql(u8, text, "local")) return .{ .placement = .local };
    if (std.mem.eql(u8, text, "workspace")) return .{ .placement = .workspace };
    if (std.mem.eql(u8, text, "isolated")) return .{ .placement = .isolated };
    const isolated_prefix = "isolated:";
    if (!std.mem.startsWith(u8, text, isolated_prefix)) {
        return failFmt(arena, diagnostic, "{s}: unknown placement \"{s}\"", .{ label, text });
    }
    const name = text[isolated_prefix.len..];
    if (!isProfileName(name)) {
        return failFmt(arena, diagnostic, "{s}: profile name \"{s}\" must be 1 to 40 characters of a-z, 0-9, _, or -", .{ label, name });
    }
    if (std.mem.eql(u8, name, "default")) return .{ .placement = .isolated };
    if (!hasProfile(profiles, name)) {
        return failFmt(arena, diagnostic, "{s}: profile \"{s}\" is not in profiles", .{ label, name });
    }
    return .{ .placement = .isolated, .profile = name };
}

fn hasProfile(profiles: []const Profile, name: []const u8) bool {
    for (profiles) |profile| {
        if (std.mem.eql(u8, profile.name, name)) return true;
    }
    return false;
}

fn parseEnv(arena: std.mem.Allocator, diagnostic: *Diagnostic, value: std.json.Value) ParseError![]const []const u8 {
    const names = try stringArray(arena, diagnostic, value, "env");
    var seen: std.array_hash_map.String(void) = .empty;
    for (names, 0..) |name, index| {
        if (name.len > max_env_name_len) {
            return failFmt(arena, diagnostic, "env[{d}]: longer than 64 characters", .{index});
        }
        if (!isEnvName(name)) {
            return failFmt(arena, diagnostic, "env[{d}]: \"{s}\" is not an environment variable name", .{ index, name });
        }
        const slot = try seen.getOrPut(arena, name);
        if (slot.found_existing) return failFmt(arena, diagnostic, "env[{d}]: duplicate \"{s}\"", .{ index, name });
    }
    return names;
}

/// A JSON array whose items are all strings. `label` names the array in messages.
fn stringArray(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    value: std.json.Value,
    label: []const u8,
) ParseError![][]const u8 {
    const items = switch (value) {
        .array => |array| array.items,
        else => return failFmt(arena, diagnostic, "{s}: must be an array of strings", .{label}),
    };
    const out = try arena.alloc([]const u8, items.len);
    for (items, 0..) |item, index| {
        out[index] = switch (item) {
            .string => |text| text,
            else => return failFmt(arena, diagnostic, "{s}[{d}]: must be a string", .{ label, index }),
        };
    }
    return out;
}

/// The string at `label.key`. A missing key or a non-string value is an error.
fn requiredString(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    fields: std.json.ObjectMap,
    label: []const u8,
    key: []const u8,
) ParseError![]const u8 {
    const value = fields.get(key) orelse return failFmt(arena, diagnostic, "{s}.{s}: required", .{ label, key });
    return switch (value) {
        .string => |text| text,
        else => return failFmt(arena, diagnostic, "{s}.{s}: must be a string", .{ label, key }),
    };
}

/// Expands a leading `~/` with `home`. Other text is returned unchanged.
fn expandHome(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    text: []const u8,
    label: []const u8,
) ParseError![]const u8 {
    if (!std.mem.startsWith(u8, text, "~/")) return text;
    if (home.len == 0) return failFmt(arena, diagnostic, "{s}: ~/ needs a home folder", .{label});
    return arena.print("{s}/{s}", .{ std.mem.trimEnd(u8, home, "/"), text[2..] });
}

fn isEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |byte, index| {
        const valid = switch (byte) {
            'A'...'Z', 'a'...'z', '_' => true,
            '0'...'9' => index > 0,
            else => false,
        };
        if (!valid) return false;
    }
    return true;
}

fn isProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_profile_name_len) return false;
    for (name) |byte| {
        const valid = switch (byte) {
            'a'...'z', '0'...'9', '_', '-' => true,
            else => false,
        };
        if (!valid) return false;
    }
    return true;
}

fn contains(list: []const []const u8, text: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, text)) return true;
    }
    return false;
}

fn fail(diagnostic: *Diagnostic, message: []const u8) ParseError {
    diagnostic.message = message;
    return error.InvalidSandboxConfig;
}

fn failFmt(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    comptime format: []const u8,
    args: anytype,
) ParseError {
    diagnostic.message = arena.print(format, args) catch return error.OutOfMemory;
    return error.InvalidSandboxConfig;
}

const home_folder = "/Users/example";

fn expectRejected(text: []const u8, home: []const u8, message: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidSandboxConfig, parse(arena_state.allocator(), text, home, &diagnostic));
    try std.testing.expectEqualStrings(message, diagnostic.message);
}

fn repeated(arena: std.mem.Allocator, byte: u8, count: usize) ![]u8 {
    const out = try arena.alloc(u8, count);
    @memset(out, byte);
    return out;
}

test "an empty config gives local for every command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(arena_state.allocator(), "{}", home_folder, &diagnostic);

    try std.testing.expectEqual(@as(?[]const []const u8, null), cfg.provider);
    try std.testing.expectEqual(@as(u32, 5000), cfg.grace_ms);
    try std.testing.expectEqual(@as(usize, 0), cfg.rules.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.workspaces.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.env.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.profiles.len);

    const roots = [_][]const u8{ "/Users/example/repo", "/", "" };
    const commands = [_][]const u8{ "zig build test", "rm -rf /", "" };
    for (roots) |root| {
        for (commands) |command| {
            const target = decide(&cfg, root, command);
            try std.testing.expectEqual(command_environment.Placement.local, target.placement);
            try std.testing.expectEqual(@as(?[]const u8, null), target.profile);
        }
    }
}

test "every schema error names the field it failed on" {
    const Case = struct {
        text: []const u8,
        home: []const u8 = home_folder,
        message: []const u8,
    };
    const cases = [_]Case{
        .{ .text = "not json", .message = "config: not valid JSON" },
        .{ .text = "[]", .message = "config: must be a JSON object" },
        .{ .text = "{\"grace\":1000}", .message = "grace: unknown key" },
        .{ .text = "{\"rules\":{}}", .message = "rules: must be an array" },
        .{ .text = "{\"rules\":[\"ls\"]}", .message = "rules[0]: must be an object" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"placement\":\"local\",\"shell\":\"x\"}]}", .message = "rules[0].shell: unknown key" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\"}]}", .message = "rules[0].placement: required" },
        .{ .text = "{\"rules\":[{\"placement\":\"local\"}]}", .message = "rules[0].command: required" },
        .{ .text = "{\"rules\":[{\"command\":1,\"placement\":\"local\"}]}", .message = "rules[0].command: must be a string" },
        .{ .text = "{\"rules\":[{\"command\":\"  \",\"placement\":\"local\"}]}", .message = "rules[0].command: must not be empty" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"placement\":\"local\"},{\"command\":\"ls\",\"placement\":\"local\"},{\"command\":\"ls\",\"placement\":\"sandbox\"}]}", .message = "rules[2].placement: unknown placement \"sandbox\"" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"placement\":\"isolated:media\"}]}", .message = "rules[0].placement: profile \"media\" is not in profiles" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"placement\":\"isolated:Media\"}]}", .message = "rules[0].placement: profile name \"Media\" must be 1 to 40 characters of a-z, 0-9, _, or -" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"placement\":\"isolated:\"}]}", .message = "rules[0].placement: profile name \"\" must be 1 to 40 characters of a-z, 0-9, _, or -" },
        .{ .text = "{\"grace_ms\":999}", .message = "grace_ms: must be from 1000 to 60000" },
        .{ .text = "{\"grace_ms\":60001}", .message = "grace_ms: must be from 1000 to 60000" },
        .{ .text = "{\"grace_ms\":1.5}", .message = "grace_ms: must be an integer" },
        .{ .text = "{\"grace_ms\":\"5000\"}", .message = "grace_ms: must be an integer" },
        .{ .text = "{\"provider\":\"sandbox\"}", .message = "provider: must be an array of strings" },
        .{ .text = "{\"provider\":[]}", .message = "provider: must name a program" },
        .{ .text = "{\"provider\":[1]}", .message = "provider[0]: must be a string" },
        .{ .text = "{\"provider\":[\"\"]}", .message = "provider[0]: must not be empty" },
        .{ .text = "{\"provider\":[\"/bin/x\",\"\"]}", .message = "provider[1]: must not be empty" },
        .{ .text = "{\"provider\":[\"bin/sandbox\"]}", .message = "provider[0]: must be an absolute path or a bare program name" },
        .{ .text = "{\"provider\":[\"/bin/sandbox/\"]}", .message = "provider[0]: must name a program" },
        .{ .text = "{\"provider\":[\"~/\"]}", .message = "provider[0]: must name a program" },
        .{ .text = "{\"provider\":[\"~/bin/sandbox\"]}", .home = "", .message = "provider[0]: ~/ needs a home folder" },
        .{ .text = "{\"provider_args\":\"--json\"}", .message = "provider_args: must be an array of strings" },
        .{ .text = "{\"env\":\"PATH\"}", .message = "env: must be an array of strings" },
        .{ .text = "{\"env\":[\"1X\"]}", .message = "env[0]: \"1X\" is not an environment variable name" },
        .{ .text = "{\"env\":[\"A-B\"]}", .message = "env[0]: \"A-B\" is not an environment variable name" },
        .{ .text = "{\"env\":[\"\"]}", .message = "env[0]: \"\" is not an environment variable name" },
        .{ .text = "{\"env\":[\"PATH\",\"PATH\"]}", .message = "env[1]: duplicate \"PATH\"" },
        .{ .text = "{\"workspaces\":[]}", .message = "workspaces: must be an object" },
        .{ .text = "{\"workspaces\":{\"repo\":\"workspace\"}}", .message = "workspaces[\"repo\"]: folder must be absolute or start with ~/" },
        .{ .text = "{\"workspaces\":{\"~/repo\":\"workspace\"}}", .home = "", .message = "workspaces[\"~/repo\"]: ~/ needs a home folder" },
        .{ .text = "{\"workspaces\":{\"/a/../b\":\"workspace\"}}", .message = "workspaces[\"/a/../b\"]: folder must not contain .. segments" },
        .{ .text = "{\"workspaces\":{\"/a\":\"workspace\",\"/a/\":\"local\"}}", .message = "workspaces[\"/a/\"]: duplicate folder" },
        .{ .text = "{\"workspaces\":{\"/a\":\"sandbox\"}}", .message = "workspaces[\"/a\"]: unknown placement \"sandbox\"" },
        .{ .text = "{\"workspaces\":{\"/a\":1}}", .message = "workspaces[\"/a\"]: must be a placement string" },
        .{ .text = "{\"profiles\":[]}", .message = "profiles: must be an object" },
        .{ .text = "{\"profiles\":{\"Media\":[]}}", .message = "profiles[\"Media\"]: name must be 1 to 40 characters of a-z, 0-9, _, or -" },
        .{ .text = "{\"profiles\":{\"media\":\"--gpu\"}}", .message = "profiles[\"media\"]: must be an array of strings" },
    };
    for (cases) |case| try expectRejected(case.text, case.home, case.message);
}

test "env names and profile names keep their length limits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const name_64 = try repeated(arena, 'A', 64);
    const env_ok = try arena.print("{{\"env\":[\"{s}\"]}}", .{name_64});
    const cfg = try parse(arena, env_ok, home_folder, &diagnostic);
    try std.testing.expectEqual(@as(usize, 64), cfg.env[0].len);

    const name_65 = try repeated(arena, 'A', 65);
    const env_long = try arena.print("{{\"env\":[\"{s}\"]}}", .{name_65});
    try expectRejected(env_long, home_folder, "env[0]: longer than 64 characters");

    const profile_40 = try repeated(arena, 'a', 40);
    const profile_ok = try arena.print("{{\"profiles\":{{\"{s}\":[]}}}}", .{profile_40});
    const profiles_cfg = try parse(arena, profile_ok, home_folder, &diagnostic);
    try std.testing.expectEqual(@as(usize, 40), profiles_cfg.profiles[0].name.len);

    const profile_41 = try repeated(arena, 'a', 41);
    const profile_long = try arena.print("{{\"profiles\":{{\"{s}\":[]}}}}", .{profile_41});
    const message = try arena.print(
        "profiles[\"{s}\"]: name must be 1 to 40 characters of a-z, 0-9, _, or -",
        .{profile_41},
    );
    try expectRejected(profile_long, home_folder, message);
}

test "provider, provider arguments, and grace period parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const cfg = try parse(
        arena,
        "{\"provider\":[\"~/bin/sandbox\",\"run\"],\"provider_args\":[\"--json\"],\"grace_ms\":2000,\"env\":[\"PATH\",\"CI_TOKEN_1\"],\"profiles\":{\"media\":[\"--gpu\"]}}",
        home_folder,
        &diagnostic,
    );
    const provider = cfg.provider.?;
    try std.testing.expectEqual(@as(usize, 2), provider.len);
    try std.testing.expectEqualStrings("/Users/example/bin/sandbox", provider[0]);
    try std.testing.expectEqualStrings("run", provider[1]);
    try std.testing.expectEqualStrings("--json", cfg.provider_args[0]);
    try std.testing.expectEqual(@as(u32, 2000), cfg.grace_ms);
    try std.testing.expectEqualStrings("CI_TOKEN_1", cfg.env[1]);
    try std.testing.expectEqualStrings("media", cfg.profiles[0].name);
    try std.testing.expectEqualStrings("--gpu", cfg.profiles[0].args[0]);

    const bare = try parse(arena, "{\"provider\":[\"sandbox-cli\"]}", home_folder, &diagnostic);
    try std.testing.expectEqualStrings("sandbox-cli", bare.provider.?[0]);
    const absolute = try parse(arena, "{\"provider\":[\"/usr/local/bin/sandbox\"]}", home_folder, &diagnostic);
    try std.testing.expectEqualStrings("/usr/local/bin/sandbox", absolute.provider.?[0]);
}

test "~/ expands in workspace folders and home may end with a slash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const cfg = try parse(
        arena,
        "{\"workspaces\":{\"~/repo/\":\"workspace\"}}",
        "/Users/example/",
        &diagnostic,
    );
    try std.testing.expectEqualStrings("/Users/example/repo", cfg.workspaces[0].folder);
    const target = decide(&cfg, "/Users/example/repo/app", "ls");
    try std.testing.expectEqual(command_environment.Placement.workspace, target.placement);
}

test "the longest workspaces folder that contains the root is the default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"workspaces\":{\"/Users/example/repo\":\"workspace\",\"/Users/example/repo/app\":\"isolated\"}}",
        home_folder,
        &diagnostic,
    );

    try std.testing.expectEqual(
        command_environment.Placement.isolated,
        decide(&cfg, "/Users/example/repo/app/src", "ls").placement,
    );
    try std.testing.expectEqual(
        command_environment.Placement.workspace,
        decide(&cfg, "/Users/example/repo/lib", "ls").placement,
    );
    try std.testing.expectEqual(
        command_environment.Placement.workspace,
        decide(&cfg, "/Users/example/repo", "ls").placement,
    );
    // `repository` shares a prefix with `repo` but is not inside it.
    try std.testing.expectEqual(
        command_environment.Placement.local,
        decide(&cfg, "/Users/example/repository", "ls").placement,
    );
}

test "the first matching rule wins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"rules\":[{\"command\":\"zig build*\",\"placement\":\"workspace\"},{\"command\":\"zig*\",\"placement\":\"isolated\"}]}",
        home_folder,
        &diagnostic,
    );

    try std.testing.expectEqual(
        command_environment.Placement.workspace,
        decide(&cfg, "/Users/example/repo", "zig build test").placement,
    );
    try std.testing.expectEqual(
        command_environment.Placement.isolated,
        decide(&cfg, "/Users/example/repo", "zig fmt src").placement,
    );
    try std.testing.expectEqual(
        command_environment.Placement.local,
        decide(&cfg, "/Users/example/repo", "git status").placement,
    );
}

test "an isolated default ignores local and workspace rules but takes an isolated rule" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"workspaces\":{\"/w/untrusted\":\"isolated\"}," ++
            "\"rules\":[" ++
            "{\"command\":\"ls*\",\"placement\":\"local\"}," ++
            "{\"command\":\"ls*\",\"placement\":\"workspace\"}," ++
            "{\"command\":\"make*\",\"placement\":\"isolated:x\"}," ++
            "{\"command\":\"make*\",\"placement\":\"local\"}]," ++
            "\"profiles\":{\"x\":[\"--x\"]}}",
        home_folder,
        &diagnostic,
    );

    const ls = decide(&cfg, "/w/untrusted/app", "ls -la");
    try std.testing.expectEqual(command_environment.Placement.isolated, ls.placement);
    try std.testing.expectEqual(@as(?[]const u8, null), ls.profile);

    const make = decide(&cfg, "/w/untrusted/app", "make all");
    try std.testing.expectEqual(command_environment.Placement.isolated, make.placement);
    try std.testing.expectEqualStrings("x", make.profile.?);

    const other = decide(&cfg, "/w/untrusted/app", "rm -rf build");
    try std.testing.expectEqual(command_environment.Placement.isolated, other.placement);
    try std.testing.expectEqual(@as(?[]const u8, null), other.profile);

    // A trusted root has no isolated default, so the first matching rule applies.
    const trusted = decide(&cfg, "/w/trusted", "ls -la");
    try std.testing.expectEqual(command_environment.Placement.local, trusted.placement);
}

test "rule patterns and commands are trimmed before matching" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"rules\":[{\"command\":\"  git status  \",\"placement\":\"workspace\"}," ++
            "{\"command\":\"npm test*\",\"placement\":\"isolated:default\"}]}",
        home_folder,
        &diagnostic,
    );

    try std.testing.expectEqual(
        command_environment.Placement.workspace,
        decide(&cfg, "/Users/example/repo", "\n\tgit status\t").placement,
    );
    const npm = decide(&cfg, "/Users/example/repo", "  npm test --watch ");
    try std.testing.expectEqual(command_environment.Placement.isolated, npm.placement);
    try std.testing.expectEqual(@as(?[]const u8, null), npm.profile);
    try std.testing.expectEqual(
        command_environment.Placement.local,
        decide(&cfg, "/Users/example/repo", "git status -s").placement,
    );
}

test "an isolated rule names its profile, and isolated:default is the default profile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"profiles\":{\"media\":[]},\"rules\":[" ++
            "{\"command\":\"convert *\",\"placement\":\"isolated:media\"}," ++
            "{\"command\":\"ls\",\"placement\":\"isolated:default\"}]}",
        home_folder,
        &diagnostic,
    );

    const convert = decide(&cfg, "/Users/example/repo", "convert a.png b.jpg");
    try std.testing.expectEqual(command_environment.Placement.isolated, convert.placement);
    try std.testing.expectEqualStrings("media", convert.profile.?);

    const ls = decide(&cfg, "/Users/example/repo", "ls");
    try std.testing.expectEqual(command_environment.Placement.isolated, ls.placement);
    try std.testing.expectEqual(@as(?[]const u8, null), ls.profile);
}

//! The sandbox settings in `$FX_HOME/sandbox/config.json`. fx reads this
//! file only when `experimental.sandbox_execution` is on. It lives in the
//! user's own folder, so no repository can set it. Parsing is pure.
const std = @import("std");
const placement = @import("../execution/placement.zig");

pub const default_api_url = "https://api.vercel.com";

pub const WorkspaceDefault = struct {
    /// An absolute folder. A workspace at or below it uses `decision` as its default.
    path: []const u8,
    decision: placement.Decision,
};

/// Where a sandbox's files start from. `default` is the API's default image.
pub const Source = union(enum) {
    default,
    image: []const u8,
    snapshot: []const u8,
    /// A setup script in this user's own folder. fx builds a snapshot from it.
    recipe: []const u8,
};

pub const Network = union(enum) {
    deny_all,
    allow_all,
    /// Only these domains, such as `registry.npmjs.org` or `*.example.com`.
    allow: []const []const u8,
};

/// The kept sandbox for a repository: synced from this machine, with named keys.
pub const WorkspaceProfile = struct {
    source: Source = .default,
    /// A script run once after the source is ready, for example a full build that fills caches.
    warm: ?[]const u8 = null,
    /// Keep the sandbox when it stops, so the next session resumes it.
    keep: bool = true,
    /// Names of environment variables whose values fx sends with each command.
    env: []const []const u8 = &.{},
    vcpus: ?u32 = null,
    timeout_minutes: u32 = 30,
};

/// A fresh sandbox per command. It gets no keys: this type has no `env` on purpose.
pub const IsolatedProfile = struct {
    name: []const u8,
    source: Source = .default,
    network: Network = .deny_all,
    vcpus: ?u32 = null,
    timeout_minutes: u32 = 10,
};

pub const Config = struct {
    /// The Vercel team slug.
    team: []const u8,
    /// The Vercel project name or ID that owns the sandboxes.
    project: []const u8,
    api_url: []const u8 = default_api_url,
    /// Prefix for every path in the sandbox. Empty means the sandbox uses
    /// the same absolute paths as this machine.
    remote_root: []const u8 = "",
    default: placement.Decision = .{},
    rules: []const placement.Rule = &.{},
    workspaces: []const WorkspaceDefault = &.{},
    workspace: WorkspaceProfile = .{},
    isolated: []const IsolatedProfile = &.{},
};

/// Says what is wrong when `parse` fails.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const ParseError = error{ InvalidSandboxConfig, OutOfMemory };

const known_keys = [_][]const u8{
    "team",
    "project",
    "api_url",
    "remote_root",
    "default",
    "rules",
    "workspaces",
    "workspace",
    "isolated",
};

const workspace_keys = [_][]const u8{
    "snapshot",
    "image",
    "recipe",
    "warm",
    "keep",
    "env",
    "vcpus",
    "timeout_minutes",
};

const isolated_keys = [_][]const u8{
    "snapshot",
    "image",
    "recipe",
    "network",
    "vcpus",
    "timeout_minutes",
};

/// Parses the bytes of a sandbox config file. `home` expands a leading `~/`
/// in workspace paths. The result may borrow from `bytes` and `arena`, so
/// keep both alive while the config is used. On failure, `diagnostic` names
/// the bad field.
pub fn parse(
    arena: std.mem.Allocator,
    bytes: []const u8,
    home: []const u8,
    diagnostic: *Diagnostic,
) ParseError!Config {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(diagnostic, "sandbox config is not valid JSON"),
    };
    const object = switch (root) {
        .object => |map| map,
        else => return fail(diagnostic, "sandbox config must be a JSON object"),
    };

    var keys = object.iterator();
    while (keys.next()) |entry| {
        if (!isKnownKey(entry.key_ptr.*)) {
            return failFmt(arena, diagnostic, "unknown key \"{s}\" in sandbox config", .{entry.key_ptr.*});
        }
    }
    for ([_][]const u8{ "workspace", "isolated" }) |name| {
        if (object.get(name)) |value| switch (value) {
            .object => {},
            else => return failFmt(arena, diagnostic, "{s} must be an object", .{name}),
        };
    }

    const team = try requiredText(arena, diagnostic, object, "team");
    const project = try requiredText(arena, diagnostic, object, "project");
    const api_url = try parseApiUrl(arena, diagnostic, object);
    const remote_root = try parseRemoteRoot(arena, diagnostic, object);
    const default = try parseDefault(arena, diagnostic, object);
    const rules: []const placement.Rule = if (object.get("rules")) |value|
        try parseRules(arena, diagnostic, value)
    else
        &.{};
    const workspaces: []const WorkspaceDefault = if (object.get("workspaces")) |value|
        try parseWorkspaces(arena, diagnostic, home, value)
    else
        &.{};
    const workspace: WorkspaceProfile = if (object.get("workspace")) |value|
        try parseWorkspaceProfile(arena, diagnostic, home, value)
    else
        .{};
    const isolated: []const IsolatedProfile = if (object.get("isolated")) |value|
        try parseIsolated(arena, diagnostic, home, value)
    else
        &.{};

    const config: Config = .{
        .team = team,
        .project = project,
        .api_url = api_url,
        .remote_root = remote_root,
        .default = default,
        .rules = rules,
        .workspaces = workspaces,
        .workspace = workspace,
        .isolated = isolated,
    };
    try checkProfileReferences(arena, diagnostic, config);
    return config;
}

/// The policy for `workspace_root`. The longest matching `workspaces` entry
/// wins. An untrusted workspace stays isolated: only rules that also choose
/// an isolated profile apply there, so no rule moves its commands to this
/// machine or to the kept sandbox.
pub fn policyFor(
    config: Config,
    arena: std.mem.Allocator,
    workspace_root: []const u8,
) error{OutOfMemory}!placement.Policy {
    var found: ?WorkspaceDefault = null;
    for (config.workspaces) |entry| {
        if (!covers(entry.path, workspace_root)) continue;
        if (found == null or entry.path.len > found.?.path.len) found = entry;
    }
    const entry = found orelse return .{ .default = config.default, .rules = config.rules };
    if (entry.decision.placement != .isolated) {
        return .{ .default = entry.decision, .rules = config.rules };
    }

    var kept: usize = 0;
    for (config.rules) |rule| {
        if (rule.decision.placement == .isolated) kept += 1;
    }
    const rules = try arena.alloc(placement.Rule, kept);
    var index: usize = 0;
    for (config.rules) |rule| {
        if (rule.decision.placement != .isolated) continue;
        rules[index] = rule;
        index += 1;
    }
    return .{ .default = entry.decision, .rules = rules };
}

/// The isolated profile named `name`. A null name means `default`. When the
/// config does not define `default`, the built-in one has no network and
/// the API's default image.
pub fn isolatedProfile(config: Config, name: ?[]const u8) ?IsolatedProfile {
    const wanted: []const u8 = name orelse "default";
    for (config.isolated) |profile| {
        if (std.mem.eql(u8, profile.name, wanted)) return profile;
    }
    if (std.mem.eql(u8, wanted, "default")) return .{ .name = "default" };
    return null;
}

fn isKnownKey(key: []const u8) bool {
    for (known_keys) |known| {
        if (std.mem.eql(u8, key, known)) return true;
    }
    return false;
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

fn checkKeys(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    map: std.json.ObjectMap,
    allowed: []const []const u8,
    label: []const u8,
) ParseError!void {
    var keys = map.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!contains(allowed, key)) {
            return failFmt(arena, diagnostic, "{s} has unknown key \"{s}\"", .{ label, key });
        }
    }
}

fn optionalString(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    map: std.json.ObjectMap,
    name: []const u8,
) ParseError!?[]const u8 {
    const value = map.get(name) orelse return null;
    switch (value) {
        .string => |text| return text,
        else => return failFmt(arena, diagnostic, "{s} must be a string", .{name}),
    }
}

fn requiredText(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    map: std.json.ObjectMap,
    name: []const u8,
) ParseError![]const u8 {
    const text = (try optionalString(arena, diagnostic, map, name)) orelse
        return failFmt(arena, diagnostic, "{s} is required", .{name});
    if (text.len == 0) return failFmt(arena, diagnostic, "{s} is required", .{name});
    return text;
}

fn parseApiUrl(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    map: std.json.ObjectMap,
) ParseError![]const u8 {
    const url = (try optionalString(arena, diagnostic, map, "api_url")) orelse return default_api_url;
    if (!isAllowedApiUrl(url)) return fail(diagnostic, "api_url must be an https URL");
    return trimOneTrailingSlash(url);
}

fn isAllowedApiUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://127.0.0.1:") or
        std.mem.startsWith(u8, url, "http://localhost:");
}

fn parseRemoteRoot(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    map: std.json.ObjectMap,
) ParseError![]const u8 {
    const remote = (try optionalString(arena, diagnostic, map, "remote_root")) orelse return "";
    if (remote.len == 0) return remote;
    if (remote[0] != '/' or remote[remote.len - 1] == '/') {
        return fail(diagnostic, "remote_root must be empty or an absolute path without a trailing slash");
    }
    return remote;
}

fn parseDefault(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    map: std.json.ObjectMap,
) ParseError!placement.Decision {
    const text = (try optionalString(arena, diagnostic, map, "default")) orelse return .{};
    const decision = parseDecision(text) orelse return failFmt(
        arena,
        diagnostic,
        "default: \"{s}\" is not local, workspace, isolated, or isolated:<profile>",
        .{text},
    );
    return decision;
}

fn parseRules(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    value: std.json.Value,
) ParseError![]const placement.Rule {
    const items = switch (value) {
        .array => |array| array.items,
        else => return fail(diagnostic, "rules must be an array"),
    };
    const rules = try arena.alloc(placement.Rule, items.len);
    for (items, 0..) |item, index| {
        rules[index] = try parseRule(arena, diagnostic, item, index);
    }
    return rules;
}

fn parseRule(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    value: std.json.Value,
    index: usize,
) ParseError!placement.Rule {
    const map = switch (value) {
        .object => |fields| fields,
        else => return failFmt(arena, diagnostic, "rules[{d}] must be an object", .{index}),
    };

    var keys = map.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "command") and !std.mem.eql(u8, key, "placement")) {
            return failFmt(arena, diagnostic, "rules[{d}] has unknown key \"{s}\"", .{ index, key });
        }
    }

    const command_value = map.get("command") orelse
        return failFmt(arena, diagnostic, "rules[{d}].command is required", .{index});
    const command = switch (command_value) {
        .string => |text| text,
        else => return failFmt(arena, diagnostic, "rules[{d}].command must be a string", .{index}),
    };
    if (command.len == 0) return failFmt(arena, diagnostic, "rules[{d}].command is required", .{index});

    const placement_value = map.get("placement") orelse
        return failFmt(arena, diagnostic, "rules[{d}].placement is required", .{index});
    const text = switch (placement_value) {
        .string => |string| string,
        else => return failFmt(arena, diagnostic, "rules[{d}].placement must be a string", .{index}),
    };
    const decision = parseDecision(text) orelse return failFmt(
        arena,
        diagnostic,
        "rules[{d}].placement: \"{s}\" is not local, workspace, isolated, or isolated:<profile>",
        .{ index, text },
    );
    return .{ .pattern = command, .decision = decision };
}

fn parseWorkspaces(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    value: std.json.Value,
) ParseError![]const WorkspaceDefault {
    const map = switch (value) {
        .object => |fields| fields,
        else => return fail(diagnostic, "workspaces must be an object"),
    };

    const entries = try arena.alloc(WorkspaceDefault, map.count());
    var index: usize = 0;
    var keys = map.iterator();
    while (keys.next()) |entry| : (index += 1) {
        const key = entry.key_ptr.*;
        const text = switch (entry.value_ptr.*) {
            .string => |string| string,
            else => return failFmt(arena, diagnostic, "workspaces[\"{s}\"] must be a string", .{key}),
        };
        const expanded = if (std.mem.startsWith(u8, key, "~/"))
            try arena.print("{s}/{s}", .{ home, key[2..] })
        else
            key;
        if (!std.mem.startsWith(u8, expanded, "/")) {
            return failFmt(arena, diagnostic, "workspaces[\"{s}\"]: path must be absolute", .{key});
        }
        const decision = parseDecision(text) orelse return failFmt(
            arena,
            diagnostic,
            "workspaces[\"{s}\"]: \"{s}\" is not local, workspace, isolated, or isolated:<profile>",
            .{ key, text },
        );
        entries[index] = .{ .path = trimOneTrailingSlash(expanded), .decision = decision };
    }
    return entries;
}

fn parseWorkspaceProfile(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    value: std.json.Value,
) ParseError!WorkspaceProfile {
    const map = switch (value) {
        .object => |fields| fields,
        else => return fail(diagnostic, "workspace must be an object"),
    };
    try checkKeys(arena, diagnostic, map, &workspace_keys, "workspace");

    var profile: WorkspaceProfile = .{};
    profile.source = try parseSource(arena, diagnostic, home, map, "workspace");
    profile.warm = try optionalPath(arena, diagnostic, home, map, "workspace", "warm");
    if (map.get("keep")) |setting| switch (setting) {
        .bool => |flag| profile.keep = flag,
        else => return failFmt(arena, diagnostic, "workspace.keep must be true or false", .{}),
    };
    profile.env = try parseEnv(arena, diagnostic, map);
    if (map.get("vcpus")) |setting| {
        profile.vcpus = try parseVcpus(arena, diagnostic, setting, "workspace");
    }
    if (map.get("timeout_minutes")) |setting| {
        profile.timeout_minutes = try parseBoundedInt(arena, diagnostic, setting, "workspace", "timeout_minutes", 1, 300);
    }
    return profile;
}

/// Reads the one source a profile may name, or none for the API default.
fn parseSource(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    map: std.json.ObjectMap,
    label: []const u8,
) ParseError!Source {
    const snapshot = try optionalNonEmpty(arena, diagnostic, map, label, "snapshot");
    const image = try optionalNonEmpty(arena, diagnostic, map, label, "image");
    const recipe = try optionalNonEmpty(arena, diagnostic, map, label, "recipe");
    var given: usize = 0;
    if (snapshot != null) given += 1;
    if (image != null) given += 1;
    if (recipe != null) given += 1;
    if (given > 1) {
        return failFmt(arena, diagnostic, "{s}: use only one of snapshot, image, or recipe", .{label});
    }
    if (snapshot) |id| return .{ .snapshot = id };
    if (image) |id| return .{ .image = id };
    if (recipe) |path| return .{ .recipe = try absolutePath(arena, diagnostic, home, path, label, "recipe") };
    return .default;
}

fn optionalNonEmpty(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    map: std.json.ObjectMap,
    label: []const u8,
    key: []const u8,
) ParseError!?[]const u8 {
    const value = map.get(key) orelse return null;
    const text = switch (value) {
        .string => |string| string,
        else => "",
    };
    if (text.len == 0) return failFmt(arena, diagnostic, "{s}.{s} must be a non-empty string", .{ label, key });
    return text;
}

fn optionalPath(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    map: std.json.ObjectMap,
    label: []const u8,
    key: []const u8,
) ParseError!?[]const u8 {
    const value = map.get(key) orelse return null;
    const text = switch (value) {
        .string => |string| string,
        else => "",
    };
    return try absolutePath(arena, diagnostic, home, text, label, key);
}

/// Expands a leading `~/` with `home`, then requires an absolute path.
fn absolutePath(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    text: []const u8,
    label: []const u8,
    key: []const u8,
) ParseError![]const u8 {
    const expanded = try expandHome(arena, home, text);
    if (!std.mem.startsWith(u8, expanded, "/")) {
        return failFmt(arena, diagnostic, "{s}.{s} must be an absolute path", .{ label, key });
    }
    return expanded;
}

fn expandHome(arena: std.mem.Allocator, home: []const u8, text: []const u8) ParseError![]const u8 {
    if (!std.mem.startsWith(u8, text, "~/")) return text;
    return arena.print("{s}/{s}", .{ home, text[2..] });
}

fn parseEnv(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    map: std.json.ObjectMap,
) ParseError![]const []const u8 {
    const value = map.get("env") orelse return &.{};
    const items = switch (value) {
        .array => |array| array.items,
        else => return fail(diagnostic, "workspace.env must be an array"),
    };
    const names = try arena.alloc([]const u8, items.len);
    for (items, 0..) |item, index| {
        const name = switch (item) {
            .string => |string| string,
            else => "",
        };
        if (!isEnvName(name)) {
            return failFmt(arena, diagnostic, "workspace.env[{d}]: \"{s}\" is not an environment variable name", .{ index, name });
        }
        names[index] = name;
    }
    return names;
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

/// A JSON integer from `min` to `max`. `label` and `key` name the field in messages.
fn parseBoundedInt(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    value: std.json.Value,
    label: []const u8,
    key: []const u8,
    min: i64,
    max: i64,
) ParseError!u32 {
    const number = switch (value) {
        .integer => |integer| integer,
        else => return failFmt(arena, diagnostic, "{s}.{s} must be {d} to {d}", .{ label, key, min, max }),
    };
    if (number < min or number > max) {
        return failFmt(arena, diagnostic, "{s}.{s} must be {d} to {d}", .{ label, key, min, max });
    }
    return @intCast(number);
}

/// The Sandbox API takes 1 vCPU or an even count up to 32.
fn parseVcpus(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    value: std.json.Value,
    label: []const u8,
) ParseError!u32 {
    const count = switch (value) {
        .integer => |integer| integer,
        else => return failFmt(arena, diagnostic, "{s}.vcpus must be 1 or an even number up to 32", .{label}),
    };
    if (count < 1 or count > 32 or (count > 1 and @rem(count, 2) != 0)) {
        return failFmt(arena, diagnostic, "{s}.vcpus must be 1 or an even number up to 32", .{label});
    }
    return @intCast(count);
}

fn parseIsolated(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    value: std.json.Value,
) ParseError![]const IsolatedProfile {
    const map = switch (value) {
        .object => |fields| fields,
        else => return fail(diagnostic, "isolated must be an object"),
    };
    const profiles = try arena.alloc(IsolatedProfile, map.count());
    var index: usize = 0;
    var keys = map.iterator();
    while (keys.next()) |entry| : (index += 1) {
        profiles[index] = try parseIsolatedProfile(arena, diagnostic, home, entry.key_ptr.*, entry.value_ptr.*);
    }
    return profiles;
}

fn parseIsolatedProfile(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    name: []const u8,
    value: std.json.Value,
) ParseError!IsolatedProfile {
    if (!isProfileName(name)) {
        return failFmt(arena, diagnostic, "isolated[\"{s}\"]: profile names use a-z, 0-9, _ and -", .{name});
    }
    const label = try arena.print("isolated.{s}", .{name});
    const map = switch (value) {
        .object => |fields| fields,
        else => return failFmt(arena, diagnostic, "isolated[\"{s}\"] must be an object", .{name}),
    };
    if (map.get("env") != null) {
        return failFmt(arena, diagnostic, "{s}: an isolated profile gets no keys, so env is not allowed", .{label});
    }
    try checkKeys(arena, diagnostic, map, &isolated_keys, label);

    var profile: IsolatedProfile = .{ .name = name };
    profile.source = try parseSource(arena, diagnostic, home, map, label);
    if (map.get("network")) |setting| {
        profile.network = try parseNetwork(arena, diagnostic, label, setting);
    }
    if (map.get("vcpus")) |setting| {
        profile.vcpus = try parseVcpus(arena, diagnostic, setting, label);
    }
    if (map.get("timeout_minutes")) |setting| {
        profile.timeout_minutes = try parseBoundedInt(arena, diagnostic, setting, label, "timeout_minutes", 1, 300);
    }
    return profile;
}

fn parseNetwork(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    label: []const u8,
    value: std.json.Value,
) ParseError!Network {
    switch (value) {
        .string => |text| {
            if (std.mem.eql(u8, text, "deny")) return .deny_all;
            if (std.mem.eql(u8, text, "all")) return .allow_all;
        },
        .array => |array| {
            if (array.items.len == 0) return .deny_all;
            const domains = try arena.alloc([]const u8, array.items.len);
            for (array.items, 0..) |item, index| {
                const domain = switch (item) {
                    .string => |string| string,
                    else => "",
                };
                if (!isDomain(domain)) {
                    return failFmt(arena, diagnostic, "{s}.network[{d}]: \"{s}\" is not a domain", .{ label, index, domain });
                }
                domains[index] = domain;
            }
            return .{ .allow = domains };
        },
        else => {},
    }
    return failFmt(arena, diagnostic, "{s}.network must be \"deny\", \"all\", or a list of domains", .{label});
}

/// A domain such as `example.com` or `*.example.com`. No scheme, path, or port.
fn isDomain(text: []const u8) bool {
    const body = if (std.mem.startsWith(u8, text, "*.")) text[2..] else text;
    if (body.len == 0) return false;
    for (body) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Every isolated profile that a decision names must exist. `default` is
/// always defined, built in or not.
fn checkProfileReferences(arena: std.mem.Allocator, diagnostic: *Diagnostic, config: Config) ParseError!void {
    if (config.default.profile) |name| {
        if (!isDefinedProfile(config, name)) {
            return failFmt(arena, diagnostic, "default names isolated profile \"{s}\", which is not defined", .{name});
        }
    }
    for (config.rules, 0..) |rule, index| {
        if (rule.decision.profile) |name| {
            if (!isDefinedProfile(config, name)) {
                return failFmt(arena, diagnostic, "rules[{d}] names isolated profile \"{s}\", which is not defined", .{ index, name });
            }
        }
    }
    for (config.workspaces) |entry| {
        if (entry.decision.profile) |name| {
            if (!isDefinedProfile(config, name)) {
                return failFmt(arena, diagnostic, "workspaces[\"{s}\"] names isolated profile \"{s}\", which is not defined", .{ entry.path, name });
            }
        }
    }
}

fn isDefinedProfile(config: Config, name: []const u8) bool {
    if (std.mem.eql(u8, name, "default")) return true;
    for (config.isolated) |profile| {
        if (std.mem.eql(u8, profile.name, name)) return true;
    }
    return false;
}

/// Reads `local`, `workspace`, `isolated`, or `isolated:<profile>`.
fn parseDecision(text: []const u8) ?placement.Decision {
    if (std.mem.eql(u8, text, "local")) return .{ .placement = .local };
    if (std.mem.eql(u8, text, "workspace")) return .{ .placement = .workspace };
    if (std.mem.eql(u8, text, "isolated")) return .{ .placement = .isolated };
    const profile_prefix = "isolated:";
    if (!std.mem.startsWith(u8, text, profile_prefix)) return null;
    const profile = text[profile_prefix.len..];
    if (!isProfileName(profile)) return null;
    return .{ .placement = .isolated, .profile = profile };
}

fn isProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |byte| {
        switch (byte) {
            'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Drops one trailing `/`, except from the root path `/`.
fn trimOneTrailingSlash(text: []const u8) []const u8 {
    if (text.len > 1 and text[text.len - 1] == '/') return text[0 .. text.len - 1];
    return text;
}

fn covers(path: []const u8, workspace_root: []const u8) bool {
    if (std.mem.eql(u8, path, "/")) return true;
    if (std.mem.eql(u8, path, workspace_root)) return true;
    if (!std.mem.startsWith(u8, workspace_root, path)) return false;
    return workspace_root.len > path.len and workspace_root[path.len] == '/';
}

const untrusted_config =
    \\{"team":"t","project":"p","api_url":"http://127.0.0.1:4000/","remote_root":"/tmp/fake",
    \\ "default":"workspace",
    \\ "rules":[{"command":"zig build*","placement":"workspace"},
    \\          {"command":"convert *","placement":"isolated:media"}],
    \\ "workspaces":{"~/code/untrusted/":"isolated"},
    \\ "isolated":{"media":{}}}
;

const workspace_config =
    \\{"team":"t","project":"p",
    \\ "workspace":{"snapshot":"snap_1","warm":"~/warm.sh","keep":false,
    \\   "env":["AI_GATEWAY_TEST_API_KEY","GITHUB_TOKEN"],"vcpus":8,"timeout_minutes":45}}
;

const isolated_config =
    \\{"team":"t","project":"p",
    \\ "isolated":{
    \\   "media":{"recipe":"~/r/media.sh","network":[]},
    \\   "npm":{"network":["registry.npmjs.org","*.npmjs.com"]},
    \\   "open":{"image":"node24","network":"all"}}}
;

test "a minimal sandbox config uses local for everything" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const config = try parse(arena, "{\"team\":\"t\",\"project\":\"p\"}", "/home/me", &diagnostic);
    try std.testing.expectEqualStrings(default_api_url, config.api_url);
    try std.testing.expectEqualStrings("", config.remote_root);
    const policy = try policyFor(config, arena, "/repo");
    try std.testing.expectEqual(placement.Placement.local, placement.decide(policy, "zig build").placement);
}

test "sandbox config reads rules, defaults, and workspaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const config = try parse(arena, untrusted_config, "/home/me", &diagnostic);
    try std.testing.expectEqualStrings("http://127.0.0.1:4000", config.api_url);
    try std.testing.expectEqualStrings("/tmp/fake", config.remote_root);
    try std.testing.expectEqual(placement.Placement.workspace, config.default.placement);
    try std.testing.expectEqualStrings("/home/me/code/untrusted", config.workspaces[0].path);
    try std.testing.expectEqual(placement.Placement.isolated, config.workspaces[0].decision.placement);
    try std.testing.expectEqualStrings("media", config.rules[1].decision.profile.?);
}

test "an untrusted workspace keeps only isolated rules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const config = try parse(arena, untrusted_config, "/home/me", &diagnostic);
    const inside = try policyFor(config, arena, "/home/me/code/untrusted/app");
    const build = placement.decide(inside, "zig build test");
    try std.testing.expectEqual(placement.Placement.isolated, build.placement);
    try std.testing.expectEqual(@as(?[]const u8, null), build.profile);
    const convert = placement.decide(inside, "convert a b");
    try std.testing.expectEqual(placement.Placement.isolated, convert.placement);
    try std.testing.expectEqualStrings("media", convert.profile.?);

    const other = try policyFor(config, arena, "/home/me/code/other");
    try std.testing.expectEqual(
        placement.Placement.workspace,
        placement.decide(other, "zig build test").placement,
    );
}

test "the longest workspaces entry wins" {
    const text = "{\"team\":\"t\",\"project\":\"p\",\"default\":\"workspace\",\"workspaces\":{\"/a\":\"isolated\",\"/a/b\":\"local\"}}";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const config = try parse(arena, text, "/home/me", &diagnostic);
    const deep = try policyFor(config, arena, "/a/b/c");
    try std.testing.expectEqual(placement.Placement.local, deep.default.placement);
    const shallow = try policyFor(config, arena, "/a/x");
    try std.testing.expectEqual(placement.Placement.isolated, shallow.default.placement);
    const sibling = try policyFor(config, arena, "/ab");
    try std.testing.expectEqual(placement.Placement.workspace, sibling.default.placement);
}

test "bad sandbox configs name the bad field" {
    const cases = [_]struct { bytes: []const u8, message: []const u8 }{
        .{ .bytes = "not json", .message = "not valid JSON" },
        .{ .bytes = "{\"project\":\"p\"}", .message = "team is required" },
        .{ .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolate\":{}}", .message = "unknown key \"isolate\"" },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"rules\":[{\"command\":\"x\",\"placement\":\"isolate\"}]}",
            .message = "rules[0].placement",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"rules\":[{\"command\":\"x\",\"run\":\"local\"}]}",
            .message = "rules[0] has unknown key \"run\"",
        },
        .{ .bytes = "{\"team\":\"t\",\"project\":\"p\",\"default\":\"isolated:Bad Name\"}", .message = "default:" },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"api_url\":\"http://example.com\"}",
            .message = "api_url must be an https URL",
        },
        .{ .bytes = "{\"team\":\"t\",\"project\":\"p\",\"remote_root\":\"/tmp/x/\"}", .message = "remote_root must be" },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspaces\":{\"relative\":\"local\"}}",
            .message = "path must be absolute",
        },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(
            error.InvalidSandboxConfig,
            parse(arena_state.allocator(), case.bytes, "/home/me", &diagnostic),
        );
        try std.testing.expect(std.mem.find(u8, diagnostic.message, case.message) != null);
    }
}

test "sandbox config reads the workspace profile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const config = try parse(arena, workspace_config, "/home/me", &diagnostic);
    switch (config.workspace.source) {
        .snapshot => |id| try std.testing.expectEqualStrings("snap_1", id),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("/home/me/warm.sh", config.workspace.warm.?);
    try std.testing.expect(!config.workspace.keep);
    try std.testing.expectEqual(@as(usize, 2), config.workspace.env.len);
    try std.testing.expectEqualStrings("AI_GATEWAY_TEST_API_KEY", config.workspace.env[0]);
    try std.testing.expectEqualStrings("GITHUB_TOKEN", config.workspace.env[1]);
    try std.testing.expectEqual(@as(?u32, 8), config.workspace.vcpus);
    try std.testing.expectEqual(@as(u32, 45), config.workspace.timeout_minutes);
}

test "sandbox config reads isolated profiles and their networks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const config = try parse(arena, isolated_config, "/home/me", &diagnostic);

    const media = isolatedProfile(config, "media") orelse return error.TestUnexpectedResult;
    switch (media.source) {
        .recipe => |path| try std.testing.expectEqualStrings("/home/me/r/media.sh", path),
        else => return error.TestUnexpectedResult,
    }
    switch (media.network) {
        .deny_all => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 10), media.timeout_minutes);

    const npm = isolatedProfile(config, "npm") orelse return error.TestUnexpectedResult;
    switch (npm.source) {
        .default => {},
        else => return error.TestUnexpectedResult,
    }
    switch (npm.network) {
        .allow => |domains| {
            try std.testing.expectEqual(@as(usize, 2), domains.len);
            try std.testing.expectEqualStrings("registry.npmjs.org", domains[0]);
            try std.testing.expectEqualStrings("*.npmjs.com", domains[1]);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 10), npm.timeout_minutes);

    const open = isolatedProfile(config, "open") orelse return error.TestUnexpectedResult;
    switch (open.source) {
        .image => |image| try std.testing.expectEqualStrings("node24", image),
        else => return error.TestUnexpectedResult,
    }
    switch (open.network) {
        .allow_all => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 10), open.timeout_minutes);
}

test "the default isolated profile is built in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const config = try parse(arena, "{\"team\":\"t\",\"project\":\"p\"}", "/home/me", &diagnostic);
    const implicit = isolatedProfile(config, null) orelse return error.TestUnexpectedResult;
    const named = isolatedProfile(config, "default") orelse return error.TestUnexpectedResult;
    for ([_]IsolatedProfile{ implicit, named }) |profile| {
        switch (profile.network) {
            .deny_all => {},
            else => return error.TestUnexpectedResult,
        }
        switch (profile.source) {
            .default => {},
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(isolatedProfile(config, "media") == null);
}

test "bad sandbox profiles name the bad field" {
    const cases = [_]struct { bytes: []const u8, message: []const u8 }{
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"snapshot\":\"s\",\"image\":\"i\"}}",
            .message = "use only one of",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"env\":[\"BAD-NAME\"]}}",
            .message = "is not an environment variable name",
        },
        .{ .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"vcpus\":64}}", .message = "vcpus must be 1 or an even number up to 32" },
        .{ .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"vcpus\":3}}", .message = "vcpus must be 1 or an even number up to 32" },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"warm\":\"relative.sh\"}}",
            .message = "warm must be an absolute path",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"recipe\":\"rel.sh\"}}",
            .message = "recipe must be an absolute path",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"timeout_minutes\":301}}",
            .message = "timeout_minutes must be 1 to 300",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"keep\":\"yes\"}}",
            .message = "keep must be true or false",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"env\":\"A\"}}",
            .message = "env must be an array",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"snapshot\":\"\"}}",
            .message = "snapshot must be a non-empty string",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":{\"nope\":1}}",
            .message = "workspace has unknown key \"nope\"",
        },
        .{ .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspace\":\"x\"}", .message = "workspace must be an object" },
        .{ .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":[]}", .message = "isolated must be an object" },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":1}}",
            .message = "isolated[\"x\"] must be an object",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"env\":[\"A\"]}}}",
            .message = "gets no keys",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"network\":[\"http://a.com\"]}}}",
            .message = "is not a domain",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"network\":[\"a.com/path\"]}}}",
            .message = "is not a domain",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"network\":[\"*\"]}}}",
            .message = "is not a domain",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"network\":[1]}}}",
            .message = "is not a domain",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"network\":true}}}",
            .message = "must be \"deny\", \"all\", or a list",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"Bad\":{}}}",
            .message = "profile names use",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"snapshot\":\"s\",\"recipe\":\"~/r.sh\"}}}",
            .message = "use only one of",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"recipe\":\"rel.sh\"}}}",
            .message = "isolated.x.recipe must be an absolute path",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"vcpus\":0}}}",
            .message = "isolated.x.vcpus must be 1 or an even number up to 32",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"timeout_minutes\":0}}}",
            .message = "isolated.x.timeout_minutes must be 1 to 300",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"isolated\":{\"x\":{\"sneaky\":1}}}",
            .message = "isolated.x has unknown key \"sneaky\"",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"rules\":[{\"command\":\"x\",\"placement\":\"isolated:media\"}]}",
            .message = "rules[0] names isolated profile \"media\"",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"default\":\"isolated:gone\"}",
            .message = "default names isolated profile \"gone\"",
        },
        .{
            .bytes = "{\"team\":\"t\",\"project\":\"p\",\"workspaces\":{\"/repo\":\"isolated:gone\"}}",
            .message = "workspaces[\"/repo\"] names isolated profile \"gone\"",
        },
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(
            error.InvalidSandboxConfig,
            parse(arena_state.allocator(), case.bytes, "/home/me", &diagnostic),
        );
        try std.testing.expect(std.mem.find(u8, diagnostic.message, case.message) != null);
    }
}

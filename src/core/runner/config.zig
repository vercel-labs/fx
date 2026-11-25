//! The private sandbox config, `~/.fx/sandbox/config.json`, and the placement
//! it gives a shell command. The caller reads the file and passes its text and
//! the home folder. Parsing and deciding are pure: no I/O and no clock.
const std = @import("std");
const command_environment = @import("../execution/command_environment.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const pathing = @import("../workspace/pathing.zig");

/// Where a command runs. `profile` applies to `.isolated` only. Null means the
/// profile named `default`.
pub const Target = struct {
    placement: command_environment.Placement,
    profile: ?[]const u8 = null,
};

/// Set by a failed `parse`. The message names the field that failed, such as
/// `rules[2].runner: unknown runner "sandbox"`. Its text lives in the
/// arena that `parse` was given.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const ParseError = error{ InvalidSandboxConfig, OutOfMemory };

const Rule = struct {
    /// The command pattern with surrounding whitespace removed. `decide.zig`
    /// matches it against the trimmed command.
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

const Remote = struct {
    team_id: []const u8,
    team_slug: []const u8,
    project_id: []const u8,
    project_name: []const u8,
    user_id: []const u8,
    confirmed_at: []const u8,
};

const FolderPaths = struct {
    /// Absolute and normalized, like `Workspace.folder`.
    folder: []const u8,
    /// Relative paths inside the folder's workspace root.
    paths: []const []const u8,
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
    /// Variables passed to remote runs.
    env: []const []const u8 = &.{},
    /// Extra provider arguments for isolated runs, by profile name.
    profiles: []const Profile = &.{},
    /// The Vercel destination that setup wrote. Null until setup runs.
    remote: ?Remote = null,
    /// Repo paths sent to remote runs even when git ignores them, by folder.
    include: []const FolderPaths = &.{},
    /// Repo paths brought back even when git ignores them, by folder.
    bring_back: []const FolderPaths = &.{},
    /// Sandbox size for the built-in runner. Null means Vercel's default.
    vcpus: ?u8 = null,
};

const default_grace_ms: u32 = 5000;
const min_grace_ms: i64 = 1000;
const max_grace_ms: i64 = 60000;
const max_env_name_len = 64;
const max_path_entries = 50;
const max_path_bytes = 1024;
const known_keys = [_][]const u8{ "provider", "provider_args", "grace_ms", "rules", "workspaces", "env", "profiles", "remote", "include", "bring_back", "vcpus" };
const remote_keys = [_][]const u8{ "backend", "team_id", "team_slug", "project_id", "project_name", "user_id", "confirmed_at" };
/// Names that `env` refuses, so a config never passes a Vercel token to a run.
const vercel_token_names = [_][]const u8{ "VERCEL_TOKEN", "VERCEL_AUTH_TOKEN", "VERCEL_OIDC_TOKEN" };

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
    const remote: ?Remote = if (object.get("remote")) |value|
        try parseRemote(arena, diagnostic, value)
    else
        null;
    const include: []const FolderPaths = if (object.get("include")) |value|
        try parseFolderPaths(arena, diagnostic, home, "include", value)
    else
        &.{};
    const bring_back: []const FolderPaths = if (object.get("bring_back")) |value|
        try parseFolderPaths(arena, diagnostic, home, "bring_back", value)
    else
        &.{};
    const vcpus: ?u8 = if (object.get("vcpus")) |value|
        try parseVcpus(diagnostic, value)
    else
        null;

    return .{
        .provider = provider,
        .provider_args = provider_args,
        .grace_ms = grace_ms,
        .rules = rules,
        .workspaces = workspaces,
        .env = env,
        .profiles = profiles,
        .remote = remote,
        .include = include,
        .bring_back = bring_back,
        .vcpus = vcpus,
    };
}

/// The largest config file fx reads.
pub const max_bytes: usize = 256 * 1024;

pub const Fingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const FingerprintError = error{ OutOfMemory, InvalidSandboxConfig };

/// The fingerprint of a missing config file: the fingerprint of an empty object.
pub const absent_fingerprint: Fingerprint = blk: {
    @setEvalBranchQuota(100_000);
    var digest: Fingerprint = undefined;
    std.crypto.hash.sha2.Sha256.hash("{}", &digest, .{});
    break :blk digest;
};

/// The fingerprint of the config keys other than `remote`, which setup's locked
/// write compares with what this process loaded (spec U9). The object is written
/// in canonical form (keys sorted at every level, no whitespace) and hashed with
/// SHA-256, so the file's formatting and key order do not change it. `null` is a
/// missing file.
pub fn fingerprintWithoutRemote(arena: std.mem.Allocator, bytes: ?[]const u8) FingerprintError!Fingerprint {
    const text = bytes orelse return absent_fingerprint;
    var root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSandboxConfig,
    };
    if (root != .object) return error.InvalidSandboxConfig;
    _ = root.object.swapRemove("remote");

    var canonical: std.Io.Writer.Allocating = .init(arena);
    writeCanonical(&canonical.writer, root, arena) catch return error.OutOfMemory;
    var digest: Fingerprint = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical.written(), &digest, .{});
    return digest;
}

const CanonicalError = std.Io.Writer.Error || std.mem.Allocator.Error;

fn writeCanonical(out: *std.Io.Writer, value: std.json.Value, arena: std.mem.Allocator) CanonicalError!void {
    switch (value) {
        .object => |object| {
            const keys = try arena.dupe([]const u8, object.keys());
            sort_utils.sort([]const u8, keys, {}, sort_utils.lessThanBytes);
            try out.writeByte('{');
            for (keys, 0..) |key, index| {
                if (index > 0) try out.writeByte(',');
                try std.json.Stringify.value(key, .{}, out);
                try out.writeByte(':');
                try writeCanonical(out, object.get(key).?, arena);
            }
            try out.writeByte('}');
        },
        .array => |array| {
            try out.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try out.writeByte(',');
                try writeCanonical(out, item, arena);
            }
            try out.writeByte(']');
        },
        else => try std.json.Stringify.value(value, .{}, out),
    }
}

/// The `include` paths for a workspace root: those of the longest folder that
/// contains the root, or none.
pub fn includeFor(cfg: *const Config, workspace_root: []const u8) []const []const u8 {
    return pathsCovering(cfg.include, workspace_root);
}

/// The `bring_back` paths for a workspace root, chosen as `includeFor` chooses.
pub fn bringBackFor(cfg: *const Config, workspace_root: []const u8) []const []const u8 {
    return pathsCovering(cfg.bring_back, workspace_root);
}

fn pathsCovering(lists: []const FolderPaths, workspace_root: []const u8) []const []const u8 {
    const none: []const []const u8 = &.{};
    const index = longestCovering(lists, workspace_root) orelse return none;
    return lists[index].paths;
}

/// The index of the longest entry in `folders` whose `folder` contains
/// `workspace_root`, or null. `workspaces` and the path lists both use it, and
/// `decide.zig` uses it for the folder default.
pub fn longestCovering(folders: anytype, workspace_root: []const u8) ?usize {
    var best: ?usize = null;
    for (folders, 0..) |entry, index| {
        if (!pathing.pathInside(entry.folder, workspace_root)) continue;
        if (best) |current| {
            if (folders[current].folder.len >= entry.folder.len) continue;
        }
        best = index;
    }
    return best;
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
        if (!command_environment.isProfileName(name)) {
            return failFmt(arena, diagnostic, "{s}: name must be 1 to {d} characters of a-z, 0-9, _, or -", .{ label, command_environment.max_profile_name_len });
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
        if (!std.mem.eql(u8, key, "command") and !std.mem.eql(u8, key, "runner")) {
            return failFmt(arena, diagnostic, "{s}.{s}: unknown key", .{ label, key });
        }
    }
    const command = try requiredString(arena, diagnostic, fields, label, "command");
    const pattern = std.mem.trim(u8, command, &std.ascii.whitespace);
    if (pattern.len == 0) return failFmt(arena, diagnostic, "{s}.command: must not be empty", .{label});
    const runner_text = try requiredString(arena, diagnostic, fields, label, "runner");
    const runner_label = try arena.print("{s}.runner", .{label});
    return .{
        .pattern = pattern,
        .target = try parseTarget(arena, diagnostic, profiles, runner_text, runner_label),
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
            else => return failFmt(arena, diagnostic, "{s}: must be a runner string", .{label}),
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

/// A runner string: `local`, `remote`, `isolated`, or `isolated:<profile>`.
/// `isolated:default` means the default profile, which is null in the target.
fn parseTarget(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    profiles: []const Profile,
    text: []const u8,
    label: []const u8,
) ParseError!Target {
    if (std.mem.eql(u8, text, "local")) return .{ .placement = .local };
    if (std.mem.eql(u8, text, "remote")) return .{ .placement = .remote };
    if (std.mem.eql(u8, text, "isolated")) return .{ .placement = .isolated };
    const isolated_prefix = "isolated:";
    if (!std.mem.startsWith(u8, text, isolated_prefix)) {
        return failFmt(arena, diagnostic, "{s}: unknown runner \"{s}\"", .{ label, text });
    }
    const name = text[isolated_prefix.len..];
    if (!command_environment.isProfileName(name)) {
        return failFmt(arena, diagnostic, "{s}: profile name \"{s}\" must be 1 to {d} characters of a-z, 0-9, _, or -", .{ label, name, command_environment.max_profile_name_len });
    }
    if (std.mem.eql(u8, name, command_environment.default_profile_name)) return .{ .placement = .isolated };
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
        if (contains(&vercel_token_names, name)) {
            return failFmt(arena, diagnostic, "env[{d}]: \"{s}\" is a Vercel token name, and env refuses it", .{ index, name });
        }
        const slot = try seen.getOrPut(arena, name);
        if (slot.found_existing) return failFmt(arena, diagnostic, "env[{d}]: duplicate \"{s}\"", .{ index, name });
    }
    return names;
}

/// The Vercel destination: six strings and the backend name.
fn parseRemote(arena: std.mem.Allocator, diagnostic: *Diagnostic, value: std.json.Value) ParseError!Remote {
    const fields = switch (value) {
        .object => |map| map,
        else => return fail(diagnostic, "remote: must be an object"),
    };
    var keys = fields.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!contains(&remote_keys, key)) return failFmt(arena, diagnostic, "remote.{s}: unknown key", .{key});
    }
    const backend = try requiredString(arena, diagnostic, fields, "remote", "backend");
    if (!std.mem.eql(u8, backend, "vercel")) return fail(diagnostic, "remote.backend: must be \"vercel\"");
    return .{
        .team_id = try requiredString(arena, diagnostic, fields, "remote", "team_id"),
        .team_slug = try requiredString(arena, diagnostic, fields, "remote", "team_slug"),
        .project_id = try requiredString(arena, diagnostic, fields, "remote", "project_id"),
        .project_name = try requiredString(arena, diagnostic, fields, "remote", "project_name"),
        .user_id = try requiredString(arena, diagnostic, fields, "remote", "user_id"),
        .confirmed_at = try requiredString(arena, diagnostic, fields, "remote", "confirmed_at"),
    };
}

/// `include` or `bring_back`: an object whose keys are folders, as in
/// `workspaces`, and whose values are lists of repo paths.
fn parseFolderPaths(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    home: []const u8,
    field: []const u8,
    value: std.json.Value,
) ParseError![]const FolderPaths {
    const fields = switch (value) {
        .object => |map| map,
        else => return failFmt(arena, diagnostic, "{s}: must be an object", .{field}),
    };
    const lists = try arena.alloc(FolderPaths, fields.count());
    var folders: std.array_hash_map.String(void) = .empty;
    var keys = fields.iterator();
    var index: usize = 0;
    while (keys.next()) |entry| : (index += 1) {
        const raw = entry.key_ptr.*;
        const label = try arena.print("{s}[\"{s}\"]", .{ field, raw });
        const folder = try normalizeFolder(arena, diagnostic, home, raw, label);
        const slot = try folders.getOrPut(arena, folder);
        if (slot.found_existing) return failFmt(arena, diagnostic, "{s}: duplicate folder", .{label});
        const paths = try parsePaths(arena, diagnostic, entry.value_ptr.*, label);
        lists[index] = .{ .folder = folder, .paths = paths };
    }
    return lists;
}

/// The repo paths of one folder. `label` names the folder key in messages.
fn parsePaths(
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    value: std.json.Value,
    label: []const u8,
) ParseError![]const []const u8 {
    const paths = try stringArray(arena, diagnostic, value, label);
    if (paths.len > max_path_entries) {
        return failFmt(arena, diagnostic, "{s}: must have at most {d} entries", .{ label, max_path_entries });
    }
    for (paths, 0..) |path, index| {
        const item_label = try arena.print("{s}[{d}]", .{ label, index });
        try validatePath(arena, diagnostic, path, item_label);
    }
    return paths;
}

/// A repo path that a remote run may send or bring back: not empty, at most
/// 1,024 bytes, relative, and made of plain names. It has no `.` or `..`
/// segment, no empty segment, no trailing `/`, and no `.git` component in any case.
pub fn validatePath(arena: std.mem.Allocator, diagnostic: *Diagnostic, text: []const u8, label: []const u8) ParseError!void {
    if (text.len == 0) return failFmt(arena, diagnostic, "{s}: must not be empty", .{label});
    if (text.len > max_path_bytes) {
        return failFmt(arena, diagnostic, "{s}: longer than {d} bytes", .{ label, max_path_bytes });
    }
    if (std.mem.startsWith(u8, text, "/")) return failFmt(arena, diagnostic, "{s}: must be a relative path", .{label});
    if (std.mem.endsWith(u8, text, "/")) return failFmt(arena, diagnostic, "{s}: must not end with /", .{label});
    var parts = std.mem.splitScalar(u8, text, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return failFmt(arena, diagnostic, "{s}: must not contain empty segments", .{label});
        if (std.mem.eql(u8, part, ".")) return failFmt(arena, diagnostic, "{s}: must not contain . segments", .{label});
        if (std.mem.eql(u8, part, "..")) return failFmt(arena, diagnostic, "{s}: must not contain .. segments", .{label});
        if (std.ascii.eqlIgnoreCase(part, ".git")) {
            return failFmt(arena, diagnostic, "{s}: must not contain a .git component", .{label});
        }
    }
}

/// The sandbox size. Vercel offers these sizes; anything else is an error.
fn parseVcpus(diagnostic: *Diagnostic, value: std.json.Value) ParseError!u8 {
    const number: i64 = switch (value) {
        .integer => |int| int,
        else => return fail(diagnostic, "vcpus: must be 1, 2, 4, 6, or 8"),
    };
    switch (number) {
        1, 2, 4, 6, 8 => return @intCast(number),
        else => return fail(diagnostic, "vcpus: must be 1, 2, 4, 6, or 8"),
    }
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
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"runner\":\"local\",\"shell\":\"x\"}]}", .message = "rules[0].shell: unknown key" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"placement\":\"local\"}]}", .message = "rules[0].placement: unknown key" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\"}]}", .message = "rules[0].runner: required" },
        .{ .text = "{\"rules\":[{\"runner\":\"local\"}]}", .message = "rules[0].command: required" },
        .{ .text = "{\"rules\":[{\"command\":1,\"runner\":\"local\"}]}", .message = "rules[0].command: must be a string" },
        .{ .text = "{\"rules\":[{\"command\":\"  \",\"runner\":\"local\"}]}", .message = "rules[0].command: must not be empty" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"runner\":\"local\"},{\"command\":\"ls\",\"runner\":\"local\"},{\"command\":\"ls\",\"runner\":\"sandbox\"}]}", .message = "rules[2].runner: unknown runner \"sandbox\"" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"runner\":\"isolated:media\"}]}", .message = "rules[0].runner: profile \"media\" is not in profiles" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"runner\":\"isolated:Media\"}]}", .message = "rules[0].runner: profile name \"Media\" must be 1 to 40 characters of a-z, 0-9, _, or -" },
        .{ .text = "{\"rules\":[{\"command\":\"ls\",\"runner\":\"isolated:\"}]}", .message = "rules[0].runner: profile name \"\" must be 1 to 40 characters of a-z, 0-9, _, or -" },
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
        .{ .text = "{\"env\":[\"VERCEL_TOKEN\"]}", .message = "env[0]: \"VERCEL_TOKEN\" is a Vercel token name, and env refuses it" },
        .{ .text = "{\"env\":[\"PATH\",\"VERCEL_AUTH_TOKEN\"]}", .message = "env[1]: \"VERCEL_AUTH_TOKEN\" is a Vercel token name, and env refuses it" },
        .{ .text = "{\"env\":[\"VERCEL_OIDC_TOKEN\"]}", .message = "env[0]: \"VERCEL_OIDC_TOKEN\" is a Vercel token name, and env refuses it" },
        .{ .text = "{\"workspaces\":[]}", .message = "workspaces: must be an object" },
        .{ .text = "{\"workspaces\":{\"repo\":\"remote\"}}", .message = "workspaces[\"repo\"]: folder must be absolute or start with ~/" },
        .{ .text = "{\"workspaces\":{\"~/repo\":\"remote\"}}", .home = "", .message = "workspaces[\"~/repo\"]: ~/ needs a home folder" },
        .{ .text = "{\"workspaces\":{\"/a/../b\":\"remote\"}}", .message = "workspaces[\"/a/../b\"]: folder must not contain .. segments" },
        .{ .text = "{\"workspaces\":{\"/a\":\"remote\",\"/a/\":\"local\"}}", .message = "workspaces[\"/a/\"]: duplicate folder" },
        .{ .text = "{\"workspaces\":{\"/a\":\"sandbox\"}}", .message = "workspaces[\"/a\"]: unknown runner \"sandbox\"" },
        .{ .text = "{\"workspaces\":{\"/a\":1}}", .message = "workspaces[\"/a\"]: must be a runner string" },
        .{ .text = "{\"profiles\":[]}", .message = "profiles: must be an object" },
        .{ .text = "{\"profiles\":{\"Media\":[]}}", .message = "profiles[\"Media\"]: name must be 1 to 40 characters of a-z, 0-9, _, or -" },
        .{ .text = "{\"profiles\":{\"media\":\"--gpu\"}}", .message = "profiles[\"media\"]: must be an array of strings" },
        .{ .text = "{\"remote\":\"x\"}", .message = "remote: must be an object" },
        .{ .text = "{\"remote\":{\"backend\":\"vercel\",\"extra\":\"x\"}}", .message = "remote.extra: unknown key" },
        .{ .text = "{\"remote\":{\"team_id\":\"t\"}}", .message = "remote.backend: required" },
        .{ .text = "{\"remote\":{\"backend\":\"aws\"}}", .message = "remote.backend: must be \"vercel\"" },
        .{ .text = "{\"remote\":{\"backend\":\"vercel\"}}", .message = "remote.team_id: required" },
        .{ .text = "{\"remote\":{\"backend\":\"vercel\",\"team_id\":1,\"team_slug\":\"s\",\"project_id\":\"p\",\"project_name\":\"n\",\"user_id\":\"u\",\"confirmed_at\":\"c\"}}", .message = "remote.team_id: must be a string" },
        .{ .text = "{\"remote\":{\"backend\":\"vercel\",\"team_id\":\"t\",\"team_slug\":\"s\",\"project_id\":\"p\",\"project_name\":\"n\",\"user_id\":\"u\"}}", .message = "remote.confirmed_at: required" },
        .{ .text = "{\"include\":[]}", .message = "include: must be an object" },
        .{ .text = "{\"include\":{\"repo\":[]}}", .message = "include[\"repo\"]: folder must be absolute or start with ~/" },
        .{ .text = "{\"include\":{\"/a/../b\":[]}}", .message = "include[\"/a/../b\"]: folder must not contain .. segments" },
        .{ .text = "{\"include\":{\"/a\":[],\"/a/\":[]}}", .message = "include[\"/a/\"]: duplicate folder" },
        .{ .text = "{\"include\":{\"/a\":\"x\"}}", .message = "include[\"/a\"]: must be an array of strings" },
        .{ .text = "{\"include\":{\"/a\":[1]}}", .message = "include[\"/a\"][0]: must be a string" },
        .{ .text = "{\"include\":{\"/a\":[\"\"]}}", .message = "include[\"/a\"][0]: must not be empty" },
        .{ .text = "{\"include\":{\"/a\":[\"/etc/hosts\"]}}", .message = "include[\"/a\"][0]: must be a relative path" },
        .{ .text = "{\"include\":{\"/a\":[\"b/../c\"]}}", .message = "include[\"/a\"][0]: must not contain .. segments" },
        .{ .text = "{\"include\":{\"/a\":[\".git/config\"]}}", .message = "include[\"/a\"][0]: must not contain a .git component" },
        .{ .text = "{\"include\":{\"/a\":[\"x/.GIT/y\"]}}", .message = "include[\"/a\"][0]: must not contain a .git component" },
        .{ .text = "{\"bring_back\":{\"/a\":[\"/x\"]}}", .message = "bring_back[\"/a\"][0]: must be a relative path" },
        .{ .text = "{\"include\":{\"/a\":[\".\"]}}", .message = "include[\"/a\"][0]: must not contain . segments" },
        .{ .text = "{\"include\":{\"/a\":[\"./a\"]}}", .message = "include[\"/a\"][0]: must not contain . segments" },
        .{ .text = "{\"include\":{\"/a\":[\"a/./b\"]}}", .message = "include[\"/a\"][0]: must not contain . segments" },
        .{ .text = "{\"include\":{\"/a\":[\"a//b\"]}}", .message = "include[\"/a\"][0]: must not contain empty segments" },
        .{ .text = "{\"include\":{\"/a\":[\"zig-out/bin/\"]}}", .message = "include[\"/a\"][0]: must not end with /" },
        .{ .text = "{\"bring_back\":{\"/a\":[\"out/\"]}}", .message = "bring_back[\"/a\"][0]: must not end with /" },
        .{ .text = "{\"bring_back\":{\"/a\":[\"./x\"]}}", .message = "bring_back[\"/a\"][0]: must not contain . segments" },
        .{ .text = "{\"vcpus\":3}", .message = "vcpus: must be 1, 2, 4, 6, or 8" },
        .{ .text = "{\"vcpus\":\"4\"}", .message = "vcpus: must be 1, 2, 4, 6, or 8" },
        .{ .text = "{\"vcpus\":10}", .message = "vcpus: must be 1, 2, 4, 6, or 8" },
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

test "env refuses each Vercel token name and keeps other Vercel names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const cfg = try parse(arena, "{\"env\":[\"VERCEL_TOKEN_X\",\"VERCEL_PROJECT_ID\"]}", home_folder, &diagnostic);
    try std.testing.expectEqual(@as(usize, 2), cfg.env.len);
    try std.testing.expectEqualStrings("VERCEL_PROJECT_ID", cfg.env[1]);

    for (vercel_token_names) |name| {
        const text = try arena.print("{{\"env\":[\"{s}\"]}}", .{name});
        const message = try arena.print("env[0]: \"{s}\" is a Vercel token name, and env refuses it", .{name});
        try expectRejected(text, home_folder, message);
    }
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

test "the fingerprint ignores formatting, key order and remote, and changes with any other key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plain = try fingerprintWithoutRemote(arena, "{\"grace_ms\":2000,\"env\":[\"PATH\"]}");
    const reordered = try fingerprintWithoutRemote(arena, "{\n  \"env\": [ \"PATH\" ],\n  \"remote\": {\"backend\": \"vercel\"},\n  \"grace_ms\": 2000\n}");
    try std.testing.expectEqualSlices(u8, &plain, &reordered);
    const changed = try fingerprintWithoutRemote(arena, "{\"grace_ms\":3000,\"env\":[\"PATH\"]}");
    try std.testing.expect(!std.mem.eql(u8, &plain, &changed));
    const empty = try fingerprintWithoutRemote(arena, "{}");
    try std.testing.expectEqualSlices(u8, &absent_fingerprint, &empty);
    const only_remote = try fingerprintWithoutRemote(arena, "{\"remote\":{}}");
    try std.testing.expectEqualSlices(u8, &absent_fingerprint, &only_remote);
    try std.testing.expectError(error.InvalidSandboxConfig, fingerprintWithoutRemote(arena, "[1]"));
}

test "remote holds the six strings that setup writes for the vercel backend" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"remote\":{\"backend\":\"vercel\",\"team_id\":\"team_1\",\"team_slug\":\"acme\",\"project_id\":\"prj_1\",\"project_name\":\"repo\",\"user_id\":\"usr_1\",\"confirmed_at\":\"2026-11-21T10:00:00Z\"}}",
        home_folder,
        &diagnostic,
    );
    const remote = cfg.remote.?;
    try std.testing.expectEqualStrings("team_1", remote.team_id);
    try std.testing.expectEqualStrings("acme", remote.team_slug);
    try std.testing.expectEqualStrings("prj_1", remote.project_id);
    try std.testing.expectEqualStrings("repo", remote.project_name);
    try std.testing.expectEqualStrings("usr_1", remote.user_id);
    try std.testing.expectEqualStrings("2026-11-21T10:00:00Z", remote.confirmed_at);
}

test "include and bring_back normalize folder keys and keep their paths in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena,
        "{\"include\":{\"~/repo/\":[\".env.local\",\"config/local.json\"]},\"bring_back\":{\"/w/repo\":[\"out/result.json\"]}}",
        home_folder,
        &diagnostic,
    );
    try std.testing.expectEqual(@as(usize, 1), cfg.include.len);
    try std.testing.expectEqualStrings("/Users/example/repo", cfg.include[0].folder);
    try std.testing.expectEqual(@as(usize, 2), cfg.include[0].paths.len);
    try std.testing.expectEqualStrings(".env.local", cfg.include[0].paths[0]);
    try std.testing.expectEqualStrings("config/local.json", cfg.include[0].paths[1]);
    try std.testing.expectEqualStrings("/w/repo", cfg.bring_back[0].folder);
    try std.testing.expectEqualStrings("out/result.json", cfg.bring_back[0].paths[0]);

    const empty = try parse(arena, "{\"include\":{\"/a\":[]}}", home_folder, &diagnostic);
    try std.testing.expectEqual(@as(usize, 0), empty.include[0].paths.len);
}

test "vcpus takes 1, 2, 4, 6, or 8, and is null when absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};
    for ([_]u8{ 1, 2, 4, 6, 8 }) |want| {
        const text = try arena.print("{{\"vcpus\":{d}}}", .{want});
        const cfg = try parse(arena, text, home_folder, &diagnostic);
        try std.testing.expectEqual(@as(?u8, want), cfg.vcpus);
    }
    const none = try parse(arena, "{}", home_folder, &diagnostic);
    try std.testing.expectEqual(@as(?u8, null), none.vcpus);
}

test "the new keys are absent by default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(arena_state.allocator(), "{}", home_folder, &diagnostic);
    try std.testing.expect(cfg.remote == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.include.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.bring_back.len);
    try std.testing.expectEqual(@as(?u8, null), cfg.vcpus);
}

fn pathListText(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "{\"include\":{\"/a\":[");
    for (0..count) |index| {
        if (index > 0) try text.append(arena, ',');
        try text.appendSlice(arena, "\"x\"");
    }
    try text.appendSlice(arena, "]}}");
    return text.items;
}

test "include paths keep their 1,024 byte and 50 entry limits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const max_path = try repeated(arena, 'a', 1024);
    const max_text = try arena.print("{{\"include\":{{\"/a\":[\"{s}\"]}}}}", .{max_path});
    const cfg = try parse(arena, max_text, home_folder, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1024), cfg.include[0].paths[0].len);

    const too_long = try repeated(arena, 'a', 1025);
    const long_text = try arena.print("{{\"include\":{{\"/a\":[\"{s}\"]}}}}", .{too_long});
    try expectRejected(long_text, home_folder, "include[\"/a\"][0]: longer than 1024 bytes");

    const fifty = try parse(arena, try pathListText(arena, 50), home_folder, &diagnostic);
    try std.testing.expectEqual(@as(usize, 50), fifty.include[0].paths.len);
    try expectRejected(try pathListText(arena, 51), home_folder, "include[\"/a\"]: must have at most 50 entries");
}

test "includeFor and bringBackFor give the longest folder that covers the root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"include\":{\"/Users/example/repo\":[\"a\"],\"/Users/example/repo/app\":[\"b\"]},\"bring_back\":{\"~/repo/\":[\"x\"]}}",
        home_folder,
        &diagnostic,
    );
    try std.testing.expectEqualStrings("b", includeFor(&cfg, "/Users/example/repo/app/src")[0]);
    try std.testing.expectEqualStrings("a", includeFor(&cfg, "/Users/example/repo/lib")[0]);
    try std.testing.expectEqual(@as(usize, 0), includeFor(&cfg, "/Users/example/repository").len);
    try std.testing.expectEqual(@as(usize, 0), includeFor(&cfg, "/elsewhere").len);
    try std.testing.expectEqualStrings("x", bringBackFor(&cfg, "/Users/example/repo/app")[0]);
    try std.testing.expectEqual(@as(usize, 0), bringBackFor(&cfg, "/Users/example/other").len);
}

fn fuzzRemoteSection(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, max_bytes);
    const text = raw[0..smith.slice(raw)];
    var diagnostic: Diagnostic = .{};
    const cfg = parse(arena, text, "/Users/example", &diagnostic) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {},
    };
    const remote = cfg.remote orelse return;
    // A parsed remote keeps the strings its JSON gave: the same text, read again, holds the same values.
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const fields = root.object.get("remote").?.object;
    try std.testing.expectEqualStrings(fields.get("team_id").?.string, remote.team_id);
    try std.testing.expectEqualStrings(fields.get("team_slug").?.string, remote.team_slug);
    try std.testing.expectEqualStrings(fields.get("project_id").?.string, remote.project_id);
    try std.testing.expectEqualStrings(fields.get("project_name").?.string, remote.project_name);
    try std.testing.expectEqualStrings(fields.get("user_id").?.string, remote.user_id);
    try std.testing.expectEqualStrings(fields.get("confirmed_at").?.string, remote.confirmed_at);
}

test "a remote section parses or is refused on fuzzed bytes, and a parsed remote keeps the strings its JSON gave" {
    try std.testing.fuzz({}, fuzzRemoteSection, .{
        .corpus = &@import("fuzz_corpus").vercel_config_remote.*,
    });
}

test "a full config uses every key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"provider\":[\"~/bin/sandbox\",\"run\"],\"provider_args\":[\"--json\"],\"grace_ms\":2000," ++
            "\"rules\":[{\"command\":\"zig build*\",\"runner\":\"remote\"}]," ++
            "\"workspaces\":{\"/Users/example/repo\":\"remote\"},\"env\":[\"PATH\"]," ++
            "\"profiles\":{\"media\":[\"--gpu\"]}," ++
            "\"remote\":{\"backend\":\"vercel\",\"team_id\":\"team_1\",\"team_slug\":\"acme\",\"project_id\":\"prj_1\",\"project_name\":\"repo\",\"user_id\":\"usr_1\",\"confirmed_at\":\"2026-11-21T10:00:00Z\"}," ++
            "\"include\":{\"~/repo\":[\".env.local\"]},\"bring_back\":{\"~/repo\":[\"generated/out.json\"]},\"vcpus\":4}",
        home_folder,
        &diagnostic,
    );
    try std.testing.expectEqual(@as(u32, 2000), cfg.grace_ms);
    try std.testing.expectEqual(@as(usize, 1), cfg.rules.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.workspaces.len);
    try std.testing.expectEqualStrings("PATH", cfg.env[0]);
    try std.testing.expectEqualStrings("media", cfg.profiles[0].name);
    try std.testing.expectEqualStrings("acme", cfg.remote.?.team_slug);
    try std.testing.expectEqualStrings(".env.local", includeFor(&cfg, "/Users/example/repo/app")[0]);
    try std.testing.expectEqualStrings("generated/out.json", bringBackFor(&cfg, "/Users/example/repo/app")[0]);
    try std.testing.expectEqual(@as(?u8, 4), cfg.vcpus);
}

test "dot-prefixed names and plain nested paths stay valid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"include\":{\"/a\":[\"zig-out/bin\",\".env\",\"a/b.c\",\".github/workflows\"]}}",
        home_folder,
        &diagnostic,
    );
    const paths = cfg.include[0].paths;
    try std.testing.expectEqual(@as(usize, 4), paths.len);
    try std.testing.expectEqualStrings("zig-out/bin", paths[0]);
    try std.testing.expectEqualStrings(".env", paths[1]);
    try std.testing.expectEqualStrings("a/b.c", paths[2]);
    try std.testing.expectEqualStrings(".github/workflows", paths[3]);
}

//! Agent profiles: named, saved settings for what an agent may do. Main runs
//! in one profile, `main` unless `fx --profile` names another, and each
//! subagent starts in the profile main names for it, `agent` by default.
//!
//! A profile is a folder, `<name>/profile.json` with an optional
//! `<name>/prompt.md`. A name resolves from the user's `~/.fx/agents/` first,
//! then the repository's `.fx/agents/`, then fx's own `main` and `agent`.
//! A repository's profile never sets the permission mode, so a cloned
//! repository cannot grant itself access.

const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const max_name_bytes = 64;
pub const max_settings_bytes = 64 * 1024;
pub const max_prompt_bytes = 256 * 1024;
const max_list_entry_bytes = 256;

pub const settings_file_name = "profile.json";
pub const prompt_file_name = "prompt.md";
pub const main_name = "main";
pub const agent_name = "agent";

const subagent_tool = "subagent";
const wildcard = "*";

pub const Source = enum { home, project, builtin };
/// Whether an agent is main or a subagent.
pub const Role = enum { main, subagent };
pub const PromptMode = enum { append, replace };

pub const IgnoredReason = enum {
    unknown_key,
    project_cannot_set_permissions,
};

/// A key a profile set that fx did not apply.
pub const Ignored = struct {
    key: []const u8,
    reason: IgnoredReason,
};

/// A loaded profile. Its slices belong to the arena it was parsed with.
pub const Profile = struct {
    name: []const u8,
    description: []const u8,
    source: Source,
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    /// Null means the agent runs under its parent's mode.
    permission_mode: ?types.PermissionMode = null,
    /// Tool names. `*` means every tool fx has and `!name` removes one.
    /// Set, it decides the agent's tools, even ones its parent lacks;
    /// null, the agent has its parent's.
    tools: ?[]const []const u8 = null,
    /// MCP server names, matched and inherited the same way as `tools`.
    mcp_servers: ?[]const []const u8 = null,
    prompt: []const u8 = "",
    prompt_mode: PromptMode = .append,
    ignored: []const Ignored = &.{},
};

/// A profile's name, description, and where it resolved from, for the list
/// main picks from.
pub const Entry = struct {
    name: []const u8,
    description: []const u8,
    source: Source,
};

pub const ParseError = error{ OutOfMemory, InvalidProfile };
pub const LoadError = error{ OutOfMemory, InvalidProfile, ProfileNotFound, ReadFailed };

/// Where profiles are saved. Either may be absent.
pub const Roots = struct {
    /// `~/.fx/agents`.
    home: ?[]const u8 = null,
    /// `<workspace>/.fx/agents`.
    project: ?[]const u8 = null,

    /// Builds both roots from the fx home and the workspace. Caller owns the
    /// result through `arena`.
    pub fn init(arena: Allocator, home: ?[]const u8, workspace_root: ?[]const u8) !Roots {
        return .{
            .home = if (home) |path| try profile_paths.agentsDir(arena, path) else null,
            .project = if (workspace_root) |root|
                try std.Io.Dir.path.join(arena, &.{ root, profile_paths.root_dir_name, profile_paths.agents_dir_name })
            else
                null,
        };
    }
};

/// The profile an agent runs in, with the memory it was loaded into. Starts as
/// fx's `main`.
pub const Held = struct {
    arena: ?std.heap.ArenaAllocator = null,
    profile: Profile = builtin(main_name).?,
    /// The system prompt with the profile's prompt applied, or null to use
    /// fx's own.
    system_prompt: ?[]const u8 = null,

    /// Replaces the current profile with `name` from `roots`, applying its
    /// prompt to `base_prompt`. On failure, the current profile stays and
    /// `failure` holds a message that `alloc` owns.
    pub fn replace(
        self: *Held,
        alloc: Allocator,
        roots_home: ?[]const u8,
        workspace_root: ?[]const u8,
        name: []const u8,
        base_prompt: []const u8,
        failure: *?[]u8,
    ) LoadError!void {
        var next = std.heap.ArenaAllocator.init(alloc);
        errdefer next.deinit();
        const arena = next.allocator();
        const roots = try Roots.init(arena, roots_home, workspace_root);
        var message: ?[]const u8 = null;
        const profile = load_profile: {
            break :load_profile load(arena, roots, name, &message) catch |err| {
                if (message) |text| failure.* = alloc.dupe(u8, text) catch null;
                return err;
            };
        };
        const prompt = try systemPrompt(arena, &profile, base_prompt);
        self.deinit();
        self.* = .{
            .arena = next,
            .profile = profile,
            .system_prompt = if (prompt.ptr == base_prompt.ptr) null else prompt,
        };
    }

    pub fn deinit(self: *Held) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// fx's own profiles: `main` and `agent`. Neither sets tools, MCP servers,
/// or a mode, so an agent in either is a copy of the one that started it,
/// and an instance in `main` has every tool fx has.
pub fn builtin(name: []const u8) ?Profile {
    if (std.mem.eql(u8, name, main_name)) return .{
        .name = main_name,
        .description = "fx itself, with every tool",
        .source = .builtin,
    };
    if (std.mem.eql(u8, name, agent_name)) return .{
        .name = agent_name,
        .description = "A general subagent with every tool",
        .source = .builtin,
    };
    return null;
}

/// Parses a profile's `profile.json` and `prompt.md` text. On failure,
/// `failure` holds a message naming the profile and the problem. Every slice
/// of the result, and the message, belong to `arena`.
pub fn parse(
    arena: Allocator,
    name: []const u8,
    source: Source,
    settings_json: []const u8,
    prompt: []const u8,
    failure: *?[]const u8,
) ParseError!Profile {
    if (!validName(name)) return fail(arena, failure, "profile name '{s}' must use lowercase letters, digits, '-', or '_'", .{name});
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, settings_json, .{}) catch
        return fail(arena, failure, "profile '{s}': {s} is not valid JSON", .{ name, settings_file_name });
    if (root != .object) return fail(arena, failure, "profile '{s}': {s} must be a JSON object", .{ name, settings_file_name });

    var profile: Profile = .{ .name = name, .description = "", .source = source, .prompt = prompt };
    var ignored: std.ArrayList(Ignored) = .empty;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "description")) {
            profile.description = try stringField(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "model")) {
            profile.model = try stringField(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "effort")) {
            const raw = try stringField(arena, failure, name, key, value);
            profile.effort = types.ReasoningEffort.parse(raw) orelse
                return fail(arena, failure, "profile '{s}': unknown effort '{s}'", .{ name, raw });
        } else if (std.mem.eql(u8, key, "permission_mode")) {
            if (source == .project) {
                try ignored.append(arena, .{ .key = key, .reason = .project_cannot_set_permissions });
                continue;
            }
            const raw = try stringField(arena, failure, name, key, value);
            profile.permission_mode = types.PermissionMode.parse(raw) orelse
                return fail(arena, failure, "profile '{s}': unknown permission_mode '{s}'", .{ name, raw });
        } else if (std.mem.eql(u8, key, "tools")) {
            profile.tools = try nameList(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "mcp_servers")) {
            profile.mcp_servers = try nameList(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "prompt")) {
            const raw = try stringField(arena, failure, name, key, value);
            profile.prompt_mode = std.meta.stringToEnum(PromptMode, raw) orelse
                return fail(arena, failure, "profile '{s}': prompt must be 'append' or 'replace'", .{name});
        } else {
            try ignored.append(arena, .{ .key = key, .reason = .unknown_key });
        }
    }
    if (profile.description.len == 0) return fail(arena, failure, "profile '{s}' needs a description", .{name});
    profile.ignored = ignored.items;
    return profile;
}

/// Whether `profile` lets an agent use `tool`. `*` covers every tool,
/// `subagent` included, for main and subagents alike. A profile that sets
/// no tools allows every one, leaving its parent's in place.
pub fn allowsTool(profile: *const Profile, tool: []const u8) bool {
    const tools = profile.tools orelse return true;
    return listAllows(tools, tool, false);
}

pub fn allowsMcpServer(profile: *const Profile, server: []const u8) bool {
    const servers = profile.mcp_servers orelse return true;
    return listAllows(servers, server, false);
}

/// Whether `profile` decides its agent's tools rather than inheriting its
/// parent's.
pub fn setsTools(profile: *const Profile) bool {
    return profile.tools != null;
}

/// Whether `profile` decides its agent's MCP servers rather than inheriting
/// its parent's.
pub fn setsMcpServers(profile: *const Profile) bool {
    return profile.mcp_servers != null;
}

/// The mode an agent in `profile` runs under: the profile's own, or its
/// parent's when it sets none. Main's parent is the user's own setting.
pub fn permissionMode(profile: *const Profile, parent: types.PermissionMode) types.PermissionMode {
    return profile.permission_mode orelse parent;
}

/// The system prompt for an agent in `profile`: `base` with the profile's
/// prompt added, or the profile's prompt alone when it says `replace`. A
/// profile without a prompt keeps `base`. The result may borrow `base` or the
/// profile, or belong to `arena`.
pub fn systemPrompt(arena: Allocator, profile: *const Profile, base: []const u8) ![]const u8 {
    const own = std.mem.trim(u8, profile.prompt, " \t\r\n");
    if (own.len == 0) return base;
    return switch (profile.prompt_mode) {
        .replace => own,
        .append => try arena.print("{s}\n\n{s}", .{ base, own }),
    };
}

/// Loads the profile named `name`: the user's own, then the repository's,
/// then fx's. `main` is always fx's own. On failure, `failure` holds a message
/// for the user. The result belongs to `arena`.
pub fn load(arena: Allocator, roots: Roots, name: []const u8, failure: *?[]const u8) LoadError!Profile {
    if (!validName(name)) return fail(arena, failure, "profile name '{s}' must use lowercase letters, digits, '-', or '_'", .{name});
    if (std.mem.eql(u8, name, main_name)) return builtin(main_name).?;
    // The profile keeps its name, so it is `arena`'s like the rest of it,
    // not the caller's.
    const owned = try arena.dupe(u8, name);
    if (roots.home) |dir| if (try readProfile(arena, dir, owned, .home, failure)) |profile| return profile;
    if (roots.project) |dir| if (try readProfile(arena, dir, owned, .project, failure)) |profile| return profile;
    if (builtin(name)) |profile| return profile;
    const names = try listNames(arena, roots);
    failure.* = try arena.print("no profile named '{s}'. Profiles: {s}", .{ name, names });
    return error.ProfileNotFound;
}

/// Every profile main can pick, by name, with the user's own over the
/// repository's over fx's. A profile that fails to load is left out. The
/// result belongs to `arena` and is sorted by name.
pub fn list(arena: Allocator, roots: Roots) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    const sources = [_]struct { dir: ?[]const u8, source: Source }{
        .{ .dir = roots.home, .source = .home },
        .{ .dir = roots.project, .source = .project },
    };
    for (sources) |root| {
        const dir_path = root.dir orelse continue;
        var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io_mod.getIo());
        var it = dir.iterate();
        while (it.next(io_mod.getIo()) catch null) |item| {
            if (item.kind != .directory or !validName(item.name)) continue;
            if (std.mem.eql(u8, item.name, main_name)) continue;
            if (hasEntry(entries.items, item.name)) continue;
            const name = try arena.dupe(u8, item.name);
            var failure: ?[]const u8 = null;
            const profile = (readProfile(arena, dir_path, name, root.source, &failure) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            }) orelse continue;
            try entries.append(arena, .{ .name = profile.name, .description = profile.description, .source = profile.source });
        }
    }
    for ([_][]const u8{ main_name, agent_name }) |name| {
        if (hasEntry(entries.items, name)) continue;
        const profile = builtin(name).?;
        try entries.append(arena, .{ .name = profile.name, .description = profile.description, .source = .builtin });
    }
    std.mem.sort(Entry, entries.items, {}, entryLessThan);
    return entries.items;
}

fn listNames(arena: Allocator, roots: Roots) ![]const u8 {
    const entries = try list(arena, roots);
    var out: std.ArrayList(u8) = .empty;
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, entry.name);
    }
    return out.items;
}

fn hasEntry(entries: []const Entry, name: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return true;
    return false;
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Reads `<dir>/<name>/profile.json` and its optional `prompt.md`. Returns null
/// when the profile is not saved there.
fn readProfile(arena: Allocator, dir: []const u8, name: []const u8, source: Source, failure: *?[]const u8) LoadError!?Profile {
    const settings_path = try std.Io.Dir.path.join(arena, &.{ dir, name, settings_file_name });
    const settings = readFile(arena, settings_path, max_settings_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, settings_path, @errorName(err) }),
    };
    const prompt_path = try std.Io.Dir.path.join(arena, &.{ dir, name, prompt_file_name });
    const prompt = readFile(arena, prompt_path, max_prompt_bytes) catch |err| switch (err) {
        error.FileNotFound => "",
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, prompt_path, @errorName(err) }),
    };
    return parse(arena, name, source, settings, prompt, failure) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidProfile => error.InvalidProfile,
    };
}

fn readFile(arena: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(arena, &file, max_bytes);
}

fn listAllows(entries: []const []const u8, name: []const u8, wildcard_skips: bool) bool {
    var allowed = false;
    for (entries) |entry| {
        if (entry.len > 1 and entry[0] == '!') {
            if (std.mem.eql(u8, entry[1..], name)) return false;
        } else if (std.mem.eql(u8, entry, wildcard)) {
            if (!wildcard_skips) allowed = true;
        } else if (std.mem.eql(u8, entry, name)) {
            allowed = true;
        }
    }
    return allowed;
}

fn stringField(arena: Allocator, failure: *?[]const u8, name: []const u8, key: []const u8, value: std.json.Value) ParseError![]const u8 {
    if (value != .string or value.string.len == 0)
        return fail(arena, failure, "profile '{s}': {s} must be a non-empty string", .{ name, key });
    return value.string;
}

fn nameList(arena: Allocator, failure: *?[]const u8, name: []const u8, key: []const u8, value: std.json.Value) ParseError![]const []const u8 {
    if (value != .array) return fail(arena, failure, "profile '{s}': {s} must be a list of names", .{ name, key });
    const out = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, out) |item, *slot| {
        if (item != .string or item.string.len == 0 or item.string.len > max_list_entry_bytes)
            return fail(arena, failure, "profile '{s}': {s} must be a list of names", .{ name, key });
        slot.* = item.string;
    }
    return out;
}

fn fail(arena: Allocator, failure: *?[]const u8, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, InvalidProfile } {
    failure.* = try arena.print(fmt, args);
    return error.InvalidProfile;
}

const testing = std.testing;

fn testParse(arena: Allocator, source: Source, json: []const u8, prompt: []const u8) !Profile {
    var failure: ?[]const u8 = null;
    return parse(arena, "reviewer", source, json, prompt, &failure);
}

test "a profile's settings, tools, and prompt parse from profile.json and prompt.md" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const profile = try testParse(arena_state.allocator(), .home,
        \\{"description": "Reviews pull requests", "model": "test/model", "effort": "high",
        \\ "permission_mode": "ask", "tools": ["read_file", "grep_files"], "mcp_servers": ["github"],
        \\ "prompt": "replace"}
    , "Review only.");
    try testing.expectEqualStrings("Reviews pull requests", profile.description);
    try testing.expectEqualStrings("test/model", profile.model.?);
    try testing.expect(profile.effort.?.eql(types.ReasoningEffort.literal("high")));
    try testing.expectEqual(types.PermissionMode.ask, profile.permission_mode.?);
    try testing.expectEqual(PromptMode.replace, profile.prompt_mode);
    try testing.expect(allowsTool(&profile, "read_file"));
    try testing.expect(!allowsTool(&profile, "write_file"));
    try testing.expect(allowsMcpServer(&profile, "github"));
    try testing.expect(!allowsMcpServer(&profile, "slack"));
    try testing.expectEqual(@as(usize, 0), profile.ignored.len);
}

test "a repository's profile cannot set the permission mode, and unknown keys are reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const profile = try testParse(arena_state.allocator(), .project,
        \\{"description": "Repo agent", "permission_mode": "full-access", "colour": "blue"}
    , "");
    try testing.expect(profile.permission_mode == null);
    try testing.expectEqual(types.PermissionMode.ask, permissionMode(&profile, .ask));
    try testing.expectEqual(@as(usize, 2), profile.ignored.len);
    try testing.expectEqualStrings("permission_mode", profile.ignored[0].key);
    try testing.expectEqual(IgnoredReason.project_cannot_set_permissions, profile.ignored[0].reason);
    try testing.expectEqual(IgnoredReason.unknown_key, profile.ignored[1].reason);
}

test "the user's own profile sets the mode, and a profile without one inherits its parent's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const own = try testParse(arena_state.allocator(), .home,
        \\{"description": "Fast", "permission_mode": "auto"}
    , "");
    try testing.expectEqual(types.PermissionMode.auto, permissionMode(&own, .ask));
    const plain = try testParse(arena_state.allocator(), .home,
        \\{"description": "Plain"}
    , "");
    try testing.expectEqual(types.PermissionMode.yolo, permissionMode(&plain, .yolo));
}

test "a profile without a description, with bad JSON, or with a bad value is refused with a message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { json: []const u8, message: []const u8 }{
        .{ .json = "{}", .message = "needs a description" },
        .{ .json = "{not json", .message = "is not valid JSON" },
        .{ .json = "[]", .message = "must be a JSON object" },
        .{ .json = "{\"description\": \"x\", \"effort\": 3}", .message = "effort must be a non-empty string" },
        .{ .json = "{\"description\": \"x\", \"tools\": \"read_file\"}", .message = "must be a list of names" },
        .{ .json = "{\"description\": \"x\", \"prompt\": \"prepend\"}", .message = "'append' or 'replace'" },
    };
    for (cases) |case| {
        var failure: ?[]const u8 = null;
        try testing.expectError(error.InvalidProfile, parse(arena, "reviewer", .home, case.json, "", &failure));
        try testing.expect(std.mem.find(u8, failure.?, case.message) != null);
    }
    var failure: ?[]const u8 = null;
    try testing.expectError(error.InvalidProfile, parse(arena, "Bad Name", .home, "{\"description\": \"x\"}", "", &failure));
}

test "fx's main and agent profiles decide nothing, so an agent in either copies its parent" {
    const main = builtin(main_name).?;
    const agent = builtin(agent_name).?;
    try testing.expect(allowsTool(&main, "subagent"));
    try testing.expect(allowsTool(&main, "write_file"));
    try testing.expect(allowsTool(&agent, "subagent"));
    try testing.expect(allowsTool(&agent, "write_file"));
    try testing.expect(!setsTools(&main) and !setsTools(&agent));
    try testing.expect(!setsMcpServers(&main) and !setsMcpServers(&agent));
    try testing.expect(main.permission_mode == null and agent.permission_mode == null);
    try testing.expect(builtin("reviewer") == null);
}

test "a profile's * covers every tool, subagent included, and only !subagent leaves it out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const all = try testParse(arena_state.allocator(), .home,
        \\{"description": "All", "tools": ["*", "!shell"]}
    , "");
    try testing.expect(allowsTool(&all, "read_file"));
    try testing.expect(!allowsTool(&all, "shell"));
    try testing.expect(allowsTool(&all, "subagent"));
    const leaf = try testParse(arena_state.allocator(), .home,
        \\{"description": "Leaf", "tools": ["*", "!subagent"]}
    , "");
    try testing.expect(!allowsTool(&leaf, "subagent"));
    try testing.expect(allowsTool(&leaf, "read_file"));
    const none = try testParse(arena_state.allocator(), .home,
        \\{"description": "None", "tools": []}
    , "");
    try testing.expect(!allowsTool(&none, "read_file"));
    try testing.expect(setsTools(&none));
    const unset = try testParse(arena_state.allocator(), .home,
        \\{"description": "Unset"}
    , "");
    try testing.expect(!setsTools(&unset) and !setsMcpServers(&unset));
    try testing.expect(allowsTool(&unset, "shell"));
}

test "a profile's prompt adds to fx's prompt, or replaces it when the profile says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const append = try testParse(arena, .home, "{\"description\": \"x\"}", "  Review only.\n");
    try testing.expectEqualStrings("BASE\n\nReview only.", try systemPrompt(arena, &append, "BASE"));
    const replace = try testParse(arena, .home, "{\"description\": \"x\", \"prompt\": \"replace\"}", "Review only.");
    try testing.expectEqualStrings("Review only.", try systemPrompt(arena, &replace, "BASE"));
    const empty = try testParse(arena, .home, "{\"description\": \"x\", \"prompt\": \"replace\"}", "\n");
    try testing.expectEqualStrings("BASE", try systemPrompt(arena, &empty, "BASE"));
}

fn writeTestProfile(dir: std.Io.Dir, sub_path: []const u8, json: []const u8) !void {
    try dir.createDirPath(io_mod.getIo(), sub_path);
    const file_path = try std.Io.Dir.path.join(testing.allocator, &.{ sub_path, settings_file_name });
    defer testing.allocator.free(file_path);
    var file = try dir.createFile(io_mod.getIo(), file_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), json);
}

test "a name resolves from the user's profiles, then the repository's, then fx's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestProfile(tmp.dir, "home/reviewer", "{\"description\": \"Home reviewer\"}");
    try writeTestProfile(tmp.dir, "project/reviewer", "{\"description\": \"Repo reviewer\"}");
    try writeTestProfile(tmp.dir, "project/tester", "{\"description\": \"Repo tester\", \"permission_mode\": \"full-access\"}");
    try writeTestProfile(tmp.dir, "project/broken", "{not json");
    try writeTestProfile(tmp.dir, "home/main", "{\"description\": \"Not fx\", \"tools\": []}");
    const roots: Roots = .{
        .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home"),
        .project = try io_mod.dirRealpathAlloc(arena, tmp.dir, "project"),
    };

    var failure: ?[]const u8 = null;
    const reviewer = try load(arena, roots, "reviewer", &failure);
    try testing.expectEqual(Source.home, reviewer.source);
    try testing.expectEqualStrings("Home reviewer", reviewer.description);
    const tester = try load(arena, roots, "tester", &failure);
    try testing.expectEqual(Source.project, tester.source);
    try testing.expect(tester.permission_mode == null);
    const agent = try load(arena, roots, "agent", &failure);
    try testing.expectEqual(Source.builtin, agent.source);
    const main = try load(arena, roots, "main", &failure);
    try testing.expectEqual(Source.builtin, main.source);
    try testing.expect(allowsTool(&main, "read_file"));
    try testing.expectError(error.InvalidProfile, load(arena, roots, "broken", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "not valid JSON") != null);
    try testing.expectError(error.ProfileNotFound, load(arena, roots, "missing", &failure));
    try testing.expectEqualStrings("no profile named 'missing'. Profiles: agent, main, reviewer, tester", failure.?);

    const entries = try list(arena, roots);
    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqualStrings("reviewer", entries[2].name);
    try testing.expectEqual(Source.home, entries[2].source);
    try testing.expectEqual(Source.builtin, entries[0].source);
}

test "a held profile replaces the last only when the next one loads, and keeps its prompt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestProfile(tmp.dir, "fxhome/.fx/agents/reviewer", "{\"description\": \"Reviewer\", \"permission_mode\": \"ask\"}");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "fxhome/.fx/agents/reviewer/prompt.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "Review only.");
    }
    const fx_home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "fxhome");
    defer testing.allocator.free(fx_home);

    var held: Held = .{};
    defer held.deinit();
    try testing.expectEqualStrings(main_name, held.profile.name);
    var failure: ?[]u8 = null;
    defer if (failure) |message| testing.allocator.free(message);
    try testing.expectError(error.ProfileNotFound, held.replace(testing.allocator, null, null, "reviewer", "BASE", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "no profile named 'reviewer'") != null);
    try testing.expectEqualStrings(main_name, held.profile.name);
    try testing.expect(held.system_prompt == null);

    // It keeps its own copy of the name it was asked for.
    var name_buf = "reviewer".*;
    try held.replace(testing.allocator, fx_home, null, &name_buf, "BASE", &failure);
    @memset(&name_buf, 'x');
    try testing.expectEqualStrings("reviewer", held.profile.name);
    try testing.expectEqual(types.PermissionMode.ask, held.profile.permission_mode.?);
    try testing.expectEqualStrings("BASE\n\nReview only.", held.system_prompt.?);
}

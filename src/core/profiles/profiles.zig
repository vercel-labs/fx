//! Agent profiles: named, saved settings for what an agent may do. Main runs
//! in one profile, `main` unless `fx --profile` names another, and each
//! subagent starts in the profile main names for it, `main` by default.
//!
//! A profile is a folder, `<name>/profile.json` with an optional
//! `<name>/prompt.md`. A name resolves from the user's `~/.fx/agents/` first,
//! then enabled mods in name order, then the repository's `.fx/agents/`, then
//! fx's own `main` and `agent`. A mod's or repository's profile never sets the
//! permission mode, so it cannot grant itself access, and its files never
//! resolve outside its own folder or repository.

const std = @import("std");
const build_options = @import("build_options");
const debug_trace = @import("../shared/debug_trace.zig");
const toolbox = @import("../tooling/toolbox.zig");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("../workspace/pathing.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const mods_mod = if (build_options.libfx) struct {} else @import("../mods/mods.zig");

const Allocator = std.mem.Allocator;

pub const max_name_bytes = 64;
pub const max_settings_bytes = 64 * 1024;
pub const max_prompt_bytes = 256 * 1024;
pub const max_list_entry_bytes = 256;

pub const settings_file_name = "profile.json";
pub const prompt_file_name = "prompt.md";
pub const main_name = "main";
pub const agent_name = "agent";

const subagent_tool = "subagent";
const wildcard = "*";

pub const Source = enum { home, mod, project, builtin };
/// Whether an agent is main or a subagent.
pub const Role = enum { main, subagent };
pub const PromptMode = enum { append, replace };

pub const IgnoredReason = enum {
    unknown_key,
    project_cannot_set_permissions,
    mod_cannot_set_permissions,
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
    /// Set when `source == .mod`: the name of the mod that defines it.
    mod_name: ?[]const u8 = null,
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
    /// Set when `source == .mod`: the name of the mod that defines it.
    mod_name: ?[]const u8 = null,
    /// The profile's own model, effort, and tools; null keeps the ones fx
    /// runs with.
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    tools: ?[]const []const u8 = null,
};

pub const ParseError = error{ OutOfMemory, InvalidProfile };
pub const LoadError = error{ OutOfMemory, InvalidProfile, ProfileNotFound, ReadFailed };

pub const ModRoot = struct {
    mod_name: []const u8,
    dir: []const u8,
    /// Containing version folder for symlink containment; defaults to `dir`.
    within: ?[]const u8 = null,
};

pub const ModClash = struct {
    name: []u8,
    mods: [][]u8,

    pub fn deinit(self: *ModClash, alloc: Allocator) void {
        alloc.free(self.name);
        for (self.mods) |m| alloc.free(m);
        alloc.free(self.mods);
        self.* = .{ .name = &.{}, .mods = &.{} };
    }
};

/// Where profiles are saved. Any may be absent.
pub const Roots = struct {
    /// `~/.fx/agents`.
    home: ?[]const u8 = null,
    /// `~/.fx/mods` (or `$FX_HOME/mods`). When set and `mod_roots` is null,
    /// readers pin enabled mods around each scan or load.
    mods_dir: ?[]const u8 = null,
    /// Explicit mod agent roots (for tests or a caller that already holds pins).
    mod_roots: ?[]const ModRoot = null,
    /// `<workspace>/.fx/agents`.
    project: ?[]const u8 = null,
    /// The workspace itself, which a repository's profile files must stay
    /// inside. Without it they must stay inside `project`.
    repository: ?[]const u8 = null,

    /// Builds roots from the fx home and the workspace. Caller owns the
    /// result through `arena`.
    pub fn init(arena: Allocator, home: ?[]const u8, workspace_root: ?[]const u8) !Roots {
        return .{
            .home = if (home) |path| try profile_paths.agentsDir(arena, path) else null,
            .mods_dir = if (comptime build_options.libfx)
                null
            else if (home) |path|
                try profile_paths.modsDir(arena, path)
            else
                null,
            .project = if (workspace_root) |root|
                try std.Io.Dir.path.join(arena, &.{ root, profile_paths.root_dir_name, profile_paths.agents_dir_name })
            else
                null,
            .repository = workspace_root,
        };
    }

    /// The folder a profile saved in `dir` must keep its files in: the
    /// repository for a repository's profile, or `within`/`dir` for a mod's.
    /// The user's own profiles may link anywhere, so theirs is null.
    fn fileRoot(self: Roots, source: Source, dir: []const u8) ?[]const u8 {
        return switch (source) {
            .project => self.repository orelse dir,
            .mod => dir,
            .home, .builtin => null,
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
        .description = "A copy of the agent that starts it",
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
            if (source == .mod) {
                try ignored.append(arena, .{ .key = key, .reason = .mod_cannot_set_permissions });
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
/// no tools allows every one, leaving its parent's in place. `behind` names
/// the built-in tools the agent's run offers through toolbox.
pub fn allowsTool(profile: *const Profile, tool: []const u8, behind: []const []const u8) bool {
    const tools = profile.tools orelse return true;
    if (listAllows(tools, tool, false)) return true;
    // A profile written for the tools toolbox replaces keeps what they gave:
    // toolbox reaches its skills and MCP tools now. One that lists a tool
    // the run keeps behind toolbox reaches it there. What toolbox runs is
    // still decided against the profile, call by call.
    if (std.mem.eql(u8, tool, toolbox.tool_name)) {
        // Leaving toolbox out by name leaves it out, whatever else is kept.
        if (listDenies(tools, toolbox.tool_name)) return false;
        for (toolbox.replaced) |name| if (listAllows(tools, name, false)) return true;
        for (behind) |name| if (listAllows(tools, name, false)) return true;
    }
    // Opening a skill, opening an MCP tool, and searching are each named for
    // the tool they replaced; a profile that lists toolbox itself allows all
    // three, apart from one it leaves out by name.
    if (toolbox.isReplaced(tool)) return !listDenies(tools, tool) and listAllows(tools, toolbox.tool_name, false);
    return false;
}

/// Whether `entries` leaves `name` out with a `!name` entry.
fn listDenies(entries: []const []const u8, name: []const u8) bool {
    for (entries) |entry| {
        if (entry.len > 1 and entry[0] == '!' and std.mem.eql(u8, entry[1..], name)) return true;
    }
    return false;
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

/// Loads the profile named `name`: the user's own, then enabled mods in name
/// order, then the repository's, then fx's. `main` is always fx's own. On
/// failure, `failure` holds a message for the user. The result belongs to
/// `arena`.
pub fn load(arena: Allocator, roots: Roots, name: []const u8, failure: *?[]const u8) LoadError!Profile {
    if (!validName(name)) return fail(arena, failure, "profile name '{s}' must use lowercase letters, digits, '-', or '_'", .{name});
    if (std.mem.eql(u8, name, main_name)) return builtin(main_name).?;
    // The profile keeps its name, so it is `arena`'s like the rest of it,
    // not the caller's.
    const owned = try arena.dupe(u8, name);
    if (roots.home) |dir| if (try readProfile(arena, dir, owned, .home, roots.fileRoot(.home, dir), failure)) |profile| return profile;
    if (try loadFromConfiguredMods(arena, roots, owned, failure)) |profile| return profile;
    if (roots.project) |dir| if (try readProfile(arena, dir, owned, .project, roots.fileRoot(.project, dir), failure)) |profile| return profile;
    if (builtin(name)) |profile| return profile;
    const names = try listNames(arena, roots);
    failure.* = try arena.print("no profile named '{s}'. Profiles: {s}", .{ name, names });
    return error.ProfileNotFound;
}

/// Loads `name` only from the enabled mod `mod_name` (used on child resume so
/// another source cannot hijack or shadow the profile). Pins enabled mods
/// while reading and releases them before returning.
pub fn loadFromMod(
    arena: Allocator,
    mods_dir: ?[]const u8,
    mod_name: []const u8,
    name: []const u8,
    failure: *?[]const u8,
) LoadError!Profile {
    if (comptime build_options.libfx) return error.ProfileNotFound;
    if (!validName(name)) return fail(arena, failure, "profile name '{s}' must use lowercase letters, digits, '-', or '_'", .{name});
    if (std.mem.eql(u8, name, main_name)) return builtin(main_name).?;
    const root_path = mods_dir orelse return error.ProfileNotFound;
    const Ctx = struct {
        arena: Allocator,
        mod_name: []const u8,
        name: []const u8,
        failure: *?[]const u8,
    };
    const Body = struct {
        fn run(ctx: Ctx, pinned: *const mods_mod.ModPins) anyerror!?Profile {
            traceModPinProblems("loadFromMod", pinned.problems);
            for (pinned.pins) |p| {
                if (!std.mem.eql(u8, p.name, ctx.mod_name)) continue;
                const agents_dir = try std.Io.Dir.path.join(ctx.arena, &.{ p.path, profile_paths.agents_dir_name });
                const owned = try ctx.arena.dupe(u8, ctx.name);
                var loaded = (try readProfile(ctx.arena, agents_dir, owned, .mod, p.path, ctx.failure)) orelse return null;
                loaded.mod_name = try ctx.arena.dupe(u8, p.name);
                return loaded;
            }
            return null;
        }
    };
    const result = mods_mod.withPinnedMods(arena, root_path, Ctx{
        .arena = arena,
        .mod_name = mod_name,
        .name = name,
        .failure = failure,
    }, ?Profile, Body.run) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidProfile => return error.InvalidProfile,
        error.ReadFailed => return error.ReadFailed,
        else => {
            debug_trace.logf("profile", "mod_pins_load_failed op=loadFromMod mod={s} err={s}", .{ mod_name, @errorName(err) });
            return error.ProfileNotFound;
        },
    };
    return result orelse error.ProfileNotFound;
}

fn loadFromConfiguredMods(arena: Allocator, roots: Roots, owned_name: []const u8, failure: *?[]const u8) LoadError!?Profile {
    if (comptime build_options.libfx) return null;
    if (roots.mod_roots) |mod_roots| {
        return loadFromModRoots(arena, mod_roots, owned_name, failure);
    }
    const root_path = roots.mods_dir orelse return null;
    const Ctx = struct {
        arena: Allocator,
        name: []const u8,
        failure: *?[]const u8,
    };
    const Body = struct {
        fn run(ctx: Ctx, pinned: *const mods_mod.ModPins) anyerror!?Profile {
            traceModPinProblems("load", pinned.problems);
            var mod_roots = try pinned.roots(ctx.arena, .agents);
            defer mod_roots.deinit(ctx.arena);
            const adapted = try modRootsFromPinned(ctx.arena, mod_roots.items);
            return try loadFromModRoots(ctx.arena, adapted, ctx.name, ctx.failure);
        }
    };
    return mods_mod.withPinnedMods(arena, root_path, Ctx{
        .arena = arena,
        .name = owned_name,
        .failure = failure,
    }, ?Profile, Body.run) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidProfile => return error.InvalidProfile,
        error.ReadFailed => return error.ReadFailed,
        else => {
            debug_trace.logf("profile", "mod_pins_load_failed op=load err={s}", .{@errorName(err)});
            return null;
        },
    };
}

fn modRootsFromPinned(arena: Allocator, items: []const mods_mod.ModRoot) Allocator.Error![]ModRoot {
    const out = try arena.alloc(ModRoot, items.len);
    for (items, out) |item, *slot| {
        slot.* = .{
            .mod_name = item.mod_name,
            .dir = item.path,
            .within = std.Io.Dir.path.dirname(item.path) orelse item.path,
        };
    }
    return out;
}

fn loadFromModRoots(arena: Allocator, mod_roots: []const ModRoot, owned_name: []const u8, failure: *?[]const u8) LoadError!?Profile {
    var matches: std.ArrayList(ModRoot) = .empty;
    for (mod_roots) |root| {
        if (try hasProfileSettings(arena, root.dir, owned_name)) {
            try matches.append(arena, root);
        }
    }
    if (matches.items.len == 0) return null;
    if (matches.items.len >= 2) {
        var mod_names: std.ArrayList(u8) = .empty;
        for (matches.items, 0..) |m, index| {
            if (index > 0) try mod_names.appendSlice(arena, ", ");
            try mod_names.appendSlice(arena, m.mod_name);
        }
        return fail(arena, failure, "profile '{s}' is defined by multiple mods ({s}); remove or disable one", .{ owned_name, mod_names.items });
    }
    const matched = matches.items[0];
    var loaded = (try readProfile(arena, matched.dir, owned_name, .mod, matched.within orelse matched.dir, failure)) orelse return null;
    loaded.mod_name = try arena.dupe(u8, matched.mod_name);
    return loaded;
}

fn hasProfileSettings(arena: Allocator, dir_path: []const u8, name: []const u8) Allocator.Error!bool {
    const settings_path = try std.Io.Dir.path.join(arena, &.{ dir_path, name, settings_file_name });
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), settings_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return true,
    };
    file.close(io_mod.getIo());
    return true;
}

fn traceModPinProblems(op: []const u8, problems: []const []u8) void {
    for (problems) |problem| {
        debug_trace.logf("profile", "mod_pin_skipped op={s} problem={s}", .{ op, problem });
    }
}

/// Every profile main can pick, by name, with the user's own over enabled
/// mods over the repository's over fx's. A profile that fails to load, or a
/// name defined by two or more enabled mods, is left out. The result belongs to
/// `arena` and is sorted by name.
pub fn list(arena: Allocator, roots: Roots) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var clashed_mod_names: std.ArrayList([]const u8) = .empty;
    if (roots.home) |dir_path| try listDirInto(arena, &entries, &clashed_mod_names, dir_path, .home, null, roots.fileRoot(.home, dir_path));
    try listModsInto(arena, &entries, &clashed_mod_names, roots);
    if (roots.project) |dir_path| try listDirInto(arena, &entries, &clashed_mod_names, dir_path, .project, null, roots.fileRoot(.project, dir_path));
    for ([_][]const u8{ main_name, agent_name }) |name| {
        if (hasEntry(entries.items, name) or hasName(clashed_mod_names.items, name)) continue;
        const profile = builtin(name).?;
        try entries.append(arena, .{ .name = profile.name, .description = profile.description, .source = .builtin, .model = profile.model, .effort = profile.effort, .tools = profile.tools });
    }
    sort_utils.sort(Entry, entries.items, {}, entryLessThan);
    return entries.items;
}

fn listDirInto(
    arena: Allocator,
    entries: *std.ArrayList(Entry),
    clashed_mod_names: *const std.ArrayList([]const u8),
    dir_path: []const u8,
    source: Source,
    mod_name: ?[]const u8,
    within: ?[]const u8,
) Allocator.Error!void {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io_mod.getIo());
    var it = dir.iterate();
    while (it.next(io_mod.getIo()) catch null) |item| {
        if (item.kind != .directory or !validName(item.name)) continue;
        if (std.mem.eql(u8, item.name, main_name)) continue;
        if (hasEntry(entries.items, item.name) or hasName(clashed_mod_names.items, item.name)) continue;
        const name = try arena.dupe(u8, item.name);
        var failure: ?[]const u8 = null;
        const profile = (readProfile(arena, dir_path, name, source, within, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        }) orelse continue;
        try entries.append(arena, .{
            .name = profile.name,
            .description = profile.description,
            .source = profile.source,
            .mod_name = if (mod_name) |m| try arena.dupe(u8, m) else null,
            .model = profile.model,
            .effort = profile.effort,
            .tools = profile.tools,
        });
    }
}

fn listModsInto(
    arena: Allocator,
    entries: *std.ArrayList(Entry),
    clashed_mod_names: *std.ArrayList([]const u8),
    roots: Roots,
) Allocator.Error!void {
    if (comptime build_options.libfx) return;
    if (roots.mod_roots) |mod_roots| {
        try listModRootsInto(arena, entries, clashed_mod_names, mod_roots);
        return;
    }
    const root_path = roots.mods_dir orelse return;
    const Ctx = struct {
        arena: Allocator,
        entries: *std.ArrayList(Entry),
        clashed: *std.ArrayList([]const u8),
    };
    const Body = struct {
        fn run(ctx: Ctx, pinned: *const mods_mod.ModPins) anyerror!void {
            traceModPinProblems("list", pinned.problems);
            var mod_roots = try pinned.roots(ctx.arena, .agents);
            defer mod_roots.deinit(ctx.arena);
            const adapted = try modRootsFromPinned(ctx.arena, mod_roots.items);
            try listModRootsInto(ctx.arena, ctx.entries, ctx.clashed, adapted);
        }
    };
    mods_mod.withPinnedMods(arena, root_path, Ctx{
        .arena = arena,
        .entries = entries,
        .clashed = clashed_mod_names,
    }, void, Body.run) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => debug_trace.logf("profile", "mod_pins_load_failed op=list err={s}", .{@errorName(err)}),
    };
}

fn listModRootsInto(
    arena: Allocator,
    entries: *std.ArrayList(Entry),
    clashed_mod_names: *std.ArrayList([]const u8),
    mod_roots: []const ModRoot,
) Allocator.Error!void {
    const SeenMod = struct {
        name: []const u8,
        entry_index: ?usize,
        clashed: bool = false,
    };
    var seen: std.ArrayList(SeenMod) = .empty;
    var mod_entries: std.ArrayList(Entry) = .empty;

    for (mod_roots) |mod_root| {
        var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), mod_root.dir, .{ .iterate = true }) catch continue;
        defer dir.close(io_mod.getIo());
        var it = dir.iterate();
        while (it.next(io_mod.getIo()) catch null) |item| {
            if (item.kind != .directory or !validName(item.name)) continue;
            if (std.mem.eql(u8, item.name, main_name)) continue;
            if (hasEntry(entries.items, item.name)) continue;
            if (!(try hasProfileSettings(arena, mod_root.dir, item.name))) continue;

            var existing_idx: ?usize = null;
            for (seen.items, 0..) |s, idx| {
                if (std.mem.eql(u8, s.name, item.name)) {
                    existing_idx = idx;
                    break;
                }
            }
            if (existing_idx) |idx| {
                if (!seen.items[idx].clashed) {
                    seen.items[idx].clashed = true;
                    try clashed_mod_names.append(arena, seen.items[idx].name);
                }
                continue;
            }

            const name = try arena.dupe(u8, item.name);
            var failure: ?[]const u8 = null;
            const within = mod_root.within orelse mod_root.dir;
            const loaded = readProfile(arena, mod_root.dir, name, .mod, within, &failure) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (loaded) |profile| {
                const entry_idx = mod_entries.items.len;
                try mod_entries.append(arena, .{
                    .name = profile.name,
                    .description = profile.description,
                    .source = .mod,
                    .mod_name = try arena.dupe(u8, mod_root.mod_name),
                    .model = profile.model,
                    .effort = profile.effort,
                    .tools = profile.tools,
                });
                try seen.append(arena, .{ .name = name, .entry_index = entry_idx });
            } else {
                try seen.append(arena, .{ .name = name, .entry_index = null });
            }
        }
    }

    for (seen.items) |s| {
        if (s.clashed) continue;
        const idx = s.entry_index orelse continue;
        try entries.append(arena, mod_entries.items[idx]);
    }
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

fn hasName(names: []const []const u8, target: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, target)) return true;
    return false;
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Folder entries `listForCompletion` reads across both roots, counting every
/// one, profile or not.
const max_completion_dir_entries = 128;
/// `profile.json` bytes `listForCompletion` reads across every profile.
const max_completion_settings_bytes = 1024 * 1024;

/// Profiles to offer as completions. `limited` says the scan stopped at a
/// bound or skipped a file too large to read, so profiles may be missing.
pub const CompletionList = struct {
    entries: []Entry,
    limited: bool,

    /// Frees what `listForCompletion` returned, for an `alloc` that is not an
    /// arena.
    pub fn deinit(self: CompletionList, alloc: Allocator) void {
        freeEntries(alloc, self.entries);
        alloc.free(self.entries);
    }
};

/// Like `list`, but bounded for completion: it reads at most
/// `max_completion_dir_entries` folder entries and
/// `max_completion_settings_bytes` of settings, and never reads `prompt.md`.
/// The user's own still win over enabled mods over the repository's, fx's
/// `main` and `agent` are always there (unless shadowed by a mod clash), and
/// the entries are sorted by name. Every slice of the result belongs to
/// `alloc`.
pub fn listForCompletion(alloc: Allocator, roots: Roots) Allocator.Error!CompletionList {
    const io = io_mod.getIo();
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        freeEntries(alloc, entries.items);
        entries.deinit(alloc);
    }
    var scan_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer scan_arena_state.deinit();
    const scan_arena = scan_arena_state.allocator();
    // Holds one profile's paths, settings, parsed JSON, and failure message,
    // reset before the next so a scan of failing profiles stays bounded.
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    var visited: usize = 0;
    var budget: usize = max_completion_settings_bytes;
    var limited = false;
    var clashed_mod_names: std.ArrayList([]const u8) = .empty;

    if (roots.home) |dir_path| {
        try listCompletionDirInto(
            alloc,
            io,
            &scratch_state,
            &entries,
            &clashed_mod_names,
            dir_path,
            .home,
            roots.fileRoot(.home, dir_path),
            &visited,
            &budget,
            &limited,
        );
    }
    if (!limited) {
        try listCompletionModsInto(
            alloc,
            scan_arena,
            io,
            &scratch_state,
            &entries,
            &clashed_mod_names,
            roots,
            &visited,
            &budget,
            &limited,
        );
    }
    if (!limited) {
        if (roots.project) |dir_path| {
            try listCompletionDirInto(
                alloc,
                io,
                &scratch_state,
                &entries,
                &clashed_mod_names,
                dir_path,
                .project,
                roots.fileRoot(.project, dir_path),
                &visited,
                &budget,
                &limited,
            );
        }
    }
    for ([_][]const u8{ main_name, agent_name }) |name| {
        if (hasEntry(entries.items, name) or hasName(clashed_mod_names.items, name)) continue;
        try entries.ensureUnusedCapacity(alloc, 1);
        entries.appendAssumeCapacity(try cloneEntry(alloc, builtin(name).?));
    }
    sort_utils.sort(Entry, entries.items, {}, entryLessThan);
    return .{ .entries = try entries.toOwnedSlice(alloc), .limited = limited };
}

fn listCompletionDirInto(
    alloc: Allocator,
    io: std.Io,
    scratch_state: *std.heap.ArenaAllocator,
    entries: *std.ArrayList(Entry),
    clashed_mod_names: *const std.ArrayList([]const u8),
    dir_path: []const u8,
    source: Source,
    within: ?[]const u8,
    visited: *usize,
    budget: *usize,
    limited: *bool,
) Allocator.Error!void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch {
        limited.* = true;
        return;
    }) |item| {
        visited.* += 1;
        if (visited.* > max_completion_dir_entries) {
            limited.* = true;
            return;
        }
        if (item.kind != .directory or !validName(item.name)) continue;
        if (std.mem.eql(u8, item.name, main_name)) continue;
        if (hasEntry(entries.items, item.name) or hasName(clashed_mod_names.items, item.name)) continue;
        _ = scratch_state.reset(.retain_capacity);
        const read = try readCompletionProfile(scratch_state.allocator(), dir_path, item.name, source, within, budget.*);
        budget.* -= read.bytes;
        switch (read.outcome) {
            .missing, .invalid => {},
            .too_large => limited.* = true,
            // A profile left unread may outrank a later one of the same
            // name, so the scan stops rather than offer the wrong one.
            .over_budget => {
                limited.* = true;
                return;
            },
            .loaded => |profile| {
                try entries.ensureUnusedCapacity(alloc, 1);
                entries.appendAssumeCapacity(try cloneEntry(alloc, profile));
            },
        }
    }
}

fn listCompletionModsInto(
    alloc: Allocator,
    scan_arena: Allocator,
    io: std.Io,
    scratch_state: *std.heap.ArenaAllocator,
    entries: *std.ArrayList(Entry),
    clashed_mod_names: *std.ArrayList([]const u8),
    roots: Roots,
    visited: *usize,
    budget: *usize,
    limited: *bool,
) Allocator.Error!void {
    if (comptime build_options.libfx) return;
    if (roots.mod_roots) |mod_roots| {
        try listCompletionModRootsInto(alloc, scan_arena, io, scratch_state, entries, clashed_mod_names, mod_roots, visited, budget, limited);
        return;
    }
    const root_path = roots.mods_dir orelse return;
    const Ctx = struct {
        alloc: Allocator,
        scan_arena: Allocator,
        io: std.Io,
        scratch_state: *std.heap.ArenaAllocator,
        entries: *std.ArrayList(Entry),
        clashed: *std.ArrayList([]const u8),
        visited: *usize,
        budget: *usize,
        limited: *bool,
    };
    const Body = struct {
        fn run(ctx: Ctx, pinned: *const mods_mod.ModPins) anyerror!void {
            traceModPinProblems("listForCompletion", pinned.problems);
            var mod_roots = try pinned.roots(ctx.scan_arena, .agents);
            defer mod_roots.deinit(ctx.scan_arena);
            const adapted = try modRootsFromPinned(ctx.scan_arena, mod_roots.items);
            try listCompletionModRootsInto(
                ctx.alloc,
                ctx.scan_arena,
                ctx.io,
                ctx.scratch_state,
                ctx.entries,
                ctx.clashed,
                adapted,
                ctx.visited,
                ctx.budget,
                ctx.limited,
            );
        }
    };
    mods_mod.withPinnedMods(scan_arena, root_path, Ctx{
        .alloc = alloc,
        .scan_arena = scan_arena,
        .io = io,
        .scratch_state = scratch_state,
        .entries = entries,
        .clashed = clashed_mod_names,
        .visited = visited,
        .budget = budget,
        .limited = limited,
    }, void, Body.run) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => debug_trace.logf("profile", "mod_pins_load_failed op=listForCompletion err={s}", .{@errorName(err)}),
    };
}

fn listCompletionModRootsInto(
    alloc: Allocator,
    scan_arena: Allocator,
    io: std.Io,
    scratch_state: *std.heap.ArenaAllocator,
    entries: *std.ArrayList(Entry),
    clashed_mod_names: *std.ArrayList([]const u8),
    mod_roots: []const ModRoot,
    visited: *usize,
    budget: *usize,
    limited: *bool,
) Allocator.Error!void {
    const SeenMod = struct {
        name: []const u8,
        entry_index: ?usize,
        clashed: bool = false,
    };
    var seen: std.ArrayList(SeenMod) = .empty;
    var mod_entries: std.ArrayList(Entry) = .empty;
    errdefer {
        freeEntries(alloc, mod_entries.items);
        mod_entries.deinit(alloc);
    }

    scan: for (mod_roots) |mod_root| {
        var dir = std.Io.Dir.openDirAbsolute(io, mod_root.dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch {
            limited.* = true;
            break :scan;
        }) |item| {
            visited.* += 1;
            if (visited.* > max_completion_dir_entries) {
                limited.* = true;
                break :scan;
            }
            if (item.kind != .directory or !validName(item.name)) continue;
            if (std.mem.eql(u8, item.name, main_name)) continue;
            if (hasEntry(entries.items, item.name)) continue;
            if (!(try hasProfileSettings(scan_arena, mod_root.dir, item.name))) continue;

            var existing_idx: ?usize = null;
            for (seen.items, 0..) |s, idx| {
                if (std.mem.eql(u8, s.name, item.name)) {
                    existing_idx = idx;
                    break;
                }
            }
            if (existing_idx) |idx| {
                if (!seen.items[idx].clashed) {
                    seen.items[idx].clashed = true;
                    try clashed_mod_names.append(scan_arena, seen.items[idx].name);
                }
                continue;
            }

            const owned_name = try scan_arena.dupe(u8, item.name);
            _ = scratch_state.reset(.retain_capacity);
            const within = mod_root.within orelse mod_root.dir;
            const read = try readCompletionProfile(scratch_state.allocator(), mod_root.dir, item.name, .mod, within, budget.*);
            budget.* -= read.bytes;
            switch (read.outcome) {
                .missing, .invalid => {
                    try seen.append(scan_arena, .{ .name = owned_name, .entry_index = null });
                },
                .too_large => {
                    limited.* = true;
                    try seen.append(scan_arena, .{ .name = owned_name, .entry_index = null });
                },
                .over_budget => {
                    limited.* = true;
                    break :scan;
                },
                .loaded => |profile| {
                    var copy = profile;
                    copy.mod_name = mod_root.mod_name;
                    const cloned = try cloneEntry(alloc, copy);
                    errdefer freeEntry(alloc, cloned);
                    try mod_entries.append(alloc, cloned);
                    try seen.append(scan_arena, .{ .name = owned_name, .entry_index = mod_entries.items.len - 1 });
                },
            }
        }
    }

    for (mod_entries.items, 0..) |entry, idx| {
        const keep = for (seen.items) |s| {
            if (s.entry_index == idx) break !s.clashed;
        } else false;
        if (keep) {
            try entries.append(alloc, entry);
        } else {
            freeEntry(alloc, entry);
        }
    }
    mod_entries.deinit(alloc);
}

const CompletionRead = struct {
    /// Settings bytes read, counted against the budget whether or not they
    /// parsed.
    bytes: usize = 0,
    outcome: union(enum) {
        missing,
        invalid,
        /// Larger than `max_settings_bytes`, which `load` refuses too.
        too_large,
        /// Larger than what was left of the budget.
        over_budget,
        loaded: Profile,
    },
};

/// Reads and parses `<dir>/<name>/profile.json` alone into `scratch`, reading
/// no more than `budget` bytes.
fn readCompletionProfile(
    scratch: Allocator,
    dir: []const u8,
    name: []const u8,
    source: Source,
    within: ?[]const u8,
    budget: usize,
) Allocator.Error!CompletionRead {
    const limit = @min(max_settings_bytes, budget);
    if (limit == 0) return .{ .outcome = .over_budget };
    const settings_path = try std.Io.Dir.path.join(scratch, &.{ dir, name, settings_file_name });
    const settings = readFile(scratch, settings_path, limit, within) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => .{ .outcome = .missing },
        error.StreamTooLong => .{
            .bytes = limit,
            .outcome = if (limit < max_settings_bytes) .over_budget else .too_large,
        },
        else => .{ .outcome = .invalid },
    };
    var failure: ?[]const u8 = null;
    const profile = parse(scratch, name, source, settings, "", &failure) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidProfile => .{ .bytes = settings.len, .outcome = .invalid },
    };
    return .{ .bytes = settings.len, .outcome = .{ .loaded = profile } };
}

/// Copies the parts of `profile` an `Entry` keeps into `alloc`.
fn cloneEntry(alloc: Allocator, profile: Profile) Allocator.Error!Entry {
    const name = try alloc.dupe(u8, profile.name);
    errdefer alloc.free(name);
    const description = try alloc.dupe(u8, profile.description);
    errdefer alloc.free(description);
    const mod_name = if (profile.mod_name) |text| try alloc.dupe(u8, text) else null;
    errdefer if (mod_name) |text| alloc.free(text);
    const model = if (profile.model) |text| try alloc.dupe(u8, text) else null;
    errdefer if (model) |text| alloc.free(text);
    const tools = if (profile.tools) |names| try cloneNames(alloc, names) else null;
    return .{
        .name = name,
        .description = description,
        .source = profile.source,
        .mod_name = mod_name,
        .model = model,
        .effort = profile.effort,
        .tools = tools,
    };
}

/// A copy of `names` that `alloc` owns, each name and the list itself.
pub fn cloneNames(alloc: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try alloc.alloc([]const u8, names.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |text| alloc.free(text);
        alloc.free(out);
    }
    for (names, out) |text, *slot| {
        slot.* = try alloc.dupe(u8, text);
        done += 1;
    }
    return out;
}

fn freeEntry(alloc: Allocator, entry: Entry) void {
    alloc.free(entry.name);
    alloc.free(entry.description);
    if (entry.mod_name) |text| alloc.free(text);
    if (entry.model) |text| alloc.free(text);
    if (entry.tools) |names| {
        for (names) |text| alloc.free(text);
        alloc.free(names);
    }
}

fn freeEntries(alloc: Allocator, entries: []const Entry) void {
    for (entries) |entry| freeEntry(alloc, entry);
}

/// Returns every profile name defined by two or more enabled mods (when not
/// shadowed by `~/.fx/agents/`), for `fx doctor`. Caller frees each element
/// via `ModClash.deinit` and the outer slice.
pub fn findModClashes(alloc: Allocator, home: ?[]const u8) ![]ModClash {
    if (comptime build_options.libfx) return &.{};
    const root_path = if (home) |h| try profile_paths.modsDir(alloc, h) else return &.{};
    defer alloc.free(root_path);
    const home_agents = if (home) |h| try profile_paths.agentsDir(alloc, h) else null;
    defer if (home_agents) |dir| alloc.free(dir);
    return findModClashesIn(alloc, home_agents, root_path);
}

pub fn findModClashesIn(alloc: Allocator, home_agents: ?[]const u8, mods_dir: []const u8) ![]ModClash {
    if (comptime build_options.libfx) return &.{};

    const Ctx = struct {
        alloc: Allocator,
        home_agents: ?[]const u8,
    };
    const Body = struct {
        fn run(ctx: Ctx, pinned: *const mods_mod.ModPins) anyerror![]ModClash {
            traceModPinProblems("findModClashes", pinned.problems);
            var scratch_state = std.heap.ArenaAllocator.init(ctx.alloc);
            defer scratch_state.deinit();
            const scratch = scratch_state.allocator();

            var mod_roots = try pinned.roots(scratch, .agents);
            defer mod_roots.deinit(scratch);

            const Seen = struct {
                name: []const u8,
                mods: std.ArrayList([]const u8),
            };
            var seen: std.ArrayList(Seen) = .empty;
            for (mod_roots.items) |mod_root| {
                var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), mod_root.path, .{ .iterate = true }) catch continue;
                defer dir.close(io_mod.getIo());
                var it = dir.iterate();
                while (it.next(io_mod.getIo()) catch null) |item| {
                    if (item.kind != .directory or !validName(item.name)) continue;
                    if (std.mem.eql(u8, item.name, main_name)) continue;
                    if (!(try hasProfileSettings(scratch, mod_root.path, item.name))) continue;
                    if (ctx.home_agents) |h_dir| {
                        if (try hasProfileSettings(scratch, h_dir, item.name)) continue;
                    }
                    var slot: ?*Seen = null;
                    for (seen.items) |*s| {
                        if (std.mem.eql(u8, s.name, item.name)) {
                            slot = s;
                            break;
                        }
                    }
                    if (slot) |s| {
                        try s.mods.append(scratch, mod_root.mod_name);
                    } else {
                        var list_mods: std.ArrayList([]const u8) = .empty;
                        try list_mods.append(scratch, mod_root.mod_name);
                        try seen.append(scratch, .{
                            .name = try scratch.dupe(u8, item.name),
                            .mods = list_mods,
                        });
                    }
                }
            }

            var out: std.ArrayList(ModClash) = .empty;
            errdefer {
                for (out.items) |*c| c.deinit(ctx.alloc);
                out.deinit(ctx.alloc);
            }
            for (seen.items) |s| {
                if (s.mods.items.len < 2) continue;
                const name_copy = try ctx.alloc.dupe(u8, s.name);
                errdefer ctx.alloc.free(name_copy);
                const mods_copy = try ctx.alloc.alloc([]u8, s.mods.items.len);
                var filled: usize = 0;
                errdefer {
                    for (mods_copy[0..filled]) |m| ctx.alloc.free(m);
                    ctx.alloc.free(mods_copy);
                }
                for (s.mods.items, mods_copy) |m, *dst| {
                    dst.* = try ctx.alloc.dupe(u8, m);
                    filled += 1;
                }
                try out.append(ctx.alloc, .{ .name = name_copy, .mods = mods_copy });
            }
            sort_utils.sort(ModClash, out.items, {}, struct {
                fn lessThan(_: void, a: ModClash, b: ModClash) bool {
                    return std.mem.lessThan(u8, a.name, b.name);
                }
            }.lessThan);
            return try out.toOwnedSlice(ctx.alloc);
        }
    };
    return mods_mod.withPinnedMods(alloc, mods_dir, Ctx{
        .alloc = alloc,
        .home_agents = home_agents,
    }, []ModClash, Body.run) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("profile", "mod_pins_load_failed op=findModClashes err={s}", .{@errorName(err)});
            return &.{};
        },
    };
}

/// Reads `<dir>/<name>/profile.json` and its optional `prompt.md`. Returns null
/// when the profile is not saved there. With `within`, both files must
/// resolve inside that folder (`Roots.fileRoot`).
fn readProfile(
    arena: Allocator,
    dir: []const u8,
    name: []const u8,
    source: Source,
    within: ?[]const u8,
    failure: *?[]const u8,
) LoadError!?Profile {
    const settings_path = try std.Io.Dir.path.join(arena, &.{ dir, name, settings_file_name });
    const settings = readFile(arena, settings_path, max_settings_bytes, within) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, settings_path, try readFailure(arena, err, max_settings_bytes, source) }),
    };
    const prompt_path = try std.Io.Dir.path.join(arena, &.{ dir, name, prompt_file_name });
    const prompt = readFile(arena, prompt_path, max_prompt_bytes, within) catch |err| switch (err) {
        error.FileNotFound => "",
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, prompt_path, try readFailure(arena, err, max_prompt_bytes, source) }),
    };
    return parse(arena, name, source, settings, prompt, failure) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidProfile => error.InvalidProfile,
    };
}

/// Why a profile file couldn't be read, in words, with the error's name when
/// there are none for it. A link out of the profile's folder names where the
/// profile comes from. The result belongs to `arena`.
fn readFailure(arena: Allocator, err: anyerror, max_bytes: usize, source: Source) Allocator.Error![]const u8 {
    return switch (err) {
        error.StreamTooLong => if (max_bytes == max_prompt_bytes)
            "it is larger than the 256 KiB a profile file may hold"
        else
            "it is larger than the 64 KiB a profile file may hold",
        error.AccessDenied, error.PermissionDenied => "fx isn't allowed to read it",
        error.IsDir => "it is a folder, not a file",
        error.NotRegularFile => "it isn't a regular file",
        error.OutsideRepository => if (source == .mod)
            "it links outside the mod, and a mod's profile may read only its own files"
        else
            "it links outside the repository, and a repository's profile may read only its own files",
        else => try arena.print("the file couldn't be read ({s})", .{@errorName(err)}),
    };
}

test "profile read failures name the limit or the cause instead of an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(std.mem.find(u8, try readFailure(arena, error.StreamTooLong, max_prompt_bytes, .project), "256 KiB") != null);
    try std.testing.expect(std.mem.find(u8, try readFailure(arena, error.StreamTooLong, max_settings_bytes, .project), "64 KiB") != null);
    try std.testing.expectEqualStrings("it is a folder, not a file", try readFailure(arena, error.IsDir, max_prompt_bytes, .project));
    try std.testing.expectEqualStrings("the file couldn't be read (SymLinkLoop)", try readFailure(arena, error.SymLinkLoop, max_prompt_bytes, .project));
    // A link out of the folder names the profile's own origin.
    try std.testing.expect(std.mem.find(u8, try readFailure(arena, error.OutsideRepository, max_prompt_bytes, .project), "outside the repository") != null);
    try std.testing.expectEqualStrings(
        "it links outside the mod, and a mod's profile may read only its own files",
        try readFailure(arena, error.OutsideRepository, max_prompt_bytes, .mod),
    );
}

test "profile parsing stays bounded on fuzzed settings and prompts" {
    try std.testing.fuzz({}, fuzzProfileParse, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{}",
            "{\"tools\": [\"read_file\"], \"prompt\": \"replace\"}",
            "{\"mcp_servers\": [\"*\"], \"model\": \"openai/gpt-5\", \"effort\": \"low\"}",
            "{\"tools\": 3, \"unknown\": null}",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").profile_parse.*),
    });
}

fn fuzzProfileParse(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var settings_buffer: [4096]u8 = undefined;
    const settings = settings_buffer[0..@intCast(smith.slice(&settings_buffer))];
    var prompt_buffer: [512]u8 = undefined;
    const prompt = prompt_buffer[0..@intCast(smith.slice(&prompt_buffer))];
    var failure: ?[]const u8 = null;
    const profile = parse(arena.allocator(), "fuzz", .project, settings, prompt, &failure) catch |err| switch (err) {
        // A refused profile always says why.
        error.InvalidProfile => return std.testing.expect(failure != null),
        error.OutOfMemory => return err,
    };
    try std.testing.expectEqualStrings("fuzz", profile.name);
}

/// Reads the profile file at `path`, up to `max_bytes`, into `arena`. It
/// reads only a regular file, so a link to a terminal, a pipe, or a device
/// can neither hang fx nor feed it. With `within`, the file's real path must
/// lie inside that folder, so a link can't hand a repository's or a mod's
/// profile a file from elsewhere on the machine.
fn readFile(arena: Allocator, path: []const u8, max_bytes: usize, within: ?[]const u8) ![]u8 {
    const io = io_mod.getIo();
    const target = try io_mod.realpathAlloc(arena, path);
    if (within) |root_path| {
        const root = try io_mod.realpathAlloc(arena, root_path);
        if (!pathing.pathInside(root, target)) return error.OutsideRepository;
    }
    // Checked before opening: opening a pipe waits for a writer.
    const stat = try std.Io.Dir.cwd().statFile(io, target, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .file => {},
        .directory => return error.IsDir,
        else => return error.NotRegularFile,
    }
    var file = try std.Io.Dir.openFileAbsolute(io, target, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    // The path may have changed since the check.
    if ((try file.stat(io)).kind != .file) return error.NotRegularFile;
    return io_mod.readFileToEnd(arena, &file, max_bytes);
}

/// Saves `target` at `sub_path` as a link, creating its folders.
fn linkTestFile(dir: std.Io.Dir, target: []const u8, sub_path: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try dir.createDirPath(io_mod.getIo(), parent);
    try dir.symLink(io_mod.getIo(), target, sub_path, .{ .is_directory = false });
}

/// Saves `bytes` at `sub_path`, creating its folders. For tests, here and in
/// other files.
pub fn writeTestFile(dir: std.Io.Dir, sub_path: []const u8, bytes: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try dir.createDirPath(io_mod.getIo(), parent);
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), bytes);
}

test "a repository's profile reads only files inside the repository" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "outside/secret.txt", "SECRET");
    try writeTestFile(tmp.dir, "repo/prompts/review.md", "Review only.");
    const outside_secret = try io_mod.dirRealpathAlloc(arena, tmp.dir, "outside/secret.txt");
    const inside_prompt = try io_mod.dirRealpathAlloc(arena, tmp.dir, "repo/prompts/review.md");
    try writeTestProfile(tmp.dir, "repo/.fx/agents/evil", "{\"description\": \"Evil\"}");
    try linkTestFile(tmp.dir, outside_secret, "repo/.fx/agents/evil/prompt.md");
    try writeTestProfile(tmp.dir, "repo/.fx/agents/shared", "{\"description\": \"Shared prompt\"}");
    try linkTestFile(tmp.dir, inside_prompt, "repo/.fx/agents/shared/prompt.md");
    try writeTestFile(tmp.dir, "outside/settings/profile.json", "{\"description\": \"Elsewhere\"}");
    try linkTestFile(tmp.dir, try io_mod.dirRealpathAlloc(arena, tmp.dir, "outside/settings/profile.json"), "repo/.fx/agents/far/profile.json");
    const roots = try Roots.init(arena, null, try io_mod.dirRealpathAlloc(arena, tmp.dir, "repo"));

    var failure: ?[]const u8 = null;
    try testing.expectError(error.InvalidProfile, load(arena, roots, "evil", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "links outside the repository") != null);
    try testing.expectError(error.InvalidProfile, load(arena, roots, "far", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "links outside the repository") != null);
    // A link that stays inside the repository is read.
    const shared = try load(arena, roots, "shared", &failure);
    try testing.expectEqualStrings("Review only.", shared.prompt);
    // Neither refused profile is offered.
    const entries = try list(arena, roots);
    for (entries) |entry| try testing.expect(!std.mem.eql(u8, entry.name, "evil") and !std.mem.eql(u8, entry.name, "far"));
}

test "a profile reads only regular files, and the user's own may link anywhere" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "dotfiles/review.md", "Review only.");
    try writeTestProfile(tmp.dir, "home/linked", "{\"description\": \"Linked\"}");
    try linkTestFile(tmp.dir, try io_mod.dirRealpathAlloc(arena, tmp.dir, "dotfiles/review.md"), "home/linked/prompt.md");
    try writeTestProfile(tmp.dir, "home/device", "{\"description\": \"Device\"}");
    try linkTestFile(tmp.dir, "/dev/null", "home/device/prompt.md");
    try writeTestProfile(tmp.dir, "home/folder", "{\"description\": \"Folder\"}");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/folder/prompt.md");
    const roots: Roots = .{ .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home") };

    var failure: ?[]const u8 = null;
    const linked = try load(arena, roots, "linked", &failure);
    try testing.expectEqualStrings("Review only.", linked.prompt);
    try testing.expectError(error.InvalidProfile, load(arena, roots, "device", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "isn't a regular file") != null);
    try testing.expectError(error.InvalidProfile, load(arena, roots, "folder", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "it is a folder, not a file") != null);
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

/// The text of one entry of a `tools` or `mcp_servers` list: a non-empty string
/// of at most `max_list_entry_bytes`, or null for anything else. A profile
/// file and a saved copy of its lists (`started_with.zig`) both take entries
/// by this rule.
pub fn listEntry(value: std.json.Value) ?[]const u8 {
    if (value != .string or value.string.len == 0 or value.string.len > max_list_entry_bytes) return null;
    return value.string;
}

fn nameList(arena: Allocator, failure: *?[]const u8, name: []const u8, key: []const u8, value: std.json.Value) ParseError![]const []const u8 {
    if (value != .array) return fail(arena, failure, "profile '{s}': {s} must be a list of names", .{ name, key });
    const out = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, out) |item, *slot| {
        slot.* = listEntry(item) orelse
            return fail(arena, failure, "profile '{s}': {s} must be a list of names", .{ name, key });
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
    try testing.expect(allowsTool(&profile, "read_file", &toolbox.default_behind));
    try testing.expect(!allowsTool(&profile, "write_file", &toolbox.default_behind));
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
    try testing.expect(allowsTool(&main, "subagent", &toolbox.default_behind));
    try testing.expect(allowsTool(&main, "write_file", &toolbox.default_behind));
    try testing.expect(allowsTool(&agent, "subagent", &toolbox.default_behind));
    try testing.expect(allowsTool(&agent, "write_file", &toolbox.default_behind));
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
    try testing.expect(allowsTool(&all, "read_file", &toolbox.default_behind));
    try testing.expect(!allowsTool(&all, "shell", &toolbox.default_behind));
    try testing.expect(allowsTool(&all, "subagent", &toolbox.default_behind));
    const leaf = try testParse(arena_state.allocator(), .home,
        \\{"description": "Leaf", "tools": ["*", "!subagent"]}
    , "");
    try testing.expect(!allowsTool(&leaf, "subagent", &toolbox.default_behind));
    try testing.expect(allowsTool(&leaf, "read_file", &toolbox.default_behind));
    const none = try testParse(arena_state.allocator(), .home,
        \\{"description": "None", "tools": []}
    , "");
    try testing.expect(!allowsTool(&none, "read_file", &toolbox.default_behind));
    try testing.expect(setsTools(&none));
    const unset = try testParse(arena_state.allocator(), .home,
        \\{"description": "Unset"}
    , "");
    try testing.expect(!setsTools(&unset) and !setsMcpServers(&unset));
    try testing.expect(allowsTool(&unset, "shell", &toolbox.default_behind));
}

test "a profile that lists a tool the run keeps behind toolbox keeps toolbox to reach it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile = try testParse(arena, .home,
        \\{"description": "Finder", "tools": ["glob_files"]}
    , "");
    const moved = [_][]const u8{ "install_skill", "glob_files" };
    // With glob_files placed behind toolbox, toolbox is its only way in.
    try testing.expect(allowsTool(&profile, "toolbox", &moved));
    try testing.expect(!allowsTool(&profile, "toolbox", &toolbox.default_behind));
    try testing.expect(allowsTool(&profile, "glob_files", &moved));
    // What toolbox opens and searches is still the profile's to give.
    for (toolbox.replaced) |name| try testing.expect(!allowsTool(&profile, name, &moved));
    // Leaving toolbox out by name leaves it out, with every tool kept.
    const no_toolbox = try testParse(arena, .home,
        \\{"description": "No toolbox", "tools": ["*", "!toolbox"]}
    , "");
    try testing.expect(!allowsTool(&no_toolbox, "toolbox", &moved));
    try testing.expect(allowsTool(&no_toolbox, "glob_files", &moved));
}

test "a profile decides toolbox's open and search as the tools they replaced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Written for the old tools: toolbox comes with what they gave, no more.
    const old = try testParse(arena, .home,
        \\{"description": "Old", "tools": ["read_file", "mcp_select_tool"]}
    , "");
    try testing.expect(allowsTool(&old, "toolbox", &toolbox.default_behind));
    try testing.expect(allowsTool(&old, "mcp_select_tool", &toolbox.default_behind));
    try testing.expect(!allowsTool(&old, "skill", &toolbox.default_behind));
    try testing.expect(!allowsTool(&old, "capability_search", &toolbox.default_behind));
    // Listing toolbox, or every tool, allows all three.
    for ([_][]const u8{
        \\{"description": "Box", "tools": ["toolbox"]}
        ,
        \\{"description": "All", "tools": ["*"]}
        ,
        \\{"description": "Unset"}
    }) |json| {
        const profile = try testParse(arena, .home, json, "");
        for (toolbox.replaced) |name| try testing.expect(allowsTool(&profile, name, &toolbox.default_behind));
    }
    // A name left out stays out, even with toolbox allowed.
    const no_skills = try testParse(arena, .home,
        \\{"description": "No skills", "tools": ["*", "!skill"]}
    , "");
    try testing.expect(allowsTool(&no_skills, "toolbox", &toolbox.default_behind));
    try testing.expect(!allowsTool(&no_skills, "skill", &toolbox.default_behind));
    try testing.expect(allowsTool(&no_skills, "capability_search", &toolbox.default_behind));
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
    try testing.expect(allowsTool(&main, "read_file", &toolbox.default_behind));
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

fn findEntry(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

test "completion keeps the user's profiles over the repository's and fx's, sorted, in memory the caller owns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestProfile(tmp.dir, "home/reviewer", "{\"description\": \"Home reviewer\", \"model\": \"test/model\", \"effort\": \"high\", \"tools\": [\"read_file\", \"!shell\"]}");
    try writeTestProfile(tmp.dir, "project/reviewer", "{\"description\": \"Repo reviewer\"}");
    try writeTestProfile(tmp.dir, "project/tester", "{\"description\": \"Repo tester\"}");
    try writeTestProfile(tmp.dir, "project/agent", "{\"description\": \"Repo agent\"}");
    try writeTestProfile(tmp.dir, "project/broken", "{not json");
    try writeTestProfile(tmp.dir, "home/main", "{\"description\": \"Not fx\"}");
    const roots: Roots = .{
        .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home"),
        .project = try io_mod.dirRealpathAlloc(arena, tmp.dir, "project"),
    };

    // The testing allocator fails the test on a leak, so every scratch byte
    // is freed and every kept slice was copied into the caller's allocator.
    const result = try listForCompletion(testing.allocator, roots);
    defer result.deinit(testing.allocator);
    try testing.expect(!result.limited);
    try testing.expectEqual(@as(usize, 4), result.entries.len);
    const names = [_][]const u8{ "agent", "main", "reviewer", "tester" };
    for (names, result.entries) |name, entry| try testing.expectEqualStrings(name, entry.name);
    try testing.expectEqual(Source.project, result.entries[0].source);
    try testing.expectEqual(Source.builtin, result.entries[1].source);
    const reviewer = result.entries[2];
    try testing.expectEqual(Source.home, reviewer.source);
    try testing.expectEqualStrings("Home reviewer", reviewer.description);
    try testing.expectEqualStrings("test/model", reviewer.model.?);
    try testing.expect(reviewer.effort.?.eql(types.ReasoningEffort.literal("high")));
    try testing.expectEqual(@as(usize, 2), reviewer.tools.?.len);
    try testing.expectEqualStrings("!shell", reviewer.tools.?[1]);
}

test "completion never reads a prompt, so a large or linked one does not hide its profile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestProfile(tmp.dir, "home/huge", "{\"description\": \"Huge prompt\"}");
    const huge = try arena.alloc(u8, max_prompt_bytes + 1);
    @memset(huge, 'x');
    try writeTestFile(tmp.dir, "home/huge/prompt.md", huge);
    try writeTestProfile(tmp.dir, "home/device", "{\"description\": \"Device prompt\"}");
    try linkTestFile(tmp.dir, "/dev/null", "home/device/prompt.md");
    try writeTestFile(tmp.dir, "outside/secret.txt", "SECRET");
    try writeTestProfile(tmp.dir, "repo/.fx/agents/evil", "{\"description\": \"Linked prompt\"}");
    try linkTestFile(tmp.dir, try io_mod.dirRealpathAlloc(arena, tmp.dir, "outside/secret.txt"), "repo/.fx/agents/evil/prompt.md");
    var roots = try Roots.init(arena, null, try io_mod.dirRealpathAlloc(arena, tmp.dir, "repo"));
    roots.home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home");

    // `load` reads each prompt and refuses all three.
    var failure: ?[]const u8 = null;
    for ([_][]const u8{ "huge", "device", "evil" }) |name|
        try testing.expectError(error.InvalidProfile, load(arena, roots, name, &failure));

    const result = try listForCompletion(arena, roots);
    try testing.expect(!result.limited);
    for ([_][]const u8{ "huge", "device", "evil" }) |name| try testing.expect(findEntry(result.entries, name) != null);
}

test "completion stops after its folder entry cap, counting entries that are not profiles" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Junk fills the cap in the user's folder: files and folders whose names
    // are not profile names.
    for (0..max_completion_dir_entries) |index| {
        if (index % 2 == 0) {
            try writeTestFile(tmp.dir, try arena.print("home/junk{d}.txt", .{index}), "");
        } else {
            try tmp.dir.createDirPath(io_mod.getIo(), try arena.print("home/Junk {d}", .{index}));
        }
    }
    try writeTestProfile(tmp.dir, "project/tester", "{\"description\": \"Repo tester\"}");
    const roots: Roots = .{
        .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home"),
        .project = try io_mod.dirRealpathAlloc(arena, tmp.dir, "project"),
    };

    const capped = try listForCompletion(arena, roots);
    try testing.expect(capped.limited);
    try testing.expect(findEntry(capped.entries, "tester") == null);
    try testing.expectEqual(@as(usize, 2), capped.entries.len);
    try testing.expectEqualStrings("agent", capped.entries[0].name);
    try testing.expectEqualStrings("main", capped.entries[1].name);

    // Under the cap, the repository's profile is offered.
    const full = try listForCompletion(arena, .{ .project = roots.project });
    try testing.expect(!full.limited);
    try testing.expect(findEntry(full.entries, "tester") != null);
}

test "completion skips a settings file over its own limit and stops at the shared byte budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const padding = try arena.alloc(u8, max_settings_bytes - 1024);
    @memset(padding, 'x');
    const big_json = try arena.print("{{\"description\": \"Big\", \"pad\": \"{s}\"}}", .{padding});
    try testing.expect(big_json.len < max_settings_bytes);

    const oversized = try arena.alloc(u8, max_settings_bytes + 16);
    @memset(oversized, ' ');
    try writeTestProfile(tmp.dir, "alone/oversized", oversized);
    try writeTestProfile(tmp.dir, "alone/fine", "{\"description\": \"Fine\"}");
    const alone = try listForCompletion(arena, .{ .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "alone") });
    try testing.expect(alone.limited);
    try testing.expect(findEntry(alone.entries, "oversized") == null);
    try testing.expect(findEntry(alone.entries, "fine") != null);

    // Twenty files of almost 64 KiB pass 1 MiB together.
    const count = 20;
    for (0..count) |index| try writeTestProfile(tmp.dir, try arena.print("home/big{d}", .{index}), big_json);
    const result = try listForCompletion(testing.allocator, .{ .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home") });
    defer result.deinit(testing.allocator);
    try testing.expect(result.limited);
    const listed = result.entries.len - 2;
    try testing.expect(listed > 0 and listed < count);
    try testing.expect(listed * big_json.len < max_completion_settings_bytes);
    try testing.expect(findEntry(result.entries, "main") != null and findEntry(result.entries, "agent") != null);
}

test "a mod profile ignores permission_mode with mod_cannot_set_permissions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const profile = try testParse(arena_state.allocator(), .mod,
        \\{"description": "Mod agent", "permission_mode": "yolo", "colour": "green"}
    , "");
    try testing.expect(profile.permission_mode == null);
    try testing.expectEqual(types.PermissionMode.ask, permissionMode(&profile, .ask));
    try testing.expectEqual(@as(usize, 2), profile.ignored.len);
    try testing.expectEqualStrings("permission_mode", profile.ignored[0].key);
    try testing.expectEqual(IgnoredReason.mod_cannot_set_permissions, profile.ignored[0].reason);
    try testing.expectEqual(IgnoredReason.unknown_key, profile.ignored[1].reason);
}

test "profiles resolve home, then mods, then project, then builtins, and mod clashes load from neither" {
    if (comptime build_options.libfx) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestProfile(tmp.dir, "home-agents/shared", "{\"description\": \"Home wins\"}");
    try writeTestProfile(tmp.dir, "project-agents/shared", "{\"description\": \"Project loses\"}");
    try writeTestProfile(tmp.dir, "project-agents/mod-wins", "{\"description\": \"Project loses to mod\"}");
    try writeTestProfile(tmp.dir, "project-agents/clashed", "{\"description\": \"Project under clash\"}");

    // Mod alpha defines shared (loses to home), mod-wins (wins over project),
    // clashed (clashes with beta), and main (ignored: main stays builtin).
    try writeTestFile(tmp.dir, "src-alpha/mod.json", "{\"name\":\"alpha\",\"version\":\"1.0.0\"}");
    try writeTestProfile(tmp.dir, "src-alpha/agents/shared", "{\"description\": \"Alpha loses to home\"}");
    try writeTestProfile(tmp.dir, "src-alpha/agents/mod-wins", "{\"description\": \"Alpha wins over project\"}");
    try writeTestFile(tmp.dir, "src-alpha/agents/mod-wins/prompt.md", "Alpha prompt v1.");
    try writeTestProfile(tmp.dir, "src-alpha/agents/clashed", "{\"description\": \"Alpha clash\"}");
    try writeTestProfile(tmp.dir, "src-alpha/agents/main", "{\"description\": \"Fake main\"}");

    // Mod beta also defines clashed, plus beta-only.
    try writeTestFile(tmp.dir, "src-beta/mod.json", "{\"name\":\"beta\",\"version\":\"1.0.0\"}");
    try writeTestProfile(tmp.dir, "src-beta/agents/clashed", "{\"description\": \"Beta clash\"}");
    try writeTestProfile(tmp.dir, "src-beta/agents/beta-only", "{\"description\": \"Beta only\"}");

    // Disabled mod gamma defines gamma-only (must stay hidden).
    try writeTestFile(tmp.dir, "src-gamma/mod.json", "{\"name\":\"gamma\",\"version\":\"1.0.0\"}");
    try writeTestProfile(tmp.dir, "src-gamma/agents/gamma-only", "{\"description\": \"Hidden when off\"}");

    const mods_dir = try std.Io.Dir.path.join(arena, &.{ try io_mod.dirRealpathAlloc(arena, tmp.dir, "."), "mods" });
    try tmp.dir.createDirPath(io_mod.getIo(), "mods");
    try testing.expect((try mods_mod.add(arena, mods_dir, "alpha", try io_mod.dirRealpathAlloc(arena, tmp.dir, "src-alpha"))) == .ok);
    try testing.expect((try mods_mod.add(arena, mods_dir, "beta", try io_mod.dirRealpathAlloc(arena, tmp.dir, "src-beta"))) == .ok);
    try testing.expect((try mods_mod.add(arena, mods_dir, "gamma", try io_mod.dirRealpathAlloc(arena, tmp.dir, "src-gamma"))) == .ok);
    try testing.expect((try mods_mod.setOn(arena, mods_dir, "gamma", false)) == .ok);

    const roots: Roots = .{
        .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home-agents"),
        .mods_dir = mods_dir,
        .project = try io_mod.dirRealpathAlloc(arena, tmp.dir, "project-agents"),
        .repository = try io_mod.dirRealpathAlloc(arena, tmp.dir, "project-agents"),
    };

    var failure: ?[]const u8 = null;
    // Home beats mods and project.
    const shared = try load(arena, roots, "shared", &failure);
    try testing.expectEqual(Source.home, shared.source);
    try testing.expect(shared.mod_name == null);

    // Mods beat project.
    const mod_wins = try load(arena, roots, "mod-wins", &failure);
    try testing.expectEqual(Source.mod, mod_wins.source);
    try testing.expectEqualStrings("alpha", mod_wins.mod_name.?);
    try testing.expectEqualStrings("Alpha prompt v1.", mod_wins.prompt);

    // `main` stays builtin even when a mod defines `main`.
    const main_prof = try load(arena, roots, "main", &failure);
    try testing.expectEqual(Source.builtin, main_prof.source);

    // Disabled mod is not loaded.
    try testing.expectError(error.ProfileNotFound, load(arena, roots, "gamma-only", &failure));

    // Clash across two enabled mods fails naming both mods.
    try testing.expectError(error.InvalidProfile, load(arena, roots, "clashed", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "alpha") != null);
    try testing.expect(std.mem.find(u8, failure.?, "beta") != null);

    // `list` and `listForCompletion` skip `clashed` and `gamma-only`, and mark `alpha`/`beta`.
    const entries = try list(arena, roots);
    try testing.expect(findEntry(entries, "clashed") == null);
    try testing.expect(findEntry(entries, "gamma-only") == null);
    const mw_entry = findEntry(entries, "mod-wins").?;
    try testing.expectEqual(Source.mod, mw_entry.source);
    try testing.expectEqualStrings("alpha", mw_entry.mod_name.?);

    const comp = try listForCompletion(testing.allocator, roots);
    defer comp.deinit(testing.allocator);
    try testing.expect(findEntry(comp.entries, "clashed") == null);
    try testing.expect(findEntry(comp.entries, "gamma-only") == null);
    try testing.expectEqualStrings("alpha", findEntry(comp.entries, "mod-wins").?.mod_name.?);

    // `findModClashesIn` reports `clashed` with `alpha` and `beta`, not `shared` (shadowed by home).
    const clashes = try findModClashesIn(testing.allocator, roots.home, mods_dir);
    defer {
        for (clashes) |*c| c.deinit(testing.allocator);
        testing.allocator.free(clashes);
    }
    try testing.expectEqual(@as(usize, 1), clashes.len);
    try testing.expectEqualStrings("clashed", clashes[0].name);
    try testing.expectEqual(@as(usize, 2), clashes[0].mods.len);
    try testing.expectEqualStrings("alpha", clashes[0].mods[0]);
    try testing.expectEqualStrings("beta", clashes[0].mods[1]);

    // Live update: updating alpha applies to the next load immediately.
    try writeTestFile(tmp.dir, "src-alpha/mod.json", "{\"name\":\"alpha\",\"version\":\"2.0.0\"}");
    try writeTestFile(tmp.dir, "src-alpha/agents/mod-wins/prompt.md", "Alpha prompt v2.");
    try testing.expect((try mods_mod.update(arena, mods_dir, "alpha", try io_mod.dirRealpathAlloc(arena, tmp.dir, "src-alpha"))) == .ok);
    const updated = try load(arena, roots, "mod-wins", &failure);
    try testing.expectEqualStrings("Alpha prompt v2.", updated.prompt);
}

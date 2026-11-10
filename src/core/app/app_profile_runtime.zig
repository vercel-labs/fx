//! Puts each instance in its profile: the first in its launch profile, `fx
//! --profile <name>` or fx's own `main`, and every later one in its own.

const std = @import("std");
const profiles = @import("../profiles/profiles.zig");
const tool_set = @import("../tooling/tool_set.zig");
const toolbox = @import("../tooling/toolbox.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const agents = @import("../agents/agents.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const mod_registry = @import("../mods/registry.zig");
const ui_render = @import("../../ui/render.zig");
const text_utils = @import("../shared/text_utils.zig");
const row_text = @import("../../ui/footer/row_text.zig");

/// Decides tool membership for `tool_set.narrow` from a profile.
pub const ProfileTools = struct {
    profile: *const profiles.Profile,
    role: profiles.Role,
    /// The built-in tools the run offers through toolbox.
    behind: []const []const u8,

    pub fn allows(self: ProfileTools, name: []const u8) bool {
        return profiles.allowsTool(self.profile, name, self.behind);
    }
};

/// The message for a `--profile` that cannot be used, or null when it loads.
/// Caller owns the message.
pub fn launchFailure(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    const reason = try failureReason(alloc, name) orelse return null;
    defer alloc.free(reason);
    return try alloc.print("fx: {s}\n", .{reason});
}

/// Why profile `name` cannot be loaded, such as "no profile named 'x'.
/// Profiles: agent, main", or null when it loads. Resolves from the same home
/// and workspace that startup uses. Caller owns the reason.
pub fn failureReason(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace_root = io_mod.realpathAlloc(arena, ".") catch null;
    const roots = try profiles.Roots.init(arena, io_mod.homeDir(), workspace_root);
    var failure: ?[]const u8 = null;
    _ = profiles.load(arena, roots, name, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try alloc.dupe(u8, failure orelse @errorName(err)),
    };
    return null;
}

/// A bounded snapshot of the profiles `/launch` can start. Loaded once on
/// opening the selector and released when the composer leaves the command.
pub const LaunchCompletion = struct {
    entries: []const mod_registry.ArgumentCompletion = &.{},
    arena: ?std.heap.ArenaAllocator = null,
    attempted: bool = false,

    /// What a launched instance starts with besides its profile, as
    /// `app_instances_runtime` applies them: the overrides win over the
    /// profile, which wins over the settings later instances start from.
    /// Borrowed.
    pub const Defaults = struct {
        model: []const u8 = "",
        effort: types.ReasoningEffort = .auto,
        /// `--model`, `--provider`, or `FX_MODEL`.
        model_override: ?[]const u8 = null,
        /// `--effort`.
        effort_override: ?types.ReasoningEffort = null,
        /// The profile a bare `/launch` starts, listed first so Enter on an
        /// empty `/launch ` starts it too.
        profile_name: []const u8 = profiles.main_name,
    };

    pub fn deinit(self: *LaunchCompletion) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    /// Returns whether the footer needs repainting after loading or releasing
    /// the snapshot. Changes on disk appear the next time the selector opens.
    pub fn refresh(
        self: *LaunchCompletion,
        alloc: std.mem.Allocator,
        input: []const u8,
        home: ?[]const u8,
        workspace_root: ?[]const u8,
        defaults: Defaults,
    ) bool {
        const command = std.mem.trimStart(u8, input, " \t");
        const prefix = "/launch";
        const active = std.mem.startsWith(u8, command, prefix) and
            (command.len == prefix.len or command[prefix.len] == ' ' or command[prefix.len] == '\t');
        if (!active) {
            const had_entries = self.entries.len > 0;
            self.deinit();
            return had_entries;
        }
        if (self.attempted) return false;
        self.attempted = true;
        var next: std.heap.ArenaAllocator = .init(alloc);
        const entries = build(alloc, next.allocator(), home, workspace_root, defaults) catch |err| {
            next.deinit();
            debug_trace.logf("profile", "launch listing failed err={s}", .{@errorName(err)});
            return false;
        };
        if (self.arena) |*old| old.deinit();
        self.arena = next;
        self.entries = entries;
        return true;
    }

    fn build(backing: std.mem.Allocator, arena: std.mem.Allocator, home: ?[]const u8, workspace_root: ?[]const u8, defaults: Defaults) ![]const mod_registry.ArgumentCompletion {
        const roots = try profiles.Roots.init(arena, home, workspace_root);
        const listing = try profiles.listForCompletion(backing, roots);
        defer listing.deinit(backing);
        const listed = listing.entries;
        var has_default = false;
        for (listed, 0..) |entry, index| if (std.mem.eql(u8, entry.name, defaults.profile_name)) {
            has_default = true;
            std.mem.rotate(profiles.Entry, listed[0 .. index + 1], index);
            break;
        };
        const rows = try arena.alloc(Row, listed.len);
        var widths: Widths = @splat(0);
        for (listed, rows) |entry, *row| {
            row.* = try rowOf(arena, entry, defaults);
            for (row.*, &widths) |cell, *width| width.* = @max(width.*, text_utils.terminalSafeVisibleWidth(cell));
        }
        const offset: usize = if (has_default) 0 else 1;
        const out = try arena.alloc(mod_registry.ArgumentCompletion, listed.len + offset);
        if (!has_default) out[0] = .{
            .full = try arena.print("/launch {s}", .{defaults.profile_name}),
            .description = if (listing.limited)
                "Not in listing; list limited, type /launch <name>"
            else
                "Not in listing; launch validates this profile",
            .select_description = true,
        };
        for (listed, rows, out[offset..], offset..) |entry, row, *completion, index| {
            const description = try alignedRow(arena, row, widths);
            completion.* = .{
                .full = try arena.print("/launch {s}", .{entry.name}),
                .description = if (listing.limited and index == 0)
                    if (description) |text|
                        try arena.print("{s}  List limited; type /launch <name>", .{text})
                    else
                        "List limited; type /launch <name>"
                else
                    description,
                .select_description = true,
            };
        }
        return out;
    }

    /// Model, effort, tools, and where it is saved.
    const column_count = 4;
    const Row = [column_count][]const u8;
    const Widths = [column_count]usize;
    const column_gap = 2;

    /// The values the instance would start with, as the agent list names
    /// them. A profile, the repository's included, may set any model or
    /// effort, so both show their control bytes as escapes. The text belongs
    /// to `arena`.
    fn rowOf(arena: std.mem.Allocator, entry: profiles.Entry, defaults: Defaults) !Row {
        var model_buf: [96]u8 = undefined;
        const model_id = defaults.model_override orelse entry.model orelse defaults.model;
        const model = try cellText(arena, ui_render.compactModelLabel(model_id, &model_buf), 32);
        // A named effort keeps its label inline, so it is copied from here.
        const effort_value = defaults.effort_override orelse entry.effort orelse defaults.effort;
        const effort = try cellText(arena, effort_value.displayLabel(), 16);
        return .{
            model,
            effort,
            toolsText(entry),
            if (entry.source == .project) "project" else "",
        };
    }

    /// `row`'s cells padded to `widths`, two columns apart, leaving out a
    /// column no profile fills; null when the row has nothing to show. The
    /// result belongs to `arena`.
    fn alignedRow(arena: std.mem.Allocator, row: Row, widths: Widths) !?[]const u8 {
        var line: std.ArrayList(u8) = .empty;
        for (row, widths) |cell, width| {
            if (width == 0) continue;
            if (line.items.len > 0) try line.appendNTimes(arena, ' ', column_gap);
            try line.appendSlice(arena, cell);
            try line.appendNTimes(arena, ' ', width -| text_utils.terminalSafeVisibleWidth(cell));
        }
        const text = std.mem.trimEnd(u8, line.items, " ");
        return if (text.len == 0) null else text;
    }

    /// Bounds allocation and padding before the rows are aligned, and escapes
    /// terminal controls from repository-owned values.
    fn cellText(arena: std.mem.Allocator, raw: []const u8, width: usize) ![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        try row_text.appendTerminalSafeSingleLine(arena, &text, raw, width);
        return text.items;
    }

    /// These are tool-set descriptions, not guarantees about side effects.
    /// In particular, omitting file edits does not make shell, installation,
    /// delegation, or MCP tools read-only.
    fn toolsText(entry: profiles.Entry) []const u8 {
        const tools = entry.tools orelse return "all tools";
        if (tools.len == 1 and std.mem.eql(u8, tools[0], "*")) return "all tools";
        return "custom";
    }
};

test "a launch row shows the model and effort the instance would start with" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const defaults: LaunchCompletion.Defaults = .{ .model = "openai/gpt-5", .effort = .literal("medium") };
    var reviewer: profiles.Entry = .{ .name = "reviewer", .description = "A long description", .source = .home };
    reviewer.model = "anthropic/claude-opus-4-7";
    reviewer.effort = .literal("high");
    reviewer.tools = &.{ "read_file", "grep_files" };
    const main_entry: profiles.Entry = .{ .name = "main", .description = "fx itself", .source = .builtin };

    const reviewer_row = try LaunchCompletion.rowOf(arena, reviewer, defaults);
    const main_row = try LaunchCompletion.rowOf(arena, main_entry, defaults);
    var widths: LaunchCompletion.Widths = @splat(0);
    for ([_]LaunchCompletion.Row{ reviewer_row, main_row }) |row| {
        for (row, &widths) |cell, *width| width.* = @max(width.*, cell.len);
    }

    try std.testing.expectEqualStrings("opus 4-7  high    custom", (try LaunchCompletion.alignedRow(arena, reviewer_row, widths)).?);
    // A profile that sets nothing shows fx's model and effort.
    try std.testing.expectEqualStrings("gpt-5     medium  all tools", (try LaunchCompletion.alignedRow(arena, main_row, widths)).?);
    // An effort fx leaves at its default says so, as `/effort` does.
    const plain = try LaunchCompletion.rowOf(arena, main_entry, .{ .model = "openai/gpt-5" });
    try std.testing.expectEqualStrings("default", plain[1]);
}

test "launch tool summaries never promise read-only behavior" {
    const base: profiles.Entry = .{ .name = "x", .description = "", .source = .home };
    try std.testing.expectEqualStrings("all tools", LaunchCompletion.toolsText(base));
    var every = base;
    every.tools = &.{"*"};
    try std.testing.expectEqualStrings("all tools", LaunchCompletion.toolsText(every));
    var custom = base;
    custom.tools = &.{ "*", "!subagent" };
    try std.testing.expectEqualStrings("custom", LaunchCompletion.toolsText(custom));
    var read_only = base;
    read_only.tools = &.{ "read_file", "grep_files" };
    try std.testing.expectEqualStrings("custom", LaunchCompletion.toolsText(read_only));
    var no_shell = base;
    no_shell.tools = &.{ "*", "!shell" };
    try std.testing.expectEqualStrings("custom", LaunchCompletion.toolsText(no_shell));
    var no_edits = base;
    no_edits.tools = &.{ "*", "!edit_file", "!write_file" };
    try std.testing.expectEqualStrings("custom", LaunchCompletion.toolsText(no_edits));
    for ([_][]const u8{ "install_skill", "subagent", "mcp_select_tool", "shell" }) |tool| {
        var effectful = base;
        effectful.tools = &.{tool};
        try std.testing.expectEqualStrings("custom", LaunchCompletion.toolsText(effectful));
    }
}

test "a launch row shows the overrides fx started with, and a profile's control bytes as escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entry: profiles.Entry = .{ .name = "x", .description = "", .source = .project };
    entry.model = "evil\x1b]0;owned\x07";
    entry.effort = .literal("high");
    const row = try LaunchCompletion.rowOf(arena, entry, .{ .model = "openai/gpt-5" });
    try std.testing.expect(std.mem.findScalar(u8, row[0], 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, row[0], 0x07) == null);

    // `--model` and `--effort` win over the profile, as the launch applies them.
    const overridden = try LaunchCompletion.rowOf(arena, entry, .{ .model = "openai/gpt-5", .model_override = "openai/gpt-5.4-mini", .effort_override = .literal("low") });
    try std.testing.expectEqualStrings("gpt-5.4-mini", overridden[0]);
    try std.testing.expectEqualStrings("low", overridden[1]);
}

test "launch completion lists profiles only while the composer holds /launch" {
    var completion: LaunchCompletion = .{};
    defer completion.deinit();
    try std.testing.expect(!completion.refresh(std.testing.allocator, "/model", null, null, .{}));
    try std.testing.expectEqual(@as(usize, 0), completion.entries.len);
    try std.testing.expect(completion.refresh(std.testing.allocator, "/launch ", null, null, .{}));
    // Further loop passes reuse the snapshot without reading disk.
    try std.testing.expect(!completion.refresh(std.testing.allocator, "/launch ", null, null, .{}));
    // The profile a bare `/launch` starts comes first.
    try std.testing.expectEqualStrings("/launch main", completion.entries[0].full);
    try std.testing.expect(completion.refresh(std.testing.allocator, "/launchx", null, null, .{}));
    try std.testing.expect(completion.arena == null);
    try std.testing.expectEqual(@as(usize, 0), completion.entries.len);
    try std.testing.expect(!completion.refresh(std.testing.allocator, "/launchx", null, null, .{}));
    try std.testing.expect(completion.refresh(std.testing.allocator, "/launch ", null, null, .{}));
}

/// The model the first instance starts with: `--model`, else the launch
/// profile's, unless `--provider` or `FX_MODEL` chose the process's model, as
/// `applyProcessModelOverride` decides for `/launch <profile>`. Null leaves the
/// choice to startup.
pub fn launchModel(model_flag: ?[]const u8, provider_flag: bool, env_model: ?[]const u8, profile_model: ?[]const u8) ?[]const u8 {
    if (model_flag) |model| return model;
    if (provider_flag or env_model != null) return null;
    return profile_model;
}

test "the launch profile's model gives way to the model the process chose" {
    try std.testing.expectEqualStrings("profile/model", launchModel(null, false, null, "profile/model").?);
    try std.testing.expect(launchModel(null, false, "env/model", "profile/model") == null);
    try std.testing.expect(launchModel(null, true, null, "profile/model") == null);
    try std.testing.expectEqualStrings("flag/model", launchModel("flag/model", true, "env/model", "profile/model").?);
    try std.testing.expect(launchModel(null, false, null, null) == null);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = agents.Agent;
        /// Narrows `agent`'s tools to its profile, by the tools its run keeps
        /// behind toolbox now. The launch profile is applied before settings
        /// and flags place them, so startup narrows main's again after.
        pub fn narrowProfileTools(app: *App, agent: *AppAgent, base_tools: tool_set.ToolSet) !void {
            const held = &agent.profile;
            agent.profile_tools = try tool_set.narrow(held.arena.?.allocator(), base_tools, ProfileTools{
                .profile = &held.profile,
                .role = .main,
                .behind = if (comptime @hasField(App, "toolbox_behind")) app.toolbox_behind.slice() else &toolbox.default_behind,
            });
        }

        /// Loads main's profile before startup, so its model and effort reach
        /// startup. `--model`, `--provider`, `FX_MODEL`, and `--effort` still
        /// win, as `launchModel` decides. Narrows main's tools to the profile.
        pub fn applyLaunchProfile(
            app: *App,
            name: []const u8,
            base_prompt: []const u8,
            base_tools: tool_set.ToolSet,
        ) !void {
            try applyProfile(app, &app.main_agent, name, base_prompt, base_tools);
        }

        /// Applies profile `name` to `agent`, any instance, as the launch
        /// profile is applied to the first one.
        pub fn applyProfile(
            app: *App,
            agent: *AppAgent,
            name: []const u8,
            base_prompt: []const u8,
            base_tools: tool_set.ToolSet,
        ) !void {
            const workspace_root = io_mod.realpathAlloc(app.alloc, ".") catch null;
            defer if (workspace_root) |root| app.alloc.free(root);
            var failure: ?[]u8 = null;
            defer if (failure) |message| app.alloc.free(message);
            agent.profile.replace(app.alloc, io_mod.homeDir(), workspace_root, name, base_prompt, &failure) catch |err| {
                debug_trace.eventf("profile", "profile_failed", .{}, "name={s} reason={s}", .{
                    name,
                    failure orelse @errorName(err),
                });
                return err;
            };
            try narrowProfileTools(app, agent, base_tools);
        }

        /// After startup has read the user's permission mode, applies the
        /// profile's own for this session. A profile without one keeps the
        /// user's. Reports the launch profile here, because startup is what
        /// turns tracing on.
        pub fn applyLaunchMode(app: *App) !void {
            try reportProfile(app, &app.main_agent, "main");
            const permission = app_permission_runtime.Runtime(App);
            permission.initMode(app, &app.main_agent, profileMode(&app.main_agent, "main", permission.modeOf(app, &app.main_agent)));
        }

        /// The permission mode `agent`'s profile gives it over `parent`, the
        /// user's: the profile's own, else `parent`.
        pub fn profileMode(agent: *AppAgent, label: []const u8, parent: types.PermissionMode) types.PermissionMode {
            const profile = &agent.profile.profile;
            const mode = profiles.permissionMode(profile, parent);
            debug_trace.eventf("profile", "profile_mode", .{}, "agent={s} name={s} parent={s} mode={s}", .{
                label,
                profile.name,
                @tagName(parent),
                @tagName(mode),
            });
            return mode;
        }

        /// Traces how `agent`'s profile resolved: its ignored keys, prompt,
        /// and tools.
        pub fn reportProfile(app: *App, agent: *AppAgent, label: []const u8) !void {
            const held = &agent.profile;
            for (held.profile.ignored) |ignored| {
                debug_trace.eventf("profile", "profile_key_ignored", .{}, "name={s} key={s} reason={s}", .{
                    held.profile.name,
                    ignored.key,
                    @tagName(ignored.reason),
                });
            }
            // `tools=*` means every tool fx has; otherwise the names main kept.
            var names: std.ArrayList(u8) = .empty;
            defer names.deinit(app.alloc);
            if (agent.profile_tools) |set| {
                for (set.registry.tools, 0..) |tool, index| {
                    if (index > 0) try names.append(app.alloc, ',');
                    try names.appendSlice(app.alloc, tool.name);
                }
            } else try names.append(app.alloc, '*');
            debug_trace.eventf("profile", "profile_resolved", .{}, "agent={s} name={s} source={s} prompt={s} tools={s}", .{
                label,
                held.profile.name,
                @tagName(held.profile.source),
                if (held.system_prompt == null) "fx" else @tagName(held.profile.prompt_mode),
                names.items,
            });
        }
    };
}

test "launch model cells stay bounded before padding every row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const huge = try arena.alloc(u8, profiles.max_settings_bytes);
    @memset(huge, 'x');
    const entry: profiles.Entry = .{ .name = "long", .description = "", .source = .project, .model = huge };
    const row = try LaunchCompletion.rowOf(arena, entry, .{});
    try std.testing.expect(text_utils.terminalSafeVisibleWidth(row[0]) <= 32);
    try std.testing.expect(row[0].len < 128);
}

test "a limited launch listing keeps the default profile first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(std.testing.io, ".fx/agents");
    for (0..140) |index| {
        const name = try arena.print(".fx/agents/junk-{d}", .{index});
        var file = try tmp.dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    const home = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    var completion: LaunchCompletion = .{};
    defer completion.deinit();
    try std.testing.expect(completion.refresh(std.testing.allocator, "/launch ", home, null, .{ .profile_name = "reviewer" }));
    try std.testing.expectEqualStrings("/launch reviewer", completion.entries[0].full);
    try std.testing.expect(std.mem.find(u8, completion.entries[0].description.?, "Not in listing") != null);
    try std.testing.expect(std.mem.find(u8, completion.entries[0].description.?, "list limited") != null);
    // Builtins remain usable even when no folder entries can be read.
    try std.testing.expectEqual(@as(usize, 3), completion.entries.len);
}

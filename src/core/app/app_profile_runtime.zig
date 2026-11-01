//! Puts each instance in its profile: the first in its launch profile, `fx
//! --profile <name>` or fx's own `main`, and every later one in its own.

const std = @import("std");
const profiles = @import("../profiles/profiles.zig");
const tool_set = @import("../tooling/tool_set.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const agents = @import("../agents/agents.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");

/// Decides tool membership for `tool_set.narrow` from a profile.
pub const ProfileTools = struct {
    profile: *const profiles.Profile,
    role: profiles.Role,

    pub fn allows(self: ProfileTools, name: []const u8) bool {
        return profiles.allowsTool(self.profile, name);
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

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = agents.Agent;
        /// Loads main's profile before startup, so its model and effort reach
        /// startup like `--model` and `--effort`, which still win. Narrows
        /// main's tools to the profile.
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
            const held = &agent.profile;
            agent.profile_tools = try tool_set.narrow(held.arena.?.allocator(), base_tools, ProfileTools{
                .profile = &held.profile,
                .role = .main,
            });
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

//! Binds an ACP session to the workspace its client names in `cwd`.
//!
//! The server's workspace starts as the directory `fx acp` was launched in.
//! `session/new`, `session/load`, and `session/resume` may name a different
//! absolute directory; that session then uses it for file access, shell
//! commands, project instructions, project skills, project MCP servers, its
//! permission rules and `.fx.json` limits (`context`, `max_agent_steps`,
//! `max_tool_result_bytes`), and its session record. Connection settings such
//! as model, provider, credentials, and permission mode stay as resolved at
//! `initialize`.

const std = @import("std");
const server = @import("server.zig");
const app_runtime_setup = @import("../core/app/app_runtime_setup.zig");
const app_lifecycle = @import("../core/app/app_lifecycle.zig");
const builtin_skills = @import("../builtins/skills.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const workspace_access = @import("../core/workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const PrepareError = Allocator.Error || error{
    InvalidParams,
    InvalidCwd,
    CwdNotAbsolute,
    CwdUnavailable,
    WorkspaceSettingsUnavailable,
};

/// A staged workspace for one session. Nothing on the server changes until
/// `commit`, so a rejected request leaves the active session untouched.
pub const Binding = struct {
    root: []u8,
    access: workspace_access.WorkspaceAccess,
    skills: app_runtime_setup.LoadedSkills,
    /// The new root's own rules and limits, which `commit` installs in place of the launch
    /// workspace's.
    permission_rules: types.PermissionRuleSet,
    agent_step_limit: usize,
    max_tool_result_bytes: usize,
    context_enabled: bool,

    pub fn deinit(self: *Binding, alloc: Allocator) void {
        alloc.free(self.root);
        self.access.deinit(alloc);
        self.skills.deinit(alloc);
        self.permission_rules.deinit(alloc);
        self.* = undefined;
    }
};

pub fn prepareErrorMessage(err: PrepareError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "Out of memory",
        error.InvalidParams => "Invalid params",
        error.InvalidCwd => "cwd must be a string",
        error.CwdNotAbsolute => "cwd must be an absolute path",
        error.CwdUnavailable => "cwd must name an existing directory",
        error.WorkspaceSettingsUnavailable => "Workspace settings for cwd could not be loaded",
    };
}

/// Stages the workspace named by `cwd`. Returns null when `cwd` is absent,
/// names the current workspace, or the host pins the workspace root.
pub fn prepare(state: *const server.ServerState, alloc: Allocator, params_raw: ?[]const u8) PrepareError!?Binding {
    if (state.cfg.minimal_kernel or state.cfg.workspace_root_override != null) return null;
    const raw = params_raw orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidParams;
    const cwd = parsed.value.object.get("cwd") orelse return null;
    if (cwd == .null) return null;
    if (cwd != .string) return error.InvalidCwd;
    if (!std.Io.Dir.path.isAbsolute(cwd.string)) return error.CwdNotAbsolute;

    const root = io_mod.realpathAlloc(alloc, cwd.string) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CwdUnavailable,
    };
    var root_owned = true;
    defer if (root_owned) alloc.free(root);
    if (std.mem.eql(u8, root, state.workspace_root)) return null;
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{}) catch return error.CwdUnavailable;
    dir.close(io_mod.getIo());

    var detailed = try loadSettings(state, alloc, root);
    defer detailed.deinit(alloc);
    var access = try loadAccess(state, alloc, root, &detailed);
    errdefer access.deinit(alloc);
    var resolved: app_lifecycle.StartupState = .{ .agent_step_limit = state.cfg.default_agent_step_limit };
    defer resolved.deinit(alloc);
    try app_lifecycle.resolveSettings(alloc, &resolved, &detailed);
    var skills = try app_runtime_setup.loadSkills(alloc, root, builtin_skills.root_policy);
    errdefer skills.deinit(alloc);
    skill_runtime.traceDiagnostics("acp_session_workspace", skills.diagnostics);

    root_owned = false;
    return .{
        .root = root,
        .access = access,
        .skills = skills,
        .permission_rules = resolved.takePermissionRules(),
        .agent_step_limit = resolved.agent_step_limit,
        .max_tool_result_bytes = resolved.max_tool_result_bytes,
        .context_enabled = resolved.context_enabled,
    };
}

fn loadSettings(state: *const server.ServerState, alloc: Allocator, root: []const u8) PrepareError!config_runtime.DetailedSettings {
    var detailed = (if (state.cfg.home_override) |home|
        config_runtime.loadMergedSettingsDetailedFromHome(alloc, home, root)
    else
        config_runtime.loadMergedSettingsDetailed(alloc, root)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("acp", "session workspace settings unavailable err={s}", .{@errorName(err)});
            return error.WorkspaceSettingsUnavailable;
        },
    };
    errdefer detailed.deinit(alloc);
    for (detailed.diagnostics) |diagnostic| {
        if (diagnostic.layer != .user) continue;
        // A missing profile is valid; a rejected profile layer can hide configured denies.
        switch (diagnostic.cause) {
            .malformed_settings,
            .settings_too_large,
            .durable_path_unsafe,
            .private_state_permissions_unsupported,
            .invalid_model_id,
            .retired_skill_match_fuzzy,
            .invalid_context_limits,
            .invalid_tool_placement,
            .invalid_skill_symlink_authorities,
            => {
                debug_trace.logf("acp", "session workspace profile unavailable cause={s}", .{@tagName(diagnostic.cause)});
                return error.WorkspaceSettingsUnavailable;
            },
            .private_state_permissions_tightened,
            .ignored_project_user_only_setting,
            .legacy_workspace_preferences,
            .manual_backup_available,
            .invalid_additional_directories,
            .invalid_ultrafast_mode_override,
            => {},
        }
    }
    return detailed;
}

/// Saved directories come from the profile entry for the new root; command
/// line directories and suppression apply to every session.
fn loadAccess(state: *const server.ServerState, alloc: Allocator, root: []const u8, detailed: *const config_runtime.DetailedSettings) PrepareError!workspace_access.WorkspaceAccess {
    const saved: []const []const u8 = if (detailed.additional_directory_sources) |paths| paths else &.{};
    return workspace_access.WorkspaceAccess.init(
        alloc,
        root,
        saved,
        state.cfg.additional_directories,
        state.cfg.saved_directories_suppressed,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("acp", "session workspace access unavailable err={s}", .{@errorName(err)});
            return error.CwdUnavailable;
        },
    };
}

/// Installs a staged workspace and leaves `binding` empty, so its owner may
/// still call `deinit`. The previous session must already be released
/// because it borrows the server's workspace root.
pub fn commit(state: *server.ServerState, binding: *Binding) Allocator.Error!void {
    std.debug.assert(state.active_session == null);
    try state.skills.replaceLoaded(state.alloc, binding.skills.dir, binding.skills.skills, binding.skills.diagnostics);
    binding.skills = .{};
    debug_trace.logf("acp", "session workspace rebound bytes={d}", .{binding.root.len});
    if (state.workspace_root.len > 0) state.alloc.free(state.workspace_root);
    state.workspace_root = binding.root;
    binding.root = &.{};
    state.workspace_access.deinit(state.alloc);
    state.workspace_access = binding.access;
    binding.access = .{};
    state.permission_rules.deinit(state.alloc);
    state.permission_rules = binding.permission_rules;
    binding.permission_rules = .{};
    state.agent_step_limit = binding.agent_step_limit;
    state.max_tool_result_bytes = binding.max_tool_result_bytes;
    state.context_enabled = binding.context_enabled;
    state.context_snapshot.deinit(state.alloc);
    state.context_snapshot = .{};
}

test "a session bound to another workspace uses that workspace's rules and limits" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "launch");
    try tmp.dir.createDirPath(io_mod.getIo(), "bound");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const launch = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "launch");
    defer alloc.free(launch);
    const bound = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "bound");
    defer alloc.free(bound);

    const settings = try alloc.print(
        "{{\"workspaces\":{{\"{s}\":{{\"permission\":{{\"bash\":{{\"touch *\":\"allow\"}}}}}},\"{s}\":{{\"permission\":{{\"bash\":{{\"touch *\":\"deny\"}}}}}}}}}}",
        .{ launch, bound },
    );
    defer alloc.free(settings);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "home/.fx/settings.json", .data = settings });
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "bound/.fx.json",
        .data = "{\"context\":false,\"max_agent_steps\":1,\"max_tool_result_bytes\":131072}",
    });

    const Discard = struct {
        fn write(_: ?*anyopaque, _: []const u8) !void {}
    };
    var state = server.ServerState{
        .alloc = alloc,
        .cfg = undefined,
        .writer = @import("jsonrpc.zig").Writer.initCallback(null, Discard.write),
    };
    state.cfg.minimal_kernel = false;
    state.cfg.workspace_root_override = null;
    state.cfg.home_override = home;
    state.cfg.default_agent_step_limit = 25;
    state.cfg.additional_directories = &.{};
    state.cfg.saved_directories_suppressed = false;
    state.workspace_root = try alloc.dupe(u8, launch);
    state.agent_step_limit = 25;
    state.context_enabled = true;
    defer {
        state.workspace_access.deinit(alloc);
        alloc.free(state.workspace_root);
        state.permission_rules.deinit(alloc);
        state.skills.deinit(alloc);
        state.context_snapshot.deinit(alloc);
    }

    const params = try alloc.print("{{\"cwd\":\"{s}\"}}", .{bound});
    defer alloc.free(params);
    var binding = (try prepare(&state, alloc, params)).?;
    defer binding.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), binding.permission_rules.rules.len);
    try std.testing.expectEqualStrings("touch *", binding.permission_rules.rules[0].pattern);
    try std.testing.expectEqual(types.PermissionAction.deny, binding.permission_rules.rules[0].action);

    try commit(&state, &binding);
    try std.testing.expectEqualStrings(bound, state.workspace_root);
    try std.testing.expectEqual(@as(usize, 1), state.permission_rules.rules.len);
    try std.testing.expectEqual(types.PermissionAction.deny, state.permission_rules.rules[0].action);
    try std.testing.expectEqual(@as(usize, 1), state.agent_step_limit);
    try std.testing.expectEqual(@as(usize, 131072), state.max_tool_result_bytes);
    try std.testing.expect(!state.context_enabled);
}

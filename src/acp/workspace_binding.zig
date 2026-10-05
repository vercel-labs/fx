//! Binds an ACP session to the workspace its client names in `cwd`.
//!
//! The server's workspace starts as the directory `fx acp` was launched in.
//! `session/new`, `session/load`, and `session/resume` may name a different
//! absolute directory; that session then uses it for file access, shell
//! commands, project instructions, project skills, project MCP servers, and
//! its session record. Connection settings such as model, provider,
//! credentials, and permission policy stay as resolved at `initialize`.

const std = @import("std");
const server = @import("server.zig");
const app_runtime_setup = @import("../core/app/app_runtime_setup.zig");
const builtin_skills = @import("../builtins/skills.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
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

    pub fn deinit(self: *Binding, alloc: Allocator) void {
        alloc.free(self.root);
        self.access.deinit(alloc);
        self.skills.deinit(alloc);
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
    if (!std.fs.path.isAbsolute(cwd.string)) return error.CwdNotAbsolute;

    const root = io_mod.realpathAlloc(alloc, cwd.string) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CwdUnavailable,
    };
    var root_owned = true;
    defer if (root_owned) alloc.free(root);
    if (std.mem.eql(u8, root, state.workspace_root)) return null;
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{}) catch return error.CwdUnavailable;
    dir.close(io_mod.getIo());

    var access = try loadAccess(state, alloc, root);
    errdefer access.deinit(alloc);
    var skills = try app_runtime_setup.loadSkills(alloc, root, builtin_skills.root_policy);
    errdefer skills.deinit(alloc);
    skill_runtime.traceDiagnostics("acp_session_workspace", skills.diagnostics);

    root_owned = false;
    return .{ .root = root, .access = access, .skills = skills };
}

/// Saved directories come from the profile entry for the new root; command
/// line directories and suppression apply to every session.
fn loadAccess(state: *const server.ServerState, alloc: Allocator, root: []const u8) PrepareError!workspace_access.WorkspaceAccess {
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
    defer detailed.deinit(alloc);
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
    state.context_snapshot.deinit(state.alloc);
    state.context_snapshot = .{};
}

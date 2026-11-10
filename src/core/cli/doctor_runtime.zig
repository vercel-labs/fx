const std = @import("std");
const profile_paths = @import("../shared/profile_paths.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const agent_steps = @import("../config/agent_steps.zig");
const config_runtime = @import("../config/config_runtime.zig");
const settings_keys = @import("../config/settings_keys.zig");
const settings_messages = @import("settings_messages.zig");
const host = @import("../hosts/host.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mcp_health = @import("../mcp/health.zig");
const session_adapter = @import("../session/session_adapter.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const safe_git = @import("../shell_command/safe_git.zig");
const command_lex = @import("../shell_command/command_lex.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const app_runtime_setup = @import("../app/app_runtime_setup.zig");

const Allocator = std.mem.Allocator;
const default_session_diagnostics_limit: usize = 64;

pub const CheckStatus = enum {
    ok,
    warn,
    fail,
};

pub const Check = struct {
    name: []const u8,
    status: CheckStatus,
    detail: []const u8,
    owned_detail: ?[]u8 = null,
    /// What to run or change, for a check that found a problem.
    fix: ?[]const u8 = null,
    owned_fix: ?[]u8 = null,

    pub fn deinit(self: *Check, alloc: Allocator) void {
        if (self.owned_detail) |detail| alloc.free(detail);
        if (self.owned_fix) |fix| alloc.free(fix);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    workspace_root: []u8,
    model: []const u8,
    provider: model_provider.ProviderId = .gateway,
    owned_model: ?[]u8 = null,
    auth: auth_runtime.StatusSnapshot = .{},
    permission_mode: types.PermissionMode,
    agent_step_limit: usize,
    checks: []Check,
    /// The workspace is in a git repository, where fx pr and fx issue work.
    in_git_repository: bool = false,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        if (self.owned_model) |model| alloc.free(model);
        self.auth.deinit(alloc);
        for (self.checks) |*entry| entry.deinit(alloc);
        alloc.free(self.checks);
        self.* = undefined;
    }
};

const CollectOptions = struct {
    /// Old side folders whose session is gone: counted, or removed with
    /// `fx doctor --fix`.
    orphans: session_adapter.OrphanSweep = .count,
    version: []const u8 = "",
    channel: []const u8 = "",
    skill_root_policy: skill_contract.RootPolicy = .{ .managed_root_source = null },
};

/// The checks that read only this machine. The network and process checks
/// live in `doctor_probes.zig`.
pub fn collect(
    alloc: Allocator,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
    mcp_config_diagnostic: mcp_contract.ProfileConfigDiagnostic,
    mcp_issues: []const mcp_health.ConfigurationIssue,
    options: CollectOptions,
) !Snapshot {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    debug_trace.configureFromEnv(alloc, workspace_root);

    var checks: std.ArrayList(Check) = .empty;
    errdefer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    var snapshot = Snapshot{
        .workspace_root = workspace_root,
        .model = default_model,
        .permission_mode = config_runtime.default_permission_mode,
        .agent_step_limit = default_agent_step_limit,
        .checks = &.{},
    };
    errdefer {
        alloc.free(snapshot.workspace_root);
        if (snapshot.owned_model) |model| alloc.free(model);
        snapshot.auth.deinit(alloc);
    }

    const workspace_detail = try alloc.print("using workspace {s}", .{snapshot.workspace_root});
    try appendCheckOwned(&checks, alloc, "workspace", .ok, workspace_detail);
    try appendInstallCheck(&checks, alloc, options.version, options.channel);

    const paths = try config_runtime.discoverPaths(alloc, snapshot.workspace_root);
    defer {
        var mutable_paths = paths;
        mutable_paths.deinit(alloc);
    }

    var detailed = config_runtime.loadMergedSettingsDetailed(alloc, snapshot.workspace_root) catch |err| {
        // Settings are unreadable, so no remembered choice is available to honour.
        snapshot.auth = try auth_runtime.loadStatusSnapshot(alloc, secret_store, null);
        try appendConfigLoadFailureCheck(&checks, alloc, "config", "failed to load config", err);
        try appendMcpConfigCheck(&checks, alloc, mcp_config_diagnostic);
        try appendMcpIssueChecks(&checks, alloc, mcp_issues);
        try appendAuthCheck(&checks, alloc, snapshot.auth, snapshot.provider);
        try appendConfigLoadFailureCheck(&checks, alloc, "startup", "failed to resolve startup settings", err);
        try appendStateChecks(&checks, alloc, options.orphans);
        snapshot.in_git_repository = try appendGitCheck(&checks, alloc, snapshot.workspace_root);
        try appendSkillChecks(&checks, alloc, snapshot.workspace_root, options.skill_root_policy);

        snapshot.checks = try checks.toOwnedSlice(alloc);
        return snapshot;
    };
    defer detailed.deinit(alloc);
    snapshot.provider = detailed.settings.provider orelse .gateway;

    snapshot.auth = try auth_runtime.loadStatusSnapshotForProvider(
        alloc,
        secret_store,
        snapshot.provider,
        detailed.settings.credential_source,
    );

    try appendConfigCheck(&checks, alloc, paths, detailed.diagnostics);
    try appendConfigDiagnosticChecks(&checks, alloc, detailed.diagnostics);
    try appendUnknownSettingChecks(&checks, alloc, paths);
    try appendEnvChecks(&checks, alloc, detailed.settings.permission_mode, detailed.settings.max_agent_steps, default_agent_step_limit);
    try appendMcpConfigCheck(&checks, alloc, mcp_config_diagnostic);
    try appendMcpIssueChecks(&checks, alloc, mcp_issues);
    try appendAuthCheck(&checks, alloc, snapshot.auth, snapshot.provider);
    const selection = config_runtime.selectProviderModel(
        default_model,
        &detailed.settings,
        null,
        config_runtime.modelEnvOverride(),
    );
    try appendResolvedStartupCheck(&snapshot, &checks, alloc, selection, .{
        .permission_mode = detailed.settings.permission_mode,
        .max_agent_steps = detailed.settings.max_agent_steps,
    }, default_agent_step_limit);
    try appendStateChecks(&checks, alloc, options.orphans);
    snapshot.in_git_repository = try appendGitCheck(&checks, alloc, snapshot.workspace_root);
    try appendSkillChecks(&checks, alloc, snapshot.workspace_root, options.skill_root_policy);

    snapshot.checks = try checks.toOwnedSlice(alloc);
    return snapshot;
}

fn appendConfigDiagnosticChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        const file = switch (diagnostic.layer) {
            .user => profile_paths.displayText("~/.fx/settings.json"),
            .project => ".fx.json",
        };
        const rejected = causeRejectsLayer(diagnostic.cause);
        var detail_writer: std.Io.Writer.Allocating = .init(alloc);
        defer detail_writer.deinit();
        try detail_writer.writer.print(
            "{s}{s}: {s}",
            .{ file, if (rejected) " is ignored" else "", @tagName(diagnostic.cause) },
        );
        try config_runtime.writeDiagnosticMetadata(&detail_writer.writer, diagnostic);
        const detail = try detail_writer.toOwnedSlice();
        if (rejected) {
            try appendCheckOwnedFix(checks, alloc, "config", .fail, detail, try alloc.print("fix or remove {s}, then run fx doctor again", .{file}));
        } else {
            try appendCheckOwnedFix(checks, alloc, "config", .warn, detail, try configWarningFix(alloc, diagnostic, file));
        }
    }
}

/// What to change for a diagnostic that leaves its settings file in use.
fn configWarningFix(alloc: Allocator, diagnostic: config_runtime.ConfigDiagnostic, file: []const u8) ![]u8 {
    return switch (diagnostic.cause) {
        .invalid_additional_directories => alloc.print("fix additional_directories in {s}", .{file}),
        .ignored_project_user_only_setting => alloc.print("move {s} from .fx.json to {s}", .{ diagnostic.setting_key orelse "that setting", profile_paths.displayText("~/.fx/settings.json") }),
        .legacy_workspace_preferences => alloc.print("move these preferences out of workspaces in {s}", .{file}),
        .manual_backup_available => if (diagnostic.recovery_path) |path| blk: {
            const quoted = try command_lex.quoteWord(alloc, path);
            defer alloc.free(quoted);
            break :blk alloc.print("to go back to the last good settings, copy {s} to {s}", .{ quoted, file });
        } else alloc.print("fix or remove {s}, then run fx doctor again", .{file}),
        .private_state_permissions_tightened => alloc.print("check {s} if you did not write it yourself", .{file}),
        else => alloc.print("fix or remove {s}, then run fx doctor again", .{file}),
    };
}

/// Warns about each key fx doesn't know in the profile and project settings
/// files, with the closest known key. Startup ignores these keys silently.
fn appendUnknownSettingChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    paths: config_runtime.Paths,
) !void {
    if (paths.user_settings) |path| try appendUnknownSettingChecksFor(checks, alloc, path, profile_paths.displayText("~/.fx/settings.json"), .profile);
    try appendUnknownSettingChecksFor(checks, alloc, paths.workspace_settings, ".fx.json", .project);
}

fn appendUnknownSettingChecksFor(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    path: []const u8,
    display_path: []const u8,
    file: settings_keys.File,
) !void {
    // An unreadable or malformed file is already reported by the config check.
    const loaded = config_runtime.readSettingsFileJson(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    var parsed = loaded orelse return;
    defer parsed.deinit();
    const unknown = try settings_keys.findUnknown(alloc, parsed.value, file);
    defer alloc.free(unknown);
    for (unknown) |key| {
        try appendCheckOwnedFix(checks, alloc, "config", .warn, try settings_messages.formatUnknownSetting(alloc, key, display_path), try alloc.print("rename or remove that key in {s}", .{display_path}));
    }
    const older = try settings_keys.findOlderNames(alloc, parsed.value, file);
    defer alloc.free(older);
    for (older) |entry| {
        const fix = if (entry.both)
            try alloc.print("remove {s} from {s}", .{ entry.older, display_path })
        else
            try alloc.print("rename {s} to {s} in {s}", .{ entry.older, entry.current, display_path });
        try appendCheckOwnedFix(checks, alloc, "config", .warn, try settings_messages.formatOlderName(alloc, entry, display_path), fix);
    }
    if (parsed.value != .object) return;
    try appendOldYolo(checks, alloc, parsed.value.object, null, display_path);
    if (file != .profile) return;
    const workspaces = parsed.value.object.get("workspaces") orelse return;
    if (workspaces != .object) return;
    var iterator = workspaces.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* == .object) try appendOldYolo(checks, alloc, entry.value_ptr.object, entry.key_ptr.*, display_path);
    }
}

/// Warns about a saved `permission_mode: "yolo"`, the older name for
/// `full-access`.
fn appendOldYolo(checks: *std.ArrayList(Check), alloc: Allocator, object: std.json.ObjectMap, workspace: ?[]const u8, display_path: []const u8) !void {
    const mode = object.get("permission_mode") orelse return;
    if (mode != .string or !std.mem.eql(u8, mode.string, "yolo")) return;
    try appendCheckOwnedFix(checks, alloc, "config", .warn, try settings_messages.formatOldYolo(alloc, workspace, display_path), try alloc.print("set permission_mode to full-access in {s}", .{display_path}));
}

fn appendConfigCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    paths: config_runtime.Paths,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    const user_present = if (paths.user_settings) |path| try fileExists(path) else false;
    const repo_present = try fileExists(paths.workspace_settings);
    if (!user_present and !repo_present) {
        try appendCheck(checks, alloc, "config", .ok, "no config files; fx uses its defaults and env overrides");
        return;
    }
    const user_exists = user_present and !configLayerRejected(diagnostics, .user);
    const repo_exists = repo_present and !configLayerRejected(diagnostics, .project);
    // A file that exists but is ignored gets its own fail line.
    if (!user_exists and !repo_exists) return;

    const detail = try formatConfigPresence(alloc, user_exists, repo_exists);
    try appendCheckOwned(checks, alloc, "config", .ok, detail);
}

fn configLayerRejected(
    diagnostics: []const config_runtime.ConfigDiagnostic,
    layer: config_runtime.ConfigLayer,
) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.layer == layer and causeRejectsLayer(diagnostic.cause)) return true;
    }
    return false;
}

/// Whether startup ignores the whole file for this cause.
fn causeRejectsLayer(cause: @FieldType(config_runtime.ConfigDiagnostic, "cause")) bool {
    {
        switch (cause) {
            .malformed_settings,
            .settings_too_large,
            .durable_path_unsafe,
            .private_state_permissions_unsupported,
            .invalid_model_id,
            .retired_skill_match_fuzzy,
            .invalid_context_limits,
            .invalid_ultrafast_mode_override,
            .invalid_skill_symlink_authorities,
            => return true,
            .invalid_additional_directories,
            .ignored_project_user_only_setting,
            .legacy_workspace_preferences,
            .manual_backup_available,
            .private_state_permissions_tightened,
            => return false,
        }
    }
}

/// The command that signs in to `provider`.
pub fn loginCommand(provider: model_provider.ProviderId) []const u8 {
    return switch (provider) {
        .gateway => "fx login",
        .codex => "fx login codex",
        .grok => "fx login grok",
        .configured => profile_paths.displayText("check the connection's auth in ~/.fx/settings.json"),
    };
}

fn appendAuthCheck(checks: *std.ArrayList(Check), alloc: Allocator, auth: auth_runtime.StatusSnapshot, provider: model_provider.ProviderId) !void {
    if (auth.missingHelp(.cli)) |help| {
        try checks.append(alloc, .{ .name = "auth", .status = .fail, .detail = help, .fix = loginCommand(provider) });
        return;
    }

    const detail = try auth.formatDoctorDetail(alloc);
    if (auth.expired) {
        errdefer alloc.free(detail);
        try checks.append(alloc, .{ .name = "auth", .status = .warn, .detail = detail, .owned_detail = detail, .fix = loginCommand(provider) });
        return;
    }
    try appendCheckOwned(checks, alloc, "auth", .ok, detail);
}

fn appendResolvedStartupCheck(
    snapshot: *Snapshot,
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    selection: config_runtime.ModelSelectionError!model_provider.ProviderSelection,
    settings: config_runtime.StartupStatusSettings,
    default_agent_step_limit: usize,
) !void {
    snapshot.permission_mode = try resolvePermissionMode(settings.permission_mode);
    snapshot.agent_step_limit = try resolveAgentStepLimit(default_agent_step_limit, settings.max_agent_steps);
    if (snapshot.owned_model) |model| alloc.free(model);
    snapshot.owned_model = null;
    const selected = selection catch |err| {
        // Startup refuses this provider, so no model would run.
        snapshot.model = "";
        const fix: []const u8 = switch (err) {
            error.CodexModelNotSelected => "fx provider codex",
            error.GrokModelNotSelected => "fx provider grok",
            error.ConfiguredModelNotSelected => profile_paths.displayText("save a model under \"models\" in ~/.fx/settings.json"),
        };
        try checks.append(alloc, .{ .name = "startup", .status = .fail, .detail = config_runtime.modelNotSelectedMessage(err) orelse @errorName(err), .fix = fix });
        return;
    };
    const model = try alloc.dupe(u8, config_runtime.modelEnvOverride() orelse selected.model);
    snapshot.model = model;
    snapshot.owned_model = model;

    const detail = try alloc.print(
        "resolved model={s}, permission_mode={s}, agent_step_limit={d}",
        .{ snapshot.model, permissionModeLabel(snapshot.permission_mode), snapshot.agent_step_limit },
    );
    try appendCheckOwned(checks, alloc, "startup", .ok, detail);
}

fn appendConfigLoadFailureCheck(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, prefix: []const u8, err: anyerror) !void {
    const detail = try formatConfigLoadFailure(alloc, prefix, err);
    try appendCheckOwnedStaticFix(checks, alloc, name, .fail, detail, profile_paths.displayText("check that ~/.fx/settings.json and .fx.json can be read, then run fx doctor again"));
}

fn formatConfigLoadFailure(alloc: Allocator, prefix: []const u8, err: anyerror) ![]u8 {
    return alloc.print("{s}: {s}", .{ prefix, @errorName(err) });
}

/// Reports damaged sessions, and counts side folders whose session is gone
/// or removes them, as `orphans` says (D36). Rebuilds nothing.
fn appendStateChecks(checks: *std.ArrayList(Check), alloc: Allocator, orphans: session_adapter.OrphanSweep) !void {
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        const status: CheckStatus = if (err == error.HomeNotSet) .warn else .fail;
        try appendStateFailure(checks, alloc, status, err);
        return;
    };
    defer store.deinit(alloc);
    var report = session_adapter.doctor(&store, alloc, default_session_diagnostics_limit, io_mod.milliTimestamp(), orphans) catch |err| {
        try appendStateFailure(checks, alloc, .fail, err);
        return;
    };
    defer report.deinit(alloc);
    try appendCheck(checks, alloc, "state", .ok, "sessions ready");
    for (report.damaged.items) |id| {
        const detail = try alloc.print("session {s} has a damaged log; `fx session recover {s}` copies its good turns", .{ id, id });
        try appendCheckOwnedFix(checks, alloc, "session", .warn, detail, try alloc.print("fx session recover {s}", .{id}));
    }
    for (report.stuck.items) |stuck| try appendStuckCheck(checks, alloc, stuck);
    for (report.kept_children) |kept| {
        const detail = try alloc.print("session {s}, a subagent an older fx saved, is kept as it is: {s}", .{ kept.id, kept.reason });
        try appendCheckOwned(checks, alloc, "session", .ok, detail);
    }
    // The limit covers v1's unconverted sessions too (D73).
    if (report.checked < report.sessions + report.unconverted) try appendSessionDiagnosticsTruncatedCheck(checks, alloc, report.checked);
    if (report.removable > 0) {
        const detail = try alloc.print("{d} old terminal or side folder(s) whose session is gone can be removed", .{report.removable});
        try appendCheckOwnedFix(checks, alloc, "session", .warn, detail, try alloc.dupe(u8, "fx doctor --fix"));
    }
    if (report.removed > 0) {
        const detail = try alloc.print("removed {d} terminal or side folder(s) whose session is gone", .{report.removed});
        try appendCheckOwned(checks, alloc, "session", .ok, detail);
    }
    if (report.kept > 0) {
        const detail = try alloc.print("{d} terminal or side folder(s) whose session is gone could not be removed", .{report.kept});
        try appendCheckOwnedStaticFix(checks, alloc, "session", .warn, detail, profile_paths.displayText("check that you own the folders in ~/.fx/session-files and ~/.fx/terminal, then run fx doctor --fix again"));
    }
    if (report.keeps_left_out > 0) {
        const detail = try alloc.print("{d} earlier session folder(s) under ~/.fx/sessions keep files their conversion left out", .{report.keeps_left_out});
        try appendCheckOwned(checks, alloc, "sessions", .ok, detail);
    }
    const convertible = report.unconverted - report.stuck.items.len;
    if (convertible > 0) {
        const detail = try alloc.print("{d} session(s) saved by an older fx will be converted when first opened", .{convertible});
        try appendCheckOwned(checks, alloc, "sessions", .ok, detail);
    }
    try appendSessionsCountCheck(checks, alloc, report.sessions, report.latest orelse "", report.unconverted > 0);
}

/// The sessions could not be inspected at all.
fn appendStateFailure(checks: *std.ArrayList(Check), alloc: Allocator, status: CheckStatus, err: anyerror) !void {
    const fix = switch (err) {
        error.HomeNotSet => "set HOME, then run fx doctor again",
        error.PrivateStatePermissionsUnsupported => profile_paths.displayText("make ~/.fx private with chmod -R go-rwx ~/.fx, then run fx doctor again"),
        else => profile_paths.displayText("check that you own ~/.fx and can read it, then run fx doctor again"),
    };
    try appendCheckOwnedStaticFix(checks, alloc, "state", status, try alloc.print("failed to inspect sessions: {s}", .{@errorName(err)}), fix);
}

/// A session an older fx saved that can't be converted, with what
/// `fx session recover` copies of it (D73). Its v1 folder is kept.
fn appendStuckCheck(checks: *std.ArrayList(Check), alloc: Allocator, stuck: session_adapter.Doctor.Stuck) !void {
    if (stuck.recover == .nothing) {
        // The one problem with no fix: fx can copy nothing out of it.
        const detail = try alloc.print(
            "session {s} saved by an older fx can't be converted: {s}; nothing in it can be copied, so it is kept as it is",
            .{ stuck.id, stuck.reason },
        );
        return appendCheckOwned(checks, alloc, "session", .warn, detail);
    }
    const detail = switch (stuck.recover) {
        .without_rules => try alloc.print(
            "session {s} saved by an older fx can't be converted: {s}; `fx session recover {s}` copies its conversation without its saved permission rules",
            .{ stuck.id, stuck.reason, stuck.id },
        ),
        .good_turns => try alloc.print(
            "session {s} saved by an older fx can't be converted: {s}; `fx session recover {s}` copies its good turns",
            .{ stuck.id, stuck.reason, stuck.id },
        ),
        .nothing => unreachable,
    };
    try appendCheckOwnedFix(checks, alloc, "session", .warn, detail, try alloc.print("fx session recover {s}", .{stuck.id}));
}

fn appendSessionDiagnosticsTruncatedCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    inspected_count: usize,
) !void {
    const detail = try alloc.print(
        "session diagnostics truncated after {d} session director{s} to keep doctor bounded",
        .{ inspected_count, if (inspected_count == 1) "y" else "ies" },
    );
    try appendCheckOwnedStaticFix(checks, alloc, "session", .warn, detail, "run fx session ID to check a session doctor did not reach");
}

fn appendSessionsCountCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    count: usize,
    latest_id: []const u8,
    older_saved: bool,
) !void {
    if (count == 0) {
        // Sessions only an older fx saved are not "no sessions" (D73).
        if (!older_saved) try appendCheck(checks, alloc, "sessions", .ok, "no saved sessions yet");
        return;
    }

    const detail = try alloc.print("{d} saved session(s); latest={s}", .{ count, latest_id });
    try appendCheckOwned(checks, alloc, "sessions", .ok, detail);
}

/// Returns whether the workspace is in a git repository.
fn appendGitCheck(checks: *std.ArrayList(Check), alloc: Allocator, workspace_root: []const u8) !bool {
    if (!try inGitRepository(alloc, workspace_root)) {
        try checks.append(alloc, .{ .name = "git", .status = .warn, .detail = "this folder is not in a git repository; fx pr and fx issue need one", .fix = "run git init here, or run fx in a repository" });
        return false;
    }
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    switch (try safe_git.prepare(arena_state.allocator(), workspace_root)) {
        .ready => try appendCheck(checks, alloc, "git", .ok, "git is installed and this folder is in a repository"),
        .refused => |reason| {
            const text: struct { []const u8, []const u8 } = switch (reason) {
                .git_missing => .{ "git was not found where fx looks for it, such as /usr/bin/git; fx pr and fx issue need it", "install git" },
                .git_version_unknown => .{ "fx could not read the version of git", "git --version" },
                .git_too_old => .{ "git is too old for fx", "update git" },
                .repo_config_unavailable => .{ "fx could not read this repository's git config", "git config --list --show-origin" },
                .unsupported_filter_name => .{ "this repository's git config names a filter fx cannot turn off, so fx does not run git here", "rename that filter in the repository's git config so its name has no =" },
                .repository_mismatch => .{ "git would use a different repository than the one fx read here", "check GIT_DIR and GIT_WORK_TREE" },
            };
            try checks.append(alloc, .{ .name = "git", .status = .warn, .detail = text[0], .fix = text[1] });
        },
    }
    return true;
}

/// Whether `workspace_root` or a folder above it has a `.git` file or folder.
fn inGitRepository(alloc: Allocator, workspace_root: []const u8) !bool {
    var dir: ?[]const u8 = workspace_root;
    while (dir) |current| : (dir = std.Io.Dir.path.dirname(current)) {
        if (try hasGitMetadata(alloc, current)) return true;
    }
    return false;
}

/// The running fx, and any other `fx` on PATH that a shell could run instead.
fn appendInstallCheck(checks: *std.ArrayList(Check), alloc: Allocator, version: []const u8, channel: []const u8) !void {
    const self_path = std.process.executablePathAlloc(io_mod.getIo(), alloc) catch {
        try appendCheckOwnedStaticFix(checks, alloc, "install", .warn, try alloc.print("fx {s}; fx could not find its own binary", .{version}), "reinstall fx from https://fx.sh, then run fx doctor again");
        return;
    };
    defer alloc.free(self_path);
    try appendCheckOwned(checks, alloc, "install", .ok, try alloc.print("fx {s} at {s} ({s} channel)", .{ version, self_path, channel }));
    const self_real = io_mod.realpathAlloc(alloc, self_path) catch try alloc.dupe(u8, self_path);
    defer alloc.free(self_real);
    const path_env = io_mod.getenv("PATH") orelse return;
    var seen: std.ArrayList([]u8) = .empty;
    defer {
        for (seen.items) |item| alloc.free(item);
        seen.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, path_env, std.Io.Dir.path.delimiter);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try std.Io.Dir.path.join(alloc, &.{ entry, "fx" });
        defer alloc.free(candidate);
        if (!pathExists(candidate)) continue;
        const real = io_mod.realpathAlloc(alloc, candidate) catch continue;
        var known = std.mem.eql(u8, real, self_real);
        for (seen.items) |item| known = known or std.mem.eql(u8, item, real);
        if (known) {
            alloc.free(real);
            continue;
        }
        try seen.append(alloc, real);
        try appendCheckOwnedFix(
            checks,
            alloc,
            "install",
            .warn,
            try alloc.print("another fx at {s} is on PATH; a shell may run it instead of this one", .{candidate}),
            try alloc.dupe(u8, "remove the copy you do not use, so one fx is on PATH"),
        );
    }
}

/// FX_ values that startup cannot read and replaces silently.
fn appendEnvChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    configured_mode: ?types.PermissionMode,
    configured_steps: ?usize,
    default_steps: usize,
) !void {
    if (io_mod.getenv("FX_PERMISSION_MODE")) |raw| if (config_runtime.parsePermissionMode(raw) == null) {
        const used = permissionModeLabel(configured_mode orelse config_runtime.default_permission_mode);
        try appendCheckOwnedFix(checks, alloc, "env", .warn, try alloc.print("FX_PERMISSION_MODE={s} is not a mode; fx uses {s}", .{ raw, used }), try alloc.dupe(u8, "set it to ask, auto, or full-access, or unset it"));
    };
    if (io_mod.getenv("FX_MAX_AGENT_STEPS")) |raw| if (agent_steps.parseMaxAgentSteps(raw) == null) {
        const used = agent_steps.resolveMaxAgentSteps(configured_steps, default_steps);
        const detail = if (used == 0)
            try alloc.print("FX_MAX_AGENT_STEPS={s} is not a whole number; fx uses no step limit", .{raw})
        else
            try alloc.print("FX_MAX_AGENT_STEPS={s} is not a whole number; fx uses {d}", .{ raw, used });
        try appendCheckOwnedFix(checks, alloc, "env", .warn, detail, try alloc.dupe(u8, "set it to a whole number, or unset it"));
    };
}

/// Skill files that skill discovery skips, with their paths.
fn appendSkillChecks(checks: *std.ArrayList(Check), alloc: Allocator, workspace_root: []const u8, root_policy: skill_contract.RootPolicy) !void {
    var loaded = try app_runtime_setup.loadSkills(alloc, workspace_root, root_policy);
    defer loaded.deinit(alloc);
    for (loaded.diagnostics) |diagnostic| {
        const why: struct { []const u8, []const u8 } = switch (diagnostic.scope) {
            .root => .{ "could not be read, so some skills may be missing", "fix access to that folder" },
            .candidate => switch (diagnostic.cause) {
                .invalid_metadata => .{ "was skipped: its SKILL.md frontmatter is invalid", "use one safe name and a short description in its frontmatter" },
                .linked_candidate_unavailable => .{ "was skipped: its link does not lead to a readable folder", "repair or remove the link" },
                .unreadable => .{ "was skipped: SKILL.md cannot be read", "fix the file type or permissions of SKILL.md" },
                .oversized => .{ "was skipped: its frontmatter is too large", "shorten its name and description" },
            },
        };
        try appendCheckOwnedFix(checks, alloc, "skills", .warn, try alloc.print("{s} {s}", .{ diagnostic.path, why[0] }), try alloc.dupe(u8, why[1]));
    }
}

fn resolvePermissionMode(configured: ?types.PermissionMode) !types.PermissionMode {
    const fallback = configured orelse config_runtime.default_permission_mode;
    const raw = io_mod.getenv("FX_PERMISSION_MODE") orelse return fallback;
    return config_runtime.parsePermissionMode(raw) orelse fallback;
}

fn resolveAgentStepLimit(fallback: usize, configured: ?usize) !usize {
    return agent_steps.resolveMaxAgentStepsWithOverride(
        configured,
        fallback,
        io_mod.getenv("FX_MAX_AGENT_STEPS"),
    );
}

fn appendCheck(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, status: CheckStatus, detail: []const u8) !void {
    try checks.append(alloc, .{
        .name = name,
        .status = status,
        .detail = detail,
    });
}

/// Appends a check that owns its detail and its fix, if it has one. Both are
/// freed when the append fails.
pub fn appendCheckOwnedFix(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, status: CheckStatus, detail: []u8, fix: ?[]u8) !void {
    errdefer alloc.free(detail);
    errdefer if (fix) |owned| alloc.free(owned);
    try checks.append(alloc, .{
        .name = name,
        .status = status,
        .detail = detail,
        .owned_detail = detail,
        .fix = fix,
        .owned_fix = fix,
    });
}

/// Like `appendCheckOwnedFix`, for a fix that is not allocated.
fn appendCheckOwnedStaticFix(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, status: CheckStatus, detail: []u8, fix: []const u8) !void {
    errdefer alloc.free(detail);
    try checks.append(alloc, .{ .name = name, .status = status, .detail = detail, .owned_detail = detail, .fix = fix });
}

fn appendCheckOwned(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, status: CheckStatus, detail: []u8) !void {
    errdefer alloc.free(detail);
    try checks.append(alloc, .{
        .name = name,
        .status = status,
        .detail = detail,
        .owned_detail = detail,
    });
}

fn appendMcpConfigCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    diagnostic: mcp_contract.ProfileConfigDiagnostic,
) !void {
    switch (diagnostic) {
        .clear => return,
        .warning => |warning| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try out.writer.print(
                "{s}/mcp.json warning: {s}",
                .{ profile_paths.displayRoot(), @tagName(warning.cause) },
            );
            if (warning.key()) |key| try out.writer.print(" key={s}", .{key});
            try out.writer.print(
                " additional_matches={d}",
                .{warning.additional_matches},
            );
            const fix = switch (warning.cause) {
                .ignored_mcp_servers_alias, .suspicious_server_key => profile_paths.displayText("put each server under \"mcp\" in ~/.fx/mcp.json"),
                .suspicious_key_scan_indeterminate => profile_paths.displayText("check the keys in ~/.fx/mcp.json"),
            };
            try appendCheckOwnedStaticFix(checks, alloc, "mcp_config", .warn, try out.toOwnedSlice(), fix);
            return;
        },
        .failed => |err| {
            const detail = try alloc.print(
                "failed to load {s}/mcp.json: {s}",
                .{ profile_paths.displayRoot(), @errorName(err) },
            );
            try appendCheckOwnedStaticFix(checks, alloc, "mcp_config", .fail, detail, profile_paths.displayText("fix or remove ~/.fx/mcp.json, then run fx doctor again"));
            return;
        },
    }
}

/// One failure for each issue the MCP config inspection found, as for a
/// `~/.fx/mcp.json` fx cannot read. The inspection reads `~/.fx/mcp.json`
/// whole, so a problem there fails the file (`appendMcpConfigCheck`), and
/// its issues all come from the project's `.mcp.json`, each one a server
/// that does not load (`builtin_mcp.inspectLocalConfig`).
fn appendMcpIssueChecks(checks: *std.ArrayList(Check), alloc: Allocator, issues: []const mcp_health.ConfigurationIssue) !void {
    for (issues) |issue| {
        try appendCheckOwnedStaticFix(checks, alloc, "mcp_config", .fail, try alloc.dupe(u8, issue.message), "fix .mcp.json, then run fx doctor again");
    }
}

fn formatConfigPresence(alloc: Allocator, user_exists: bool, repo_exists: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("loaded config from ");
    var first = true;
    if (user_exists) {
        if (!first) try out.writer.writeAll(", ");
        first = false;
        try out.writer.writeAll(profile_paths.displayText("~/.fx/settings.json"));
    }
    if (repo_exists) {
        if (!first) try out.writer.writeAll(", ");
        try out.writer.writeAll(".fx.json");
    }
    return try out.toOwnedSlice();
}

fn fileExists(path: []const u8) !bool {
    if (comptime @import("builtin").target.os.tag != .windows) {
        return accessPath(path);
    }
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn hasGitMetadata(alloc: Allocator, workspace_root: []const u8) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const git_path = std.mem.print(&path_buf, "{s}" ++ std.Io.Dir.path.sep_str ++ ".git", .{workspace_root}) catch {
        const owned = try std.Io.Dir.path.join(alloc, &.{ workspace_root, ".git" });
        defer alloc.free(owned);
        return try fileExists(owned);
    };
    return try fileExists(git_path);
}

fn pathExists(path: []const u8) bool {
    if (comptime @import("builtin").target.os.tag != .windows) {
        return accessPath(path) catch false;
    }

    if (std.Io.Dir.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
        return true;
    }

    std.Io.Dir.cwd().access(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn accessPath(path: []const u8) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = std.mem.printSentinel(&path_buf, "{s}", .{path}, 0) catch return false;
    const rc = std.c.access(path_z.ptr, std.c.F_OK);
    if (rc == 0) return true;
    return switch (std.posix.errno(rc)) {
        .NOENT, .NOTDIR => false,
        .ACCES => false,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn permissionModeLabel(mode: types.PermissionMode) []const u8 {
    return switch (mode) {
        .ask => "ask",
        .auto => "auto",
        .yolo => "full access",
    };
}

test "format config presence names existing layers" {
    const detail = try formatConfigPresence(std.testing.allocator, true, false);
    defer std.testing.allocator.free(detail);

    try std.testing.expectEqualStrings("loaded config from ~/.fx/settings.json", detail);
}

test "MCP config diagnostic maps only failures to one doctor check" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendMcpConfigCheck(&checks, alloc, .clear);
    try std.testing.expectEqual(@as(usize, 0), checks.items.len);

    try appendMcpConfigCheck(
        &checks,
        alloc,
        .{ .failed = error.McpConfigInvalidJson },
    );
    try std.testing.expectEqual(@as(usize, 1), checks.items.len);
    try std.testing.expectEqualStrings("mcp_config", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.fail, checks.items[0].status);
    try std.testing.expectEqualStrings(
        "failed to load ~/.fx/mcp.json: McpConfigInvalidJson",
        checks.items[0].detail,
    );
}

test "config check handles user and workspace config files together" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeDoctorFixtureFile(tmp.dir, "home/.fx/settings.json", "{\"permission_mode\":\"ask\"}");
    try writeDoctorFixtureFile(tmp.dir, "workspace/.fx.json", "{\"permission_mode\":\"auto\"}");

    const home_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_root);
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);

    var paths = try config_runtime.discoverPathsFromHome(std.testing.allocator, home_root, workspace_root);
    defer paths.deinit(std.testing.allocator);

    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(std.testing.allocator);
        checks.deinit(std.testing.allocator);
    }

    try appendConfigCheck(&checks, std.testing.allocator, paths, &.{});

    try std.testing.expectEqual(@as(usize, 1), checks.items.len);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[0].status);
    try std.testing.expect(std.mem.find(u8, checks.items[0].detail, "~/.fx/settings.json") != null);
    try std.testing.expect(std.mem.find(u8, checks.items[0].detail, ".fx.json") != null);
}

test "config check does not claim rejected user settings loaded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeDoctorFixtureFile(tmp.dir, "home/.fx/settings.json", "{\"permission_mode\":\"ask\"}");
    try writeDoctorFixtureFile(tmp.dir, "workspace/.fx.json", "{\"permission_mode\":\"auto\"}");

    const home_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_root);
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);

    var paths = try config_runtime.discoverPathsFromHome(std.testing.allocator, home_root, workspace_root);
    defer paths.deinit(std.testing.allocator);

    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(std.testing.allocator);
        checks.deinit(std.testing.allocator);
    }

    const diagnostics = [_]config_runtime.ConfigDiagnostic{
        .{
            .layer = .user,
            .cause = .private_state_permissions_unsupported,
        },
    };
    try appendConfigCheck(&checks, std.testing.allocator, paths, &diagnostics);

    try std.testing.expectEqual(@as(usize, 1), checks.items.len);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[0].status);
    try std.testing.expect(std.mem.find(u8, checks.items[0].detail, "~/.fx/settings.json") == null);
    try std.testing.expect(std.mem.find(u8, checks.items[0].detail, ".fx.json") != null);
}

test "session count check preserves empty and latest details" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendSessionsCountCheck(&checks, alloc, 0, "", false);
    try appendSessionsCountCheck(&checks, alloc, 2, "session-2", false);
    // Sessions only an older fx saved are not "no sessions" (D73).
    try appendSessionsCountCheck(&checks, alloc, 0, "", true);

    try std.testing.expectEqual(@as(usize, 2), checks.items.len);
    try std.testing.expectEqualStrings("sessions", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[0].status);
    try std.testing.expectEqualStrings("no saved sessions yet", checks.items[0].detail);
    try std.testing.expectEqualStrings("sessions", checks.items[1].name);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[1].status);
    try std.testing.expectEqualStrings("2 saved session(s); latest=session-2", checks.items[1].detail);
}

test "doctor startup check fails when the provider has no model to run" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }
    var snapshot = Snapshot{
        .workspace_root = "",
        .model = "default/model",
        .permission_mode = config_runtime.default_permission_mode,
        .agent_step_limit = 25,
        .checks = &.{},
    };

    try appendResolvedStartupCheck(&snapshot, &checks, alloc, error.CodexModelNotSelected, .{ .max_agent_steps = 7 }, 25);
    try std.testing.expectEqualStrings("", snapshot.model);
    try std.testing.expectEqual(@as(usize, 7), snapshot.agent_step_limit);
    try std.testing.expectEqual(CheckStatus.fail, checks.items[0].status);
    try std.testing.expect(std.mem.startsWith(u8, checks.items[0].detail, "no Codex model is selected;"));

    try appendResolvedStartupCheck(&snapshot, &checks, alloc, .{ .provider = .codex, .model = "gpt-saved" }, .{}, 25);
    defer if (snapshot.owned_model) |model| alloc.free(model);
    try std.testing.expectEqualStrings("gpt-saved", snapshot.model);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[1].status);
}

test "bounded doctor warnings use existing check stream" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendSessionDiagnosticsTruncatedCheck(&checks, alloc, 64);

    try std.testing.expectEqual(@as(usize, 1), checks.items.len);
    try std.testing.expectEqualStrings("session", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
    try std.testing.expect(std.mem.find(
        u8,
        checks.items[0].detail,
        "truncated after 64 session directories",
    ) != null);
}

fn writeDoctorFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, text);
}

test "has git metadata detects .git file or directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);

    try std.testing.expect(try hasGitMetadata(std.testing.allocator, workspace_root));
}

test "each MCP config issue is a failure with a fix" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }
    const issues = [_]mcp_health.ConfigurationIssue{
        .{ .message = @constCast(".mcp.json server 'unknown' was skipped: invalid_json.") },
        .{ .message = @constCast(".mcp.json server 'odd' was skipped: its \"type\" isn't valid.") },
    };
    try appendMcpIssueChecks(&checks, alloc, &issues);
    try std.testing.expectEqual(issues.len, checks.items.len);
    for (issues, checks.items) |issue, check| {
        try std.testing.expectEqualStrings("mcp_config", check.name);
        try std.testing.expectEqual(CheckStatus.fail, check.status);
        try std.testing.expectEqualStrings(issue.message, check.detail);
        try std.testing.expectEqualStrings("fix .mcp.json, then run fx doctor again", check.fix.?);
    }
}

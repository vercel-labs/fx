const std = @import("std");
const auth_runtime = @import("../auth/auth_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const agent_steps = @import("../config/agent_steps.zig");
const config_runtime = @import("../config/config_runtime.zig");
const host = @import("../hosts/host.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const session_store = @import("../session/session_store.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");

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

    pub fn deinit(self: *Check, alloc: Allocator) void {
        if (self.owned_detail) |detail| alloc.free(detail);
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

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        if (self.owned_model) |model| alloc.free(model);
        self.auth.deinit(alloc);
        for (self.checks) |*entry| entry.deinit(alloc);
        alloc.free(self.checks);
        self.* = undefined;
    }
};

const ResolvedModel = struct {
    value: []const u8,
    owned: ?[]u8 = null,
};

pub fn collect(
    alloc: Allocator,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
    mcp_config_diagnostic: mcp_contract.ProfileConfigDiagnostic,
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

    const workspace_detail = try std.fmt.allocPrint(alloc, "using workspace {s}", .{snapshot.workspace_root});
    try appendCheckOwned(&checks, alloc, "workspace", .ok, workspace_detail);

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
        try appendAuthCheck(&checks, alloc, snapshot.auth);
        try appendConfigLoadFailureCheck(&checks, alloc, "startup", "failed to resolve startup settings", err);
        try appendStateChecks(&checks, alloc, snapshot.workspace_root);
        try appendGitCheck(&checks, alloc, snapshot.workspace_root);
        try appendGhCheck(&checks, alloc);

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
    try appendMcpConfigCheck(&checks, alloc, mcp_config_diagnostic);
    try appendAuthCheck(&checks, alloc, snapshot.auth);
    try appendResolvedStartupCheck(&snapshot, &checks, alloc, .{
        .model = switch (snapshot.provider) {
            .gateway => detailed.settings.model,
            .codex => detailed.settings.codex_model,
            .grok => detailed.settings.grok_model,
            .claude => detailed.settings.claude_model,
        },
        .permission_mode = detailed.settings.permission_mode,
        .max_agent_steps = detailed.settings.max_agent_steps,
    }, default_model, default_agent_step_limit);
    try appendStateChecks(&checks, alloc, snapshot.workspace_root);
    try appendGitCheck(&checks, alloc, snapshot.workspace_root);
    try appendGhCheck(&checks, alloc);

    snapshot.checks = try checks.toOwnedSlice(alloc);
    return snapshot;
}

fn appendConfigDiagnosticChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        var detail_writer: std.Io.Writer.Allocating = .init(alloc);
        defer detail_writer.deinit();
        try detail_writer.writer.print(
            "{s} config diagnostic: {s}",
            .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
        );
        try config_runtime.writeDiagnosticMetadata(&detail_writer.writer, diagnostic);
        const detail = try detail_writer.toOwnedSlice();
        try appendCheckOwned(checks, alloc, "config", .warn, detail);
    }
}

fn appendConfigCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    paths: config_runtime.Paths,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    const user_exists = if (paths.user_settings) |path|
        try fileExists(path) and !configLayerRejected(diagnostics, .user)
    else
        false;
    const repo_exists = try fileExists(paths.workspace_settings) and
        !configLayerRejected(diagnostics, .project);

    if (!user_exists and !repo_exists) {
        try appendCheck(checks, alloc, "config", .warn, "no config files found; using defaults and env overrides");
        return;
    }

    const detail = try formatConfigPresence(alloc, user_exists, repo_exists);
    try appendCheckOwned(checks, alloc, "config", .ok, detail);
}

fn configLayerRejected(
    diagnostics: []const config_runtime.ConfigDiagnostic,
    layer: config_runtime.ConfigLayer,
) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.layer != layer) continue;
        switch (diagnostic.cause) {
            .malformed_settings,
            .settings_too_large,
            .durable_path_unsafe,
            .private_state_permissions_unsupported,
            .invalid_model_id,
            .retired_skill_match_fuzzy,
            .invalid_context_limits,
            => return true,
            .invalid_additional_directories,
            .ignored_project_user_only_setting,
            .legacy_workspace_preferences,
            .manual_backup_available,
            => {},
        }
    }
    return false;
}

fn appendAuthCheck(checks: *std.ArrayList(Check), alloc: Allocator, auth: auth_runtime.StatusSnapshot) !void {
    if (auth.missingHelp(.cli)) |help| {
        try appendCheck(checks, alloc, "auth", .fail, help);
        return;
    }

    const detail = try auth.formatDoctorDetail(alloc);
    try appendCheckOwned(checks, alloc, "auth", if (auth.expired) .warn else .ok, detail);
}

fn appendResolvedStartupCheck(
    snapshot: *Snapshot,
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    settings: config_runtime.StartupStatusSettings,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !void {
    const next_model = try resolveModel(alloc, default_model, settings.model);
    if (snapshot.owned_model) |model| alloc.free(model);
    snapshot.model = next_model.value;
    snapshot.owned_model = next_model.owned;
    snapshot.permission_mode = try resolvePermissionMode(settings.permission_mode);
    snapshot.agent_step_limit = try resolveAgentStepLimit(default_agent_step_limit, settings.max_agent_steps);

    const detail = try std.fmt.allocPrint(
        alloc,
        "resolved model={s}, permission_mode={s}, agent_step_limit={d}",
        .{ snapshot.model, permissionModeLabel(snapshot.permission_mode), snapshot.agent_step_limit },
    );
    try appendCheckOwned(checks, alloc, "startup", .ok, detail);
}

fn appendConfigLoadFailureCheck(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, prefix: []const u8, err: anyerror) !void {
    const detail = try formatConfigLoadFailure(alloc, prefix, err);
    try appendCheckOwned(checks, alloc, name, .fail, detail);
}

fn formatConfigLoadFailure(alloc: Allocator, prefix: []const u8, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}: {s}", .{ prefix, @errorName(err) });
}

fn appendStateChecks(checks: *std.ArrayList(Check), alloc: Allocator, workspace_root: []const u8) !void {
    var store = session_store.Store.initReadOnly(alloc, workspace_root) catch |err| {
        const status: CheckStatus = if (err == error.HomeNotSet) .warn else .fail;
        const detail = try std.fmt.allocPrint(alloc, "failed to inspect workspace state: {s}", .{@errorName(err)});
        try appendCheckOwned(checks, alloc, "state", status, detail);
        return;
    };
    defer store.deinit(alloc);

    if (store.canonical_root.sessions == null) {
        try appendCheck(checks, alloc, "state", .warn, "durable state is not initialized");
        try appendCheck(checks, alloc, "sessions", .warn, "no saved sessions yet");
        return;
    }

    const state_detail = try std.fmt.allocPrint(alloc, "state dir ready at {s} (per-session managed state created on demand)", .{store.sessions_dir});
    try appendCheckOwned(checks, alloc, "state", .ok, state_detail);

    var inspection = try store.inspectForDoctorBounded(alloc, default_session_diagnostics_limit);
    defer inspection.deinit(alloc);
    try appendSessionDiagnosticChecks(
        checks,
        alloc,
        &store,
        inspection.diagnostics.items,
    );
    if (inspection.truncated) {
        try appendSessionDiagnosticsTruncatedCheck(checks, alloc, inspection.inspected_count);
    }

    if (try store.readStateSummary(alloc)) |summary_value| {
        var summary = summary_value;
        defer summary.deinit(alloc);
        try appendSessionsCountCheck(checks, alloc, summary.count, summary.latest_id orelse "");
        return;
    }

    try appendSessionsCountUnavailableCheck(checks, alloc);
}

fn appendSessionDiagnosticsTruncatedCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    inspected_count: usize,
) !void {
    const detail = try std.fmt.allocPrint(
        alloc,
        "session diagnostics truncated after {d} session director{s} to keep doctor bounded",
        .{ inspected_count, if (inspected_count == 1) "y" else "ies" },
    );
    try appendCheckOwned(checks, alloc, "session", .warn, detail);
}

fn appendSessionsCountUnavailableCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
) !void {
    try appendCheck(
        checks,
        alloc,
        "sessions",
        .warn,
        "exact saved-session count unavailable without a full session scan",
    );
}

fn appendSessionsCountCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    count: usize,
    latest_id: []const u8,
) !void {
    if (count == 0) {
        try appendCheck(checks, alloc, "sessions", .warn, "no saved sessions yet");
        return;
    }

    const detail = try std.fmt.allocPrint(alloc, "{d} saved session(s); latest={s}", .{ count, latest_id });
    try appendCheckOwned(checks, alloc, "sessions", .ok, detail);
}

fn appendSessionDiagnosticChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    read_store: *const session_store.Store,
    diagnostics: []const session_store.DoctorDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        if (diagnostic.kind == .cleanup_candidate) {
            const cleanup = read_store.cleanupForDoctor(
                alloc,
                diagnostic.session_id,
            ) catch |err| {
                const detail = try std.fmt.allocPrint(
                    alloc,
                    "session {s}: cleanup_candidate report_only=true error={s}",
                    .{ diagnostic.session_id, @errorName(err) },
                );
                try appendCheckOwned(checks, alloc, "session", .warn, detail);
                continue;
            };
            const detail = try std.fmt.allocPrint(
                alloc,
                "session {s}: cleanup_candidate cleanup_removed={d} report_only={d} ignored={d}",
                .{
                    diagnostic.session_id,
                    cleanup.removed,
                    cleanup.report_only,
                    cleanup.ignored,
                },
            );
            try appendCheckOwned(
                checks,
                alloc,
                "session",
                if (cleanup.removed > 0) .ok else .warn,
                detail,
            );
            continue;
        }

        const status: CheckStatus = switch (diagnostic.kind) {
            .authority_less_creation_orphan,
            .authority_transition_pending,
            .commit_intent_pending,
            .oversized_legacy_snapshot,
            .projection_missing,
            .projection_stale,
            .canonical_log_large,
            .canonical_log_compaction_overdue,
            .canonical_log_compaction_failed,
            .cleanup_candidate,
            => .warn,
            .invalid_authority_transition,
            .missing_authority,
            .invalid_authority,
            .invalid_commit_intent,
            .projection_invalid,
            .commit_watermark_missing,
            .commit_watermark_invalid,
            .commit_watermark_mismatched,
            .canonical_state_invalid,
            .unsafe_path,
            => .fail,
        };

        var recovery_buffer: [512]u8 = undefined;
        const recovery = try recoveryActionForSessionDiagnostic(
            diagnostic.kind,
            diagnostic.session_id,
            &recovery_buffer,
        );
        const detail = if (diagnostic.growth_bytes) |growth_bytes|
            try std.fmt.allocPrint(
                alloc,
                "session {s}: {s} bytes={d} growth_bytes={d} growth_frames={d}; recovery={s}",
                .{
                    diagnostic.session_id,
                    @tagName(diagnostic.kind),
                    diagnostic.bytes.?,
                    growth_bytes,
                    diagnostic.growth_frames.?,
                    recovery,
                },
            )
        else if (diagnostic.bytes) |bytes|
            try std.fmt.allocPrint(
                alloc,
                "session {s}: {s} bytes={d}; recovery={s}",
                .{ diagnostic.session_id, @tagName(diagnostic.kind), bytes, recovery },
            )
        else
            try std.fmt.allocPrint(
                alloc,
                "session {s}: {s}{s}; recovery={s}",
                .{
                    diagnostic.session_id,
                    @tagName(diagnostic.kind),
                    if (diagnostic.kind == .authority_transition_pending)
                        " report_only=true"
                    else
                        "",
                    recovery,
                },
            );
        try appendCheckOwned(checks, alloc, "session", status, detail);
    }
}

fn recoveryActionForSessionDiagnostic(
    kind: session_store.DoctorIssueKind,
    session_id: []const u8,
    buffer: []u8,
) ![]const u8 {
    return switch (kind) {
        .authority_less_creation_orphan,
        .authority_transition_pending,
        .commit_intent_pending,
        .cleanup_candidate,
        => "rerun fx doctor after active writers exit; cleanup is guarded",

        .canonical_log_large,
        .canonical_log_compaction_overdue,
        => "resume or update the session to trigger compaction",

        .canonical_log_compaction_failed,
        => "inspect the failed compaction artifact; keep it until no writer is active",

        .oversized_legacy_snapshot,
        => "rerun migration with --allow-large only after verifying the legacy snapshot",

        .projection_missing,
        .projection_stale,
        => "open the session detail or resume it to rebuild projections",

        .commit_watermark_missing,
        .commit_watermark_invalid,
        .commit_watermark_mismatched,
        => std.fmt.bufPrint(
            buffer,
            "run fx session recover {s}; it creates a separate resumable copy and leaves the source unchanged",
            .{session_id},
        ),

        .projection_invalid,
        .canonical_state_invalid,
        .invalid_commit_intent,
        => std.fmt.bufPrint(
            buffer,
            "back up ~/.fx/sessions, then inspect this session with fx session {s} --json",
            .{session_id},
        ),

        .missing_authority,
        .invalid_authority,
        .invalid_authority_transition,
        .unsafe_path,
        => "back up ~/.fx/sessions and avoid opening this session until the path is repaired",
    };
}

fn appendGitCheck(checks: *std.ArrayList(Check), alloc: Allocator, workspace_root: []const u8) !void {
    if (try hasGitMetadata(alloc, workspace_root)) {
        try appendCheck(checks, alloc, "git", .ok, "git metadata detected for this workspace");
        return;
    }
    try appendCheck(checks, alloc, "git", .warn, "not a git repository; pr/issue workflows will be limited");
}

fn appendGhCheck(checks: *std.ArrayList(Check), alloc: Allocator) !void {
    if (try commandInPath(alloc, "gh")) {
        try appendCheck(checks, alloc, "gh", .ok, "GitHub CLI found in PATH");
        return;
    }
    try appendCheck(checks, alloc, "gh", .warn, "GitHub CLI not found in PATH; publish workflows unavailable");
}

fn resolveModel(alloc: Allocator, default_model: []const u8, configured: ?[]const u8) !ResolvedModel {
    if (io_mod.getenv("FX_MODEL")) |model| {
        const trimmed = std.mem.trim(u8, model, " \t\r\n");
        if (trimmed.len > 0) return .{ .value = trimmed };
    }

    if (configured) |model| {
        const owned = try alloc.dupe(u8, model);
        return .{ .value = owned, .owned = owned };
    }

    return .{ .value = default_model };
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
    const err = switch (diagnostic) {
        .clear => return,
        .failed => |value| value,
    };
    const detail = try std.fmt.allocPrint(
        alloc,
        "failed to load ~/.fx/mcp.json: {s}",
        .{@errorName(err)},
    );
    try appendCheckOwned(checks, alloc, "mcp_config", .fail, detail);
}

fn formatConfigPresence(alloc: Allocator, user_exists: bool, repo_exists: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("loaded config from ");
    var first = true;
    if (user_exists) {
        if (!first) try out.writer.writeAll(", ");
        first = false;
        try out.writer.writeAll("~/.fx/settings.json");
    }
    if (repo_exists) {
        if (!first) try out.writer.writeAll(", ");
        try out.writer.writeAll(".fx.json");
    }
    return try out.toOwnedSlice();
}

fn fileExists(path: []const u8) !bool {
    if (comptime @import("builtin").os.tag != .windows) {
        return accessPath(path);
    }
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn hasGitMetadata(alloc: Allocator, workspace_root: []const u8) !bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_path = std.fmt.bufPrint(&path_buf, "{s}" ++ std.fs.path.sep_str ++ ".git", .{workspace_root}) catch {
        const owned = try std.fs.path.join(alloc, &.{ workspace_root, ".git" });
        defer alloc.free(owned);
        return try fileExists(owned);
    };
    return try fileExists(git_path);
}

fn commandInPath(alloc: Allocator, command_name: []const u8) !bool {
    const path_env = io_mod.getenv("PATH") orelse return false;

    return commandInPathValue(alloc, command_name, path_env);
}

fn commandInPathValue(alloc: Allocator, command_name: []const u8, path_env: []const u8) !bool {
    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;

        var candidate_buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrint(&candidate_buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ entry, command_name }) catch {
            const owned = try std.fs.path.join(alloc, &.{ entry, command_name });
            defer alloc.free(owned);
            if (pathExists(owned)) return true;
            continue;
        };

        if (pathExists(candidate)) {
            return true;
        }
    }

    return false;
}

fn pathExists(path: []const u8) bool {
    if (comptime @import("builtin").os.tag != .windows) {
        return accessPath(path) catch false;
    }

    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
        return true;
    }

    std.Io.Dir.cwd().access(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn accessPath(path: []const u8) !bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
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
        .yolo => "yolo",
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

    try appendSessionsCountCheck(&checks, alloc, 0, "");
    try appendSessionsCountCheck(&checks, alloc, 2, "session-2");

    try std.testing.expectEqual(@as(usize, 2), checks.items.len);
    try std.testing.expectEqualStrings("sessions", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
    try std.testing.expectEqualStrings("no saved sessions yet", checks.items[0].detail);
    try std.testing.expectEqualStrings("sessions", checks.items[1].name);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[1].status);
    try std.testing.expectEqualStrings("2 saved session(s); latest=session-2", checks.items[1].detail);
}

test "bounded doctor warnings use existing check stream" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendSessionDiagnosticsTruncatedCheck(&checks, alloc, 64);
    try appendSessionsCountUnavailableCheck(&checks, alloc);

    try std.testing.expectEqual(@as(usize, 2), checks.items.len);
    try std.testing.expectEqualStrings("session", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
    try std.testing.expect(std.mem.find(
        u8,
        checks.items[0].detail,
        "truncated after 64 session directories",
    ) != null);
    try std.testing.expectEqualStrings("sessions", checks.items[1].name);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[1].status);
    try std.testing.expect(std.mem.find(
        u8,
        checks.items[1].detail,
        "unavailable without a full session scan",
    ) != null);
}

test "session doctor renders precise watermark and compaction diagnostics" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }
    var unused_store: session_store.Store = undefined;
    const diagnostics = [_]session_store.DoctorDiagnostic{
        .{
            .session_id = @constCast("missing-watermark"),
            .kind = .commit_watermark_missing,
        },
        .{
            .session_id = @constCast("failed-compaction"),
            .kind = .canonical_log_compaction_failed,
            .bytes = 1024,
            .growth_bytes = 512,
            .growth_frames = 9,
        },
    };

    try appendSessionDiagnosticChecks(
        &checks,
        alloc,
        &unused_store,
        &diagnostics,
    );

    try std.testing.expectEqual(@as(usize, 2), checks.items.len);
    try std.testing.expectEqual(CheckStatus.fail, checks.items[0].status);
    try std.testing.expect(std.mem.find(
        u8,
        checks.items[0].detail,
        "commit_watermark_missing",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        checks.items[0].detail,
        "fx session recover missing-watermark",
    ) != null);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[1].status);
    try std.testing.expect(std.mem.find(
        u8,
        checks.items[1].detail,
        "growth_bytes=512 growth_frames=9",
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

test "command in path checks explicit path entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "bin");
    var file = try tmp.dir.createFile(std.testing.io, "bin/gh", .{});
    file.close(io_mod.getIo());

    const bin_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "bin");
    defer std.testing.allocator.free(bin_root);

    const path_env = try std.fmt.allocPrint(std.testing.allocator, "{s}", .{bin_root});
    defer std.testing.allocator.free(path_env);

    try std.testing.expect(try commandInPathValue(std.testing.allocator, "gh", path_env));
    try std.testing.expect(!(try commandInPathValue(std.testing.allocator, "missing-command", path_env)));
}

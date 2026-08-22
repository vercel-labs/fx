const std = @import("std");
const io_mod = @import("../shared/io.zig");
const agent_steps = @import("../config/agent_steps.zig");
const config_runtime = @import("../config/config_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const claude_code_store = @import("../auth/claude_code_store.zig");
const credentials = @import("../auth/credentials.zig");
const host = @import("../hosts/host.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const record_tape = @import("../workspace/record_tape.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const update_target = @import("../upgrade/update_target.zig");
const notification_sound = @import("../notifications/sound.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");
const ui_render = @import("../../ui/render.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const ui_terminal = @import("../../ui/terminal/terminal.zig");
const terminal_diff = @import("../../ui/render_engine/terminal_diff.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const PermissionMode = types.PermissionMode;
const CursorPosition = shell_runtime.CursorPosition;
const TerminalState = shell_runtime.TerminalState;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
pub const ResizeHandler = shell_runtime.ResizeHandler;
pub const default_permission_mode = config_runtime.default_permission_mode;

/// Compile-time terminal restoration for one async-signal-safe `write(2)` call.
/// Resets terminal modes and ends with a newline before the next shell prompt.
const abnormal_exit_restore_prefix = "\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l\x1b[?1l\x1b>\x1b[?1049l\x1b[?7h\x1b[4l\x1b[?6l\x1b[0m\x1b[?25h\x1b[?2031l\x1b[?2004l";
const abnormal_exit_restore = abnormal_exit_restore_prefix ++ "\x1b[<u\x1b[>4;0m\n";
const tmux_abnormal_exit_restore = abnormal_exit_restore_prefix ++ "\x1b[>4;0m\n";
const normal_exit_restore_prefix = ui_terminal.theme_notification_disable_sequence ++ "\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l\x1b[?1l\x1b>\x1b[4l\x1b[?6l\x1b[?2004l";
const normal_exit_restore = normal_exit_restore_prefix ++ "\x1b[<u\x1b[>4;0m";
const tmux_normal_exit_restore = normal_exit_restore_prefix ++ "\x1b[>4;0m";
const alternate_screen_enter = "\x1b[?1049h";
const alternate_mouse_tracking_enter = "\x1b[?1000h\x1b[?1006h";
const terminal_takeover_reset = "\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l\x1b[?1l\x1b>\x1b[?2004l\x1b[<u\x1b[>4;0m\x1b[4l\x1b[?6l\x1b[?7h\x1b[0m\x1b[?25h";

/// Original handlers, written at bootstrap and restored at shutdown.
/// Signal context never mutates them.
var old_sigterm_action: ?std.posix.Sigaction = null;
var old_sighup_action: ?std.posix.Sigaction = null;

/// Restores terminal state, installs the default disposition, and re-raises.
/// Must remain async-signal-safe: only `write(2)`, `sigaction(2)`, and `raise(3)`.
fn abnormalExitHandlerWithRestore(comptime restore: []const u8, sig: std.posix.SIG) void {
    // Signal context cannot recover from a failed async-signal-safe write.
    _ = std.c.write(
        std.posix.STDOUT_FILENO,
        restore.ptr,
        restore.len,
    );

    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &default_action, null);
    _ = std.c.raise(sig);
}

fn abnormalExitHandler(sig: std.posix.SIG) callconv(.c) void {
    abnormalExitHandlerWithRestore(abnormal_exit_restore, sig);
}

fn tmuxAbnormalExitHandler(sig: std.posix.SIG) callconv(.c) void {
    abnormalExitHandlerWithRestore(tmux_abnormal_exit_restore, sig);
}

/// Install handlers for SIGTERM and SIGHUP so an externally-terminated
/// fx restores terminal state before dying. SIGINT is not included
/// because raw mode disables terminal-generated SIGINT.
pub fn installAbnormalExitHandlers(tmux: ?[]const u8) void {
    if (!shell_runtime.supports_resize_signal) return;

    const handler: std.posix.Sigaction.handler_fn = if (tmux == null)
        abnormalExitHandler
    else
        tmuxAbnormalExitHandler;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, &act, &old_term);
    old_sigterm_action = old_term;

    var old_hup: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.HUP, &act, &old_hup);
    old_sighup_action = old_hup;
}

pub fn uninstallAbnormalExitHandlers() void {
    if (!shell_runtime.supports_resize_signal) return;

    if (old_sigterm_action) |old| {
        std.posix.sigaction(std.posix.SIG.TERM, &old, null);
        old_sigterm_action = null;
    }
    if (old_sighup_action) |old| {
        std.posix.sigaction(std.posix.SIG.HUP, &old, null);
        old_sighup_action = null;
    }
}

pub const StartupState = struct {
    workspace_root: []u8 = &.{},
    workspace_access: workspace_access.WorkspaceAccess = .{},
    credential: ?credentials.Credential = null,
    credential_onboarding_skipped: bool = false,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    provider: model_provider.ProviderId = .gateway,
    selected_model: []u8 = &.{},
    configured_model: []u8 = &.{},
    model_source: config_runtime.ModelSource = .compiled_default,
    permission_mode: PermissionMode = default_permission_mode,
    yolo_acknowledged: bool = false,
    permission_rules: types.PermissionRuleSet = .{},
    agent_step_limit: usize,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    context_limits: config_runtime.context_limits.Values = .{},
    context_enabled: bool = true,
    fast_mode: bool = false,
    fast_mode_source: config_runtime.ConfigSource = .compiled_default,
    slash_menu_categories: bool = true,
    auto_upgrade: bool = true,
    update_channel: update_target.Channel = .stable,
    startup_scrollback: bool = true,
    prompt_history_enabled: bool = true,
    prompt_history_store_allowed: bool = true,
    config_diagnostics: []config_runtime.ConfigDiagnostic = &.{},
    effort: types.ReasoningEffort = .auto,
    first_call_tool_choice: types.ToolChoice = .auto,
    statusline_context: bool = false,
    statusline_session: bool = false,
    statusline_workspace: bool = false,
    notification_turn_end: bool = false,
    notification_attention_required: bool = false,
    notification_max: bool = false,
    theme_monitor_enabled: bool = false,

    pub fn deinit(self: *StartupState, alloc: Allocator) void {
        self.workspace_access.deinit(alloc);
        if (self.workspace_root.len > 0) alloc.free(self.workspace_root);
        if (self.credential) |*credential| credential.deinit(alloc);
        if (self.selected_model.len > 0) alloc.free(self.selected_model);
        if (self.configured_model.len > 0) alloc.free(self.configured_model);
        self.permission_rules.deinit(alloc);
        if (self.config_diagnostics.len > 0) {
            for (self.config_diagnostics) |*diagnostic| diagnostic.deinit(alloc);
            alloc.free(self.config_diagnostics);
        }
        self.* = .{ .agent_step_limit = self.agent_step_limit };
    }

    pub fn takeWorkspaceRoot(self: *StartupState) []u8 {
        const value = self.workspace_root;
        self.workspace_root = &.{};
        return value;
    }

    pub fn takeWorkspaceAccess(self: *StartupState) workspace_access.WorkspaceAccess {
        const value = self.workspace_access;
        self.workspace_access = .{};
        return value;
    }

    pub fn apiKey(self: *const StartupState) ?[]const u8 {
        const credential = self.credential orelse return null;
        if (credential.needsRefreshAt(io_mod.milliTimestamp())) return null;
        return credential.token;
    }

    pub fn modelCatalogAccess(self: *const StartupState) credentials.CatalogAccess {
        return credentials.catalogAccessAt(self.credential, io_mod.milliTimestamp());
    }

    pub fn gatewayTeam(self: *const StartupState) ?[]const u8 {
        const credential = self.credential orelse return null;
        if (credential.needsRefreshAt(io_mod.milliTimestamp())) return null;
        return credential.gatewayTeam();
    }

    pub fn takeCredential(self: *StartupState) ?credentials.Credential {
        const value = self.credential;
        self.credential = null;
        return value;
    }

    pub fn takeSelectedModel(self: *StartupState) []u8 {
        const value = self.selected_model;
        self.selected_model = &.{};
        return value;
    }

    pub fn takePermissionRules(self: *StartupState) types.PermissionRuleSet {
        const value = self.permission_rules;
        self.permission_rules = .{};
        return value;
    }
};

pub const StartupStatus = struct {
    workspace_root: []u8,
    provider: model_provider.ProviderId = .gateway,
    selected_model: []const u8,
    owned_selected_model: ?[]u8 = null,
    auth: auth_runtime.StatusSnapshot = .{},
    permission_mode: PermissionMode,
    agent_step_limit: usize,
    update_channel: update_target.Channel = .stable,
    config_diagnostics: []config_runtime.ConfigDiagnostic = &.{},

    pub fn deinit(self: *StartupStatus, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        if (self.owned_selected_model) |model| alloc.free(model);
        self.auth.deinit(alloc);
        if (self.config_diagnostics.len > 0) {
            for (self.config_diagnostics) |*diagnostic| diagnostic.deinit(alloc);
            alloc.free(self.config_diagnostics);
        }
        self.* = undefined;
    }
};

const StartupStatusModel = struct {
    value: []const u8,
    owned: ?[]u8 = null,
};

pub const BootstrapConfig = struct {
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    terminal_title: host.TerminalTitle,
    footer_rows: u16,
    startup_min_body_rows: u16 = 0,
    default_model: []const u8,
    default_agent_step_limit: usize,
    secret_store: host.SecretStore,
    resize_handler: ResizeHandler,
    fx_version: []const u8 = "",
    record_requested: bool = false,
};

pub fn loadStartupState(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, transport, secret_store, workspace_root, default_model, default_agent_step_limit, null, .refresh_if_needed);
}

pub fn loadStartupStateWithoutCredentials(alloc: Allocator, default_model: []const u8, default_agent_step_limit: usize) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, workspace_root, default_model, default_agent_step_limit, null, null);
}

pub fn loadEmbeddedStartupState(
    alloc: Allocator,
    home_dir: []const u8,
    workspace_root: []const u8,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupState {
    const owned_workspace_root = try io_mod.realpathAlloc(alloc, workspace_root);
    return loadStartupStateFromOwnedWorkspace(
        alloc,
        oauth_transport.unavailable_provider,
        host.unavailable_secret_store,
        owned_workspace_root,
        default_model,
        default_agent_step_limit,
        home_dir,
        null,
    );
}

pub fn loadCatalogStartupState(
    alloc: Allocator,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, oauth_transport.unavailable_provider, secret_store, workspace_root, default_model, default_agent_step_limit, null, .stored);
}

pub fn loadStartupStatus(
    alloc: Allocator,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupStatus {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    errdefer alloc.free(workspace_root);
    debug_trace.configureFromEnv(alloc, workspace_root);

    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, workspace_root);
    defer detailed.deinit(alloc);
    const settings = &detailed.settings;
    if (settings.claude_code_tools) |enabled| {
        claude_code_store.setClaudeCodeToolsFromSettings(enabled);
    }

    const configured_selection = try configuredProviderSelection(default_model, settings);
    const selected_model = try loadStartupStatusModel(alloc, configured_selection.model, null);
    errdefer if (selected_model.owned) |model| alloc.free(model);

    var auth_status = try auth_runtime.loadStatusSnapshotForProvider(
        alloc,
        secret_store,
        configured_selection.provider,
        settings.credential_source,
    );
    errdefer auth_status.deinit(alloc);

    const result = StartupStatus{
        .workspace_root = workspace_root,
        .provider = configured_selection.provider,
        .selected_model = selected_model.value,
        .owned_selected_model = selected_model.owned,
        .auth = auth_status,
        .permission_mode = loadPermissionMode(settings.permission_mode),
        .agent_step_limit = loadAgentStepLimit(default_agent_step_limit, settings.max_agent_steps),
        .update_channel = settings.update_channel orelse .stable,
        .config_diagnostics = detailed.diagnostics,
    };
    auth_status.owned_team = null;
    detailed.diagnostics = &.{};
    return result;
}

pub fn applyWorkspaceLaunch(
    self: *StartupState,
    alloc: Allocator,
    command_line_directories: []const []const u8,
    saved_suppressed: bool,
) !void {
    try self.workspace_access.applyLaunch(
        alloc,
        self.workspace_root,
        command_line_directories,
        saved_suppressed,
    );
}

fn loadStartupStateForWorkspace(alloc: Allocator, workspace_root: []const u8, default_model: []const u8, default_agent_step_limit: usize) !StartupState {
    const owned_workspace_root = try alloc.dupe(u8, workspace_root);
    return loadStartupStateFromOwnedWorkspace(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, owned_workspace_root, default_model, default_agent_step_limit, null, null);
}

const CredentialLoadMode = credentials.LoadMode;

fn loadStartupStateFromOwnedWorkspace(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    owned_workspace_root: []u8,
    default_model: []const u8,
    default_agent_step_limit: usize,
    profile_home: ?[]const u8,
    credential_mode: ?CredentialLoadMode,
) !StartupState {
    var state = StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);

    state.workspace_root = owned_workspace_root;
    debug_trace.configureFromEnv(alloc, state.workspace_root);
    var detailed = if (profile_home) |home_dir|
        try config_runtime.loadMergedSettingsDetailedFromHome(alloc, home_dir, state.workspace_root)
    else
        try config_runtime.loadMergedSettingsDetailed(alloc, state.workspace_root);
    defer detailed.deinit(alloc);
    const settings = &detailed.settings;
    if (settings.claude_code_tools) |enabled| {
        claude_code_store.setClaudeCodeToolsFromSettings(enabled);
    }

    state.workspace_access = try workspace_access.WorkspaceAccess.init(
        alloc,
        state.workspace_root,
        detailed.additional_directory_sources orelse &.{},
        &.{},
        false,
    );

    const configured_selection = try configuredProviderSelection(default_model, settings);
    state.provider = configured_selection.provider;
    state.configured_model = try alloc.dupe(u8, configured_selection.model);
    state.model_source = detailed.model_source orelse .compiled_default;
    state.selected_model = try loadInitialModel(alloc, configured_selection.model, null);
    if (hasProcessModelOverride()) state.model_source = .process_override;
    state.config_diagnostics = detailed.diagnostics;
    detailed.diagnostics = &.{};
    state.prompt_history_enabled = settings.prompt_history_enabled orelse true;
    state.prompt_history_store_allowed = detailed.prompt_history_store_allowed;
    if (credential_mode) |mode| {
        const resolution = try credentials.resolveForProvider(
            alloc,
            transport,
            secret_store,
            mode,
            state.provider,
            settings.credential_source,
        );
        state.credential = resolution.credential;
        state.stored_key_status = resolution.stored_key_status;
    }
    state.permission_mode = loadPermissionMode(settings.permission_mode);
    state.yolo_acknowledged = settings.yolo_acknowledged orelse false;
    state.permission_rules = try types.dupePermissionRuleSet(alloc, settings.permission_rules);
    state.agent_step_limit = loadAgentStepLimit(default_agent_step_limit, settings.max_agent_steps);
    state.max_tool_result_bytes = tool_result_limits.resolveMaxToolResultBytes(settings.max_tool_result_bytes, tool_result_limits.default_max_tool_result_bytes);
    state.context_limits = config_runtime.resolveContextLimits(settings, &.{});
    state.context_enabled = settings.context orelse true;
    state.fast_mode = settings.fast_mode orelse
        (state.provider == .gateway and state.model_source == .compiled_default);
    state.fast_mode_source = detailed.sources.fast_mode;
    state.slash_menu_categories = settings.slash_menu_categories orelse true;
    state.auto_upgrade = settings.auto_upgrade orelse true;
    state.update_channel = settings.update_channel orelse .stable;
    state.startup_scrollback = settings.startup_scrollback orelse true;
    state.effort = settings.effort orelse .auto;
    state.first_call_tool_choice = settings.first_call_tool_choice orelse .auto;
    state.statusline_context = settings.statusline_context orelse false;
    state.statusline_session = settings.statusline_session orelse false;
    state.statusline_workspace = settings.statusline_workspace orelse false;
    const sound_override = soundEnvOverride();
    const sound_on_override: ?bool = if (sound_override) |level| level != .off else null;
    const max_override: ?bool = if (sound_override) |level| level == .max else null;
    state.notification_turn_end = sound_on_override orelse settings.notification_turn_end orelse notification_sound.default_enabled;
    state.notification_attention_required = sound_on_override orelse settings.notification_attention_required orelse notification_sound.default_enabled;
    state.notification_max = max_override orelse settings.notification_max orelse false;

    return state;
}

pub fn bootstrapInteractiveApp(cfg: BootstrapConfig) !StartupState {
    try cfg.terminal.ensureInteractive();
    try cfg.terminal.captureOriginalTermios();

    cfg.shell.sync_updates_enabled = shell_runtime.detectSyncUpdatesEnabled(cfg.alloc);
    cfg.shell.history_reset_uses_ris = shell_runtime.detectHistoryResetUsesRis(cfg.alloc);
    cfg.shell.layout = minimalLayout();
    try cfg.shell.initBacking(cfg.alloc);

    var state = try loadCatalogStartupState(
        cfg.alloc,
        cfg.secret_store,
        cfg.default_model,
        cfg.default_agent_step_limit,
    );
    errdefer state.deinit(cfg.alloc);

    state.credential_onboarding_skipped = credentialOnboardingDisabled();

    errdefer shutdownInteractiveShell(
        cfg.terminal,
        cfg.shell,
        cfg.metrics,
        cfg.terminal_title,
    );

    try cfg.terminal.enableRawMode();
    cfg.terminal.installResizeSignal(cfg.resize_handler);
    installAbnormalExitHandlers(io_mod.getenv("TMUX"));
    cfg.shell.layout = try cfg.terminal.queryLayout(cfg.footer_rows);

    record_tape.configureFromEnv(
        cfg.alloc,
        state.workspace_root,
        cfg.shell.layout.cols,
        cfg.shell.layout.rows,
        cfg.fx_version,
        cfg.record_requested,
    ) catch |err| {
        debug_trace.logf("record", "startup recording failed err={s}", .{@errorName(err)});
        return error.RecordingStartFailed;
    };

    // The shadow VT is load-bearing: frame commit diffs the target
    // surface against it and records the accepted terminal state.
    try cfg.shell.enableShadowVt(cfg.alloc);

    ui_render.setTruecolorSupport(ui_render.truecolorSupportedForValues(
        io_mod.getenv("COLORTERM"),
        io_mod.getenv("TERM_PROGRAM"),
    ));
    const theme = ui_render.detectTheme(cfg.alloc, cfg.terminal);
    ui_render.initTheme(theme.light, theme.rgb);
    state.theme_monitor_enabled = ui_render.explicitThemeOverride() == null;

    const cursor = cfg.terminal.queryCursorPosition() catch blk: {
        break :blk CursorPosition{
            .row = cfg.shell.layout.content_bottom,
            .col = 1,
        };
    };
    const start_row = blk: {
        var row = cursor.row;
        if (cursor.col > 1 and row < cfg.shell.layout.rows) row += 1;
        break :blk row;
    };
    var launch_start_row = start_row;
    const effective_startup_min_body_rows = try prepareStartupViewport(
        cfg.shell,
        cfg.metrics,
        &launch_start_row,
        cfg.startup_min_body_rows,
        state.startup_scrollback,
    );
    // Enable keyboard/paste protocol modes and disable autowrap for the
    // interactive session. Shutdown restores each mode.
    try enableInteractiveTerminalModes(cfg.shell, cfg.metrics);
    try cfg.shell.initViewportWithReservedRows(cfg.metrics, launch_start_row, effective_startup_min_body_rows);

    return state;
}

fn prepareStartupViewport(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    launch_start_row: *u16,
    startup_min_body_rows: u16,
    startup_scrollback: bool,
) !u16 {
    if (startup_scrollback and launch_start_row.* > 1) {
        try pushLaunchRowsIntoScrollback(shell, metrics, launch_start_row.* - 1);
        launch_start_row.* = 1;
    } else if (shell.layout.content_bottom > 0) {
        const reserve_rows = @min(startup_min_body_rows, shell.layout.content_bottom);
        const max_start_row = if (reserve_rows > 0)
            shell.layout.content_bottom - reserve_rows + 1
        else
            shell.layout.content_bottom;
        if (launch_start_row.* > max_start_row) {
            try pushLaunchRowsIntoScrollback(shell, metrics, launch_start_row.* - max_start_row);
            launch_start_row.* = max_start_row;
        }
    }
    return startup_min_body_rows;
}

fn pushLaunchRowsIntoScrollback(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    rows: u16,
) !void {
    if (rows == 0 or shell.layout.rows == 0) return;
    debug_trace.logf("render", "launch_scrollback_push rows={d} cols={d} content_bottom={d}", .{
        rows,
        shell.layout.cols,
        shell.layout.content_bottom,
    });
    var cursor_buf: [32]u8 = undefined;
    const cursor = try ui_terminal.moveCursorSequence(&cursor_buf, shell.layout.rows, 1);
    try writeLifecycleTerminalBytes(shell, metrics, cursor);

    var newlines: [64]u8 = undefined;
    @memset(newlines[0..], '\n');
    var remaining = rows;
    while (remaining > 0) {
        const count: u16 = @min(remaining, newlines.len);
        try writeLifecycleTerminalBytes(shell, metrics, newlines[0..count]);
        remaining -= count;
    }
}

pub fn shutdownInteractiveShell(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    terminal_title: host.TerminalTitle,
) void {
    leaveAlternateScreens(terminal, shell, metrics);
    terminal.uninstallResizeSignal();
    uninstallAbnormalExitHandlers();
    _ = writeLifecycleTerminalBytes(shell, metrics, normalExitRestoreSequence(io_mod.getenv("TMUX"))) catch {};
    terminal_title.clear();
    record_tape.shutdown();
    finishLeavingInteractiveMode(terminal, shell, metrics);
}

/// Cooked-mode handoff for Ctrl-Z / SIGTSTP. Same terminal restore as
/// shutdown, but keeps signal handlers, title, and recording so resume can
/// continue the same session.
fn suspendTerminalForJobControl(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) void {
    leaveAlternateScreens(terminal, shell, metrics);
    _ = writeLifecycleTerminalBytes(shell, metrics, normalExitRestoreSequence(io_mod.getenv("TMUX"))) catch {};
    finishLeavingInteractiveMode(terminal, shell, metrics);
}

/// Raise SIGTSTP after restoring cooked mode; on SIGCONT rebuild interactive
/// terminal state and request a full repaint. Platforms without job-control
/// signals (same set as `supports_resize_signal`) are a no-op.
pub fn suspendToJobControl(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    footer_rows: u16,
) !void {
    if (!shell_runtime.supports_resize_signal) return;

    suspendTerminalForJobControl(terminal, shell, metrics);
    _ = std.c.raise(std.posix.SIG.TSTP);
    try resumeTerminalAfterJobControl(terminal, shell, metrics, footer_rows);
}

fn leaveAlternateScreens(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) void {
    switch (terminal.alternate_screen_owner) {
        .none => {},
        .file_approval => _ = leaveApprovalScreen(terminal, shell, metrics) catch {},
        .full_transcript => _ = leaveFullTranscriptScreen(terminal, shell, metrics) catch {},
        .catalog_menu => _ = leaveCatalogMenuScreen(terminal, shell, metrics) catch {},
        .subagent_manager => _ = leaveSubagentManagerScreen(terminal, shell, metrics) catch {},
        .terminal_session => _ = leaveTerminalSessionScreen(terminal, shell, metrics) catch {},
    }
}

fn finishLeavingInteractiveMode(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) void {
    shell.footer_viewport.eraseCurrentFrame(shell, metrics) catch {};
    terminal.disableRawMode();
    emitShutdownCleanupAndResume(shell, metrics);
}

/// Re-arm raw mode after a job-control continue, re-query layout in case the
/// terminal was resized while stopped, then request a full repaint.
fn resumeTerminalAfterJobControl(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    footer_rows: u16,
) !void {
    shell.layout = terminal.queryLayout(footer_rows) catch shell.layout;
    try terminal.captureOriginalTermios();
    try terminal.enableRawMode();
    try enableInteractiveTerminalModes(shell, metrics);
    try shell.requestTerminalReset(metrics);
    shell.render_requests.request(.first_frame);
}

fn enableInteractiveTerminalModes(shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        ui_terminal.interactiveModeEnableSequence(io_mod.getenv("TMUX")),
    );
}

fn normalExitRestoreSequence(tmux: ?[]const u8) []const u8 {
    return if (tmux == null)
        normal_exit_restore
    else
        tmux_normal_exit_restore;
}

/// Full transcript steady state is `active`: the terminal owns the
/// full-transcript alternate screen and the shell projection is active.
/// The drift states exist only while a recovery or approval handoff path
/// is resolving a partially transitioned screen.
const FullTranscriptLifecycleState = enum {
    inactive,
    active,
    terminal_only,
    projection_only,
};

pub const FullTranscriptApprovalTransition = enum {
    inactive,
    closed,
    handed_off,
};

fn fullTranscriptLifecycleState(
    terminal: *const TerminalState,
    shell: *const TranscriptRuntime,
) FullTranscriptLifecycleState {
    const terminal_active = terminal.fullTranscriptScreenActive();
    const projection_active = shell.fullTranscriptActive();
    if (terminal_active and projection_active) return .active;
    if (terminal_active) return .terminal_only;
    if (projection_active) return .projection_only;
    return .inactive;
}

fn fullTranscriptActive(
    terminal: *const TerminalState,
    shell: *const TranscriptRuntime,
) bool {
    return fullTranscriptStateIsActive(fullTranscriptLifecycleState(terminal, shell));
}

fn fullTranscriptStateIsActive(state: FullTranscriptLifecycleState) bool {
    return state != .inactive;
}

fn fullTranscriptStateOwnsAlternateScreen(state: FullTranscriptLifecycleState) bool {
    return state == .active or state == .terminal_only;
}

fn fullTranscriptStateDrifted(state: FullTranscriptLifecycleState) bool {
    return state == .terminal_only or state == .projection_only;
}

pub fn closeFullTranscriptIfActive(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !bool {
    if (!fullTranscriptActive(terminal, shell)) return false;
    try closeFullTranscript(alloc, terminal, shell, metrics);
    return true;
}

pub fn recoverFullTranscriptDriftBeforeRender(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !bool {
    const state = fullTranscriptLifecycleState(terminal, shell);
    if (!fullTranscriptStateDrifted(state)) return false;

    debug_trace.logf(
        "full_transcript",
        "reconcile_before_render state={s} action=recover_to_inline",
        .{@tagName(state)},
    );
    try closeFullTranscript(alloc, terminal, shell, metrics);
    return true;
}

pub fn transitionFullTranscriptForApproval(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    approval_screen_active: bool,
) !FullTranscriptApprovalTransition {
    const state = fullTranscriptLifecycleState(terminal, shell);
    if (!fullTranscriptStateIsActive(state)) return .inactive;

    if (approval_screen_active and fullTranscriptStateOwnsAlternateScreen(state)) {
        try handoffFullTranscriptToApproval(alloc, terminal, shell);
        return .handed_off;
    }

    try closeFullTranscript(alloc, terminal, shell, metrics);
    return .closed;
}

pub fn enterApprovalScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try enterAlternateScreen(terminal, shell, metrics, .file_approval);
}

pub fn leaveApprovalScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .file_approval);
}

pub fn approvalInlineRestoreTransition(
    terminal: *const TerminalState,
) terminal_diff.FrameTerminalTransition {
    if (!terminal.fileApprovalScreenActive()) return .none;
    return .{ .restore_normal_screen = .{
        .mouse_tracking_active = terminal.alternate_mouse_tracking_active,
    } };
}

pub fn commitApprovalInlineRestore(terminal: *TerminalState) void {
    if (!terminal.fileApprovalScreenActive()) return;
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .none;
    terminal.alternate_frame_layout = .{};
}

pub fn setApprovalScreenMouseTracking(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    enabled: bool,
) !void {
    try setAlternateScreenMouseTracking(terminal, shell, metrics, .file_approval, enabled);
}

pub fn enterCatalogMenuScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try enterAlternateScreen(terminal, shell, metrics, .catalog_menu);
}

pub fn leaveCatalogMenuScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .catalog_menu);
}

pub fn handoffCatalogMenuToSubagentManager(terminal: *TerminalState) !void {
    if (!terminal.catalogMenuScreenActive()) return error.CatalogMenuScreenNotActive;
    terminal.alternate_screen_owner = .subagent_manager;
    terminal.alternate_frame_layout = .{};
}

pub fn handoffApprovalToSubagentManager(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (!terminal.fileApprovalScreenActive()) return error.ApprovalScreenNotActive;
    try setAlternateScreenMouseTracking(
        terminal,
        shell,
        metrics,
        .file_approval,
        false,
    );
    terminal.alternate_screen_owner = .subagent_manager;
    terminal.alternate_frame_layout = .{};
}

pub fn enterSubagentManagerScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    try enterAlternateScreen(terminal, shell, metrics, .subagent_manager);
}

pub fn leaveSubagentManagerScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .subagent_manager);
}

pub fn enterTerminalSessionScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    try enterAlternateScreen(terminal, shell, metrics, .terminal_session);
    try writeLifecycleTerminalBytes(shell, metrics, terminal_takeover_reset ++ "\x1b[2J\x1b[H");
}

pub fn leaveTerminalSessionScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (!terminal.terminalSessionScreenActive()) return;
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        terminal_takeover_reset ++ ui_terminal.alternate_screen_leave_sequence,
    );
    try enableInteractiveTerminalModes(shell, metrics);
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .none;
    terminal.alternate_frame_layout = .{};
}

/// Transfer the existing alternate buffer directly back to the manager.
/// The child modes are removed before ownership changes, so a failed write
/// leaves terminal-session cleanup armed.
pub fn handoffTerminalSessionToSubagentManager(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (!terminal.terminalSessionScreenActive()) {
        return error.TerminalSessionScreenNotActive;
    }
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        terminal_takeover_reset ++ "\x1b[2J\x1b[H",
    );
    try enableInteractiveTerminalModes(shell, metrics);
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .subagent_manager;
    terminal.alternate_frame_layout = .{};
}

pub fn openFullTranscript(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (terminal.alternate_screen_owner != .none and !terminal.fullTranscriptScreenActive()) {
        return error.AlternateScreenAlreadyOwned;
    }

    try setFullTranscriptProjection(alloc, shell, .review);
    errdefer {
        if (terminal.fullTranscriptScreenActive()) {
            leaveFullTranscriptScreen(terminal, shell, metrics) catch {};
        }
        setFullTranscriptProjection(alloc, shell, .inline_mode) catch {};
    }

    try enterFullTranscriptScreen(terminal, shell, metrics);
    try setFullTranscriptScreenMouseTracking(terminal, shell, metrics, true);
}

pub fn closeFullTranscript(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    const primary_restore = shell.fullTranscriptPrimaryRestore();
    debug_trace.logf(
        "full_transcript",
        "close_full_transcript restore={s}",
        .{@tagName(primary_restore)},
    );
    const primary_recovery = if (primary_restore == .changed_resized)
        try shell.prepareRestoredPrimaryTranscriptRecovery(alloc)
    else
        null;
    defer if (primary_recovery) |bytes| alloc.free(bytes);
    if (terminal.fullTranscriptScreenActive()) {
        try leaveFullTranscriptScreen(terminal, shell, metrics);
    }
    try setFullTranscriptProjection(alloc, shell, .inline_mode);
    switch (primary_restore) {
        .changed => {},
        .changed_resized => if (primary_recovery) |bytes| {
            try writeLifecycleTerminalBytes(shell, metrics, bytes);
            shell.repaintRestoredPrimaryTranscriptAfterResize();
        },
        .exact => shell.retainRestoredPrimaryTranscript(),
        .resized => shell.repaintRestoredPrimaryTranscriptAfterResize(),
    }
}

pub fn handoffFullTranscriptToApproval(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
) !void {
    if (!fullTranscriptStateOwnsAlternateScreen(fullTranscriptLifecycleState(terminal, shell))) {
        return error.FullTranscriptScreenNotActive;
    }
    const from = shell.transcriptPresentationDepth();
    try setFullTranscriptProjection(alloc, shell, .inline_mode);
    debug_trace.logf(
        "full_transcript",
        "depth_transition from={s} to=inline route=root trigger=approval_handoff",
        .{switch (from) {
            .inline_mode => "inline",
            .review => "review",
            .full => "full",
        }},
    );
    terminal.alternate_screen_owner = .file_approval;
    terminal.alternate_frame_layout = .{};
}

fn setFullTranscriptProjection(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    depth: transcript_presentation.Depth,
) !void {
    _ = try shell.setTranscriptPresentationDepth(alloc, depth);
}

fn enterFullTranscriptScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try enterAlternateScreen(terminal, shell, metrics, .full_transcript);
}

fn leaveFullTranscriptScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .full_transcript);
}

fn setFullTranscriptScreenMouseTracking(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    enabled: bool,
) !void {
    try setAlternateScreenMouseTracking(terminal, shell, metrics, .full_transcript, enabled);
}

fn enterAlternateScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    owner: shell_runtime.AlternateScreenOwner,
) !void {
    if (terminal.alternate_screen_owner == owner) return;
    if (terminal.alternate_screen_owner != .none) return error.AlternateScreenAlreadyOwned;
    // Keep the flag set if the write fails so shutdown still attempts a restore.
    terminal.alternate_screen_owner = owner;
    terminal.alternate_frame_layout = .{};
    try writeLifecycleTerminalBytes(shell, metrics, alternate_screen_enter);
}

fn leaveAlternateScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    owner: shell_runtime.AlternateScreenOwner,
) !void {
    if (terminal.alternate_screen_owner != owner) return;
    const restore = ui_terminal.alternateScreenLeaveSequence(
        terminal.alternate_mouse_tracking_active,
    );
    try writeLifecycleTerminalBytes(shell, metrics, restore);
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .none;
    terminal.alternate_frame_layout = .{};
}

fn setAlternateScreenMouseTracking(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    owner: shell_runtime.AlternateScreenOwner,
    enabled: bool,
) !void {
    if (terminal.alternate_screen_owner != owner or
        terminal.alternate_mouse_tracking_active == enabled)
    {
        return;
    }
    if (enabled) {
        // Keep the state armed on an enable write failure so leave/shutdown
        // still attempts to restore the terminal mode.
        terminal.alternate_mouse_tracking_active = true;
        try writeLifecycleTerminalBytes(shell, metrics, alternate_mouse_tracking_enter);
        return;
    }

    // Keep the state armed on a disable failure so leave/shutdown still
    // attempts to restore the terminal mode.
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        ui_terminal.alternate_mouse_tracking_leave_sequence,
    );
    terminal.alternate_mouse_tracking_active = false;
}

fn emitShutdownCleanupAndResume(shell: *TranscriptRuntime, metrics: *Metrics) void {
    if (shell.sync_updates_enabled) {
        _ = writeLifecycleTerminalBytes(shell, metrics, "\x1b[?2026l") catch {};
    }
    _ = writeLifecycleTerminalBytes(shell, metrics, "\x1b[?7h\x1b[0m") catch {};

    var cursor_buf: [32]u8 = undefined;
    if (ui_terminal.moveCursorSequence(&cursor_buf, shutdownCleanupRow(shell), 1)) |cursor| {
        _ = writeLifecycleTerminalBytes(shell, metrics, cursor) catch {};
    } else |_| {}
    _ = writeLifecycleTerminalBytes(shell, metrics, "\x1b[J\x1b[?25h\n") catch {};
}

pub fn writeLifecycleTerminalBytes(shell: *TranscriptRuntime, metrics: *Metrics, bytes: []const u8) !void {
    try shell.stdout_file.writeStreamingAll(io_mod.getIo(), bytes);
    if (shell.shadow_vt) |grid| {
        grid.feed(bytes) catch |err| debug_trace.logf(
            "render",
            "lifecycle_shadow_feed_drop bytes={d} err={s}",
            .{ bytes.len, @errorName(err) },
        );
    }
    record_tape.recordStdout(bytes);
    metrics.ansi_bytes += bytes.len;
}

fn shutdownCleanupRow(shell: *const TranscriptRuntime) u16 {
    const row = if (shell.footer_viewport.has_frame)
        shell.footer_viewport.geometry.top
    else
        shell.cursor_row;

    if (row == 0) return 1;
    if (shell.layout.rows == 0) return row;
    return @min(row, shell.layout.rows);
}

fn loadPermissionMode(configured: ?PermissionMode) PermissionMode {
    const fallback = configured orelse default_permission_mode;
    const mode = io_mod.getenv("FX_PERMISSION_MODE") orelse return fallback;
    return config_runtime.parsePermissionMode(mode) orelse fallback;
}

fn loadAgentStepLimit(fallback: usize, configured: ?usize) usize {
    return agent_steps.resolveMaxAgentStepsWithOverride(
        configured,
        fallback,
        io_mod.getenv("FX_MAX_AGENT_STEPS"),
    );
}

fn configuredProviderSelection(
    default_model: []const u8,
    settings: *const config_runtime.Settings,
) !model_provider.ProviderSelection {
    const provider = settings.provider orelse .gateway;
    const model = switch (provider) {
        .gateway => settings.model orelse default_model,
        .codex => settings.codex_model orelse return error.CodexModelNotSelected,
        .grok => settings.grok_model orelse return error.GrokModelNotSelected,
        .claude => settings.claude_model orelse return error.ClaudeModelNotSelected,
    };
    return .{ .provider = provider, .model = model };
}

fn initialModelId(default_model: []const u8, configured: ?[]const u8) []const u8 {
    const model = io_mod.getenv("FX_MODEL") orelse return configured orelse default_model;
    const trimmed = std.mem.trim(u8, model, " \t\r\n");
    return if (trimmed.len > 0) trimmed else configured orelse default_model;
}

test "startup provider chooses only its provider-scoped model" {
    const gateway_settings = config_runtime.Settings{
        .model = @constCast("gateway/model"),
        .provider = .gateway,
        .codex_model = @constCast("gpt-model"),
    };
    const gateway = try configuredProviderSelection("default/model", &gateway_settings);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, gateway.provider);
    try std.testing.expectEqualStrings("gateway/model", gateway.model);

    const codex_settings = config_runtime.Settings{
        .model = @constCast("gateway/model"),
        .provider = .codex,
        .codex_model = @constCast("gpt-model"),
    };
    const codex = try configuredProviderSelection("default/model", &codex_settings);
    try std.testing.expectEqual(model_provider.ProviderId.codex, codex.provider);
    try std.testing.expectEqualStrings("gpt-model", codex.model);

    const missing_codex = config_runtime.Settings{ .provider = .codex };
    try std.testing.expectError(
        error.CodexModelNotSelected,
        configuredProviderSelection("default/model", &missing_codex),
    );

    const grok_settings = config_runtime.Settings{
        .provider = .grok,
        .grok_model = @constCast("grok-model"),
    };
    const grok = try configuredProviderSelection("default/model", &grok_settings);
    try std.testing.expectEqual(model_provider.ProviderId.grok, grok.provider);
    try std.testing.expectEqualStrings("grok-model", grok.model);
}

fn loadInitialModel(alloc: Allocator, default_model: []const u8, configured: ?[]const u8) ![]u8 {
    return alloc.dupe(u8, initialModelId(default_model, configured));
}

fn hasProcessModelOverride() bool {
    const model = io_mod.getenv("FX_MODEL") orelse return false;
    return std.mem.trim(u8, model, " \t\r\n").len > 0;
}

fn loadStartupStatusModel(alloc: Allocator, default_model: []const u8, configured: ?[]const u8) !StartupStatusModel {
    const owned = try alloc.dupe(u8, initialModelId(default_model, configured));
    return .{ .value = owned, .owned = owned };
}

fn credentialOnboardingDisabled() bool {
    const value = io_mod.getenv("FX_SKIP_ONBOARDING") orelse return false;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return false;
    return !std.mem.eql(u8, trimmed, "0") and !std.ascii.eqlIgnoreCase(trimmed, "false");
}

const SoundEnvLevel = enum { off, on, max };

fn soundEnvOverride() ?SoundEnvLevel {
    const value = io_mod.getenv("FX_SOUND") orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "max")) return .max;
    const off = std.mem.eql(u8, trimmed, "0") or
        std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "off");
    return if (off) .off else .on;
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, entries: []const EnvEntry) !*TestEnv {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        for (entries) |entry| {
            try self.map.put(entry.key, entry.value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

test "permission mode parser accepts known modes" {
    try std.testing.expectEqual(PermissionMode.ask, config_runtime.parsePermissionMode("ask").?);
    try std.testing.expectEqual(PermissionMode.auto, config_runtime.parsePermissionMode("auto").?);
    try std.testing.expectEqual(PermissionMode.yolo, config_runtime.parsePermissionMode("yolo").?);
    try std.testing.expect(config_runtime.parsePermissionMode("weird") == null);
}

test "permission mode loader defaults to auto" {
    var env = try TestEnv.install(std.testing.allocator, &.{});
    defer env.deinit();

    try std.testing.expectEqual(PermissionMode.auto, loadPermissionMode(null));
    try std.testing.expectEqual(PermissionMode.ask, loadPermissionMode(.ask));
}

test "permission mode environment accepts yolo without changing fallback" {
    var env = try TestEnv.install(std.testing.allocator, &.{
        .{ .key = "FX_PERMISSION_MODE", .value = "yolo" },
    });
    defer env.deinit();

    try std.testing.expectEqual(PermissionMode.yolo, loadPermissionMode(.ask));
}

test "agent step limit loader distinguishes missing and explicit zero" {
    var env = try TestEnv.install(std.testing.allocator, &.{});
    defer env.deinit();

    try std.testing.expectEqual(agent_steps.default_max_agent_steps, loadAgentStepLimit(agent_steps.default_max_agent_steps, null));
    try std.testing.expectEqual(@as(usize, 0), loadAgentStepLimit(agent_steps.default_max_agent_steps, 0));
    try std.testing.expectEqual(@as(usize, 50), loadAgentStepLimit(agent_steps.default_max_agent_steps, 50));
}

fn minimalLayout() types.Layout {
    return .{
        .rows = 1,
        .cols = 1,
        .content_bottom = 1,
        .divider_top_row = 1,
        .input_row = 1,
        .divider_bottom_row = 1,
        .hint_row = 1,
    };
}

test "minimal layout is safe for shutdown fallback" {
    const layout = minimalLayout();
    try std.testing.expectEqual(@as(u16, 1), layout.rows);
    try std.testing.expectEqual(@as(u16, 1), layout.cols);
    try std.testing.expectEqual(@as(u16, 1), layout.input_row);
}

test "lifecycle terminal writer updates bytes metrics and shadow" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "lifecycle.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{
        .stdout_file = out_file,
        .layout = .{
            .rows = 4,
            .cols = 8,
            .content_bottom = 1,
            .divider_top_row = 1,
            .input_row = 2,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);

    var metrics = Metrics{};
    try writeLifecycleTerminalBytes(&shell, &metrics, "x");
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 32);
    defer alloc.free(bytes);

    try std.testing.expectEqualStrings("x", bytes);
    try std.testing.expectEqual(@as(usize, 1), metrics.ansi_bytes);
    try std.testing.expectEqual(@as(u21, 'x'), shell.shadow_vt.?.cellAt(1, 1).?.codepoint);
}

test "approval alternate screen lifecycle restores the shadow terminal once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "approval-screen.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{
        .stdout_file = out_file,
        .layout = .{
            .rows = 4,
            .cols = 16,
            .content_bottom = 1,
            .divider_top_row = 1,
            .input_row = 2,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);

    var metrics = Metrics{};
    var terminal = TerminalState{};
    try writeLifecycleTerminalBytes(&shell, &metrics, "normal");

    try enterApprovalScreen(&terminal, &shell, &metrics);
    try enterApprovalScreen(&terminal, &shell, &metrics);
    try setApprovalScreenMouseTracking(&terminal, &shell, &metrics, true);
    try setApprovalScreenMouseTracking(&terminal, &shell, &metrics, true);
    try writeLifecycleTerminalBytes(&shell, &metrics, "approval");
    try leaveApprovalScreen(&terminal, &shell, &metrics);
    try leaveApprovalScreen(&terminal, &shell, &metrics);
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 256);
    defer alloc.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049l"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1000h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1006h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1000l"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1006l"));
    try std.testing.expect(!terminal.fileApprovalScreenActive());
    try std.testing.expect(!terminal.alternate_mouse_tracking_active);
    try std.testing.expectEqual(@as(u21, 'n'), shell.shadow_vt.?.cellAt(1, 1).?.codepoint);
}

test "approval inline restore keeps ownership armed until frame commit" {
    var terminal = TerminalState{
        .alternate_screen_owner = .file_approval,
        .alternate_mouse_tracking_active = true,
        .alternate_frame_layout = .{ .layout_id = 51 },
    };

    switch (approvalInlineRestoreTransition(&terminal)) {
        .none => return error.TestExpectedApprovalRestore,
        .restore_normal_screen => |restore| {
            try std.testing.expect(restore.mouse_tracking_active);
        },
    }
    try std.testing.expect(terminal.fileApprovalScreenActive());
    try std.testing.expect(terminal.alternate_mouse_tracking_active);
    try std.testing.expectEqual(@as(u64, 51), terminal.alternate_frame_layout.layout_id);

    commitApprovalInlineRestore(&terminal);
    try std.testing.expect(!terminal.fileApprovalScreenActive());
    try std.testing.expect(!terminal.alternate_mouse_tracking_active);
    try std.testing.expectEqual(@as(u64, 0), terminal.alternate_frame_layout.layout_id);
    try std.testing.expectEqual(
        terminal_diff.FrameTerminalTransition.none,
        approvalInlineRestoreTransition(&terminal),
    );
}

test "approval hands its alternate screen to subagent manager without buffer swap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "approval-to-subagent-manager.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{ .stdout_file = out_file };
    defer shell.deinit(alloc);
    var metrics = Metrics{};
    var terminal = TerminalState{};
    try std.testing.expectError(
        error.ApprovalScreenNotActive,
        handoffApprovalToSubagentManager(&terminal, &shell, &metrics),
    );

    terminal.alternate_screen_owner = .file_approval;
    terminal.alternate_mouse_tracking_active = true;
    terminal.alternate_frame_layout.layout_id = 52;
    try handoffApprovalToSubagentManager(&terminal, &shell, &metrics);
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 64);
    defer alloc.free(bytes);

    try std.testing.expectEqualStrings(
        ui_terminal.alternate_mouse_tracking_leave_sequence,
        bytes,
    );
    try std.testing.expect(std.mem.find(
        u8,
        bytes,
        ui_terminal.alternate_screen_leave_sequence,
    ) == null);
    try std.testing.expect(terminal.subagentManagerScreenActive());
    try std.testing.expect(!terminal.alternate_mouse_tracking_active);
    try std.testing.expectEqual(@as(u64, 0), terminal.alternate_frame_layout.layout_id);

    const failure_file = try tmp.dir.createFile(
        io_mod.getIo(),
        "approval-to-subagent-manager-failure.out",
        .{ .truncate = true },
    );
    var failure_shell = TranscriptRuntime{ .stdout_file = failure_file };
    defer failure_shell.deinit(alloc);
    failure_shell.stdout_file.close(io_mod.getIo());
    var failed_terminal = TerminalState{
        .alternate_screen_owner = .file_approval,
        .alternate_mouse_tracking_active = true,
        .alternate_frame_layout = .{ .layout_id = 53 },
    };
    if (handoffApprovalToSubagentManager(
        &failed_terminal,
        &failure_shell,
        &metrics,
    )) |_| {
        return error.TestExpectedApprovalHandoffFailure;
    } else |_| {}
    try std.testing.expect(failed_terminal.fileApprovalScreenActive());
    try std.testing.expect(failed_terminal.alternate_mouse_tracking_active);
    try std.testing.expectEqual(@as(u64, 53), failed_terminal.alternate_frame_layout.layout_id);
}

test "full transcript alternate screen lifecycle restores the shadow terminal once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "full-transcript-screen.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{
        .stdout_file = out_file,
        .layout = .{
            .rows = 4,
            .cols = 16,
            .content_bottom = 1,
            .divider_top_row = 1,
            .input_row = 2,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);

    var metrics = Metrics{};
    var terminal = TerminalState{
        .alternate_frame_layout = .{ .layout_id = 41 },
    };
    try enterFullTranscriptScreen(&terminal, &shell, &metrics);
    try std.testing.expectEqual(@as(u64, 0), terminal.alternate_frame_layout.layout_id);
    try enterFullTranscriptScreen(&terminal, &shell, &metrics);
    try setFullTranscriptScreenMouseTracking(&terminal, &shell, &metrics, true);
    try setFullTranscriptScreenMouseTracking(&terminal, &shell, &metrics, true);
    terminal.alternate_frame_layout.layout_id = 42;
    try leaveFullTranscriptScreen(&terminal, &shell, &metrics);
    try std.testing.expectEqual(@as(u64, 0), terminal.alternate_frame_layout.layout_id);
    try leaveFullTranscriptScreen(&terminal, &shell, &metrics);
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 256);
    defer alloc.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049l"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1000h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1006h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1000l"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1006l"));
    try std.testing.expect(!terminal.fullTranscriptScreenActive());
    try std.testing.expect(!terminal.alternate_mouse_tracking_active);
}

test "skills menu alternate screen lifecycle restores the shadow terminal once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "skills-menu-screen.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{
        .stdout_file = out_file,
        .layout = .{
            .rows = 4,
            .cols = 16,
            .content_bottom = 1,
            .divider_top_row = 1,
            .input_row = 2,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);

    var metrics = Metrics{};
    var terminal = TerminalState{};
    try enterCatalogMenuScreen(&terminal, &shell, &metrics);
    try enterCatalogMenuScreen(&terminal, &shell, &metrics);
    try writeLifecycleTerminalBytes(&shell, &metrics, "skills");
    try leaveCatalogMenuScreen(&terminal, &shell, &metrics);
    try leaveCatalogMenuScreen(&terminal, &shell, &metrics);
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 256);
    defer alloc.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049l"));
    try std.testing.expect(!terminal.catalogMenuScreenActive());
    try std.testing.expectEqual(@as(u21, ' '), shell.shadow_vt.?.cellAt(1, 1).?.codepoint);
}

test "closed catalog hands its alternate screen directly to subagent manager" {
    var terminal = TerminalState{};
    try std.testing.expectError(
        error.CatalogMenuScreenNotActive,
        handoffCatalogMenuToSubagentManager(&terminal),
    );

    terminal.alternate_screen_owner = .catalog_menu;
    terminal.alternate_frame_layout.layout_id = 73;
    try handoffCatalogMenuToSubagentManager(&terminal);
    try std.testing.expect(terminal.subagentManagerScreenActive());
    try std.testing.expectEqual(@as(u64, 0), terminal.alternate_frame_layout.layout_id);
}

test "full transcript handoff to approval reuses the alternate screen" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "full-transcript-to-approval-screen.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{
        .stdout_file = out_file,
        .layout = .{
            .rows = 4,
            .cols = 16,
            .content_bottom = 1,
            .divider_top_row = 1,
            .input_row = 2,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);

    var metrics = Metrics{};
    var terminal = TerminalState{};
    try writeLifecycleTerminalBytes(&shell, &metrics, "normal");
    try openFullTranscript(alloc, &terminal, &shell, &metrics);
    try writeLifecycleTerminalBytes(&shell, &metrics, "viewer");
    try std.testing.expect(shell.fullTranscriptActive());
    terminal.alternate_frame_layout.layout_id = 43;
    try handoffFullTranscriptToApproval(alloc, &terminal, &shell);
    try std.testing.expectEqual(@as(u64, 0), terminal.alternate_frame_layout.layout_id);
    try std.testing.expect(terminal.fileApprovalScreenActive());
    try std.testing.expect(!shell.fullTranscriptActive());
    try std.testing.expect(terminal.alternate_mouse_tracking_active);
    try writeLifecycleTerminalBytes(&shell, &metrics, "approval");
    try leaveApprovalScreen(&terminal, &shell, &metrics);
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 256);
    defer alloc.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049l"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1000h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1006h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1000l"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1006l"));
    try std.testing.expect(!terminal.fileApprovalScreenActive());
    try std.testing.expect(!terminal.alternate_mouse_tracking_active);
    try std.testing.expectEqual(@as(u21, 'n'), shell.shadow_vt.?.cellAt(1, 1).?.codepoint);
}

test "full transcript transitions own terminal and projection together" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "full-transcript-transition.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{
        .stdout_file = out_file,
        .layout = .{
            .rows = 4,
            .cols = 16,
            .content_bottom = 1,
            .divider_top_row = 1,
            .input_row = 2,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);

    var metrics = Metrics{};
    var terminal = TerminalState{};

    try openFullTranscript(alloc, &terminal, &shell, &metrics);
    try openFullTranscript(alloc, &terminal, &shell, &metrics);
    try std.testing.expectEqual(
        FullTranscriptLifecycleState.active,
        fullTranscriptLifecycleState(&terminal, &shell),
    );
    try std.testing.expect(terminal.fullTranscriptScreenActive());
    try std.testing.expect(shell.fullTranscriptActive());
    try std.testing.expect(terminal.alternate_mouse_tracking_active);

    try handoffFullTranscriptToApproval(alloc, &terminal, &shell);
    try std.testing.expectEqual(
        FullTranscriptLifecycleState.inactive,
        fullTranscriptLifecycleState(&terminal, &shell),
    );
    try std.testing.expect(terminal.fileApprovalScreenActive());
    try std.testing.expect(!shell.fullTranscriptActive());
    try std.testing.expect(terminal.alternate_mouse_tracking_active);
    try leaveApprovalScreen(&terminal, &shell, &metrics);
    try std.testing.expect(!terminal.fileApprovalScreenActive());
    try std.testing.expect(!terminal.alternate_mouse_tracking_active);

    try openFullTranscript(alloc, &terminal, &shell, &metrics);
    try std.testing.expect(terminal.fullTranscriptScreenActive());
    try std.testing.expect(shell.fullTranscriptActive());
    try std.testing.expect(terminal.alternate_mouse_tracking_active);
    shell.render_requests.clearReason(.footer);
    try closeFullTranscript(alloc, &terminal, &shell, &metrics);
    try closeFullTranscript(alloc, &terminal, &shell, &metrics);
    try std.testing.expect(!terminal.fullTranscriptScreenActive());
    try std.testing.expect(!shell.fullTranscriptActive());
    try std.testing.expect(!terminal.alternate_mouse_tracking_active);
    try std.testing.expect(!shell.transcript_band_dirty);
    try std.testing.expect(!shell.render_requests.hasReason(.transcript));
    try std.testing.expect(shell.render_requests.hasReason(.footer));

    try openFullTranscript(alloc, &terminal, &shell, &metrics);
    shell.layout.cols += 1;
    shell.terminal_reset_pending = true;
    shell.resize_history_row_delta = 12;
    try closeFullTranscript(alloc, &terminal, &shell, &metrics);
    try std.testing.expect(shell.transcript_band_dirty);
    try std.testing.expect(shell.render_requests.hasReason(.transcript));
    try std.testing.expect(!shell.terminal_reset_pending);
    try std.testing.expectEqual(@as(?i32, null), shell.resize_history_row_delta);
    shell.layout.cols -= 1;
    shell.transcript_band_dirty = false;
    shell.render_requests.clearReason(.transcript);

    try openFullTranscript(alloc, &terminal, &shell, &metrics);
    shell.markTranscriptContentDirty();
    try closeFullTranscript(alloc, &terminal, &shell, &metrics);
    try std.testing.expect(shell.transcript_band_dirty);
    try std.testing.expect(shell.render_requests.hasReason(.transcript));

    shell.stdout_file.close(io_mod.getIo());
    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 512);
    defer alloc.free(bytes);

    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, bytes, "\x1b[?1049h"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, bytes, "\x1b[?1049l"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, bytes, "\x1b[?1000h"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, bytes, "\x1b[?1006h"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, bytes, "\x1b[?1000l"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, bytes, "\x1b[?1006l"));
}

test "full transcript drift recovery is explicit and scoped to lifecycle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const terminal_only_path = "terminal-only.out";
    const terminal_only_file = try tmp.dir.createFile(io_mod.getIo(), terminal_only_path, .{ .truncate = true });
    var terminal_only_shell = TranscriptRuntime{
        .stdout_file = terminal_only_file,
        .layout = .{
            .rows = 4,
            .cols = 16,
            .content_bottom = 1,
            .divider_top_row = 1,
            .input_row = 2,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
    };
    defer terminal_only_shell.deinit(alloc);
    try terminal_only_shell.enableShadowVt(alloc);

    var metrics = Metrics{};
    var terminal_only = TerminalState{ .alternate_screen_owner = .full_transcript };
    try std.testing.expectEqual(
        FullTranscriptLifecycleState.terminal_only,
        fullTranscriptLifecycleState(&terminal_only, &terminal_only_shell),
    );
    try std.testing.expect(try recoverFullTranscriptDriftBeforeRender(
        alloc,
        &terminal_only,
        &terminal_only_shell,
        &metrics,
    ));
    try std.testing.expectEqual(
        FullTranscriptLifecycleState.inactive,
        fullTranscriptLifecycleState(&terminal_only, &terminal_only_shell),
    );
    terminal_only_shell.stdout_file.close(io_mod.getIo());

    var terminal_only_read = try tmp.dir.openFile(io_mod.getIo(), terminal_only_path, .{});
    defer terminal_only_read.close(io_mod.getIo());
    const terminal_only_bytes = try io_mod.readFileToEnd(alloc, &terminal_only_read, 64);
    defer alloc.free(terminal_only_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            terminal_only_bytes,
            ui_terminal.alternate_screen_leave_sequence,
        ),
    );

    const projection_only_path = "projection-only.out";
    const projection_only_file = try tmp.dir.createFile(io_mod.getIo(), projection_only_path, .{ .truncate = true });
    var projection_only_shell = TranscriptRuntime{
        .stdout_file = projection_only_file,
        .layout = terminal_only_shell.layout,
    };
    defer projection_only_shell.deinit(alloc);
    try setFullTranscriptProjection(alloc, &projection_only_shell, .review);

    var projection_only = TerminalState{};
    try std.testing.expectEqual(
        FullTranscriptLifecycleState.projection_only,
        fullTranscriptLifecycleState(&projection_only, &projection_only_shell),
    );
    try std.testing.expect(try recoverFullTranscriptDriftBeforeRender(
        alloc,
        &projection_only,
        &projection_only_shell,
        &metrics,
    ));
    try std.testing.expectEqual(
        FullTranscriptLifecycleState.inactive,
        fullTranscriptLifecycleState(&projection_only, &projection_only_shell),
    );
    projection_only_shell.stdout_file.close(io_mod.getIo());

    var projection_only_read = try tmp.dir.openFile(io_mod.getIo(), projection_only_path, .{});
    defer projection_only_read.close(io_mod.getIo());
    const projection_only_bytes = try io_mod.readFileToEnd(alloc, &projection_only_read, 64);
    defer alloc.free(projection_only_bytes);
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(
            u8,
            projection_only_bytes,
            ui_terminal.alternate_screen_leave_sequence,
        ),
    );
}

test "abnormal exit restoration leaves the alternate screen" {
    try std.testing.expect(std.mem.startsWith(u8, abnormal_exit_restore, "\x1b[?2026l"));
    try std.testing.expect(std.mem.indexOf(u8, abnormal_exit_restore, "\x1b[?2026l").? <
        std.mem.indexOf(u8, abnormal_exit_restore, ui_terminal.alternate_screen_leave_sequence).?);
    try std.testing.expect(std.mem.startsWith(
        u8,
        normal_exit_restore,
        ui_terminal.theme_notification_disable_sequence ++ "\x1b[?2026l",
    ));
    try std.testing.expect(std.mem.indexOf(u8, abnormal_exit_restore, "\x1b[?1000l") != null);
    try std.testing.expect(std.mem.indexOf(u8, abnormal_exit_restore, "\x1b[?1006l") != null);
    try std.testing.expect(std.mem.indexOf(u8, abnormal_exit_restore, "\x1b[?1049l") != null);
    try std.testing.expect(std.mem.indexOf(u8, abnormal_exit_restore, "\x1b[?2031l") != null);
    try std.testing.expect(std.mem.indexOf(u8, normal_exit_restore, "\x1b[?2031l") != null);
}

test "terminal keyboard stack restore stays paired with enable policy" {
    try std.testing.expect(std.mem.find(u8, normalExitRestoreSequence(null), "\x1b[<u") != null);
    try std.testing.expect(std.mem.find(u8, abnormal_exit_restore, "\x1b[<u") != null);

    const tmux_restore = normalExitRestoreSequence("");
    try std.testing.expect(std.mem.find(u8, tmux_restore, "\x1b[<u") == null);
    try std.testing.expect(std.mem.find(u8, tmux_abnormal_exit_restore, "\x1b[<u") == null);
    try std.testing.expect(std.mem.find(u8, tmux_restore, "\x1b[?2004l") != null);
    try std.testing.expect(std.mem.find(u8, tmux_restore, "\x1b[>4;0m") != null);
}

test "launch scrollback push creates top-of-viewport space" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "launch.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{
        .stdout_file = out_file,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    };
    defer shell.deinit(alloc);

    var metrics = Metrics{};
    try pushLaunchRowsIntoScrollback(&shell, &metrics, 3);
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 1024);
    defer alloc.free(bytes);

    try std.testing.expectEqualStrings("\x1b[24;1H\n\n\n", bytes);
}

test "prepare startup viewport uses scrollback setting for launch push only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const enabled_path = "enabled.out";
    const enabled_file = try tmp.dir.createFile(io_mod.getIo(), enabled_path, .{ .truncate = true });
    var enabled_shell = TranscriptRuntime{
        .stdout_file = enabled_file,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    };
    defer enabled_shell.deinit(alloc);

    var metrics = Metrics{};
    var enabled_launch_row: u16 = 6;
    const enabled_reservation = try prepareStartupViewport(&enabled_shell, &metrics, &enabled_launch_row, 11, true);
    enabled_shell.stdout_file.close(io_mod.getIo());

    var enabled_read = try tmp.dir.openFile(io_mod.getIo(), enabled_path, .{});
    defer enabled_read.close(io_mod.getIo());
    const enabled_bytes = try io_mod.readFileToEnd(alloc, &enabled_read, 1024);
    defer alloc.free(enabled_bytes);

    try std.testing.expectEqual(@as(u16, 1), enabled_launch_row);
    try std.testing.expectEqual(@as(u16, 11), enabled_reservation);
    try std.testing.expectEqualStrings("\x1b[24;1H\n\n\n\n\n", enabled_bytes);

    const disabled_path = "disabled.out";
    const disabled_file = try tmp.dir.createFile(io_mod.getIo(), disabled_path, .{ .truncate = true });
    var disabled_shell = TranscriptRuntime{
        .stdout_file = disabled_file,
        .layout = enabled_shell.layout,
    };
    defer disabled_shell.deinit(alloc);

    var disabled_launch_row: u16 = 6;
    const disabled_reservation = try prepareStartupViewport(&disabled_shell, &metrics, &disabled_launch_row, 11, false);
    disabled_shell.stdout_file.close(io_mod.getIo());

    var disabled_read = try tmp.dir.openFile(io_mod.getIo(), disabled_path, .{});
    defer disabled_read.close(io_mod.getIo());
    const disabled_bytes = try io_mod.readFileToEnd(alloc, &disabled_read, 1024);
    defer alloc.free(disabled_bytes);

    try std.testing.expectEqual(@as(u16, 6), disabled_launch_row);
    try std.testing.expectEqual(@as(u16, 11), disabled_reservation);
    try std.testing.expectEqualStrings("", disabled_bytes);
}

test "shutdown cleanup erases from footer frame top after frame commit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "shutdown.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{
        .stdout_file = out_file,
        .sync_updates_enabled = false,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .cursor_row = 6,
        .cursor_col = 1,
        .has_committed_frame = true,
    };
    defer shell.deinit(alloc);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry = .{
        .top = 21,
        .top_divider = 21,
        .input_base = 22,
        .bottom_divider = 23,
        .hint = 24,
    };

    var metrics = Metrics{};
    emitShutdownCleanupAndResume(&shell, &metrics);
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 1024);
    defer alloc.free(bytes);

    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[6;1H\x1b[J") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[21;1H\x1b[J") != null);
}

test "startup credential modes select a refresh policy, never a narrower source set" {
    const modes = std.meta.fields(CredentialLoadMode);
    try std.testing.expectEqual(@as(usize, 2), modes.len);
    try std.testing.expectEqualStrings("stored", modes[0].name);
    try std.testing.expectEqualStrings("refresh_if_needed", modes[1].name);
}

test "loadStartupState applies core env overrides" {
    var env = try TestEnv.install(std.testing.allocator, &.{
        .{ .key = "FX_MODEL", .value = "  env-model  " },
        .{ .key = "AI_GATEWAY_API_KEY", .value = "gateway-key" },
        .{ .key = "FX_PERMISSION_MODE", .value = "auto" },
        .{ .key = "FX_MAX_AGENT_STEPS", .value = "37" },
    });
    defer env.deinit();

    var state = try loadStartupState(
        std.testing.allocator,
        oauth_transport.unavailable_provider,
        host.unavailable_secret_store,
        "default-model",
        12,
    );
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(state.workspace_root.len > 0);
    try std.testing.expectEqualStrings("env-model", state.selected_model);
    try std.testing.expectEqualStrings("default-model", state.configured_model);
    try std.testing.expectEqual(config_runtime.ModelSource.process_override, state.model_source);
    try std.testing.expect(!state.fast_mode);
    try std.testing.expectEqualStrings("gateway-key", state.apiKey().?);
    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, state.credential.?.source);
    try std.testing.expectEqual(PermissionMode.auto, state.permission_mode);
    try std.testing.expectEqual(@as(usize, 37), state.agent_step_limit);
}

test "loadStartupState defaults fast mode on only for the compiled Gateway default and preserves explicit preferences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "absent");
    try tmp.dir.createDirPath(io_mod.getIo(), "configured");
    try tmp.dir.createDirPath(io_mod.getIo(), "disabled");
    try tmp.dir.createDirPath(io_mod.getIo(), "codex");

    const home_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_root);
    const absent_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "absent");
    defer std.testing.allocator.free(absent_root);
    const configured_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "configured");
    defer std.testing.allocator.free(configured_root);
    const disabled_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "disabled");
    defer std.testing.allocator.free(disabled_root);
    const codex_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "codex");
    defer std.testing.allocator.free(codex_root);

    const fixture = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"workspaces\":{{\"{s}\":{{\"model\":\"openai/gpt-5\"}},\"{s}\":{{\"fast_mode\":false}},\"{s}\":{{\"provider\":\"codex\",\"codex_model\":\"gpt-5.4-mini\"}}}}}}\n",
        .{ configured_root, disabled_root, codex_root },
    );
    defer std.testing.allocator.free(fixture);
    try writeFixtureFile(tmp.dir, "home/.fx/settings.json", fixture);

    var env = try TestEnv.install(std.testing.allocator, &.{.{ .key = "HOME", .value = home_root }});
    defer env.deinit();

    var absent = try loadStartupStateForWorkspace(std.testing.allocator, absent_root, "zai/glm-5.2", 25);
    defer absent.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zai/glm-5.2", absent.selected_model);
    try std.testing.expectEqualStrings("zai/glm-5.2", absent.configured_model);
    try std.testing.expect(absent.fast_mode);

    var configured = try loadStartupStateForWorkspace(std.testing.allocator, configured_root, "zai/glm-5.2", 25);
    defer configured.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("openai/gpt-5", configured.selected_model);
    try std.testing.expectEqualStrings("openai/gpt-5", configured.configured_model);
    try std.testing.expect(!configured.fast_mode);

    var disabled = try loadStartupStateForWorkspace(std.testing.allocator, disabled_root, "zai/glm-5.2", 25);
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expect(!disabled.fast_mode);

    var codex = try loadStartupStateForWorkspace(std.testing.allocator, codex_root, "zai/glm-5.2", 25);
    defer codex.deinit(std.testing.allocator);
    try std.testing.expectEqual(model_provider.ProviderId.codex, codex.provider);
    try std.testing.expectEqualStrings("gpt-5.4-mini", codex.selected_model);
    try std.testing.expect(!codex.fast_mode);
}

test "loadStartupState resolves startup scrollback default and explicit false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "absent");
    try tmp.dir.createDirPath(io_mod.getIo(), "disabled");

    const home_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_root);
    const absent_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "absent");
    defer std.testing.allocator.free(absent_root);
    const disabled_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "disabled");
    defer std.testing.allocator.free(disabled_root);

    const fixture = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"workspaces\":{{\"{s}\":{{\"startup_scrollback\":false}}}}}}\n",
        .{disabled_root},
    );
    defer std.testing.allocator.free(fixture);
    try writeFixtureFile(tmp.dir, "home/.fx/settings.json", fixture);

    var env = try TestEnv.install(std.testing.allocator, &.{.{ .key = "HOME", .value = home_root }});
    defer env.deinit();

    var absent = try loadStartupStateForWorkspace(std.testing.allocator, absent_root, "default-model", 25);
    defer absent.deinit(std.testing.allocator);
    try std.testing.expect(absent.startup_scrollback);

    var disabled = try loadStartupStateForWorkspace(std.testing.allocator, disabled_root, "default-model", 25);
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expect(!disabled.startup_scrollback);
}

test "loadStartupState resolves slash menu categories default and explicit false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_root);
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);

    var env = try TestEnv.install(std.testing.allocator, &.{.{ .key = "HOME", .value = home_root }});
    defer env.deinit();

    var initial = try loadStartupStateForWorkspace(std.testing.allocator, workspace_root, "default-model", 25);
    defer initial.deinit(std.testing.allocator);
    try std.testing.expect(initial.slash_menu_categories);

    try writeFixtureFile(tmp.dir, "home/.fx/settings.json", "{\"slash_menu_categories\":false}\n");
    var hidden = try loadStartupStateForWorkspace(std.testing.allocator, workspace_root, "default-model", 25);
    defer hidden.deinit(std.testing.allocator);
    try std.testing.expect(!hidden.slash_menu_categories);
}

test "loadStartupState resolves max_agent_steps default zero and positive values" {
    var env = try TestEnv.install(std.testing.allocator, &.{});
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "absent");
    try tmp.dir.createDirPath(io_mod.getIo(), "zero");
    try tmp.dir.createDirPath(io_mod.getIo(), "positive");
    try writeFixtureFile(tmp.dir, "zero/.fx.json", "{\"max_agent_steps\":0}");
    try writeFixtureFile(tmp.dir, "positive/.fx.json", "{\"max_agent_steps\":50}");

    const absent_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "absent");
    defer std.testing.allocator.free(absent_root);
    const zero_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "zero");
    defer std.testing.allocator.free(zero_root);
    const positive_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "positive");
    defer std.testing.allocator.free(positive_root);

    var absent = try loadStartupStateForWorkspace(std.testing.allocator, absent_root, "default-model", agent_steps.default_max_agent_steps);
    defer absent.deinit(std.testing.allocator);
    try std.testing.expectEqual(agent_steps.default_max_agent_steps, absent.agent_step_limit);

    var zero = try loadStartupStateForWorkspace(std.testing.allocator, zero_root, "default-model", agent_steps.default_max_agent_steps);
    defer zero.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), zero.agent_step_limit);

    var positive = try loadStartupStateForWorkspace(std.testing.allocator, positive_root, "default-model", agent_steps.default_max_agent_steps);
    defer positive.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 50), positive.agent_step_limit);
}

test "loadStartupState resolves max_tool_result_bytes default and explicit values" {
    var env = try TestEnv.install(std.testing.allocator, &.{});
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "absent");
    try tmp.dir.createDirPath(io_mod.getIo(), "explicit");
    try writeFixtureFile(tmp.dir, "explicit/.fx.json", "{\"max_tool_result_bytes\":131072}");

    const absent_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "absent");
    defer std.testing.allocator.free(absent_root);
    const explicit_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "explicit");
    defer std.testing.allocator.free(explicit_root);

    var absent = try loadStartupStateForWorkspace(std.testing.allocator, absent_root, "default-model", 25);
    defer absent.deinit(std.testing.allocator);
    try std.testing.expectEqual(tool_result_limits.default_max_tool_result_bytes, absent.max_tool_result_bytes);

    var explicit = try loadStartupStateForWorkspace(std.testing.allocator, explicit_root, "default-model", 25);
    defer explicit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 131072), explicit.max_tool_result_bytes);
}

test "loadStartupState falls back to auto for invalid first_call_tool_choice" {
    var env = try TestEnv.install(std.testing.allocator, &.{});
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeFixtureFile(tmp.dir, "workspace/.fx.json", "{\"first_call_tool_choice\":\"required\"}");

    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);

    var state = try loadStartupStateForWorkspace(std.testing.allocator, workspace_root, "default-model", 25);
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.ToolChoice.auto, state.first_call_tool_choice);
}

test "loadStartupState diagnoses the retired fuzzy skill setting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_root);
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);

    try writeFixtureFile(tmp.dir, "home/.fx/settings.json", "{\"skill_match_fuzzy\":true}");

    var env = try TestEnv.install(std.testing.allocator, &.{.{ .key = "HOME", .value = home_root }});
    defer env.deinit();

    var state = try loadStartupStateForWorkspace(std.testing.allocator, workspace_root, "default-model", 25);
    defer state.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), state.config_diagnostics.len);
    try std.testing.expectEqual(config_runtime.ConfigDiagnosticCause.retired_skill_match_fuzzy, state.config_diagnostics[0].cause);
}

test "credential onboarding can be skipped independently from Keychain" {
    var env = try TestEnv.install(std.testing.allocator, &.{
        .{ .key = "FX_SKIP_ONBOARDING", .value = "1" },
        .{ .key = "FX_DISABLE_KEYCHAIN", .value = "1" },
    });
    defer env.deinit();

    const onboarding_skipped = credentialOnboardingDisabled();
    try std.testing.expect(onboarding_skipped);
}

fn writeFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

test "subagent manager lifecycle restores exact normal screen and cursor across repeated cycles" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "subagent-manager-screen.out";
    const out_file = try tmp.dir.createFile(io_mod.getIo(), out_path, .{ .truncate = true });
    var shell = TranscriptRuntime{
        .stdout_file = out_file,
        .layout = .{
            .rows = 6,
            .cols = 24,
            .content_bottom = 3,
            .divider_top_row = 3,
            .input_row = 4,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);

    var metrics = Metrics{};
    var terminal = TerminalState{};
    try writeLifecycleTerminalBytes(&shell, &metrics, "main transcript\x1b[3;7H");
    for (0..3) |_| {
        try enterSubagentManagerScreen(&terminal, &shell, &metrics);
        try enterSubagentManagerScreen(&terminal, &shell, &metrics);
        try writeLifecycleTerminalBytes(&shell, &metrics, "\x1b[H\x1b[2JSubagent manager\x1b[6;20H");
        try leaveSubagentManagerScreen(&terminal, &shell, &metrics);
        try leaveSubagentManagerScreen(&terminal, &shell, &metrics);
    }
    try writeLifecycleTerminalBytes(&shell, &metrics, "X");
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(io_mod.getIo(), out_path, .{});
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 1024);
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\x1b[?1049h"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\x1b[?1049l"));
    try std.testing.expect(!terminal.subagentManagerScreenActive());
    try std.testing.expectEqual(@as(u21, 'm'), shell.shadow_vt.?.cellAt(1, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), shell.shadow_vt.?.cellAt(3, 7).?.codepoint);
}

test "terminal takeover leaves manager before entry and hands the alternate buffer back once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_file = try tmp.dir.createFile(
        io_mod.getIo(),
        "terminal-takeover-screen.out",
        .{ .truncate = true },
    );
    var shell = TranscriptRuntime{ .stdout_file = out_file };
    defer shell.deinit(alloc);
    var metrics = Metrics{};
    var terminal = TerminalState{};

    try enterSubagentManagerScreen(&terminal, &shell, &metrics);
    try leaveSubagentManagerScreen(&terminal, &shell, &metrics);
    try enterTerminalSessionScreen(&terminal, &shell, &metrics);
    try std.testing.expect(terminal.terminalSessionScreenActive());
    try handoffTerminalSessionToSubagentManager(&terminal, &shell, &metrics);
    try std.testing.expect(terminal.subagentManagerScreenActive());
    try leaveSubagentManagerScreen(&terminal, &shell, &metrics);
    shell.stdout_file.close(io_mod.getIo());

    var read_file = try tmp.dir.openFile(
        io_mod.getIo(),
        "terminal-takeover-screen.out",
        .{},
    );
    defer read_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &read_file, 4096);
    defer alloc.free(bytes);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, bytes, alternate_screen_enter),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, bytes, ui_terminal.alternate_screen_leave_sequence),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, bytes, "\x1b[>4;0m"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, bytes, "\x1b[>4;2m"),
    );
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[?1004l") != null);
    try std.testing.expectEqualStrings(
        "\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l\x1b[?1l\x1b>\x1b[?2004l\x1b[<u\x1b[>4;0m\x1b[4l\x1b[?6l\x1b[?7h\x1b[0m\x1b[?25h",
        terminal_takeover_reset,
    );
    try std.testing.expect(std.mem.find(
        u8,
        bytes,
        terminal_takeover_reset ++ "\x1b[2J\x1b[H",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        bytes,
        ui_terminal.interactiveModeEnableSequence(io_mod.getenv("TMUX")),
    ) != null);
}

test "failed terminal takeover leave and manager handoff keep physical ownership armed" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var metrics = Metrics{};

    const leave_file = try tmp.dir.createFile(
        io_mod.getIo(),
        "terminal-takeover-leave-failure.out",
        .{},
    );
    var leave_shell = TranscriptRuntime{ .stdout_file = leave_file };
    defer leave_shell.deinit(alloc);
    leave_shell.stdout_file.close(io_mod.getIo());
    var leave_terminal = TerminalState{
        .alternate_screen_owner = .terminal_session,
    };
    try std.testing.expectError(
        error.NotOpenForWriting,
        leaveTerminalSessionScreen(&leave_terminal, &leave_shell, &metrics),
    );
    try std.testing.expect(leave_terminal.terminalSessionScreenActive());

    const handoff_file = try tmp.dir.createFile(
        io_mod.getIo(),
        "terminal-takeover-handoff-failure.out",
        .{},
    );
    var handoff_shell = TranscriptRuntime{ .stdout_file = handoff_file };
    defer handoff_shell.deinit(alloc);
    handoff_shell.stdout_file.close(io_mod.getIo());
    var handoff_terminal = TerminalState{
        .alternate_screen_owner = .terminal_session,
    };
    try std.testing.expectError(
        error.NotOpenForWriting,
        handoffTerminalSessionToSubagentManager(
            &handoff_terminal,
            &handoff_shell,
            &metrics,
        ),
    );
    try std.testing.expect(handoff_terminal.terminalSessionScreenActive());
}

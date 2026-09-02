const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const app_lifecycle = @import("../app/app_lifecycle.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const chatgpt_oauth = @import("../auth/chatgpt_oauth.zig");
const grok_oauth = @import("../auth/grok_oauth.zig");
const acp_runner = @import("acp_runner.zig");
const cli_ask = @import("cli_ask.zig");
const cli_replay = @import("cli_replay.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const collections = @import("../shared/collections.zig");
const config_runtime = @import("../config/config_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const doctor_runtime = @import("doctor_runtime.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const execution_process_provider = @import("../execution/process_provider.zig");
const github_publish = @import("../github/github_publish.zig");
const github_workflows = @import("../github/github_workflows.zig");
const host = @import("../hosts/host.zig");
const login_flow = @import("../auth/login_flow.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const secret = @import("../auth/secret.zig");
const output_contracts = @import("../output/output_contracts.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const session_store = @import("../session/session_store.zig");
const subagent_resume_admission = @import("../subagent/resume_admission.zig");
const usage_report = @import("../session/usage_report.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const types = @import("../shared/types.zig");
const update_target = @import("../upgrade/update_target.zig");
const test_builtin_gateway = if (builtin.is_test)
    @import("../../builtins/gateway.zig")
else
    struct {};
const context_contract = @import("../workspace/context_contract.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mcp_command_provider = @import("../mcp/command_provider.zig");
const mcp_health = @import("../mcp/health.zig");
const project_config = @import("../mcp/project_config.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const text_utils = @import("../shared/text_utils.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");
const usage_cli_runtime = @import("usage_cli_runtime.zig");

const Allocator = std.mem.Allocator;
const CommandCatalog = command_specs.TopLevelRegistry;
const TopLevelKind = command_specs.TopLevelKind;

pub const Command = union(enum) {
    interactive,
    help,
    ask: []const [:0]const u8,
    acp: []const [:0]const u8,
    pr: []const [:0]const u8,
    issue: []const [:0]const u8,
    login: []const [:0]const u8,
    logout: []const [:0]const u8,
    setup: []const [:0]const u8,
    status: []const [:0]const u8,
    permissions: []const [:0]const u8,
    mcp: []const [:0]const u8,
    models: []const [:0]const u8,
    provider: []const [:0]const u8,
    doctor: []const [:0]const u8,
    teams: []const [:0]const u8,
    session: []const [:0]const u8,
    sessions: []const [:0]const u8,
    resume_session: ResumeInvocation,
    credits: []const [:0]const u8,
    usage: []const [:0]const u8,
    upgrade: []const [:0]const u8,
    replay: []const [:0]const u8,
    workspace: []const [:0]const u8,
    unknown: []const u8,
};

const ResumeInvocation = struct {
    args: []const [:0]const u8,
    top_level_alias: bool = false,
};

const resume_id_alias_prefix = "--resume-";
pub const upgrade_relaunch_arg = "--upgrade-relaunch";

pub const UpgradeRelaunch = struct {
    previous_revision: ?[]u8 = null,

    pub fn deinit(self: *UpgradeRelaunch, alloc: Allocator) void {
        if (self.previous_revision) |revision| alloc.free(revision);
        self.* = undefined;
    }
};

// The one resume alias that asks which session to open. Every other spelling
// names its target, so it resumes without a prompt.
const resume_picker_alias = "-r";

pub const ResumeTarget = union(enum) {
    pick,
    last,
    id: []u8,

    pub fn deinit(self: *ResumeTarget, alloc: Allocator) void {
        switch (self.*) {
            .pick, .last => {},
            .id => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

pub const LaunchModifiers = struct {
    context_limit_overrides: []config_runtime.context_limits.Override = &.{},
    additional_directories: [][]u8 = &.{},
    saved_directories_suppressed: bool = false,

    pub fn deinit(self: *LaunchModifiers, alloc: Allocator) void {
        if (self.context_limit_overrides.len > 0) alloc.free(self.context_limit_overrides);
        for (self.additional_directories) |path| alloc.free(path);
        if (self.additional_directories.len > 0) alloc.free(self.additional_directories);
        self.* = .{};
    }

    pub fn hasWorkspaceModifiers(self: LaunchModifiers) bool {
        return self.additional_directories.len > 0 or self.saved_directories_suppressed;
    }
};

pub const InteractiveLaunch = struct {
    requested_resume: ?ResumeTarget = null,
    upgrade_relaunch: ?UpgradeRelaunch = null,
    modifiers: LaunchModifiers = .{},

    pub fn deinit(self: *InteractiveLaunch, alloc: Allocator) void {
        if (self.requested_resume) |*target| target.deinit(alloc);
        if (self.upgrade_relaunch) |*relaunch| relaunch.deinit(alloc);
        self.modifiers.deinit(alloc);
        self.* = undefined;
    }
};

pub const RunResult = union(enum) {
    interactive: InteractiveLaunch,
    handled_success,
    handled_failure,
    handled_exit: u8,
};

const version_usage = "usage: fx --version\n";

pub const Config = struct {
    version: []const u8 = "",
    revision: []const u8 = "",
    build_channel: update_target.Channel = .stable,
    auth_mode: credentials.AuthMode = .local,
    command_catalog: CommandCatalog,
    default_model: []const u8,
    default_agent_step_limit: usize,
    models_path: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_provider: gateway_provider.Provider,
    provider_set: provider_set.Set,
    process_provider: execution_process_provider.Provider = execution_process_provider.unavailable_provider,
    url_opener: host.UrlOpener,
    secret_store: host.SecretStore,
    prompt_policy: prompt_policy.Policy,
    skill_root_policy: skill_contract.RootPolicy,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize,
    max_history_turns: usize,
    context_registry: context_contract.Registry,
    mode_registry: mode_registry.Registry,
    tool_set: tool_set_contract.ToolSet,
    inspect_mcp_profile_config: mcp_contract.InspectProfileConfigFn,
    inspect_mcp_local_config: mcp_health.InspectLocalConfigFn =
        mcp_health.inspectLocalConfigUnavailable,
    load_mcp_runtime: mcp_runtime.LoadRuntimeFn,
    add_mcp_profile_server: mcp_command_provider.AddProfileServerFn =
        mcp_command_provider.addProfileServerUnavailable,
    remove_mcp_profile_server: mcp_command_provider.RemoveProfileServerFn =
        mcp_command_provider.removeProfileServerUnavailable,
    acp_runner: acp_runner.Runner,
};

const LocalSurfaceOptions = struct {
    format: output_contracts.OutputFormat = .text,
};

fn parseLoginProvider(rest: []const [:0]const u8) !?model_provider.ProviderId {
    if (rest.len == 0) return null;
    if (rest.len != 1) return error.InvalidLoginProviderArgs;
    return provider_catalog.parse(rest[0]) orelse error.InvalidLoginProviderArgs;
}

fn selectCatalogModel(
    entries: []const model_catalog.ModelCatalogEntry,
    saved: ?[]const u8,
) ?[]const u8 {
    if (saved) |candidate| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.id, candidate)) return entry.id;
        }
    }
    return if (entries.len > 0) entries[0].id else null;
}

const UpgradeOptions = struct {
    format: output_contracts.OutputFormat = .text,
    channel: ?update_target.Channel = null,
};

const SessionListOptions = struct {
    format: output_contracts.OutputFormat = .text,
    scope: session_store.SessionListScope = .current_workspace,
    limit: usize = session_store.session_list_default_limit,
    continuation: ?session_store.ResumableSessionContinuation = null,
};

const UsageOptions = struct {
    format: output_contracts.OutputFormat = .text,
    scope: usage_report.Scope = .days_30,
};

const WorkspaceOptions = struct {
    format: output_contracts.OutputFormat = .text,
    action: ?workspace_commands.Action = null,
};

const SessionDetailTarget = union(enum) {
    last,
    id: []u8,

    fn deinit(self: *SessionDetailTarget, alloc: Allocator) void {
        switch (self.*) {
            .last => {},
            .id => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

const SessionDetailOptions = struct {
    format: output_contracts.OutputFormat = .text,
    target: ?SessionDetailTarget = null,

    fn deinit(self: *SessionDetailOptions, alloc: Allocator) void {
        if (self.target) |*target| target.deinit(alloc);
        self.* = undefined;
    }
};

const SessionMigrationOptions = struct {
    format: output_contracts.OutputFormat = .text,
    session_id: []u8,
    allow_large: bool = false,

    fn deinit(self: *SessionMigrationOptions, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const SessionRecoveryOptions = struct {
    format: output_contracts.OutputFormat = .text,
    session_id: []u8,

    fn deinit(self: *SessionRecoveryOptions, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const AcpOptions = struct {
    model: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
};

const WorkflowOptions = struct {
    auto_permission: bool,
    create: bool,
    context: []u8,

    fn deinit(self: WorkflowOptions, alloc: Allocator) void {
        alloc.free(self.context);
    }
};

const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const LoadStartupStateFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStateWithoutCredentialsFn = *const fn (Allocator, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStatusFn = *const fn (Allocator, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupStatus;
const LoadStartupStateWithAuthModeFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize, credentials.AuthMode) anyerror!app_lifecycle.StartupState;
const LoadCatalogStartupStateWithAuthModeFn = *const fn (Allocator, host.SecretStore, []const u8, usize, credentials.AuthMode) anyerror!app_lifecycle.StartupState;
const LoadStartupStatusWithAuthModeFn = *const fn (Allocator, host.SecretStore, []const u8, usize, credentials.AuthMode) anyerror!app_lifecycle.StartupStatus;
const GetenvFn = *const fn (?*anyopaque, []const u8) ?[]const u8;
const EnvironMapFn = *const fn (?*anyopaque) ?*const std.process.Environ.Map;
const SelfExePathFn = *const fn (?*anyopaque, Allocator) anyerror![]u8;
const ReadMaskedKeyFn = *const fn (?*anyopaque, Allocator, WriteFn, ?*anyopaque) anyerror![]u8;
const SetupTerminalAvailableFn = *const fn (?*anyopaque) bool;
const RunDeps = struct {
    stdout_ctx: ?*anyopaque = null,
    stderr_ctx: ?*anyopaque = null,
    env_ctx: ?*anyopaque = null,
    self_exe_ctx: ?*anyopaque = null,
    setup_ctx: ?*anyopaque = null,
    write_stdout: WriteFn = writeRealStdout,
    write_stderr: WriteFn = writeRealStderr,
    load_startup_state: LoadStartupStateFn = app_lifecycle.loadStartupState,
    load_startup_state_without_credentials: LoadStartupStateWithoutCredentialsFn = app_lifecycle.loadStartupStateWithoutCredentials,
    load_startup_status: LoadStartupStatusFn = app_lifecycle.loadStartupStatus,
    load_startup_state_with_auth_mode: LoadStartupStateWithAuthModeFn = app_lifecycle.loadStartupStateWithAuthMode,
    load_catalog_startup_state_with_auth_mode: LoadCatalogStartupStateWithAuthModeFn = app_lifecycle.loadCatalogStartupStateWithAuthMode,
    load_startup_status_with_auth_mode: LoadStartupStatusWithAuthModeFn = app_lifecycle.loadStartupStatusWithAuthMode,
    getenv: GetenvFn = getenvDefault,
    environ_map: EnvironMapFn = environMapDefault,
    self_exe_path: SelfExePathFn = selfExePathDefault,
    read_masked_key: ReadMaskedKeyFn = readMaskedKeyDefault,
    setup_terminal_available: SetupTerminalAvailableFn = setupTerminalAvailableDefault,
};

const GlobalLaunchArgs = struct {
    remaining: []const [:0]const u8,
    modifiers: LaunchModifiers = .{},

    fn deinit(self: *GlobalLaunchArgs, alloc: Allocator) void {
        self.modifiers.deinit(alloc);
        self.* = undefined;
    }

    fn takeModifiers(self: *GlobalLaunchArgs) LaunchModifiers {
        const result = self.modifiers;
        self.modifiers = .{};
        return result;
    }
};

fn parseGlobalLaunchArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !GlobalLaunchArgs {
    var overrides: std.ArrayList(config_runtime.context_limits.Override) = .empty;
    errdefer overrides.deinit(alloc);
    var directories: std.ArrayList([]u8) = .empty;
    errdefer {
        for (directories.items) |path| alloc.free(path);
        directories.deinit(alloc);
    }
    var suppress_saved = false;

    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--context-limit")) {
            index += 1;
            if (index >= args.len) return error.MissingContextLimitValue;
            try overrides.append(alloc, try config_runtime.context_limits.parseOverride(args[index]));
        } else if (std.mem.startsWith(u8, arg, "--context-limit=")) {
            try overrides.append(alloc, try config_runtime.context_limits.parseOverride(arg["--context-limit=".len..]));
        } else if (std.mem.eql(u8, arg, "--add-dir")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingAddDirectoryValue;
            try directories.append(alloc, try alloc.dupe(u8, args[index]));
        } else if (std.mem.startsWith(u8, arg, "--add-dir=")) {
            const value = arg["--add-dir=".len..];
            if (value.len == 0) return error.MissingAddDirectoryValue;
            try directories.append(alloc, try alloc.dupe(u8, value));
        } else if (std.mem.eql(u8, arg, "--no-additional-dirs")) {
            if (suppress_saved) return error.DuplicateAdditionalDirectorySuppression;
            suppress_saved = true;
        } else {
            break;
        }
        index += 1;
    }

    const override_slice = try overrides.toOwnedSlice(alloc);
    errdefer if (override_slice.len > 0) alloc.free(override_slice);
    const directory_slice = try directories.toOwnedSlice(alloc);
    return .{
        .remaining = args[index..],
        .modifiers = .{
            .context_limit_overrides = override_slice,
            .additional_directories = directory_slice,
            .saved_directories_suppressed = suppress_saved,
        },
    };
}

/// Returns the command that follows the supported global launch modifiers.
/// Startup uses this same surface to select the full runtime configuration
/// before the allocating parser runs.
pub fn commandAfterGlobalLaunchArgs(args: []const [:0]const u8) ?[]const u8 {
    const remaining = argsAfterGlobalLaunchArgs(args);
    return if (remaining.len > 0) remaining[0] else null;
}

pub fn argsAfterGlobalLaunchArgs(args: []const [:0]const u8) []const [:0]const u8 {
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--context-limit") or std.mem.eql(u8, arg, "--add-dir")) {
            index += 1;
            if (index >= args.len) return &.{};
        } else if (!std.mem.startsWith(u8, arg, "--context-limit=") and
            !std.mem.startsWith(u8, arg, "--add-dir=") and
            !std.mem.eql(u8, arg, "--no-additional-dirs"))
        {
            return args[index..];
        }
        index += 1;
    }
    return &.{};
}

pub fn parse(command_catalog: CommandCatalog, args: []const [:0]const u8) Command {
    @setRuntimeSafety(false);
    if (args.len == 0) return .interactive;

    const command = args[0];
    if (command.len == 0) return .{ .unknown = command };
    switch (command[0]) {
        '-', 'h' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .help)) return .help;
            if (command_specs.matchesTopLevel(command_catalog, command, .@"resume") or
                std.mem.startsWith(u8, command, resume_id_alias_prefix))
            {
                return .{ .resume_session = .{
                    .args = args,
                    .top_level_alias = true,
                } };
            }
        },
        'a' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .ask)) return .{ .ask = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .acp)) return .{ .acp = args[1..] };
        },
        'b' => if (command_specs.matchesTopLevel(command_catalog, command, .credits)) return .{ .credits = args[1..] },
        'c' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .credits)) return .{ .credits = args[1..] };
        },
        'd' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .doctor)) return .{ .doctor = args[1..] };
        },
        'i' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .issue)) return .{ .issue = args[1..] };
        },
        'l' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .login)) return .{ .login = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .logout)) return .{ .logout = args[1..] };
        },
        'm' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .mcp)) return .{ .mcp = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .models)) return .{ .models = args[1..] };
        },
        'p' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .pr)) return .{ .pr = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .permissions)) return .{ .permissions = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .provider)) return .{ .provider = args[1..] };
        },
        'r' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .@"resume")) return .{ .resume_session = .{ .args = args[1..] } };
            if (command_specs.matchesTopLevel(command_catalog, command, .replay)) return .{ .replay = args[1..] };
        },
        's' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .setup)) return .{ .setup = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .status)) return .{ .status = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .sessions)) return .{ .sessions = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .session)) {
                if (args.len > 1 and std.mem.eql(u8, args[1], "resume")) {
                    return .{ .resume_session = .{ .args = args[2..] } };
                }
                return .{ .session = args[1..] };
            }
        },
        't' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .teams)) return .{ .teams = args[1..] };
        },
        'u' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .usage)) return .{ .usage = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .upgrade)) return .{ .upgrade = args[1..] };
        },
        'w' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .workspace)) return .{ .workspace = args[1..] };
        },
        else => {},
    }
    return .{ .unknown = command };
}

pub const NonInteractiveLaunch = struct {
    global_args: GlobalLaunchArgs,
    effective_args: []const [:0]const u8,
    command: Command,

    pub fn deinit(self: *NonInteractiveLaunch, alloc: Allocator) void {
        self.global_args.deinit(alloc);
        self.* = undefined;
    }
};

pub const InteractiveLaunchParseResult = union(enum) {
    interactive: InteractiveLaunch,
    noninteractive: NonInteractiveLaunch,
};

/// Parses the shared interactive launch language without dispatching commands.
/// Returned launch values own their allocations and must be deinitialized.
pub fn parseInteractiveLaunch(
    alloc: Allocator,
    args: []const [:0]const u8,
    command_catalog: CommandCatalog,
) !InteractiveLaunchParseResult {
    var global_args = try parseGlobalLaunchArgs(alloc, args);
    errdefer global_args.deinit(alloc);
    const effective_args = global_args.remaining;

    if (effective_args.len == 0) {
        return .{ .interactive = .{ .modifiers = global_args.takeModifiers() } };
    }

    const command = parse(command_catalog, effective_args);
    if (topLevelHelpRequest(command_catalog, effective_args) != null) {
        return .{ .noninteractive = .{
            .global_args = global_args,
            .effective_args = effective_args,
            .command = command,
        } };
    }
    switch (command) {
        .interactive => return .{ .interactive = .{
            .modifiers = global_args.takeModifiers(),
        } },
        .resume_session => |invocation| {
            const resume_args = invocation.args;
            const has_upgrade_relaunch = !invocation.top_level_alias and
                resume_args.len >= 2 and
                std.mem.eql(u8, resume_args[1], upgrade_relaunch_arg);
            if (has_upgrade_relaunch and resume_args.len > 3) return error.InvalidResumeArgs;
            var upgrade_relaunch: ?UpgradeRelaunch = null;
            errdefer if (upgrade_relaunch) |*relaunch| relaunch.deinit(alloc);
            if (has_upgrade_relaunch) {
                const previous_revision = if (resume_args.len == 3) revision: {
                    if (!update_target.isValidRevision(resume_args[2])) return error.InvalidResumeArgs;
                    break :revision try alloc.dupe(u8, resume_args[2]);
                } else null;
                upgrade_relaunch = .{ .previous_revision = previous_revision };
            }
            const target_args = if (has_upgrade_relaunch) resume_args[0..1] else resume_args;
            const target = try parseResumeArgs(
                alloc,
                command_catalog,
                target_args,
                invocation.top_level_alias,
            );
            const relaunch = upgrade_relaunch;
            upgrade_relaunch = null;
            return .{ .interactive = .{
                .requested_resume = target,
                .upgrade_relaunch = relaunch,
                .modifiers = global_args.takeModifiers(),
            } };
        },
        else => return .{ .noninteractive = .{
            .global_args = global_args,
            .effective_args = effective_args,
            .command = command,
        } },
    }
}

/// Detects `fx <subcommand> --help` / `-h` and returns the subcommand kind so the
/// caller can render command-specific help. Top-level `fx --help`/`fx help` are
/// handled separately and intentionally excluded here.
fn topLevelHelpRequest(command_catalog: CommandCatalog, args: []const [:0]const u8) ?TopLevelKind {
    if (args.len < 2) return null;
    const kind = command_specs.topLevelKindFromToken(command_catalog, args[0]) orelse return null;
    if (kind == .help) return null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return kind;
    }
    return null;
}

pub fn runIfRequested(alloc: Allocator, args: []const [:0]const u8, cfg: Config) !RunResult {
    return runIfRequestedWithDeps(alloc, args, cfg, .{});
}

pub fn runNoConfigIfRequested(alloc: Allocator, args: []const [:0]const u8, version: []const u8, command_catalog: CommandCatalog) !bool {
    return runNoConfigIfRequestedWithDeps(alloc, args, version, command_catalog, .{});
}

fn runNoConfigIfRequestedWithDeps(
    alloc: Allocator,
    args: []const [:0]const u8,
    version: []const u8,
    command_catalog: CommandCatalog,
    deps: RunDeps,
) !bool {
    if (args.len != 1 or !command_specs.matchesTopLevel(command_catalog, args[0], .help)) {
        return false;
    }
    try writeTopLevelHelp(alloc, command_catalog, deps, version, .stdout);
    return true;
}

const ProviderActivationCaller = enum {
    provider_command,
    provider_login,
};

const CliTeamValidationContext = struct {
    alloc: Allocator,
    cfg: *const Config,
};

fn validateCliTeamCredential(
    raw: ?*anyopaque,
    candidate: credentials.Credential,
) std.mem.Allocator.Error!login_flow.TeamValidationResult {
    const context: *CliTeamValidationContext = @ptrCast(@alignCast(raw.?));
    const access = credentials.catalogAccessAt(candidate, io_mod.milliTimestamp());
    if (access.authorizationCredential() == null) return .rejected;
    const provider = context.cfg.provider_set.gateway.model_catalog orelse return .rejected;
    const fetched = try provider.fetch(context.alloc, .{
        .access = access,
        .endpoint = context.cfg.models_path,
        .view = .picker,
    });
    return switch (fetched) {
        .failure => .rejected,
        .catalog => |catalog_value| result: {
            var catalog = catalog_value;
            defer model_catalog.freeModelCatalog(context.alloc, &catalog);
            break :result if (catalog.items.len > 0) .accepted else .rejected;
        },
    };
}

fn writeProviderActivationError(
    alloc: Allocator,
    deps: RunDeps,
    caller: ProviderActivationCaller,
    detail: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        alloc,
        "{s}: {s}\n",
        .{ if (caller == .provider_login) "fx login" else "fx provider", detail },
    );
    defer alloc.free(message);
    try writeStderr(deps, message);
}

fn writeHostManagedAuthResult(deps: RunDeps) !void {
    try writeStdout(deps, credentials.host_managed_auth_message);
    try writeStdout(deps, "\n");
}

fn activateProviderSelection(
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
    target: model_provider.ProviderId,
    caller: ProviderActivationCaller,
    exact_source: ?credentials.Source,
) !bool {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    var settings = config_runtime.loadMergedSettings(alloc, workspace_root) catch |err| {
        try writeProviderActivationError(alloc, deps, caller, "could not load settings");
        debug_trace.logf("config", "provider selection settings load failed err={s}", .{@errorName(err)});
        return false;
    };
    defer settings.deinit(alloc);

    const preferred_source = exact_source orelse settings.credential_source;
    var prepared_credential = if (cfg.auth_mode == .host_managed)
        null
    else
        try auth_runtime.prepareCredential(
            alloc,
            cfg.gateway_provider.oauth_transport,
            cfg.secret_store,
            target,
            preferred_source,
        );
    defer if (prepared_credential) |*credential| credential.deinit(alloc);

    const already_selected = (settings.provider orelse .gateway) == target;
    if (caller == .provider_command and already_selected and
        (cfg.auth_mode == .host_managed or prepared_credential != null))
    {
        try writeStdout(deps, switch (target) {
            .gateway => "Gateway is already selected.\n",
            .codex => "Codex is already selected.\n",
            .grok => "Grok is already selected.\n",
        });
        return true;
    }

    var performed_login: ?model_provider.ProviderId = null;
    if (cfg.auth_mode == .local and prepared_credential == null and target == .codex and caller == .provider_command) {
        chatgpt_oauth.runLogin(alloc, cfg.gateway_provider.oauth_transport, cfg.url_opener) catch |err| {
            debug_trace.logf("auth", "provider selection Codex login failed err={s}", .{@errorName(err)});
            try writeProviderActivationError(alloc, deps, caller, "Codex login failed");
            return false;
        };
        performed_login = .codex;
        prepared_credential = try auth_runtime.prepareCredential(
            alloc,
            cfg.gateway_provider.oauth_transport,
            cfg.secret_store,
            target,
            preferred_source,
        );
    }
    if (cfg.auth_mode == .local and prepared_credential == null and target == .grok and caller == .provider_command) {
        grok_oauth.runLogin(alloc, cfg.gateway_provider.oauth_transport, cfg.url_opener) catch |err| {
            debug_trace.logf("auth", "provider selection Grok login failed err={s}", .{@errorName(err)});
            try writeProviderActivationError(alloc, deps, caller, "Grok login failed");
            return false;
        };
        performed_login = .grok;
        prepared_credential = try auth_runtime.prepareCredential(
            alloc,
            cfg.gateway_provider.oauth_transport,
            cfg.secret_store,
            target,
            preferred_source,
        );
    }

    const credential = if (cfg.auth_mode == .host_managed)
        null
    else if (prepared_credential) |*value|
        value
    else {
        try writeProviderActivationError(
            alloc,
            deps,
            caller,
            switch (target) {
                .codex => "Codex credential is unavailable",
                .grok => "Grok credential is unavailable",
                .gateway => "configure a Gateway credential first",
            },
        );
        return false;
    };
    const catalog_provider = cfg.provider_set.select(target).model_catalog orelse {
        try writeProviderActivationError(alloc, deps, caller, switch (target) {
            .codex => "Codex model catalog is unavailable",
            .grok => "Grok model catalog is unavailable",
            .gateway => "Gateway model catalog is unavailable",
        });
        return false;
    };
    const fetch_result = model_catalog.fetchWithPublicFallback(catalog_provider, alloc, .{
        .access = if (cfg.auth_mode == .host_managed)
            .host_managed
        else
            credentials.catalogAccessAt(
                credential.?.*,
                io_mod.milliTimestamp(),
            ).withExplicitAuthority(),
        .endpoint = cfg.models_path,
        .view = .picker,
    });
    var loaded = switch (fetch_result) {
        .loaded => |loaded| blk: {
            if (loaded.provenance.access.level != .authenticated or
                loaded.provenance.anonymous_fallback_used)
            {
                var rejected = loaded.catalog;
                model_catalog.freeModelCatalog(alloc, &rejected);
                try writeProviderActivationError(
                    alloc,
                    deps,
                    caller,
                    "target credential did not produce an authenticated model catalog",
                );
                return false;
            }
            break :blk loaded;
        },
        .failed => |failure| {
            debug_trace.logf("catalog", "provider selection catalog failed provider={s} category={s}", .{ @tagName(target), @tagName(failure.failure.category) });
            const detail = try std.fmt.allocPrint(
                alloc,
                "could not load the target model catalog ({s})",
                .{@tagName(failure.failure.category)},
            );
            defer alloc.free(detail);
            try writeProviderActivationError(alloc, deps, caller, detail);
            return false;
        },
    };
    defer model_catalog.freeModelCatalog(alloc, &loaded.catalog);
    const saved_model = settings.models.get(target);
    const selected_model = selectCatalogModel(loaded.catalog.items, saved_model) orelse {
        try writeProviderActivationError(alloc, deps, caller, "target model catalog is empty");
        return false;
    };
    var attempt = config_runtime.attemptUserPreferences(alloc, .{
        .provider = target,
        .model_preference = .{ .provider = target, .model = selected_model },
        .credential_source = exact_source,
    });
    defer attempt.deinit(alloc);
    switch (attempt) {
        .failure => |failure| {
            debug_trace.logf("config", "provider selection persistence failed err={s}", .{@errorName(failure.err)});
            try writeProviderActivationError(alloc, deps, caller, "failed to save provider selection");
            return false;
        },
        .outcome => {},
    }
    if (performed_login) |provider| switch (provider) {
        .codex => try writeStdout(deps, "Signed in with Codex.\n"),
        .grok => try writeStdout(deps, "Signed in with Grok.\n"),
        .gateway => unreachable,
    };
    if (caller == .provider_command) {
        try writeStdout(deps, switch (target) {
            .gateway => "Provider set to Gateway.\n",
            .codex => "Provider set to Codex.\n",
            .grok => "Provider set to Grok.\n",
        });
    }
    return true;
}

fn runIfRequestedWithDeps(alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !RunResult {
    const parsed_launch = parseInteractiveLaunch(alloc, args, cfg.command_catalog) catch |err| {
        if (err == error.InvalidResumeArgs) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .@"resume");
            return .handled_failure;
        }
        var writer: std.Io.Writer.Allocating = .init(alloc);
        defer writer.deinit();
        if (globalLaunchErrorMessage(err)) |message| {
            try writer.writer.print("fx: {s}\n", .{message});
        } else {
            try writer.writer.print("fx: invalid global launch option: {s}\n", .{@errorName(err)});
        }
        try writer.writer.writeAll("usage: fx [--context-limit NAME=BYTES|off] [--add-dir PATH]... [--no-additional-dirs] <command>\n");
        try writeStderr(deps, writer.written());
        return .handled_failure;
    };
    switch (parsed_launch) {
        .interactive => |launch| {
            try writeMcpProfileWarningIfPresent(alloc, cfg, deps);
            return .{ .interactive = launch };
        },
        .noninteractive => |value| {
            var noninteractive = value;
            defer noninteractive.deinit(alloc);
            return runNonInteractiveWithDeps(alloc, &noninteractive, cfg, deps);
        },
    }
}

fn runNonInteractiveWithDeps(
    alloc: Allocator,
    parsed_launch: *NonInteractiveLaunch,
    cfg: Config,
    deps: RunDeps,
) !RunResult {
    const global_args = &parsed_launch.global_args;
    const effective_args = parsed_launch.effective_args;
    const parsed_command = parsed_launch.command;

    if (global_args.modifiers.hasWorkspaceModifiers() and
        !commandSupportsWorkspaceModifiers(parsed_command))
    {
        try writeWorkspaceModifierUsage(deps);
        return .handled_failure;
    }

    if (isVersionFlag(effective_args[0])) {
        if (effective_args.len != 1) {
            try writeStderr(deps, version_usage);
            return .handled_failure;
        }
        try writeStdout(deps, cfg.version);
        try writeStdout(deps, "\n");
        return .handled_success;
    }

    if (topLevelHelpRequest(cfg.command_catalog, effective_args)) |kind| {
        const text = try command_specs.renderTopLevelCommandHelp(alloc, cfg.command_catalog, kind);
        defer alloc.free(text);
        try writeStdout(deps, text);
        return .handled_success;
    }

    switch (parsed_command) {
        .interactive, .resume_session => unreachable,
        .help => {
            try writeTopLevelHelp(alloc, cfg.command_catalog, deps, cfg.version, .stdout);
            return .handled_success;
        },
        .ask => |rest| {
            try writeMcpProfileWarningIfPresent(alloc, cfg, deps);
            const exit_code = try cli_ask.run(alloc, rest, workflowConfigWithLaunchModifiers(cfg, global_args.modifiers), cfg.context_registry, cfg.tool_set);
            return if (exit_code == 0) .handled_success else .handled_failure;
        },
        .acp => |rest| {
            const acp_opts = parseAcpArgs(rest) catch {
                try writeStderr(deps, "usage: fx acp [--model <id>] [--log-file <path>]\n");
                return .handled_failure;
            };
            try cfg.acp_runner.run(alloc, .{
                .auth_mode = cfg.auth_mode,
                .default_model = cfg.default_model,
                .default_agent_step_limit = cfg.default_agent_step_limit,
                .gateway_retry_count = cfg.gateway_retry_count,
                .gateway_chat_url = cfg.gateway_provider.chat_url.resolve(cfg.gateway_chat_url),
                .gateway_models_path = cfg.models_path,
                .gateway_provider = cfg.gateway_provider,
                .provider_set = cfg.provider_set,
                .process_provider = cfg.process_provider,
                .secret_store = cfg.secret_store,
                .prompt_policy = cfg.prompt_policy,
                .ignored_list_entries = cfg.ignored_list_entries,
                .max_list_entries = cfg.max_list_entries,
                .max_read_file_bytes = cfg.max_read_file_bytes,
                .max_read_file_lines = cfg.max_read_file_lines,
                .max_read_file_line_len = cfg.max_read_file_line_len,
                .max_command_output_bytes = cfg.max_command_output_bytes,
                .max_tool_result_bytes = cfg.max_tool_result_bytes,
                .max_history_turns = cfg.max_history_turns,
                .context_registry = cfg.context_registry,
                .mode_registry = cfg.mode_registry,
                .context_limit_overrides = global_args.modifiers.context_limit_overrides,
                .additional_directories = global_args.modifiers.additional_directories,
                .saved_directories_suppressed = global_args.modifiers.saved_directories_suppressed,
                .model_override = acp_opts.model,
                .log_file = acp_opts.log_file,
            });
            return .handled_success;
        },
        .pr => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .pull_request),
        .issue => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .issue),
        .login => |rest| {
            const maybe_login_provider = parseLoginProvider(rest) catch {
                try writeStderr(deps, "usage: fx login [vercel|codex|grok]\n");
                return .handled_failure;
            };
            if (cfg.auth_mode == .host_managed) {
                try writeHostManagedAuthResult(deps);
                return .handled_success;
            }
            // Preserve the original `fx login` behavior for scripts and users.
            const login_provider = maybe_login_provider orelse .gateway;
            switch (login_provider) {
                .gateway => {
                    login_flow.runLogin(
                        alloc,
                        cfg.gateway_provider.oauth_transport,
                        cfg.url_opener,
                    ) catch |err| {
                        const message = switch (err) {
                            error.ClientIdMissing => "fx login: missing FX_OAUTH_CLIENT_ID; configure the fx Vercel App client id first\n",
                            error.AccessDenied => "fx login: authorization denied\n",
                            error.ExpiredToken, error.LoginTimedOut => "fx login: authorization expired; run fx login again\n",
                            else => "fx login: failed to sign in\n",
                        };
                        try writeStderr(deps, message);
                        return .handled_failure;
                    };
                    if (!try activateProviderSelection(
                        alloc,
                        cfg,
                        deps,
                        .gateway,
                        .provider_login,
                        .fx_login,
                    )) return .handled_failure;
                    try writeStdout(deps, "Signed in to Vercel.\n");
                    try writeStdout(deps, "AI Gateway access may still require billing or API setup for the selected account.\n");
                },
                .codex => {
                    chatgpt_oauth.runLogin(
                        alloc,
                        cfg.gateway_provider.oauth_transport,
                        cfg.url_opener,
                    ) catch |err| {
                        const message = switch (err) {
                            error.ChatGptLoginTimedOut => "fx login: Codex authorization expired; run fx login codex again\n",
                            error.ChatGptAuthorizationFailed => "fx login: Codex authorization denied\n",
                            else => "fx login: failed to sign in with Codex\n",
                        };
                        try writeStderr(deps, message);
                        return .handled_failure;
                    };
                    if (!try activateProviderSelection(alloc, cfg, deps, .codex, .provider_login, null)) {
                        return .handled_failure;
                    }
                    try writeStdout(deps, "Signed in with Codex.\n");
                },
                .grok => {
                    grok_oauth.runLogin(
                        alloc,
                        cfg.gateway_provider.oauth_transport,
                        cfg.url_opener,
                    ) catch |err| {
                        debug_trace.logf("auth", "Grok login failed err={s}", .{@errorName(err)});
                        try writeStderr(deps, "fx login: failed to sign in with Grok\n");
                        return .handled_failure;
                    };
                    if (!try activateProviderSelection(alloc, cfg, deps, .grok, .provider_login, null)) {
                        return .handled_failure;
                    }
                    try writeStdout(deps, "Signed in with Grok.\n");
                },
            }
            return .handled_success;
        },
        .logout => |rest| {
            const maybe_login_provider = parseLoginProvider(rest) catch {
                try writeStderr(deps, "usage: fx logout [vercel|codex|grok]\n");
                return .handled_failure;
            };
            if (cfg.auth_mode == .host_managed) {
                try writeHostManagedAuthResult(deps);
                return .handled_success;
            }
            // Preserve the original `fx logout` behavior for scripts and users.
            const login_provider = maybe_login_provider orelse .gateway;
            if (login_provider == .codex) {
                const outcome = chatgpt_oauth.logout() catch {
                    try writeStderr(deps, "fx logout: failed to durably remove saved Codex login\n");
                    return .handled_failure;
                };
                return switch (outcome) {
                    .deleted => result: {
                        try writeStdout(deps, "Signed out of Codex.\n");
                        break :result .handled_success;
                    },
                    .missing => result: {
                        try writeStdout(deps, "No Codex login session found.\n");
                        break :result .handled_success;
                    },
                    .deleted_not_durable => result: {
                        try writeStderr(deps, "fx logout: failed to durably remove saved Codex login\n");
                        break :result .handled_failure;
                    },
                };
            }
            if (login_provider == .grok) {
                const outcome = grok_oauth.logout(alloc, cfg.gateway_provider.oauth_transport) catch {
                    try writeStderr(deps, "fx logout: failed to durably remove saved Grok login\n");
                    return .handled_failure;
                };
                if (outcome.revocation_failed) {
                    try writeStderr(deps, "fx logout: local Grok session removed, but remote revocation could not be confirmed\n");
                }
                return switch (outcome.deletion) {
                    .deleted => result: {
                        try writeStdout(deps, "Signed out of Grok.\n");
                        break :result .handled_success;
                    },
                    .missing => result: {
                        try writeStdout(deps, "No Grok login session found.\n");
                        break :result .handled_success;
                    },
                    .deleted_not_durable => result: {
                        try writeStderr(deps, "fx logout: failed to durably remove saved Grok login\n");
                        break :result .handled_failure;
                    },
                };
            }
            const result = login_flow.logout(alloc, cfg.gateway_provider.oauth_transport) catch |err| switch (err) {
                error.SessionDeleteFailed => {
                    try writeStderr(deps, "fx logout: failed to durably remove saved fx login\n");
                    return .handled_failure;
                },
            };
            if (!result.local_durability_failed) {
                var preference = config_runtime.attemptUserPreferences(
                    alloc,
                    .{ .clear_credential_source = true },
                );
                defer preference.deinit(alloc);
                switch (preference) {
                    .outcome => {},
                    .failure => |failure| {
                        debug_trace.logf(
                            "auth",
                            "logout credential preference clear failed err={s}",
                            .{@errorName(failure.err)},
                        );
                        try writeStderr(deps, "fx logout: signed out, but failed to clear the saved fx login selection\n");
                        return .handled_failure;
                    },
                }
            }
            if (result.local_durability_failed) {
                try writeStderr(deps, "fx logout: failed to durably remove saved fx login\n");
            } else {
                try writeStdout(
                    deps,
                    if (result.session_deleted) "Signed out of fx.\n" else "No fx login session found.\n",
                );
            }
            if (result.remote_revocation_failed) {
                try writeStderr(deps, login_flow.remote_revocation_warning);
                try writeStderr(deps, "\n");
            }
            return if (result.local_durability_failed) .handled_failure else .handled_success;
        },
        .teams => |rest| {
            if (rest.len != 0) {
                try writeStderr(deps, "usage: fx teams\n");
                return .handled_failure;
            }
            if (cfg.auth_mode == .host_managed) {
                try writeHostManagedAuthResult(deps);
                return .handled_success;
            }
            var validation_context = CliTeamValidationContext{ .alloc = alloc, .cfg = &cfg };
            login_flow.runTeams(
                alloc,
                cfg.gateway_provider.oauth_transport,
                .{
                    .context = &validation_context,
                    .validate_fn = validateCliTeamCredential,
                },
            ) catch |err| {
                const message = switch (err) {
                    error.NoSession => "fx teams: run fx login first\n",
                    error.SessionChanged => "fx teams: authentication changed; try again\n",
                    error.TeamRequestFailed => "fx teams: failed to list Vercel teams\n",
                    error.InvalidTeamSelection => "fx teams: no team selected\n",
                    error.AccessDenied => "fx teams: authorization denied\n",
                    error.TeamValidationFailed => "fx teams: selected team could not access AI Gateway\n",
                    else => "fx teams: failed to switch team\n",
                };
                try writeStderr(deps, message);
                return .handled_failure;
            };
            if (!try activateProviderSelection(
                alloc,
                cfg,
                deps,
                .gateway,
                .provider_login,
                .fx_login,
            )) return .handled_failure;
            return .handled_success;
        },
        .provider => |rest| {
            if (rest.len != 1) {
                try writeStderr(deps, "usage: fx provider <gateway|codex|grok>\n");
                return .handled_failure;
            }
            const target = model_provider.parse(rest[0]) orelse {
                try writeStderr(deps, "fx provider: expected gateway, codex, or grok\n");
                return .handled_failure;
            };
            return if (try activateProviderSelection(alloc, cfg, deps, target, .provider_command, null))
                .handled_success
            else
                .handled_failure;
        },
        .setup => |rest| {
            if (rest.len != 0) {
                try writeTopLevelUsage(cfg.command_catalog, deps, .setup);
                return .handled_failure;
            }
            if (cfg.auth_mode == .host_managed) {
                try writeHostManagedAuthResult(deps);
                return .handled_success;
            }
            return if (try runPasteSetup(alloc, cfg.secret_store, deps)) .handled_success else .handled_failure;
        },
        .status => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .status, "status", err, rest);
                return .handled_failure;
            };
            var startup = if (cfg.auth_mode == .host_managed)
                try deps.load_startup_status_with_auth_mode(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                    cfg.auth_mode,
                )
            else
                try deps.load_startup_status(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                );
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);
            var mcp_inspection = try cfg.inspect_mcp_local_config(
                alloc,
                startup.workspace_root,
            );
            defer mcp_inspection.deinit(alloc);

            var snapshot = statusSnapshotFromStartupWithBuild(startup, .{
                .channel = cfg.build_channel,
                .version = cfg.version,
                .revision = cfg.revision,
            }, mcp_inspection.profile_diagnostic);
            snapshot.mcp = localMcpView(&mcp_inspection);
            if (opts.format == .json) {
                try writeStatusJsonLine(alloc, deps, snapshot);
                return .handled_success;
            }

            const text = try snapshot.render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .permissions => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .permissions, "permissions", err, rest);
                return .handled_failure;
            };
            var startup = try deps.load_startup_state_without_credentials(alloc, cfg.default_model, cfg.default_agent_step_limit);
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);
            const rules = try permissionRulesForSnapshot(alloc, startup.permission_rules);
            defer if (rules.rules.len > 0) alloc.free(rules.rules);

            const text = try (output_contracts.PermissionsSnapshot{
                .workspace_root = startup.workspace_root,
                .mode = permissionModeForSnapshot(startup.permission_mode),
                .grants = &.{},
                .rules = rules,
                .runtime_grants_available = false,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .mcp => |rest| {
            return runTopLevelMcp(alloc, rest, cfg, deps);
        },
        .models => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .models, "models", err, rest);
                return .handled_failure;
            };

            var startup = if (cfg.auth_mode == .host_managed)
                try deps.load_catalog_startup_state_with_auth_mode(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                    cfg.auth_mode,
                )
            else
                try deps.load_startup_state(
                    alloc,
                    cfg.gateway_provider.oauth_transport,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                );
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            const catalog_access = startup.modelCatalogAccess();
            const catalog_provider = cfg.provider_set.select(startup.provider).cli_model_catalog orelse {
                try writeStderr(deps, switch (startup.provider) {
                    .gateway => "fx models: Gateway model catalog is unavailable\n",
                    .codex => "fx models: Codex model catalog is unavailable\n",
                    .grok => "fx models: Grok model catalog is unavailable\n",
                });
                return .handled_failure;
            };
            const loaded = switch (catalog_provider.fetch(alloc, .{
                .access = catalog_access,
                .endpoint = cfg.models_path,
            })) {
                .loaded => |loaded| loaded,
                .failure => |failure| {
                    const error_name = @errorName(failure.failure.asError());
                    const message = try std.fmt.allocPrint(
                        alloc,
                        "could not list models: {s}",
                        .{catalogFailureDetail(failure.failure)},
                    );
                    defer alloc.free(message);
                    if (opts.format == .json) {
                        try writeJsonCommandFailureCode(
                            alloc,
                            deps,
                            "models",
                            error_name,
                            message,
                        );
                    } else {
                        try writeStderr(deps, "fx models: ");
                        try writeStderr(deps, message);
                        try writeStderr(deps, "\n");
                    }
                    return .handled_failure;
                },
            };
            var ids = loaded.ids;
            defer collections.freeStringList(alloc, &ids);

            const text = try (output_contracts.ModelListSnapshot{
                .ids = ids.items,
                .provider = startup.provider,
                .private_models_hidden = loaded.provenance.access.private_models_may_be_hidden,
                .public_only_reason = loaded.provenance.access.public_only_reason,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .doctor => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .doctor, "doctor", err, rest);
                return .handled_failure;
            };

            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);
            var mcp_inspection = try cfg.inspect_mcp_local_config(
                alloc,
                workspace_root,
            );
            defer mcp_inspection.deinit(alloc);
            var snapshot = try doctor_runtime.collect(
                alloc,
                cfg.secret_store,
                cfg.default_model,
                cfg.default_agent_step_limit,
                mcp_inspection.profile_diagnostic,
            );
            defer snapshot.deinit(alloc);

            var output_snapshot = doctorSnapshotFromRuntime(snapshot);
            output_snapshot.mcp = localMcpView(&mcp_inspection);
            if (opts.format == .json) {
                try writeDoctorJsonLine(alloc, deps, output_snapshot);
                return .handled_success;
            }

            const text = try output_snapshot.render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .session => |rest| {
            if (rest.len > 0 and std.mem.eql(u8, rest[0], "recover")) {
                var recovery = parseSessionRecoveryArgs(
                    alloc,
                    rest[1..],
                ) catch |err| {
                    try writeUsageOrJsonError(
                        alloc,
                        cfg.command_catalog,
                        deps,
                        .session,
                        "session",
                        err,
                        rest[1..],
                    );
                    return .handled_failure;
                };
                defer recovery.deinit(alloc);

                const workspace_root = try io_mod.realpathAlloc(alloc, ".");
                defer alloc.free(workspace_root);
                var store = session_store.Store.init(
                    alloc,
                    workspace_root,
                ) catch |err| {
                    try writeLookupFailure(
                        alloc,
                        deps,
                        "session",
                        err,
                        recovery.format,
                    );
                    return .handled_failure;
                };
                defer store.deinit(alloc);
                var result = store.recoverSessionCopy(
                    alloc,
                    recovery.session_id,
                    .{},
                ) catch |err| {
                    try writeLookupFailure(
                        alloc,
                        deps,
                        "session",
                        err,
                        recovery.format,
                    );
                    return .handled_failure;
                };
                defer result.deinit(alloc);

                const text = try (output_contracts.SessionRecoverySnapshot{
                    .result = result,
                }).render(alloc, recovery.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, recovery.format);
                return if (result.status == .recovered)
                    .handled_success
                else
                    .handled_failure;
            }

            if (rest.len > 0 and std.mem.eql(u8, rest[0], "migrate")) {
                var migration = parseSessionMigrationArgs(alloc, rest[1..]) catch |err| {
                    try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", err, rest[1..]);
                    return .handled_failure;
                };
                defer migration.deinit(alloc);

                const workspace_root = try io_mod.realpathAlloc(alloc, ".");
                defer alloc.free(workspace_root);

                var store = session_store.Store.init(alloc, workspace_root) catch |err| {
                    try writeLookupFailure(alloc, deps, "session", err, migration.format);
                    return .handled_failure;
                };
                defer store.deinit(alloc);
                var result = store.migrateLegacyStorageOnly(
                    alloc,
                    migration.session_id,
                    .{ .allow_large = migration.allow_large },
                ) catch |err| {
                    try writeLookupFailure(alloc, deps, "session", err, migration.format);
                    return .handled_failure;
                };
                defer result.deinit(alloc);

                const text = try (output_contracts.SessionMigrationSnapshot{
                    .result = result,
                }).render(alloc, migration.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, migration.format);
                return .handled_success;
            }

            var opts = parseSessionDetailArgs(alloc, rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", err, rest);
                return .handled_failure;
            };
            defer opts.deinit(alloc);

            const target = opts.target orelse {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", error.InvalidSessionDetailArgs, rest);
                return .handled_failure;
            };

            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);

            var store = session_store.Store.initReadOnly(alloc, workspace_root) catch |err| {
                try writeLookupFailure(alloc, deps, "session", err, opts.format);
                return .handled_failure;
            };
            defer store.deinit(alloc);

            switch (target) {
                .last => {
                    var summary = subagent_resume_admission.latestVisibleWorkspaceSummary(
                        store,
                        alloc,
                    ) catch |err| {
                        try writeLookupFailure(alloc, deps, "session", err, opts.format);
                        return .handled_failure;
                    };
                    defer summary.deinit(alloc);

                    const text = try (output_contracts.SessionSummarySnapshot{
                        .summary = summary,
                    }).render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
                .id => |id| {
                    var detail = subagent_resume_admission.loadVisibleReadOnlyDetail(
                        store,
                        alloc,
                        id,
                        .{},
                    ) catch |err| {
                        try writeSessionDetailFailure(
                            alloc,
                            deps,
                            id,
                            err,
                            opts.format,
                        );
                        return .handled_failure;
                    };
                    defer detail.deinit(alloc);

                    const text = try (output_contracts.SessionDetailSnapshot{
                        .detail = detail,
                    }).render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
            }
        },
        .sessions => |rest| {
            const opts = parseSessionListArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .sessions, "sessions", err, rest);
                return .handled_failure;
            };

            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);

            var store = session_store.Store.initReadOnly(alloc, workspace_root) catch |err| {
                try writeLookupFailure(alloc, deps, "sessions", err, opts.format);
                return .handled_failure;
            };
            defer store.deinit(alloc);

            var page = subagent_resume_admission.listVisiblePage(
                store,
                alloc,
                opts.scope,
                opts.continuation,
                opts.limit,
            ) catch |err| return err;
            defer page.deinit(alloc);
            const next_cursor = if (page.has_more and page.summaries.items.len > 0)
                try formatSessionListCursor(
                    alloc,
                    page.summaries.items[page.summaries.items.len - 1],
                )
            else
                null;
            defer if (next_cursor) |cursor| alloc.free(cursor);

            const text = try (output_contracts.SessionListSnapshot{
                .sessions = page.summaries.items,
                .has_more = page.has_more,
                .next_cursor = next_cursor,
                .skipped_invalid = page.skipped_invalid,
                .all_workspaces = opts.scope == .all_workspaces,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .workspace => |rest| {
            const opts = parseWorkspaceArgs(rest) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            var startup = deps.load_startup_state_without_credentials(
                alloc,
                cfg.default_model,
                cfg.default_agent_step_limit,
            ) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            if (opts.action == null) {
                const snapshot = output_contracts.WorkspaceSnapshot.fromAccess(
                    startup.workspace_root,
                    &startup.workspace_access,
                );
                const text = try snapshot.render(alloc, opts.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, opts.format);
                return .handled_success;
            }

            var failure_phase: workspace_commands.FailurePhase = .stage;
            var result = workspace_commands.execute(
                alloc,
                startup.workspace_root,
                &startup.workspace_access,
                opts.action.?,
                &failure_phase,
            ) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            defer result.deinit(alloc);

            switch (result) {
                .updated => |updated| {
                    var snapshot = output_contracts.WorkspaceSnapshot.fromAccess(startup.workspace_root, &updated.access);
                    snapshot.mutation = updated.mutation;
                    const text = try snapshot.render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
                .indeterminate => |reconciliation| {
                    try writeWorkspaceIndeterminateError(alloc, deps, rest, reconciliation);
                    return .handled_failure;
                },
            }
        },
        .credits => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .credits, "credits", err, rest);
                return .handled_failure;
            };
            var startup = if (cfg.auth_mode == .host_managed)
                try deps.load_startup_state_with_auth_mode(
                    alloc,
                    cfg.gateway_provider.oauth_transport,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                    cfg.auth_mode,
                )
            else
                try deps.load_startup_state(
                    alloc,
                    cfg.gateway_provider.oauth_transport,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                );
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            const credits = cfg.provider_set.select(startup.provider).credits orelse
                gateway_provider.unavailable_credits_provider;
            var snapshot = credits.fetch(alloc, .{
                .credential = startup.apiKey(),
                .credential_source = if (startup.auth_mode == .host_managed)
                    .host_managed
                else if (startup.credential) |credential|
                    credential.source
                else
                    null,
                .tenant = startup.gatewayTeam(),
            });
            defer snapshot.deinit(alloc);
            const text = try snapshot.render(alloc, opts.format);
            defer alloc.free(text);
            if (snapshot.err_message != null) {
                if (opts.format == .json) {
                    try writeFormattedOutput(deps, text, opts.format);
                } else {
                    try writeStderr(deps, text);
                }
                return .handled_failure;
            }
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .usage => |rest| {
            const opts = parseUsageArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .usage, "usage", err, rest);
                return .handled_failure;
            };
            const home = deps.getenv(deps.env_ctx, "HOME") orelse {
                try writeUsageCommandFailure(
                    alloc,
                    deps,
                    error.HomeNotSet,
                    opts.format,
                );
                return .handled_failure;
            };
            var report = usage_cli_runtime.collect(
                alloc,
                home,
                opts.scope,
                @max(io_mod.milliTimestamp(), 0),
            ) catch |err| {
                try writeUsageCommandFailure(alloc, deps, err, opts.format);
                return .handled_failure;
            };
            defer report.deinit(alloc);
            const text = try (output_contracts.UsageSnapshot{
                .report = &report,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .upgrade => |rest| {
            const upgrade_runtime = @import("../upgrade/upgrade_runtime.zig");
            const opts = parseUpgradeArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .upgrade, "upgrade", err, rest);
                return .handled_failure;
            };

            var startup = deps.load_startup_state_without_credentials(
                alloc,
                cfg.default_model,
                cfg.default_agent_step_limit,
            ) catch |err| {
                if (opts.format == .json) {
                    try writeJsonCommandFailure(alloc, deps, "upgrade", err, "failed to load update settings");
                } else {
                    try writeStderr(deps, "fx upgrade: failed to load update settings\n");
                }
                return .handled_failure;
            };
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            const channel = opts.channel orelse startup.update_channel;
            if (opts.channel) |selected| {
                var outcome = config_runtime.setUserPreferences(alloc, .{ .update_channel = selected }) catch |err| {
                    if (opts.format == .json) {
                        try writeJsonCommandFailure(alloc, deps, "upgrade", err, "failed to save update channel");
                    } else {
                        try writeStderr(deps, "fx upgrade: failed to save update channel\n");
                    }
                    return .handled_failure;
                };
                defer outcome.deinit(alloc);
            }

            var result = upgrade_runtime.run(alloc, .{
                .channel = cfg.build_channel,
                .version = cfg.version,
                .revision = cfg.revision,
            }, channel, switch (opts.format) {
                .text => .text,
                .json => .json,
            });
            defer result.deinit(alloc);
            const text = result.snapshot.render(alloc, switch (opts.format) {
                .text => .text,
                .json => .json,
            }) catch {
                try writeStderr(deps, "fx upgrade: render failed\n");
                return .handled_failure;
            };
            defer alloc.free(text);
            try writeStdout(deps, text);
            if (opts.format == .json) try writeStdout(deps, "\n");
            return if (result.snapshot.status == .failed) .handled_failure else .handled_success;
        },
        .replay => |rest| {
            const exit_code = try cli_replay.run(alloc, rest);
            return if (exit_code == 0) .handled_success else .handled_failure;
        },
        .unknown => |command| {
            try writeStderr(deps, "fx: unknown subcommand: ");
            try writeStderr(deps, command);
            try writeStderr(deps, "\n\n");
            try writeTopLevelHelp(alloc, cfg.command_catalog, deps, cfg.version, .stderr);
            return error.UnknownCliCommand;
        },
    }
}

const TopLevelHelpDestination = enum { stdout, stderr };

fn writeTopLevelHelp(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    version: []const u8,
    destination: TopLevelHelpDestination,
) !void {
    const text = try command_specs.renderTopLevelHelp(
        alloc,
        command_catalog,
        command_specs.top_level_help_default_width,
        version,
    );
    defer alloc.free(text);
    switch (destination) {
        .stdout => try writeStdout(deps, text),
        .stderr => try writeStderr(deps, text),
    }
}

fn runGithubWorkflow(
    alloc: Allocator,
    args: []const [:0]const u8,
    cfg: Config,
    launch_modifiers: LaunchModifiers,
    deps: RunDeps,
    workflow: github_workflows.Workflow,
) !RunResult {
    const opts = try parseWorkflowArgs(alloc, args);
    defer opts.deinit(alloc);

    const prompt = switch (workflow) {
        .pull_request => github_workflows.buildPrompt(alloc, workflow, workflowLanguagePlaceholder(), opts.context) catch |err| switch (err) {
            error.NotGitRepository => {
                try writeStderr(deps, "fx pr: requires running inside a git repository\n");
                return .handled_failure;
            },
            else => return err,
        },
        .issue => try github_workflows.buildPrompt(alloc, workflow, workflowLanguagePlaceholder(), opts.context),
    };
    defer alloc.free(prompt);

    const workflow_cfg = workflowConfigWithLaunchModifiers(cfg, launch_modifiers);
    if (!opts.create) {
        const exit_code = try cli_ask.runPrompt(alloc, prompt, opts.auto_permission, workflow_cfg, cfg.context_registry, cfg.tool_set);
        return if (exit_code == 0) .handled_success else .handled_failure;
    }

    const run_result = try cli_ask.runPromptCapture(alloc, prompt, opts.auto_permission, workflow_cfg, cfg.context_registry, cfg.tool_set);
    defer run_result.deinit(alloc);
    if (run_result.exit_code != 0) return .handled_failure;

    const draft = github_publish.parseDraft(alloc, run_result.assistant_output) catch {
        try writeStderr(deps, switch (workflow) {
            .pull_request => "fx pr: failed to parse drafted PR title/body\n",
            .issue => "fx issue: failed to parse drafted issue title/body\n",
        });
        return .handled_failure;
    };
    defer draft.deinit(alloc);

    const published = try github_publish.publish(alloc, switch (workflow) {
        .pull_request => .pull_request,
        .issue => .issue,
    }, draft);
    defer published.deinit(alloc);
    if (!published.ok) {
        try writeStderr(deps, switch (workflow) {
            .pull_request => "fx pr: ",
            .issue => "fx issue: ",
        });
        try writeStderr(deps, published.text);
        try writeStderr(deps, "\n");
        return .handled_failure;
    }
    try writeStdout(deps, published.text);
    try writeStdout(deps, "\n");
    return .handled_success;
}

fn writeStdout(deps: RunDeps, text: []const u8) !void {
    try deps.write_stdout(deps.stdout_ctx, text);
}

fn writeStderr(deps: RunDeps, text: []const u8) !void {
    try deps.write_stderr(deps.stderr_ctx, text);
}

fn runPasteSetup(
    alloc: Allocator,
    secret_store: host.SecretStore,
    deps: RunDeps,
) !bool {
    if (secret_store.isDisabled()) {
        try writeStderr(deps, "fx setup: stored API keys are disabled by FX_DISABLE_KEYCHAIN\n");
        return false;
    }
    if (!deps.setup_terminal_available(deps.setup_ctx)) {
        try writeStderr(deps, "fx setup: an interactive terminal is required to paste an API key\n");
        return false;
    }

    try writeStderr(deps, "Paste AI Gateway API key (input hidden): ");
    const stored_interactively = secret_store.storeInteractive() catch {
        try writeStderr(deps, "\nfx setup: API key was not saved\n");
        return false;
    };
    if (!stored_interactively) {
        const key = deps.read_masked_key(
            deps.setup_ctx,
            alloc,
            deps.write_stderr,
            deps.stderr_ctx,
        ) catch {
            try writeStderr(deps, "\nfx setup: API key was not saved\n");
            return false;
        };
        defer secret.zeroAndFree(alloc, key);
        try writeStderr(deps, "\n");
        secret_store.store(alloc, key) catch {
            try writeStderr(deps, "fx setup: API key was not saved\n");
            return false;
        };
    }

    const message = try std.fmt.allocPrint(
        alloc,
        "Saved API key to {s}.\n",
        .{secret_store.backend_label},
    );
    defer alloc.free(message);
    try writeStdout(deps, message);
    return true;
}

fn setupTerminalAvailableDefault(_: ?*anyopaque) bool {
    return std.c.isatty(std.posix.STDIN_FILENO) != 0 and
        std.c.isatty(std.posix.STDERR_FILENO) != 0;
}

fn readMaskedKeyDefault(
    _: ?*anyopaque,
    alloc: Allocator,
    write_mask: WriteFn,
    write_ctx: ?*anyopaque,
) ![]u8 {
    var raw = try MaskedKeyRawMode.enable();
    defer raw.disable();

    var input: std.ArrayList(u8) = .empty;
    errdefer {
        if (input.capacity > 0) secret.zeroAndFree(alloc, input.allocatedSlice());
    }

    while (input.items.len < 8 * 1024) {
        var byte: [1]u8 = undefined;
        if (try std.posix.read(std.posix.STDIN_FILENO, &byte) == 0) return error.SetupCancelled;
        switch (byte[0]) {
            '\r', '\n' => {
                if (input.items.len == 0) continue;
                // toOwnedSlice shrinks through realloc, which may move the buffer
                // and free the original without zeroing it. Copy out and wipe the
                // source so no unzeroed key is left behind in freed memory.
                const owned = try alloc.dupe(u8, input.items);
                secret.zeroAndFree(alloc, input.allocatedSlice());
                input = .empty;
                return owned;
            },
            3, 4, 0x1b => return error.SetupCancelled,
            8, 127 => if (input.items.len > 0) {
                _ = input.pop();
                try write_mask(write_ctx, "\x08 \x08");
            },
            0x20...0x7e => {
                try input.append(alloc, byte[0]);
                try write_mask(write_ctx, "•");
            },
            else => {},
        }
    }
    return error.SetupKeyTooLong;
}

const MaskedKeyRawMode = struct {
    original: std.posix.termios = undefined,
    active: bool = false,

    fn enable() !MaskedKeyRawMode {
        if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or
            std.c.isatty(std.posix.STDERR_FILENO) == 0)
        {
            return error.NotATerminal;
        }

        var self: MaskedKeyRawMode = .{};
        self.original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = self.original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.iflag.IXOFF = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        const vmin_idx = switch (builtin.os.tag) {
            .linux => 6,
            else => 16,
        };
        const vtime_idx = switch (builtin.os.tag) {
            .linux => 5,
            else => 17,
        };
        if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
            raw.cc[vmin_idx] = 1;
            raw.cc[vtime_idx] = 0;
        }
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        self.active = true;
        return self;
    }

    fn disable(self: *MaskedKeyRawMode) void {
        if (!self.active) return;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

fn writeConfigDiagnostics(
    alloc: Allocator,
    deps: RunDeps,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        if (!diagnostic.reportAtStartup()) continue;
        var notice_writer: std.Io.Writer.Allocating = .init(alloc);
        defer notice_writer.deinit();
        try notice_writer.writer.print(
            "fx: config {s}: {s}",
            .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
        );
        try config_runtime.writeDiagnosticMetadata(&notice_writer.writer, diagnostic);
        try notice_writer.writer.writeByte('\n');
        const notice = try notice_writer.toOwnedSlice();
        defer alloc.free(notice);
        try writeStderr(deps, notice);
    }
}

fn writeFormattedOutput(deps: RunDeps, text: []const u8, format: output_contracts.OutputFormat) !void {
    switch (format) {
        .text => try writeStdout(deps, text),
        .json => try writeJsonLine(deps, text),
    }
}

fn writeJsonLine(deps: RunDeps, text: []const u8) !void {
    @setRuntimeSafety(false);
    var buf: [4096]u8 = undefined;
    if (text.len < buf.len) {
        @memcpy(buf[0..text.len], text);
        buf[text.len] = '\n';
        return writeStdout(deps, buf[0 .. text.len + 1]);
    }

    try writeStdout(deps, text);
    try writeStdout(deps, "\n");
}

const JsonLinePayload = union(enum) {
    status: output_contracts.StatusSnapshot,
    doctor: output_contracts.DoctorSnapshot,
};

fn writeRenderedJsonLine(alloc: Allocator, deps: RunDeps, fixed_buffer: []u8, payload: JsonLinePayload) !void {
    var writer: std.Io.Writer = .fixed(fixed_buffer);
    renderJsonLinePayload(&writer, payload) catch |err| switch (err) {
        error.WriteFailed => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try renderJsonLinePayload(&out.writer, payload);
            return writeJsonLine(deps, out.writer.buffered());
        },
    };
    try writeJsonLine(deps, writer.buffered());
}

fn renderJsonLinePayload(writer: *std.Io.Writer, payload: JsonLinePayload) std.Io.Writer.Error!void {
    switch (payload) {
        .status => |snapshot| try snapshot.writeJson(writer),
        .doctor => |snapshot| try snapshot.writeJson(writer),
    }
}

fn writeStatusJsonLine(alloc: Allocator, deps: RunDeps, snapshot: output_contracts.StatusSnapshot) !void {
    var buf: [1024]u8 = undefined;
    try writeRenderedJsonLine(alloc, deps, buf[0..], .{ .status = snapshot });
}

fn statusSnapshotFromStartup(startup: app_lifecycle.StartupStatus) output_contracts.StatusSnapshot {
    return statusSnapshotFromStartupWithBuild(startup, .{
        .channel = .stable,
        .version = "",
        .revision = "",
    }, .clear);
}

fn statusSnapshotFromStartupWithBuild(
    startup: app_lifecycle.StartupStatus,
    build: update_target.CurrentBuild,
    mcp_config_diagnostic: mcp_contract.ProfileConfigDiagnostic,
) output_contracts.StatusSnapshot {
    return .{
        .model = startup.selected_model,
        .provider = startup.provider,
        .auth = startup.auth,
        .auth_help = startup.auth.missingHelp(.cli),
        .permission_mode = permissionModeForSnapshot(startup.permission_mode),
        .workspace_root = startup.workspace_root,
        .history_turns = 0,
        .session_permission_grants = 0,
        .agent_step_limit = startup.agent_step_limit,
        .update_channel = startup.update_channel.label(),
        .build_channel = build.channel.label(),
        .build_revision = build.revision,
        .mcp_config_error = switch (mcp_config_diagnostic) {
            .clear, .warning => null,
            .failed => |err| @errorName(err),
        },
        .mcp_config_warning = switch (mcp_config_diagnostic) {
            .warning => |warning| warning,
            .clear, .failed => null,
        },
    };
}

fn writeDoctorJsonLine(alloc: Allocator, deps: RunDeps, snapshot: output_contracts.DoctorSnapshot) !void {
    var buf: [4096]u8 = undefined;
    try writeRenderedJsonLine(alloc, deps, buf[0..], .{ .doctor = snapshot });
}

fn doctorSnapshotFromRuntime(snapshot: doctor_runtime.Snapshot) output_contracts.DoctorSnapshot {
    return .{
        .workspace_root = snapshot.workspace_root,
        .model = snapshot.model,
        .provider = snapshot.provider,
        .auth = snapshot.auth,
        .permission_mode = permissionModeForSnapshot(snapshot.permission_mode),
        .agent_step_limit = snapshot.agent_step_limit,
        .checks = snapshot.checks,
    };
}

fn writeRealStdout(_: ?*anyopaque, text: []const u8) !void {
    if (comptime builtin.os.tag != .windows) {
        return writeFdAll(std.posix.STDOUT_FILENO, text);
    }
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeRealStderr(_: ?*anyopaque, text: []const u8) !void {
    if (comptime builtin.os.tag != .windows) {
        return writeFdAll(std.posix.STDERR_FILENO, text);
    }
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

fn writeFdAll(fd: std.posix.fd_t, text: []const u8) !void {
    @setRuntimeSafety(false);
    var remaining = text;
    while (remaining.len > 0) {
        const written = std.c.write(fd, remaining.ptr, remaining.len);
        if (written <= 0) return error.WriteFailed;
        remaining = remaining[@intCast(written)..];
    }
}

fn getenvDefault(_: ?*anyopaque, key: []const u8) ?[]const u8 {
    return io_mod.getenv(key);
}

fn environMapDefault(_: ?*anyopaque) ?*const std.process.Environ.Map {
    return io_mod.environMap();
}

fn selfExePathDefault(_: ?*anyopaque, alloc: Allocator) ![]u8 {
    const path_z = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(path_z);
    return alloc.dupe(u8, path_z);
}

fn writeTopLevelUsage(command_catalog: CommandCatalog, deps: RunDeps, kind: TopLevelKind) !void {
    try writeStderr(deps, "usage: fx ");
    try writeStderr(deps, command_specs.topLevelUsage(command_catalog, kind));
    try writeStderr(deps, "\n");
}

const McpCommandRuntime = struct {
    startup: app_lifecycle.StartupState,
    runtime: ?*mcp_runtime.McpRuntime,

    fn deinit(self: *McpCommandRuntime, alloc: Allocator) void {
        if (self.runtime) |runtime| {
            runtime.deinit();
            alloc.destroy(runtime);
        }
        self.startup.deinit(alloc);
        self.* = undefined;
    }
};

fn localMcpView(
    inspection: *const mcp_health.LocalConfigInspection,
) output_contracts.McpLocalSnapshot {
    return .{
        .servers = inspection.snapshot.servers,
        .configuration_issues = inspection.snapshot.configuration_issues,
        .inspection_error = inspection.inspection_error,
    };
}

fn loadMcpCommandRuntime(
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
) !McpCommandRuntime {
    var startup = try deps.load_startup_state_without_credentials(
        alloc,
        cfg.default_model,
        cfg.default_agent_step_limit,
    );
    errdefer startup.deinit(alloc);
    const runtime = try cfg.load_mcp_runtime(
        alloc,
        startup.workspace_root,
        .{ .form = true, .url = true },
    );
    return .{ .startup = startup, .runtime = runtime };
}

fn runTopLevelMcp(
    alloc: Allocator,
    rest: []const [:0]const u8,
    cfg: Config,
    deps: RunDeps,
) !RunResult {
    if (rest.len == 0) {
        try writeTopLevelUsage(cfg.command_catalog, deps, .mcp);
        return .handled_failure;
    }
    const operation = rest[0];
    if (std.mem.eql(u8, operation, "add")) {
        var tokens: std.ArrayList([]const u8) = .empty;
        defer tokens.deinit(alloc);
        try tokens.ensureTotalCapacity(alloc, rest.len - 1);
        for (rest[1..]) |token| tokens.appendAssumeCapacity(token);
        const intent = mcp_command_provider.parseAddIntent(tokens.items) catch |err| {
            if (err == error.McpAddUsage) {
                try writeMcpAddUsage(deps);
            } else {
                try writeMcpOperationFailure(alloc, deps, "add", err);
            }
            return .handled_failure;
        };
        var result = cfg.add_mcp_profile_server(alloc, intent) catch |err| {
            try writeMcpOperationFailure(alloc, deps, "add", err);
            return .handled_failure;
        };
        defer result.deinit(alloc);
        if (result.warning) |warning| try writeMcpProfileWarning(alloc, deps, warning);
        const name = switch (intent) {
            .local => |local| local.name,
            .http => |http| http.name,
        };
        try writeMcpProfileMutationSuccess(
            alloc,
            deps,
            "Saved",
            "to",
            name,
            result.profile_path,
        );
        return .handled_success;
    }
    if (std.mem.eql(u8, operation, "trust")) {
        const action = parseTopLevelProjectMcpAction(rest[1..]) catch {
            try writeTopLevelUsage(cfg.command_catalog, deps, .mcp);
            return .handled_failure;
        };
        const workspace_root = io_mod.realpathAlloc(alloc, ".") catch |err| {
            try writeMcpOperationFailure(alloc, deps, "trust", err);
            return .handled_failure;
        };
        defer alloc.free(workspace_root);
        var attempt = config_runtime.attemptProjectMcpMutation(
            alloc,
            workspace_root,
            action,
        );
        defer attempt.deinit(alloc);
        switch (attempt) {
            .failure => |failure| {
                try writeMcpOperationFailure(alloc, deps, "trust", failure.err);
                return .handled_failure;
            },
            .outcome => {},
        }
        try writeMcpTrustSuccess(alloc, deps, workspace_root, action);
        return .handled_success;
    }
    if (std.mem.eql(u8, operation, "path")) {
        if (rest.len != 1) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .mcp);
            return .handled_failure;
        }
        const home = deps.getenv(deps.env_ctx, "HOME") orelse {
            try writeMcpOperationFailure(alloc, deps, "path", error.HomeNotSet);
            return .handled_failure;
        };
        const path = try profile_paths.mcpConfigPath(alloc, home);
        defer alloc.free(path);
        var encoded_path = try text_utils.encodeTerminalSafe(alloc, path, 512);
        defer encoded_path.deinit(alloc);
        try writeStdout(deps, encoded_path.bytes);
        try writeStdout(deps, "\n");
        return .handled_success;
    }
    if (std.mem.eql(u8, operation, "remove")) {
        if (rest.len != 2 or rest[1].len == 0) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .mcp);
            return .handled_failure;
        }
        var result = cfg.remove_mcp_profile_server(alloc, rest[1]) catch |err| {
            try writeMcpOperationFailure(alloc, deps, "remove", err);
            return .handled_failure;
        };
        defer result.deinit(alloc);
        if (result.warning) |warning| try writeMcpProfileWarning(alloc, deps, warning);
        if (!result.removed) {
            var encoded_name = try text_utils.encodeTerminalSafe(alloc, rest[1], 160);
            defer encoded_name.deinit(alloc);
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try out.writer.print(
                "MCP server '{s}' was not found in the profile.\n",
                .{encoded_name.bytes},
            );
            try writeStderr(deps, out.written());
            return .handled_failure;
        }
        try writeMcpProfileMutationSuccess(
            alloc,
            deps,
            "Removed",
            "from",
            rest[1],
            result.profile_path,
        );
        return .handled_success;
    }
    if (std.mem.eql(u8, operation, "list")) {
        const connect = rest.len == 2 and std.mem.eql(u8, rest[1], "--connect");
        if (rest.len != 1 and !connect) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .mcp);
            return .handled_failure;
        }
        var loaded = loadMcpCommandRuntime(alloc, cfg, deps) catch |err| {
            try writeMcpOperationFailure(alloc, deps, "list", err);
            return .handled_failure;
        };
        defer loaded.deinit(alloc);
        try writeConfigDiagnostics(alloc, deps, loaded.startup.config_diagnostics);
        const listing = if (loaded.runtime) |runtime| listing: {
            if (connect) {
                runtime.connectAll(cfg.tool_set.registry);
            } else {
                try runtime.loadStoredCredentialsForHealthSnapshot();
            }
            break :listing try runtime.listServersAndTools(alloc);
        } else try alloc.dupe(u8, "No MCP servers configured.\n");
        defer alloc.free(listing);
        try writeStdout(deps, listing);
        return .handled_success;
    }
    if (std.mem.eql(u8, operation, "auth")) {
        if (rest.len != 2 or rest[1].len == 0) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .mcp);
            return .handled_failure;
        }
        var loaded = loadMcpCommandRuntime(alloc, cfg, deps) catch |err| {
            try writeMcpOperationFailure(alloc, deps, "auth", err);
            return .handled_failure;
        };
        defer loaded.deinit(alloc);
        try writeConfigDiagnostics(alloc, deps, loaded.startup.config_diagnostics);
        const runtime = loaded.runtime orelse {
            try writeMcpOperationFailure(alloc, deps, "auth", error.McpServerNotFound);
            return .handled_failure;
        };
        var opener = cfg.url_opener;
        var result = runtime.authenticateServer(
            rest[1],
            &opener,
            openTopLevelMcpUrl,
        ) catch |err| {
            try writeMcpOperationFailure(alloc, deps, "auth", err);
            return .handled_failure;
        };
        defer result.deinit();
        switch (result) {
            .authenticated => |authenticated| {
                var encoded_name = try text_utils.encodeTerminalSafe(alloc, rest[1], 160);
                defer encoded_name.deinit(alloc);
                var out: std.Io.Writer.Allocating = .init(alloc);
                defer out.deinit();
                try out.writer.print("Authenticated MCP server '{s}'.", .{encoded_name.bytes});
                if (authenticated.repaired_entries > 0) {
                    try out.writer.print(
                        " Removed {d} unreadable MCP credential {s}.",
                        .{
                            authenticated.repaired_entries,
                            if (authenticated.repaired_entries == 1) "entry" else "entries",
                        },
                    );
                }
                try out.writer.writeByte('\n');
                try writeStdout(deps, out.written());
                return .handled_success;
            },
            .issuer_mismatch => {
                try writeMcpOperationFailure(
                    alloc,
                    deps,
                    "auth",
                    error.McpAuthorizationIssuerMismatch,
                );
                return .handled_failure;
            },
        }
    }
    if (std.mem.eql(u8, operation, "logout")) {
        if (rest.len != 2 or rest[1].len == 0) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .mcp);
            return .handled_failure;
        }
        var loaded = loadMcpCommandRuntime(alloc, cfg, deps) catch |err| {
            try writeMcpOperationFailure(alloc, deps, "logout", err);
            return .handled_failure;
        };
        defer loaded.deinit(alloc);
        try writeConfigDiagnostics(alloc, deps, loaded.startup.config_diagnostics);
        const runtime = loaded.runtime orelse {
            try writeMcpOperationFailure(alloc, deps, "logout", error.McpServerNotFound);
            return .handled_failure;
        };
        const result = runtime.logoutServer(rest[1]) catch |err| {
            try writeMcpOperationFailure(alloc, deps, "logout", err);
            return .handled_failure;
        };
        var encoded_name = try text_utils.encodeTerminalSafe(alloc, rest[1], 160);
        defer encoded_name.deinit(alloc);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        if (!result.removed) {
            try out.writer.print(
                "No stored MCP credentials found for '{s}'.\n",
                .{encoded_name.bytes},
            );
        } else if (result.local_only) {
            try out.writer.print(
                "Logged out of MCP server '{s}' locally.\n",
                .{encoded_name.bytes},
            );
        } else if (result.revocation_failed) {
            try out.writer.print(
                "Logged out of MCP server '{s}' locally; remote revocation failed.\n",
                .{encoded_name.bytes},
            );
        } else {
            try out.writer.print(
                "Logged out of MCP server '{s}'.\n",
                .{encoded_name.bytes},
            );
        }
        try writeStdout(deps, out.written());
        return .handled_success;
    }

    try writeTopLevelUsage(cfg.command_catalog, deps, .mcp);
    return .handled_failure;
}

fn parseTopLevelProjectMcpAction(
    args: []const [:0]const u8,
) error{InvalidProjectMcpTrustArgs}!project_config.ProjectMcpAction {
    if (args.len == 1 and std.mem.eql(u8, args[0], "approve-all")) return .approve_all;
    if (args.len == 1 and std.mem.eql(u8, args[0], "reset")) return .reset;
    if (args.len != 2 or args[1].len == 0) return error.InvalidProjectMcpTrustArgs;
    if (std.mem.eql(u8, args[0], "approve")) return .{ .approve = args[1] };
    if (std.mem.eql(u8, args[0], "reject")) return .{ .reject = args[1] };
    return error.InvalidProjectMcpTrustArgs;
}

fn writeMcpTrustSuccess(
    alloc: Allocator,
    deps: RunDeps,
    workspace_root: []const u8,
    action: project_config.ProjectMcpAction,
) !void {
    var encoded_root = try text_utils.encodeTerminalSafe(alloc, workspace_root, 512);
    defer encoded_root.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    switch (action) {
        .approve => |name| {
            var encoded_name = try text_utils.encodeTerminalSafe(alloc, name, 160);
            defer encoded_name.deinit(alloc);
            try out.writer.print(
                "Approved project MCP server '{s}' for {s}.\n",
                .{ encoded_name.bytes, encoded_root.bytes },
            );
        },
        .reject => |name| {
            var encoded_name = try text_utils.encodeTerminalSafe(alloc, name, 160);
            defer encoded_name.deinit(alloc);
            try out.writer.print(
                "Rejected project MCP server '{s}' for {s}.\n",
                .{ encoded_name.bytes, encoded_root.bytes },
            );
        },
        .approve_all => try out.writer.print(
            "Approved all project MCP servers for {s}.\n",
            .{encoded_root.bytes},
        ),
        .reset => try out.writer.print(
            "Reset project MCP trust for {s}.\n",
            .{encoded_root.bytes},
        ),
    }
    try writeStdout(deps, out.written());
}

fn openTopLevelMcpUrl(
    raw: ?*anyopaque,
    alloc: Allocator,
    url: []const u8,
) anyerror!bool {
    const opener: *const host.UrlOpener = @ptrCast(@alignCast(raw.?));
    return opener.open(alloc, url);
}

fn writeMcpProfileMutationSuccess(
    alloc: Allocator,
    deps: RunDeps,
    action: []const u8,
    preposition: []const u8,
    name: []const u8,
    path: []const u8,
) !void {
    var encoded_name = try text_utils.encodeTerminalSafe(alloc, name, 160);
    defer encoded_name.deinit(alloc);
    var encoded_path = try text_utils.encodeTerminalSafe(alloc, path, 512);
    defer encoded_path.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "{s} MCP server '{s}' {s} {s}.\n",
        .{ action, encoded_name.bytes, preposition, encoded_path.bytes },
    );
    try writeStdout(deps, out.written());
}

fn writeMcpAddUsage(deps: RunDeps) !void {
    return writeStderr(
        deps,
        "usage: fx mcp add NAME COMMAND [ARGS...] | fx mcp add --transport http NAME URL\n",
    );
}

fn writeMcpOperationFailure(
    alloc: Allocator,
    deps: RunDeps,
    operation: []const u8,
    err: anyerror,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "fx mcp {s} failed: {s}.\n",
        .{ operation, @errorName(err) },
    );
    try writeStderr(deps, out.written());
}

fn writeMcpProfileWarningIfPresent(
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
) !void {
    const diagnostic = try cfg.inspect_mcp_profile_config(alloc);
    const warning = switch (diagnostic) {
        .warning => |value| value,
        .clear, .failed => return,
    };
    try writeMcpProfileWarning(alloc, deps, warning);
}

fn writeMcpProfileWarning(
    alloc: Allocator,
    deps: RunDeps,
    warning: mcp_contract.ProfileConfigWarning,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "fx: ~/.fx/mcp.json warning: {s}",
        .{@tagName(warning.cause)},
    );
    if (warning.key()) |key| {
        var encoded = try text_utils.encodeTerminalSafe(alloc, key, 128);
        defer encoded.deinit(alloc);
        try out.writer.print(" key={s}", .{encoded.bytes});
    }
    try out.writer.print(
        " additional_matches={d}\n",
        .{warning.additional_matches},
    );
    try writeStderr(deps, out.written());
}

fn writeUsageOrJsonError(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    usage_kind: TopLevelKind,
    output_kind: []const u8,
    err: anyerror,
    args: anytype,
) !void {
    if (argsContainJson(args)) {
        try writeCommandFailure(alloc, deps, output_kind, err, .json);
    } else {
        try writeTopLevelUsage(command_catalog, deps, usage_kind);
    }
}

fn writeUsageCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    const message = usageFailureMessage(err);
    if (format == .json) {
        return writeJsonCommandFailure(
            alloc,
            deps,
            "usage",
            err,
            message,
        );
    }
    try writeStderr(deps, "fx usage: ");
    try writeStderr(deps, message);
    try writeStderr(deps, "\n");
}

fn usageFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.HomeNotSet => "HOME is not set",
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => "local usage storage is unsafe",
        else => "local usage data is unavailable",
    };
}

fn writeWorkspaceCommandError(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    args: []const [:0]const u8,
    err: anyerror,
) !void {
    if (!argsContainJson(args)) {
        if (output_contracts.workspaceErrorMessage(err)) |message| {
            try writeStderr(deps, "fx workspace: ");
            try writeStderr(deps, message);
            try writeStderr(deps, "\n");
            return;
        }
        try writeTopLevelUsage(command_catalog, deps, .workspace);
        return;
    }

    const message = output_contracts.workspaceErrorMessage(err) orelse "invalid arguments";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"workspace\",\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll(",\"code\":");
    try std.json.Stringify.value(@errorName(err), .{}, &out.writer);
    try out.writer.writeByte('}');
    try writeJsonLine(deps, out.writer.buffered());
}

fn writeWorkspaceIndeterminateError(
    alloc: Allocator,
    deps: RunDeps,
    args: []const [:0]const u8,
    reconciliation: workspace_commands.Reconciliation,
) !void {
    const message = switch (reconciliation) {
        .intended => "settings durability is uncertain; reloaded settings match the requested update",
        .previous => "settings durability is uncertain; reloaded settings match the previous state, so the update was not applied",
        .unconfirmed => "settings durability is uncertain; reloaded settings match neither the requested nor previous state",
    };
    if (!argsContainJson(args)) {
        try writeStderr(deps, "fx workspace: ");
        try writeStderr(deps, message);
        try writeStderr(deps, "\n");
        return;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"workspace\",\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll(",\"code\":\"SettingsCommitIndeterminate\"}");
    try writeJsonLine(deps, out.writer.buffered());
}

fn argsContainJson(args: anytype) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn workflowLanguagePlaceholder() types.ConversationLanguage {
    return types.ConversationLanguage.default();
}

fn permissionModeForSnapshot(mode: anytype) types.PermissionMode {
    return switch (mode) {
        .ask => .ask,
        .auto => .auto,
        .yolo => .yolo,
    };
}

fn permissionModeLabel(mode: anytype) []const u8 {
    return switch (mode) {
        .ask => "ask",
        .auto => "auto",
        .yolo => "yolo",
    };
}

fn permissionRulesForSnapshot(alloc: Allocator, active_rules: anytype) !types.PermissionRuleSet {
    if (active_rules.rules.len == 0) return .{};
    const rules = try alloc.alloc(types.PermissionRule, active_rules.rules.len);
    for (active_rules.rules, 0..) |rule, i| {
        rules[i] = .{
            .permission = rule.permission,
            .pattern = rule.pattern,
            .action = switch (rule.action) {
                .allow => .allow,
                .ask => .ask,
                .deny => .deny,
            },
        };
    }
    return .{ .rules = rules };
}

fn loadLatestWorkspaceSessionDetail(
    alloc: Allocator,
    store: session_store.Store,
) !session_store.ReadOnlyDetail {
    var summary = try store.latestReadOnlyWorkspaceSummary(alloc);
    defer summary.deinit(alloc);
    return store.loadReadOnlyDetail(alloc, summary.id, .{});
}

fn loadLatestWorkspaceSessionSummary(
    alloc: Allocator,
    store: session_store.Store,
) !session_store.SessionSummary {
    return store.latestReadOnlyWorkspaceSummary(alloc);
}

fn catalogFailureDetail(failure: model_catalog.Failure) []const u8 {
    return switch (failure.category) {
        .authentication => "AuthenticationRejected",
        .cancellation => "the request was cancelled",
        .malformed_response => "MalformedResponse",
        .resource_exhausted => "OutOfMemory",
        .rate_limited, .gateway_unavailable, .transport, .http_status, .runtime => "Unavailable",
    };
}

fn writeCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    if (format != .json) return err;
    const message = commandFailureMessage(err) orelse return err;
    return writeJsonCommandFailure(alloc, deps, kind, err, message);
}

fn writeJsonCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    message: []const u8,
) !void {
    return writeJsonCommandFailureCode(
        alloc,
        deps,
        kind,
        @errorName(err),
        message,
    );
}

fn writeJsonCommandFailureCode(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    code: []const u8,
    message: []const u8,
) !void {
    const json = try (output_contracts.CommandFailureSnapshot{
        .kind = kind,
        .message = message,
        .code = code,
    }).renderJson(alloc);
    defer alloc.free(json);
    try writeJsonLine(deps, json);
}

fn writeLookupFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    if (format == .json) {
        return writeCommandFailure(alloc, deps, kind, err, format);
    }

    switch (err) {
        error.NoSavedSessions => {
            try writeStderr(deps, "fx session: no saved sessions for this workspace\n");
        },
        error.NoReadableSessions => {
            try writeStderr(deps, "fx session: saved sessions are unreadable; run `fx doctor` for recovery guidance\n");
        },
        error.SessionNotFound => {
            try writeStderr(deps, "fx session: record not found\n");
        },
        error.InvalidSessionFormat => {
            try writeStderr(
                deps,
                "fx session: record is corrupt; run `fx doctor` for recovery guidance\n",
            );
        },
        error.UnsupportedSessionSchema => {
            try writeStderr(
                deps,
                "fx session: record uses an unsupported session version\n",
            );
        },
        error.InvalidSessionId => {
            try writeStderr(deps, "fx session: invalid session id\n");
        },
        error.LegacySessionTooLarge => {
            try writeStderr(
                deps,
                "fx session: legacy session is too large for automatic loading; run `fx session migrate <id> --allow-large`\n",
            );
        },
        error.LegacySessionReadResourceExhausted => {
            try writeStderr(
                deps,
                "fx session: legacy session could not be loaded with available resources\n",
            );
        },
        error.LegacySessionMigrationResourceExhausted => {
            try writeStderr(
                deps,
                "fx session: migration did not complete because resources were exhausted; the original session remains authoritative\n",
            );
        },
        error.LegacySessionMigrationFailed, error.LegacySessionChanged => {
            try writeStderr(
                deps,
                "fx session: migration did not complete; the original session remains authoritative\n",
            );
        },
        error.LegacySessionMigrationIndeterminate => {
            try writeStderr(
                deps,
                "fx session: migration outcome is indeterminate and will be resolved by the next exact writable load\n",
            );
        },
        error.SessionRecoveryNotNeeded => {
            try writeStderr(
                deps,
                "fx session: recovery was refused because the session has a valid commit boundary; resume it normally\n",
            );
        },
        error.SessionRecoveryRequiresCurrentSchema => {
            try writeStderr(
                deps,
                "fx session: recovery only applies to current schema-v3 sessions; migrate legacy sessions first\n",
            );
        },
        error.SessionRecoveryUnsupportedSchema => {
            try writeStderr(
                deps,
                "fx session: recovery is unavailable for this unsupported session version\n",
            );
        },
        error.SessionRecoveryBoundaryInvalid => {
            try writeStderr(
                deps,
                "fx session: no exact trustworthy recovery boundary was found; the source was left unchanged\n",
            );
        },
        error.SessionRecoveryIndeterminate => {
            try writeStderr(
                deps,
                "fx session: the recovery copy could not be confirmed; the source was left unchanged\n",
            );
        },
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => {
            try writeStderr(
                deps,
                "fx session: session authority is temporarily unavailable while an incomplete commit is resolved\n",
            );
        },
        error.SessionAuthorityIntentCleanupPending => {
            try writeStderr(
                deps,
                "fx session: session authority is confirmed but transition cleanup is still pending\n",
            );
        },
        error.SessionBusy, error.SessionLockUnsupported => {
            try writeStderr(
                deps,
                "fx session: session is busy or the filesystem cannot provide the required lock\n",
            );
        },
        error.SessionPathUnsafe,
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => {
            try writeStderr(
                deps,
                "fx session: durable session storage is unsafe or does not support required private permissions\n",
            );
        },
        error.DurableLayoutFailed, error.SessionStoreUnavailable => {
            try writeStderr(deps, "fx session: durable session store is unavailable\n");
        },
        error.HomeNotSet => {
            try writeStderr(deps, "fx ");
            try writeStderr(deps, kind);
            try writeStderr(deps, ": HOME is not set\n");
        },
        else => return err,
    }
}

fn writeSessionDetailFailure(
    alloc: Allocator,
    deps: RunDeps,
    session_id: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    const message = switch (err) {
        error.InvalidSessionFormat => try std.fmt.allocPrint(
            alloc,
            "session {s} is corrupt; run `fx session recover {s}`",
            .{ session_id, session_id },
        ),
        error.UnsupportedSessionSchema => try std.fmt.allocPrint(
            alloc,
            "session {s} uses an unsupported session version",
            .{session_id},
        ),
        else => return writeLookupFailure(
            alloc,
            deps,
            "session",
            err,
            format,
        ),
    };
    defer alloc.free(message);
    if (format == .json) {
        return writeJsonCommandFailure(
            alloc,
            deps,
            "session",
            err,
            message,
        );
    }
    try writeStderr(deps, "fx session: ");
    try writeStderr(deps, message);
    try writeStderr(deps, "\n");
}

fn commandFailureMessage(err: anyerror) ?[]const u8 {
    if (lookupFailureMessage(err)) |message| return message;
    return switch (err) {
        error.InvalidLocalSurfaceArgs,
        error.InvalidUsageArgs,
        error.InvalidSessionDetailArgs,
        error.InvalidSessionMigrationArgs,
        error.InvalidSessionRecoveryArgs,
        error.InvalidResumeArgs,
        => "invalid arguments",
        else => null,
    };
}

fn lookupFailureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoSavedSessions => "no saved sessions for this workspace",
        error.NoReadableSessions => "saved sessions are unreadable; run `fx doctor` for recovery guidance",
        error.SessionNotFound => "record not found",
        error.InvalidSessionFormat => "record is corrupt; run `fx doctor` for recovery guidance",
        error.UnsupportedSessionSchema => "record uses an unsupported session version",
        error.InvalidSessionId => "invalid session id",
        error.LegacySessionTooLarge => "legacy session is too large for automatic loading; run `fx session migrate <id> --allow-large`",
        error.LegacySessionReadResourceExhausted => "legacy session could not be loaded with available resources",
        error.LegacySessionMigrationResourceExhausted => "migration did not complete because resources were exhausted; the original session remains authoritative",
        error.LegacySessionMigrationFailed, error.LegacySessionChanged => "migration did not complete; the original session remains authoritative",
        error.LegacySessionMigrationIndeterminate => "migration outcome is indeterminate and will be resolved by the next exact writable load",
        error.SessionRecoveryNotNeeded => "recovery was refused because the session has a valid commit boundary; resume it normally",
        error.SessionRecoveryRequiresCurrentSchema => "recovery only applies to current schema-v3 sessions; migrate legacy sessions first",
        error.SessionRecoveryUnsupportedSchema => "recovery is unavailable for this unsupported session version",
        error.SessionRecoveryBoundaryInvalid => "no exact trustworthy recovery boundary was found; the source was left unchanged",
        error.SessionRecoveryIndeterminate => "the recovery copy could not be confirmed; the source was left unchanged",
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => "session authority is temporarily unavailable while an incomplete commit is resolved",
        error.SessionAuthorityIntentCleanupPending => "session authority is confirmed but transition cleanup is still pending",
        error.SessionBusy, error.SessionLockUnsupported => "session is busy or the filesystem cannot provide the required lock",
        error.SessionPathUnsafe,
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => "durable session storage is unsafe or does not support required private permissions",
        error.DurableLayoutFailed, error.SessionStoreUnavailable => "durable session store is unavailable",
        error.HomeNotSet => "HOME is not set",
        else => null,
    };
}

test "session detail failures separate corruption from unsupported schema" {
    var corrupt_text = CaptureOutput.init(std.testing.allocator);
    defer corrupt_text.deinit();
    try writeSessionDetailFailure(
        std.testing.allocator,
        corrupt_text.deps(),
        "broken-session",
        error.InvalidSessionFormat,
        .text,
    );
    try std.testing.expectEqualStrings("", corrupt_text.stdout.written());
    try std.testing.expectEqualStrings(
        "fx session: session broken-session is corrupt; run `fx session recover broken-session`\n",
        corrupt_text.stderr.written(),
    );

    var corrupt_json = CaptureOutput.init(std.testing.allocator);
    defer corrupt_json.deinit();
    try writeSessionDetailFailure(
        std.testing.allocator,
        corrupt_json.deps(),
        "broken-session",
        error.InvalidSessionFormat,
        .json,
    );
    try std.testing.expectEqualStrings("", corrupt_json.stderr.written());
    try std.testing.expect(
        std.mem.find(
            u8,
            corrupt_json.stdout.written(),
            "\"error\":\"session broken-session is corrupt; run `fx session recover broken-session`\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.find(
            u8,
            corrupt_json.stdout.written(),
            "\"code\":\"InvalidSessionFormat\"",
        ) != null,
    );

    var unsupported_text = CaptureOutput.init(std.testing.allocator);
    defer unsupported_text.deinit();
    try writeSessionDetailFailure(
        std.testing.allocator,
        unsupported_text.deps(),
        "future-session",
        error.UnsupportedSessionSchema,
        .text,
    );
    try std.testing.expectEqualStrings("", unsupported_text.stdout.written());
    try std.testing.expectEqualStrings(
        "fx session: session future-session uses an unsupported session version\n",
        unsupported_text.stderr.written(),
    );
}

test "session recovery boundary failures keep stable text and json guidance" {
    var text_output = CaptureOutput.init(std.testing.allocator);
    defer text_output.deinit();
    try writeLookupFailure(
        std.testing.allocator,
        text_output.deps(),
        "session",
        error.SessionRecoveryBoundaryInvalid,
        .text,
    );
    try std.testing.expectEqualStrings("", text_output.stdout.written());
    try std.testing.expectEqualStrings(
        "fx session: no exact trustworthy recovery boundary was found; the source was left unchanged\n",
        text_output.stderr.written(),
    );

    var json_output = CaptureOutput.init(std.testing.allocator);
    defer json_output.deinit();
    try writeLookupFailure(
        std.testing.allocator,
        json_output.deps(),
        "session",
        error.SessionRecoveryBoundaryInvalid,
        .json,
    );
    try std.testing.expectEqualStrings("", json_output.stderr.written());
    try std.testing.expect(
        std.mem.find(
            u8,
            json_output.stdout.written(),
            "\"code\":\"SessionRecoveryBoundaryInvalid\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.find(
            u8,
            json_output.stdout.written(),
            "\"error\":\"no exact trustworthy recovery boundary was found; the source was left unchanged\"",
        ) != null,
    );
}

fn workflowConfig(cfg: Config) @import("cli_ask.zig").Config {
    return .{
        .auth_mode = cfg.auth_mode,
        .command_usage = command_specs.topLevelUsage(cfg.command_catalog, .ask),
        .default_model = cfg.default_model,
        .default_agent_step_limit = cfg.default_agent_step_limit,
        .gateway_retry_count = cfg.gateway_retry_count,
        .gateway_chat_url = cfg.gateway_provider.chat_url.resolve(cfg.gateway_chat_url),
        .gateway_models_path = cfg.models_path,
        .gateway_provider = cfg.gateway_provider,
        .provider_set = cfg.provider_set,
        .process_provider = cfg.process_provider,
        .secret_store = cfg.secret_store,
        .prompt_policy = cfg.prompt_policy,
        .skill_root_policy = cfg.skill_root_policy,
        .ignored_list_entries = cfg.ignored_list_entries,
        .max_list_entries = cfg.max_list_entries,
        .max_read_file_bytes = cfg.max_read_file_bytes,
        .max_read_file_lines = cfg.max_read_file_lines,
        .max_read_file_line_len = cfg.max_read_file_line_len,
        .max_command_output_bytes = cfg.max_command_output_bytes,
        .max_tool_result_bytes = cfg.max_tool_result_bytes,
        .max_history_turns = cfg.max_history_turns,
        .mode_registry = cfg.mode_registry,
        .load_mcp_runtime = cfg.load_mcp_runtime,
    };
}

fn workflowConfigWithLaunchModifiers(
    cfg: Config,
    modifiers: LaunchModifiers,
) @import("cli_ask.zig").Config {
    var result = workflowConfig(cfg);
    result.context_limit_overrides = modifiers.context_limit_overrides;
    result.additional_directories = modifiers.additional_directories;
    result.saved_directories_suppressed = modifiers.saved_directories_suppressed;
    return result;
}

fn commandSupportsWorkspaceModifiers(command: Command) bool {
    return switch (command) {
        .interactive, .ask, .acp, .pr, .issue, .resume_session => true,
        else => false,
    };
}

fn writeWorkspaceModifierUsage(deps: RunDeps) !void {
    try writeStderr(
        deps,
        "fx: --add-dir and --no-additional-dirs are only supported for interactive, resume, ask, ACP, PR, and issue launches\n",
    );
}

fn globalLaunchErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MissingAddDirectoryValue => "--add-dir requires a directory path",
        error.DuplicateAdditionalDirectorySuppression => "--no-additional-dirs may only be specified once",
        else => null,
    };
}

fn parseAcpArgs(args: []const [:0]const u8) !AcpOptions {
    var opts = AcpOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--model")) {
            if (opts.model != null or i + 1 >= args.len) return error.InvalidAcpArgs;
            i += 1;
            opts.model = args[i];
        } else if (std.mem.eql(u8, args[i], "--log-file")) {
            if (opts.log_file != null or i + 1 >= args.len) return error.InvalidAcpArgs;
            i += 1;
            opts.log_file = args[i];
        } else {
            return error.InvalidAcpArgs;
        }
    }
    return opts;
}

fn parseLocalSurfaceArgs(args: []const [:0]const u8) !LocalSurfaceOptions {
    var options = LocalSurfaceOptions{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
            continue;
        }
        return error.InvalidLocalSurfaceArgs;
    }
    return options;
}

fn parseUpgradeArgs(args: []const [:0]const u8) !UpgradeOptions {
    var options = UpgradeOptions{};
    var format_seen = false;
    var channel_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format_seen) return error.InvalidUpgradeArgs;
            format_seen = true;
            options.format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--channel")) {
            if (channel_seen or index + 1 >= args.len) return error.InvalidUpgradeArgs;
            channel_seen = true;
            index += 1;
            options.channel = update_target.Channel.parse(args[index]) orelse
                return error.InvalidUpgradeArgs;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--channel=")) {
            if (channel_seen) return error.InvalidUpgradeArgs;
            channel_seen = true;
            options.channel = update_target.Channel.parse(arg["--channel=".len..]) orelse
                return error.InvalidUpgradeArgs;
            continue;
        }
        return error.InvalidUpgradeArgs;
    }
    return options;
}

fn parseSessionListArgs(args: []const [:0]const u8) !SessionListOptions {
    var options = SessionListOptions{};
    var format_seen = false;
    var limit_seen = false;
    var cursor_seen = false;
    var scope_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format_seen) return error.InvalidLocalSurfaceArgs;
            format_seen = true;
            options.format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            if (scope_seen) return error.InvalidLocalSurfaceArgs;
            scope_seen = true;
            options.scope = .all_workspaces;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            if (limit_seen or index + 1 >= args.len) return error.InvalidLocalSurfaceArgs;
            limit_seen = true;
            index += 1;
            options.limit = std.fmt.parseUnsigned(usize, args[index], 10) catch
                return error.InvalidLocalSurfaceArgs;
            if (options.limit == 0 or
                options.limit > session_store.session_list_max_limit)
            {
                return error.InvalidLocalSurfaceArgs;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--cursor")) {
            if (cursor_seen or index + 1 >= args.len) return error.InvalidLocalSurfaceArgs;
            cursor_seen = true;
            index += 1;
            options.continuation = try parseSessionListCursor(args[index]);
            continue;
        }
        return error.InvalidLocalSurfaceArgs;
    }
    return options;
}

fn parseUsageArgs(args: []const [:0]const u8) !UsageOptions {
    var options = UsageOptions{};
    var period_seen = false;
    var json_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (json_seen) return error.InvalidUsageArgs;
            json_seen = true;
            options.format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--period")) {
            if (period_seen or index + 1 >= args.len) return error.InvalidUsageArgs;
            period_seen = true;
            index += 1;
            options.scope = if (std.mem.eql(u8, args[index], "24h"))
                .hours_24
            else if (std.mem.eql(u8, args[index], "7d"))
                .days_7
            else if (std.mem.eql(u8, args[index], "30d"))
                .days_30
            else
                return error.InvalidUsageArgs;
            continue;
        }
        return error.InvalidUsageArgs;
    }
    return options;
}

fn parseSessionListCursor(raw: []const u8) !session_store.ResumableSessionContinuation {
    if (raw.len == 0 or raw.len > 320) return error.InvalidLocalSurfaceArgs;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidLocalSurfaceArgs, "v1")) {
        return error.InvalidLocalSurfaceArgs;
    }
    const updated_text = fields.next() orelse return error.InvalidLocalSurfaceArgs;
    const id = fields.next() orelse return error.InvalidLocalSurfaceArgs;
    if (fields.next() != null) return error.InvalidLocalSurfaceArgs;
    session_store.validateSessionId(id) catch return error.InvalidLocalSurfaceArgs;
    const updated_at_ms = std.fmt.parseInt(i64, updated_text, 10) catch
        return error.InvalidLocalSurfaceArgs;
    var canonical: [320]u8 = undefined;
    const encoded = std.fmt.bufPrint(
        &canonical,
        "v1:{d}:{s}",
        .{ updated_at_ms, id },
    ) catch return error.InvalidLocalSurfaceArgs;
    if (!std.mem.eql(u8, encoded, raw)) return error.InvalidLocalSurfaceArgs;
    return .{ .updated_at_ms = updated_at_ms, .id = id };
}

fn formatSessionListCursor(
    alloc: Allocator,
    summary: session_store.SessionSummary,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "v1:{d}:{s}",
        .{ summary.updated_at_ms, summary.id },
    );
}

fn parseWorkspaceArgs(args: []const [:0]const u8) !WorkspaceOptions {
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var options = WorkspaceOptions{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (options.format == .json) return error.InvalidWorkspaceArgs;
            options.format = .json;
            continue;
        }
        if (positional_len >= positional.len) return error.InvalidWorkspaceArgs;
        positional[positional_len] = arg;
        positional_len += 1;
    }

    if (positional_len == 0) return options;
    if (std.mem.eql(u8, positional[0], "list")) {
        if (positional_len != 1) return error.InvalidWorkspaceArgs;
        return options;
    }
    if (std.mem.eql(u8, positional[0], "clear")) {
        if (positional_len != 1) return error.InvalidWorkspaceArgs;
        options.action = .clear;
        return options;
    }
    if (std.mem.eql(u8, positional[0], "add")) {
        if (positional_len != 2 or positional[1].len == 0) return error.InvalidWorkspaceArgs;
        options.action = .{ .add = positional[1] };
        return options;
    }
    if (std.mem.eql(u8, positional[0], "remove")) {
        if (positional_len != 2 or positional[1].len == 0) return error.InvalidWorkspaceArgs;
        options.action = .{ .remove = positional[1] };
        return options;
    }
    return error.InvalidWorkspaceArgs;
}

fn parseSessionDetailArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionDetailOptions {
    var options = SessionDetailOptions{};
    errdefer options.deinit(alloc);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
            continue;
        }
        if (options.target != null) return error.InvalidSessionDetailArgs;
        const exact_id = std.mem.eql(u8, arg, "--id");
        if (exact_id) {
            i += 1;
            if (i >= args.len) return error.InvalidSessionDetailArgs;
        }
        const trimmed = std.mem.trim(u8, args[i], " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSessionDetailArgs;
        if (!exact_id and std.mem.eql(u8, trimmed, "last")) {
            options.target = .last;
            continue;
        }
        options.target = .{ .id = try alloc.dupe(u8, trimmed) };
    }
    return options;
}

fn parseSessionMigrationArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionMigrationOptions {
    var format: output_contracts.OutputFormat = .text;
    var allow_large = false;
    var session_id: ?[]u8 = null;
    errdefer if (session_id) |id| alloc.free(id);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-large")) {
            allow_large = true;
            continue;
        }
        if (session_id != null) return error.InvalidSessionMigrationArgs;
        const exact_id = std.mem.eql(u8, arg, "--id");
        if (exact_id) {
            i += 1;
            if (i >= args.len) return error.InvalidSessionMigrationArgs;
        }
        const trimmed = std.mem.trim(u8, args[i], " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSessionMigrationArgs;
        session_id = try alloc.dupe(u8, trimmed);
    }
    return .{
        .format = format,
        .session_id = session_id orelse return error.InvalidSessionMigrationArgs,
        .allow_large = allow_large,
    };
}

fn parseSessionRecoveryArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionRecoveryOptions {
    var format: output_contracts.OutputFormat = .text;
    var session_id: ?[]u8 = null;
    errdefer if (session_id) |id| alloc.free(id);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
            continue;
        }
        if (session_id != null) return error.InvalidSessionRecoveryArgs;
        const exact_id = std.mem.eql(u8, arg, "--id");
        if (exact_id) {
            i += 1;
            if (i >= args.len) return error.InvalidSessionRecoveryArgs;
        }
        const trimmed = std.mem.trim(u8, args[i], " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSessionRecoveryArgs;
        session_id = try alloc.dupe(u8, trimmed);
    }
    return .{
        .format = format,
        .session_id = session_id orelse return error.InvalidSessionRecoveryArgs,
    };
}

fn parseResumeArgs(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    args: []const [:0]const u8,
    top_level_alias: bool,
) !ResumeTarget {
    if (args.len == 0) return .last;

    if (top_level_alias) {
        if (std.mem.eql(u8, args[0], "--resume")) {
            if (args.len == 1) return .last;
            if (args.len != 2) return error.InvalidResumeArgs;
            const id = std.mem.trim(u8, args[1], " \t\r\n");
            if (id.len == 0) return error.InvalidResumeArgs;
            if (std.mem.eql(u8, id, "last")) return .last;
            return .{ .id = try alloc.dupe(u8, id) };
        }
        if (args.len != 1) return error.InvalidResumeArgs;
        if (std.mem.eql(u8, args[0], resume_picker_alias)) return .pick;
        if (command_specs.matchesTopLevel(command_catalog, args[0], .@"resume")) return .last;
        if (!std.mem.startsWith(u8, args[0], resume_id_alias_prefix)) return error.InvalidResumeArgs;
        const id = args[0][resume_id_alias_prefix.len..];
        if (id.len == 0) return error.InvalidResumeArgs;
        return .{ .id = try alloc.dupe(u8, id) };
    }

    if (std.mem.eql(u8, args[0], "--resume")) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "--last")) return .last;
        return error.InvalidResumeArgs;
    }

    const exact_id = std.mem.eql(u8, args[0], "--id");
    const operand_index: usize = if (exact_id) 1 else 0;
    if (args.len != operand_index + 1) return error.InvalidResumeArgs;

    const trimmed = std.mem.trim(u8, args[operand_index], " \t\r\n");
    if (trimmed.len == 0) return error.InvalidResumeArgs;
    if (!exact_id and std.mem.eql(u8, trimmed, "last")) return .last;
    return .{ .id = try alloc.dupe(u8, trimmed) };
}

fn parseWorkflowArgs(alloc: Allocator, args: []const [:0]const u8) !WorkflowOptions {
    var auto_permission = false;
    var create = false;
    var start_index: usize = 0;
    while (start_index < args.len) : (start_index += 1) {
        if (std.mem.eql(u8, args[start_index], "--auto")) {
            auto_permission = true;
            continue;
        }
        if (std.mem.eql(u8, args[start_index], "--create")) {
            create = true;
            continue;
        }
        break;
    }

    return .{
        .auto_permission = auto_permission,
        .create = create,
        .context = try joinArgs(alloc, args[start_index..]),
    };
}

fn joinArgs(alloc: Allocator, args: []const [:0]const u8) ![]u8 {
    if (args.len == 0) return alloc.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (args, 0..) |arg, i| {
        if (i > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    return try out.toOwnedSlice();
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v");
}

fn testCommandCatalog() CommandCatalog {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.top_level_registry;
}

test "parse recognizes every top-level command and preserves unknown commands" {
    const command_catalog = testCommandCatalog();
    try std.testing.expectEqual(Command.interactive, parse(command_catalog, &.{}));
    try std.testing.expectEqual(Command.help, parse(command_catalog, &.{@constCast("help")}));

    switch (parse(command_catalog, &.{ @constCast("ask"), @constCast("hello") })) {
        .ask => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("acp"), @constCast("--model"), @constCast("m") })) {
        .acp => |rest| try std.testing.expectEqual(@as(usize, 2), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("pr"), @constCast("ready") })) {
        .pr => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("issue"), @constCast("flaky") })) {
        .issue => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("setup")})) {
        .setup => |rest| try std.testing.expectEqual(@as(usize, 0), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("status"), @constCast("--json") })) {
        .status => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("permissions")})) {
        .permissions => |rest| try std.testing.expectEqual(@as(usize, 0), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("models"), @constCast("--json") })) {
        .models => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("mcp"), @constCast("add"), @constCast("fixture"), @constCast("node") })) {
        .mcp => |rest| try std.testing.expectEqual(@as(usize, 3), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("doctor")})) {
        .doctor => |rest| try std.testing.expectEqual(@as(usize, 0), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("background")})) {
        .unknown => |command| try std.testing.expectEqualStrings("background", command),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("session"), @constCast("last") })) {
        .session => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("session"), @constCast("resume"), @constCast("last") })) {
        .resume_session => |invocation| try std.testing.expectEqual(@as(usize, 1), invocation.args.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("sessions"), @constCast("--json") })) {
        .sessions => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("resume"), @constCast("last") })) {
        .resume_session => |invocation| try std.testing.expectEqual(@as(usize, 1), invocation.args.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("credits"), @constCast("--json") })) {
        .credits => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("usage"), @constCast("--period"), @constCast("24h") })) {
        .usage => |rest| try std.testing.expectEqual(@as(usize, 2), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("upgrade")})) {
        .upgrade => |rest| try std.testing.expectEqual(@as(usize, 0), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("replay"), @constCast("tape") })) {
        .replay => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("wat")})) {
        .unknown => |value| try std.testing.expectEqualStrings("wat", value),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("task")})) {
        .unknown => |value| try std.testing.expectEqualStrings("task", value),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("tasks")})) {
        .unknown => |value| try std.testing.expectEqualStrings("tasks", value),
        else => return error.TestExpectedEqual,
    }
}

test "help aliases route to help" {
    const command_catalog = testCommandCatalog();
    try std.testing.expectEqual(Command.help, parse(command_catalog, &.{@constCast("--help")}));
    try std.testing.expectEqual(Command.help, parse(command_catalog, &.{@constCast("-h")}));
}

test "usage arguments accept only rolling periods and one JSON flag" {
    const defaults = try parseUsageArgs(&.{});
    try std.testing.expectEqual(usage_report.Scope.days_30, defaults.scope);
    try std.testing.expectEqual(output_contracts.OutputFormat.text, defaults.format);

    const selected = try parseUsageArgs(&.{
        @constCast("--json"),
        @constCast("--period"),
        @constCast("7d"),
    });
    try std.testing.expectEqual(usage_report.Scope.days_7, selected.scope);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, selected.format);

    for ([_][]const [:0]const u8{
        &.{@constCast("--period")},
        &.{ @constCast("--period"), @constCast("session") },
        &.{ @constCast("--period"), @constCast("24h"), @constCast("--period"), @constCast("7d") },
        &.{ @constCast("--json"), @constCast("--json") },
        &.{@constCast("30d")},
    }) |invalid| {
        try std.testing.expectError(error.InvalidUsageArgs, parseUsageArgs(invalid));
    }
}

test "global launch modifiers preserve repeatable context limits before the command" {
    var parsed = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("--context-limit"),
        @constCast("skill_chunk_bytes=4096"),
        @constCast("--context-limit=mcp_description_bytes=off"),
        @constCast("ask"),
        @constCast("hello"),
    });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.modifiers.context_limit_overrides.len);
    try std.testing.expectEqual(config_runtime.context_limits.Name.skill_chunk_bytes, parsed.modifiers.context_limit_overrides[0].name);
    try std.testing.expectEqual(@as(usize, 4096), parsed.modifiers.context_limit_overrides[0].value.bytes);
    try std.testing.expectEqual(config_runtime.context_limits.Name.mcp_description_bytes, parsed.modifiers.context_limit_overrides[1].name);
    try std.testing.expect(parsed.modifiers.context_limit_overrides[1].value == .off);
    try std.testing.expectEqualStrings("ask", parsed.remaining[0]);
    try std.testing.expectEqualStrings("hello", parsed.remaining[1]);
}

test "global context limits reject missing values and stop at the command" {
    try std.testing.expectError(
        error.MissingContextLimitValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--context-limit")}),
    );
    var parsed = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("ask"),
        @constCast("--context-limit"),
        @constCast("skill_chunk_bytes=1"),
    });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), parsed.modifiers.context_limit_overrides.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.remaining.len);
}

test "global launch modifiers own repeatable additional directories and suppression" {
    var parsed = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("--add-dir"),
        @constCast("/tmp/shared one"),
        @constCast("--context-limit=skill_chunk_bytes=2048"),
        @constCast("--add-dir=/tmp/shared-two"),
        @constCast("--no-additional-dirs"),
        @constCast("ask"),
        @constCast("inspect"),
    });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.modifiers.additional_directories.len);
    try std.testing.expectEqualStrings("/tmp/shared one", parsed.modifiers.additional_directories[0]);
    try std.testing.expectEqualStrings("/tmp/shared-two", parsed.modifiers.additional_directories[1]);
    try std.testing.expect(parsed.modifiers.saved_directories_suppressed);
    try std.testing.expectEqualStrings("ask", parsed.remaining[0]);
}

test "additional directory flags fail closed when malformed" {
    try std.testing.expectError(
        error.MissingAddDirectoryValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--add-dir")}),
    );
    try std.testing.expectError(
        error.MissingAddDirectoryValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--add-dir=")}),
    );
    try std.testing.expectError(
        error.DuplicateAdditionalDirectorySuppression,
        parseGlobalLaunchArgs(std.testing.allocator, &.{ @constCast("--no-additional-dirs"), @constCast("--no-additional-dirs") }),
    );
}

test "parse acp args extracts known flags and rejects invalid arguments" {
    const opts = try parseAcpArgs(&.{
        @constCast("--model"),
        @constCast("openai/gpt-4o"),
        @constCast("--log-file"),
        @constCast("/tmp/fx.log"),
    });
    try std.testing.expectEqualStrings("openai/gpt-4o", opts.model.?);
    try std.testing.expectEqualStrings("/tmp/fx.log", opts.log_file.?);

    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(&.{@constCast("--unknown")}));
    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(&.{@constCast("--model")}));
    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(&.{@constCast("--log-file")}));
    try std.testing.expectError(
        error.InvalidAcpArgs,
        parseAcpArgs(&.{ @constCast("--model"), @constCast("first"), @constCast("--model"), @constCast("second") }),
    );
}

test "ACP command routes parsed options and launch config through the injected runner" {
    const Capture = struct {
        expected: Config,
        calls: usize = 0,
        config_matches: bool = false,
        launch_matches: bool = false,

        fn run(raw: ?*anyopaque, _: Allocator, cfg: acp_runner.Config) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            const expected = self.expected;
            self.config_matches =
                std.mem.eql(u8, cfg.default_model, expected.default_model) and
                cfg.default_agent_step_limit == expected.default_agent_step_limit and
                cfg.gateway_retry_count == expected.gateway_retry_count and
                std.mem.eql(
                    u8,
                    cfg.gateway_chat_url,
                    expected.gateway_provider.chat_url.resolve(expected.gateway_chat_url),
                ) and
                std.mem.eql(u8, cfg.gateway_models_path, expected.models_path) and
                cfg.gateway_provider.chat_url.resolve_fn == expected.gateway_provider.chat_url.resolve_fn and
                std.mem.eql(u8, cfg.prompt_policy.system_prompt, expected.prompt_policy.system_prompt) and
                cfg.ignored_list_entries.len == expected.ignored_list_entries.len and
                cfg.max_list_entries == expected.max_list_entries and
                cfg.max_read_file_bytes == expected.max_read_file_bytes and
                cfg.max_read_file_lines == expected.max_read_file_lines and
                cfg.max_read_file_line_len == expected.max_read_file_line_len and
                cfg.max_command_output_bytes == expected.max_command_output_bytes and
                cfg.max_tool_result_bytes == expected.max_tool_result_bytes and
                cfg.max_history_turns == expected.max_history_turns and
                std.mem.eql(
                    u8,
                    cfg.context_registry.defaultProvider().id,
                    expected.context_registry.defaultProvider().id,
                ) and
                std.mem.eql(u8, cfg.mode_registry.default_mode_id, expected.mode_registry.default_mode_id) and
                cfg.provider_set.gateway.permission_reviewer.?.review_fn == expected.provider_set.gateway.permission_reviewer.?.review_fn;

            const limit_matches = cfg.context_limit_overrides.len == 1 and
                cfg.context_limit_overrides[0].name == .project_instructions_total_bytes and
                switch (cfg.context_limit_overrides[0].value) {
                    .bytes => |bytes| bytes == 1234,
                    .off => false,
                };
            self.launch_matches =
                limit_matches and
                cfg.additional_directories.len == 1 and
                std.mem.eql(u8, cfg.additional_directories[0], "/tmp/acp-extra") and
                cfg.saved_directories_suppressed and
                std.mem.eql(u8, cfg.model_override.?, "model-override") and
                std.mem.eql(u8, cfg.log_file.?, "/tmp/acp.log");
        }
    };

    var cfg = testConfig();
    cfg.provider_set.gateway.permission_reviewer = test_builtin_gateway.permission_reviewer.provider;
    var capture = Capture{ .expected = cfg };
    cfg.acp_runner = .{ .context = &capture, .run_fn = Capture.run };
    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{
            @constCast("--context-limit"),
            @constCast("project_instructions_total_bytes=1234"),
            @constCast("--add-dir"),
            @constCast("/tmp/acp-extra"),
            @constCast("--no-additional-dirs"),
            @constCast("acp"),
            @constCast("--model"),
            @constCast("model-override"),
            @constCast("--log-file"),
            @constCast("/tmp/acp.log"),
        },
        cfg,
        .{},
    );

    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.config_matches);
    try std.testing.expect(capture.launch_matches);
}

test "ACP runner errors preserve their identity" {
    const Fixture = struct {
        fn run(_: ?*anyopaque, _: Allocator, _: acp_runner.Config) anyerror!void {
            return error.TestAcpRunnerFailed;
        }
    };

    var cfg = testConfig();
    cfg.acp_runner = .{ .run_fn = Fixture.run };
    try std.testing.expectError(
        error.TestAcpRunnerFailed,
        runIfRequested(std.testing.allocator, &.{@constCast("acp")}, cfg),
    );
}

test "parse local surface args accepts only json" {
    const empty = try parseLocalSurfaceArgs(&.{});
    try std.testing.expectEqual(output_contracts.OutputFormat.text, empty.format);

    const opts = try parseLocalSurfaceArgs(&.{@constCast("--json")});
    try std.testing.expectEqual(output_contracts.OutputFormat.json, opts.format);

    try std.testing.expectError(error.InvalidLocalSurfaceArgs, parseLocalSurfaceArgs(&.{@constCast("--wat")}));
}

test "parse upgrade args accepts a remembered release channel" {
    const defaults = try parseUpgradeArgs(&.{});
    try std.testing.expectEqual(output_contracts.OutputFormat.text, defaults.format);
    try std.testing.expect(defaults.channel == null);

    const selected = try parseUpgradeArgs(&.{
        @constCast("--channel"),
        @constCast("dev"),
        @constCast("--json"),
    });
    try std.testing.expectEqual(output_contracts.OutputFormat.json, selected.format);
    try std.testing.expectEqual(update_target.Channel.dev, selected.channel.?);

    const stable = try parseUpgradeArgs(&.{@constCast("--channel=stable")});
    try std.testing.expectEqual(update_target.Channel.stable, stable.channel.?);

    try std.testing.expectError(
        error.InvalidUpgradeArgs,
        parseUpgradeArgs(&.{ @constCast("--channel"), @constCast("nightly") }),
    );
    try std.testing.expectError(
        error.InvalidUpgradeArgs,
        parseUpgradeArgs(&.{ @constCast("--channel=dev"), @constCast("--channel=stable") }),
    );
}

test "parse session list args supports bounded canonical pagination" {
    const empty = try parseSessionListArgs(&.{});
    try std.testing.expectEqual(output_contracts.OutputFormat.text, empty.format);
    try std.testing.expectEqual(session_store.session_list_default_limit, empty.limit);
    try std.testing.expect(empty.continuation == null);

    const paged = try parseSessionListArgs(&.{
        @constCast("--json"),
        @constCast("--all"),
        @constCast("--limit"),
        @constCast("2"),
        @constCast("--cursor"),
        @constCast("v1:20:session-a"),
    });
    try std.testing.expectEqual(output_contracts.OutputFormat.json, paged.format);
    try std.testing.expectEqual(session_store.SessionListScope.all_workspaces, paged.scope);
    try std.testing.expectEqual(@as(usize, 2), paged.limit);
    try std.testing.expectEqual(@as(i64, 20), paged.continuation.?.updated_at_ms);
    try std.testing.expectEqualStrings("session-a", paged.continuation.?.id);

    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--all"), @constCast("--all") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--limit"), @constCast("0") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--limit"), @constCast("101") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--limit"), @constCast("2"), @constCast("--limit"), @constCast("3") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{@constCast("--cursor")}),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--cursor"), @constCast("v1:020:session-a") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--cursor"), @constCast("v2:20:session-a") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--cursor"), @constCast("v1:20:../unsafe") }),
    );
}

test "parse session detail args owns string ids and frees through deinit" {
    var latest = try parseSessionDetailArgs(std.testing.allocator, &.{ @constCast("last"), @constCast("--json") });
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, latest.format);
    try std.testing.expectEqual(SessionDetailTarget.last, latest.target.?);

    var specific = try parseSessionDetailArgs(std.testing.allocator, &.{@constCast(" sess-1 ")});
    defer specific.deinit(std.testing.allocator);
    switch (specific.target.?) {
        .id => |value| try std.testing.expectEqualStrings("sess-1", value),
        else => return error.TestExpectedEqual,
    }

    try std.testing.expectError(error.InvalidSessionDetailArgs, parseSessionDetailArgs(std.testing.allocator, &.{ @constCast("a"), @constCast("b") }));
    try std.testing.expectError(error.InvalidSessionDetailArgs, parseSessionDetailArgs(std.testing.allocator, &.{@constCast("")}));
}

test "parse session detail args accepts explicit id flag" {
    var specific = try parseSessionDetailArgs(std.testing.allocator, &.{
        @constCast("--id"),
        @constCast("release.2026.06"),
        @constCast("--json"),
    });
    defer specific.deinit(std.testing.allocator);

    try std.testing.expectEqual(output_contracts.OutputFormat.json, specific.format);
    switch (specific.target.?) {
        .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("release.2026.06", id),
    }
}

test "parse session detail args treats last after id flag as exact id" {
    var specific = try parseSessionDetailArgs(std.testing.allocator, &.{
        @constCast("--id"),
        @constCast("last"),
    });
    defer specific.deinit(std.testing.allocator);

    switch (specific.target.?) {
        .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("last", id),
    }
}

test "parse session migration args accepts positional and exact ids" {
    var positional = try parseSessionMigrationArgs(std.testing.allocator, &.{
        @constCast("session.v2"),
        @constCast("--allow-large"),
        @constCast("--json"),
    });
    defer positional.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("session.v2", positional.session_id);
    try std.testing.expect(positional.allow_large);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, positional.format);

    var exact = try parseSessionMigrationArgs(std.testing.allocator, &.{
        @constCast("--id"),
        @constCast("--allow-large"),
        @constCast("--json"),
    });
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("--allow-large", exact.session_id);
    try std.testing.expect(!exact.allow_large);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, exact.format);
}

test "parse session migration args rejects missing repeated and mixed targets" {
    try std.testing.expectError(
        error.InvalidSessionMigrationArgs,
        parseSessionMigrationArgs(std.testing.allocator, &.{@constCast("--id")}),
    );
    try std.testing.expectError(
        error.InvalidSessionMigrationArgs,
        parseSessionMigrationArgs(std.testing.allocator, &.{
            @constCast("session.v2"),
            @constCast("--id"),
            @constCast("session.v3"),
        }),
    );
    try std.testing.expectError(
        error.InvalidSessionMigrationArgs,
        parseSessionMigrationArgs(std.testing.allocator, &.{
            @constCast("session.v2"),
            @constCast("session.v3"),
        }),
    );
}

test "parse session recovery args accepts exact ids and rejects ambiguity" {
    var positional = try parseSessionRecoveryArgs(
        std.testing.allocator,
        &.{
            @constCast("session.v3"),
            @constCast("--json"),
        },
    );
    defer positional.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("session.v3", positional.session_id);
    try std.testing.expectEqual(
        output_contracts.OutputFormat.json,
        positional.format,
    );

    var exact = try parseSessionRecoveryArgs(
        std.testing.allocator,
        &.{
            @constCast("--id"),
            @constCast("last"),
        },
    );
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("last", exact.session_id);

    try std.testing.expectError(
        error.InvalidSessionRecoveryArgs,
        parseSessionRecoveryArgs(
            std.testing.allocator,
            &.{@constCast("--id")},
        ),
    );
    try std.testing.expectError(
        error.InvalidSessionRecoveryArgs,
        parseSessionRecoveryArgs(
            std.testing.allocator,
            &.{
                @constCast("first"),
                @constCast("second"),
            },
        ),
    );
}

test "parse resume args defaults to last owns ids and rejects invalid input" {
    const command_catalog = testCommandCatalog();
    const implicit = try parseResumeArgs(std.testing.allocator, command_catalog, &.{}, false);
    try std.testing.expectEqual(ResumeTarget.last, implicit);

    const explicit = try parseResumeArgs(std.testing.allocator, command_catalog, &.{@constCast("last")}, false);
    try std.testing.expectEqual(ResumeTarget.last, explicit);

    var target = try parseResumeArgs(std.testing.allocator, command_catalog, &.{@constCast(" session-123 ")}, false);
    defer target.deinit(std.testing.allocator);
    switch (target) {
        .id => |value| try std.testing.expectEqualStrings("session-123", value),
        else => return error.TestExpectedEqual,
    }

    try std.testing.expectError(error.InvalidResumeArgs, parseResumeArgs(std.testing.allocator, command_catalog, &.{ @constCast("a"), @constCast("b") }, false));
    try std.testing.expectError(error.InvalidResumeArgs, parseResumeArgs(std.testing.allocator, command_catalog, &.{@constCast("   ")}, false));
}

test "parse resume args accepts explicit id flag" {
    const command_catalog = testCommandCatalog();
    var target = try parseResumeArgs(std.testing.allocator, command_catalog, &.{
        @constCast("--id"),
        @constCast("release.2026.06"),
    }, false);
    defer target.deinit(std.testing.allocator);

    switch (target) {
        .pick, .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("release.2026.06", id),
    }
}

test "parse resume args accepts an operand on the top-level resume flag" {
    const command_catalog = testCommandCatalog();
    var target = try parseResumeArgs(std.testing.allocator, command_catalog, &.{
        @constCast("--resume"),
        @constCast("session-123"),
    }, true);
    defer target.deinit(std.testing.allocator);

    switch (target) {
        .pick, .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("session-123", id),
    }

    const latest = try parseResumeArgs(std.testing.allocator, command_catalog, &.{
        @constCast("--resume"),
        @constCast("last"),
    }, true);
    try std.testing.expectEqual(ResumeTarget.last, latest);
}

test "parse resume args treats last after id flag as exact id" {
    const command_catalog = testCommandCatalog();
    var target = try parseResumeArgs(std.testing.allocator, command_catalog, &.{
        @constCast("--id"),
        @constCast("last"),
    }, false);
    defer target.deinit(std.testing.allocator);

    switch (target) {
        .pick, .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("last", id),
    }
}

test "parseInteractiveLaunch accepts legacy and revision-bearing upgrade relaunches" {
    const alloc = std.testing.allocator;
    const command_catalog = testCommandCatalog();
    const revision = "abcdef0123456789abcdef0123456789abcdef01";

    const cases = [_]struct {
        args: []const [:0]const u8,
        expected_revision: ?[]const u8,
    }{
        .{
            .args = &.{ @constCast("resume"), @constCast("session-123"), @constCast("--upgrade-relaunch") },
            .expected_revision = null,
        },
        .{
            .args = &.{ @constCast("resume"), @constCast("session-123"), @constCast("--upgrade-relaunch"), @constCast(revision) },
            .expected_revision = revision,
        },
    };

    for (cases) |case| {
        const parsed = try parseInteractiveLaunch(alloc, case.args, command_catalog);
        switch (parsed) {
            .interactive => |value| {
                var launch = value;
                defer launch.deinit(alloc);
                const relaunch = launch.upgrade_relaunch orelse return error.TestExpectedUpgradeRelaunch;
                if (case.expected_revision) |expected| {
                    try std.testing.expectEqualStrings(expected, relaunch.previous_revision.?);
                } else try std.testing.expect(relaunch.previous_revision == null);
            },
            .noninteractive => |value| {
                var noninteractive = value;
                defer noninteractive.deinit(alloc);
                return error.TestExpectedInteractiveLaunch;
            },
        }
    }

    try std.testing.expectError(
        error.InvalidResumeArgs,
        parseInteractiveLaunch(alloc, &.{
            @constCast("resume"),
            @constCast("session-123"),
            @constCast("--upgrade-relaunch"),
            @constCast("not-a-revision"),
        }, command_catalog),
    );
}

test "parseInteractiveLaunch shares native resume grammar" {
    const alloc = std.testing.allocator;
    const command_catalog = testCommandCatalog();
    const cases = [_]struct {
        args: []const [:0]const u8,
        expected_id: ?[]const u8,
    }{
        .{ .args = &.{@constCast("--resume")}, .expected_id = null },
        .{ .args = &.{ @constCast("--resume"), @constCast("last") }, .expected_id = null },
        .{ .args = &.{ @constCast("--resume"), @constCast("session-123") }, .expected_id = "session-123" },
        .{ .args = &.{ @constCast("session"), @constCast("resume"), @constCast("last") }, .expected_id = null },
        .{ .args = &.{ @constCast("session"), @constCast("resume"), @constCast("--id"), @constCast("session.v3") }, .expected_id = "session.v3" },
    };
    for (cases) |case| {
        const parsed = try parseInteractiveLaunch(alloc, case.args, command_catalog);
        switch (parsed) {
            .interactive => |value| {
                var launch = value;
                defer launch.deinit(alloc);
                const target = launch.requested_resume orelse return error.TestExpectedResumeTarget;
                if (case.expected_id) |expected_id| switch (target) {
                    .id => |id| try std.testing.expectEqualStrings(expected_id, id),
                    .pick, .last => return error.TestExpectedExactResumeId,
                } else try std.testing.expectEqual(ResumeTarget.last, target);
            },
            .noninteractive => |value| {
                var noninteractive = value;
                defer noninteractive.deinit(alloc);
                return error.TestExpectedInteractiveLaunch;
            },
        }
    }

    try std.testing.expectError(
        error.InvalidResumeArgs,
        parseInteractiveLaunch(
            alloc,
            &.{ @constCast("--resume"), @constCast("one"), @constCast("two") },
            command_catalog,
        ),
    );
    try std.testing.expectError(
        error.MissingAddDirectoryValue,
        parseInteractiveLaunch(alloc, &.{@constCast("--add-dir")}, command_catalog),
    );
}

test "parse workflow args consumes leading flags and joins remaining context exactly" {
    var opts = try parseWorkflowArgs(std.testing.allocator, &.{
        @constCast("--auto"),
        @constCast("--create"),
        @constCast("ready"),
        @constCast("for"),
        @constCast("review"),
    });
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.auto_permission);
    try std.testing.expect(opts.create);
    try std.testing.expectEqualStrings("ready for review", opts.context);

    var later_flag = try parseWorkflowArgs(std.testing.allocator, &.{
        @constCast("context"),
        @constCast("--auto"),
    });
    defer later_flag.deinit(std.testing.allocator);
    try std.testing.expect(!later_flag.auto_permission);
    try std.testing.expect(!later_flag.create);
    try std.testing.expectEqualStrings("context --auto", later_flag.context);

    var empty = try parseWorkflowArgs(std.testing.allocator, &.{});
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", empty.context);
}

test "runIfRequested help writes top-level help" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("help")}, testConfig(), capture.deps());
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expect(std.mem.startsWith(u8, capture.stdout.written(), "𝒇x v0.0.0\nFast, native coding agent for the terminal."));
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), testConfig().version) != null);
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "top-level MCP add mutates through the focused provider without startup" {
    const alloc = std.testing.allocator;
    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();
    var cfg = testConfig();
    cfg.add_mcp_profile_server = captureMcpProfileAddForTest;
    mcp_profile_add_calls_for_test = 0;
    var deps = capture.deps();
    deps.load_startup_state = failingStartupState;

    const result = try runIfRequestedWithDeps(
        alloc,
        &.{
            @constCast("mcp"),
            @constCast("add"),
            @constCast("fixture"),
            @constCast("node"),
            @constCast("server.js"),
        },
        cfg,
        deps,
    );
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expectEqual(@as(usize, 1), mcp_profile_add_calls_for_test);
    try std.testing.expectEqualStrings(
        "Saved MCP server 'fixture' to /tmp/test-home/.fx/mcp.json.\n",
        capture.stdout.written(),
    );
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "top-level MCP list loads configuration without discovery and remove uses its provider" {
    const alloc = std.testing.allocator;
    {
        var capture = CaptureOutput.init(alloc);
        defer capture.deinit();
        var cfg = testConfig();
        cfg.load_mcp_runtime = configuredMcpRuntimeForTest;
        var deps = capture.deps();
        deps.load_startup_state_without_credentials = stubLoadStartupStateWithoutCredentials;

        const result = try runIfRequestedWithDeps(
            alloc,
            &.{ @constCast("mcp"), @constCast("list") },
            cfg,
            deps,
        );
        try std.testing.expectEqual(RunResult.handled_success, result);
        try std.testing.expect(std.mem.find(
            u8,
            capture.stdout.written(),
            "fixture source=profile scope=profile",
        ) != null);
        try std.testing.expect(std.mem.find(
            u8,
            capture.stdout.written(),
            "state=disconnected",
        ) != null);
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }

    {
        var capture = CaptureOutput.init(alloc);
        defer capture.deinit();
        var cfg = testConfig();
        cfg.remove_mcp_profile_server = captureMcpProfileRemoveForTest;
        mcp_profile_remove_calls_for_test = 0;

        const result = try runIfRequestedWithDeps(
            alloc,
            &.{ @constCast("mcp"), @constCast("remove"), @constCast("fixture") },
            cfg,
            capture.deps(),
        );
        try std.testing.expectEqual(RunResult.handled_success, result);
        try std.testing.expectEqual(@as(usize, 1), mcp_profile_remove_calls_for_test);
        try std.testing.expectEqualStrings(
            "Removed MCP server 'fixture' from /tmp/test-home/.fx/mcp.json.\n",
            capture.stdout.written(),
        );
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }
}

test "top-level MCP trust persists project approval without interactive startup" {
    const alloc = std.testing.allocator;
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    try environ.put("HOME", home);
    try environ.put("PATH", "");
    const stable_environ = try stableCliTestEnviron();
    io_mod.setEnvironMap(&environ);
    defer io_mod.setEnvironMap(stable_environ);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();
    var deps = capture.deps();
    deps.load_startup_state_without_credentials = failingStartupStateWithoutCredentials;

    const result = try runIfRequestedWithDeps(
        alloc,
        &.{ @constCast("mcp"), @constCast("trust"), @constCast("approve"), @constCast("fixture") },
        testConfig(),
        deps,
    );
    try std.testing.expectEqual(RunResult.handled_success, result);
    const expected = try std.fmt.allocPrint(
        alloc,
        "Approved project MCP server 'fixture' for {s}.\n",
        .{workspace_root},
    );
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, capture.stdout.written());
    try std.testing.expectEqualStrings("", capture.stderr.written());

    var choices = try config_runtime.loadProjectMcpChoices(alloc, workspace_root);
    defer choices.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), choices.choices.approved.len);
    try std.testing.expectEqualStrings("fixture", choices.choices.approved[0]);
}

test "workspace launch modifiers preserve supported command help" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    const deps = capture.deps();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("--add-dir"), @constCast("/tmp/shared"), @constCast("ask"), @constCast("--help") },
        testConfig(),
        deps,
    );
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expect(std.mem.startsWith(u8, capture.stdout.written(), "fx ask\n\n"));
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "workspace launch modifiers still reject unsupported local command help" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    const deps = capture.deps();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("--add-dir"), @constCast("/tmp/shared"), @constCast("status"), @constCast("--help") },
        testConfig(),
        deps,
    );
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expect(std.mem.find(u8, capture.stderr.written(), "only supported for interactive, resume, ask, ACP, PR, and issue launches") != null);
}

test "global workspace launch option errors use user-facing copy" {
    const cases = [_]struct {
        args: []const [:0]const u8,
        expected: []const u8,
    }{
        .{
            .args = &.{@constCast("--add-dir")},
            .expected = "fx: --add-dir requires a directory path\n",
        },
        .{
            .args = &.{ @constCast("--no-additional-dirs"), @constCast("--no-additional-dirs") },
            .expected = "fx: --no-additional-dirs may only be specified once\n",
        },
    };

    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();
        const deps = capture.deps();

        const result = try runIfRequestedWithDeps(std.testing.allocator, case.args, testConfig(), deps);
        try std.testing.expectEqual(RunResult.handled_failure, result);
        try std.testing.expectEqualStrings("", capture.stdout.written());
        try std.testing.expect(std.mem.startsWith(u8, capture.stderr.written(), case.expected));
        try std.testing.expect(std.mem.endsWith(u8, capture.stderr.written(), "<command>\n"));
    }
}

test "runIfRequested version flags write configured version" {
    const cases = [_][]const [:0]const u8{
        &.{@constCast("--version")},
        &.{@constCast("-v")},
    };

    for (cases) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(std.testing.allocator, args, testConfig(), capture.deps());
        try std.testing.expectEqual(RunResult.handled_success, result);
        try std.testing.expectEqualStrings("0.0.0\n", capture.stdout.written());
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }
}

test "runIfRequested version flags reject extra args" {
    const cases = [_][]const [:0]const u8{
        &.{ @constCast("--version"), @constCast("extra") },
        &.{ @constCast("-v"), @constCast("extra") },
    };

    for (cases) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(std.testing.allocator, args, testConfig(), capture.deps());
        try std.testing.expectEqual(RunResult.handled_failure, result);
        try std.testing.expectEqualStrings("", capture.stdout.written());
        try std.testing.expectEqualStrings("usage: fx --version\n", capture.stderr.written());
    }
}

test "setup is a paste-only stored-key adapter" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var cfg = testConfig();
    cfg.secret_store = capture.secretStore();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("setup")},
        cfg,
        capture.deps(),
    );

    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expectEqual(@as(usize, 1), capture.setup_store_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.setup_read_calls);
    try std.testing.expect(capture.setup_value_matched);
    try std.testing.expect(std.mem.find(u8, capture.stderr.written(), "Paste AI Gateway API key") != null);
    try std.testing.expect(std.mem.find(u8, capture.stderr.written(), "Vercel CLI") == null);
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), cfg.secret_store.backend_label) != null);
}

test "setup delegates secure input to an interactive host store" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    capture.setup_interactive_store = true;
    var cfg = testConfig();
    cfg.secret_store = capture.secretStore();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("setup")},
        cfg,
        capture.deps(),
    );

    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expectEqual(@as(usize, 1), capture.setup_store_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.setup_read_calls);
    try std.testing.expect(!capture.setup_value_matched);
}

test "setup preserves the disabled secret-store failure" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    capture.setup_store_disabled = true;
    var cfg = testConfig();
    cfg.secret_store = capture.secretStore();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("setup")},
        cfg,
        capture.deps(),
    );

    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqual(@as(usize, 0), capture.setup_store_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.setup_read_calls);
    try std.testing.expectEqualStrings(
        "fx setup: stored API keys are disabled by FX_DISABLE_KEYCHAIN\n",
        capture.stderr.written(),
    );
}

test "workspace indeterminate errors report the reconciled durable state" {
    const cases = [_]struct {
        reconciliation: workspace_commands.Reconciliation,
        expected: []const u8,
    }{
        .{
            .reconciliation = .{ .intended = .{} },
            .expected = "reloaded settings match the requested update",
        },
        .{
            .reconciliation = .{ .previous = .{} },
            .expected = "reloaded settings match the previous state",
        },
        .{
            .reconciliation = .unconfirmed,
            .expected = "reloaded settings match neither the requested nor previous state",
        },
    };

    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();
        try writeWorkspaceIndeterminateError(
            std.testing.allocator,
            capture.deps(),
            &.{@constCast("--json")},
            case.reconciliation,
        );
        try std.testing.expect(std.mem.find(u8, capture.stdout.written(), case.expected) != null);
        try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"code\":\"SettingsCommitIndeterminate\"") != null);
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }
}

test "workspace json errors keep stable codes with shared user-facing copy" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try writeWorkspaceCommandError(
        std.testing.allocator,
        testCommandCatalog(),
        capture.deps(),
        &.{@constCast("--json")},
        error.PrimaryDirectory,
    );
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"error\":\"the primary workspace cannot be added or removed\"") != null);
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"code\":\"PrimaryDirectory\"") != null);
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "workspace unknown directory errors keep stable json codes" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try writeWorkspaceCommandError(
        std.testing.allocator,
        testCommandCatalog(),
        capture.deps(),
        &.{@constCast("--json")},
        error.UnknownAdditionalDirectory,
    );
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"error\":\"directory is not configured as an additional workspace\"") != null);
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"code\":\"UnknownAdditionalDirectory\"") != null);
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "runIfRequested rejects removed record flag as unknown input" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try std.testing.expectError(
        error.UnknownCliCommand,
        runIfRequestedWithDeps(
            std.testing.allocator,
            &.{@constCast("--record")},
            testConfig(),
            capture.deps(),
        ),
    );

    try std.testing.expect(std.mem.find(u8, capture.stderr.written(), "fx: unknown subcommand: --record") != null);
}

test "runNoConfigIfRequested handles help without config" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try std.testing.expect(try runNoConfigIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("help")},
        "0.0.0",
        testCommandCatalog(),
        capture.deps(),
    ));
    try std.testing.expect(std.mem.startsWith(u8, capture.stdout.written(), "𝒇x v0.0.0\nFast, native coding agent for the terminal."));
    try std.testing.expectEqualStrings("", capture.stderr.written());

    try std.testing.expect(!try runNoConfigIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("status")},
        "0.0.0",
        testCommandCatalog(),
        capture.deps(),
    ));
}

test "CLI surface uses the supplied command catalog for parsing usage and help" {
    const specs = [_]command_specs.TopLevelSpec{
        .{
            .kind = .help,
            .token = "guide",
            .aliases = &.{"-?"},
            .usage = "guide",
            .summary = "Show injected help",
        },
        .{
            .kind = .setup,
            .token = "start",
            .usage = "start",
            .summary = "Run injected setup",
        },
    };
    const help_groups = [_]command_specs.TopLevelHelpGroup{
        .{ .entries = &.{
            .{ .kind = .setup, .usage = "start" },
            .{ .kind = .help, .usage = "guide" },
        } },
    };
    const command_catalog = CommandCatalog{
        .specs = &specs,
        .description = "Injected command catalog.",
        .interactive_hint = "Injected interactive hint.",
        .help_groups = &help_groups,
    };

    try std.testing.expectEqual(Command.help, parse(command_catalog, &.{@constCast("-?")}));
    switch (parse(command_catalog, &.{@constCast("start")})) {
        .setup => {},
        else => return error.TestExpectedEqual,
    }

    var help_capture = CaptureOutput.init(std.testing.allocator);
    defer help_capture.deinit();
    try std.testing.expect(try runNoConfigIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("guide")},
        "1.2.3",
        command_catalog,
        help_capture.deps(),
    ));
    try std.testing.expect(std.mem.find(u8, help_capture.stdout.written(), "Injected command catalog.") != null);

    var usage_capture = CaptureOutput.init(std.testing.allocator);
    defer usage_capture.deinit();
    var cfg = testConfig();
    cfg.command_catalog = command_catalog;
    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("start"), @constCast("unexpected") },
        cfg,
        usage_capture.deps(),
    );
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("usage: fx start\n", usage_capture.stderr.written());
}

test "workflow config does not carry placeholder gateway tools" {
    const skill_roots = [_]skill_contract.RootSpec{
        .{ .source = .workspace_shared, .path = "skills" },
    };
    var chat_url_probe = ChatUrlProbe{};
    var surface_cfg = testConfig();
    surface_cfg.skill_root_policy.workspace_roots = &skill_roots;
    surface_cfg.gateway_provider.chat_url = chat_url_probe.provider();
    const cfg = workflowConfig(surface_cfg);
    try std.testing.expect(!@hasField(@TypeOf(cfg), "gateway_tools_json"));
    try std.testing.expect(!@hasField(@TypeOf(cfg), "context_registry"));
    try std.testing.expectEqualStrings("test-model", cfg.default_model);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/chat", cfg.gateway_chat_url);
    try std.testing.expect(chat_url_probe.called);
    try std.testing.expectEqualStrings("surface", cfg.mode_registry.default_mode_id);
    try std.testing.expectEqualStrings("skills", cfg.skill_root_policy.workspace_roots[0].path);
    try std.testing.expect(cfg.load_mcp_runtime == noMcpRuntimeForTest);
}
test "runIfRequested invalid local flags write usage" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("status"), @constCast("--wat") }, testConfig(), capture.deps());
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expectEqualStrings("usage: fx status [--json]\n", capture.stderr.written());
}

test "runIfRequested invalid json local flags write json error" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("status"), @constCast("--json"), @constCast("--wat") }, testConfig(), capture.deps());
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("", capture.stderr.written());
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"kind\":\"status\"") != null);
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"code\":\"InvalidLocalSurfaceArgs\"") != null);
}

test "runIfRequested resume no args returns last target" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("resume")}, testConfig(), capture.deps());
    switch (result) {
        .interactive => |launch| try std.testing.expectEqual(ResumeTarget.last, launch.requested_resume.?),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "runIfRequested -r asks which session to resume" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("-r")},
        testConfig(),
        capture.deps(),
    );
    switch (result) {
        .interactive => |launch| try std.testing.expectEqual(ResumeTarget.pick, launch.requested_resume.?),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expectEqualStrings("", capture.stderr.written());

    var extra_capture = CaptureOutput.init(std.testing.allocator);
    defer extra_capture.deinit();
    const extra = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("-r"), @constCast("session.123") },
        testConfig(),
        extra_capture.deps(),
    );
    try std.testing.expectEqual(RunResult.handled_failure, extra);
}

test "runIfRequested top-level resume aliases return the existing target" {
    const aliases = [_][]const [:0]const u8{
        &.{@constCast("--resume")},
        &.{@constCast("--resume-last")},
        &.{@constCast("--continue")},
        &.{@constCast("-c")},
    };
    for (aliases) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(
            std.testing.allocator,
            args,
            testConfig(),
            capture.deps(),
        );
        switch (result) {
            .interactive => |launch| try std.testing.expectEqual(ResumeTarget.last, launch.requested_resume.?),
            else => return error.TestExpectedEqual,
        }
        try std.testing.expectEqualStrings("", capture.stdout.written());
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }

    var operand_capture = CaptureOutput.init(std.testing.allocator);
    defer operand_capture.deinit();

    const operand = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("--resume"), @constCast("session.123") },
        testConfig(),
        operand_capture.deps(),
    );
    switch (operand) {
        .interactive => |launch_value| {
            var launch = launch_value;
            defer launch.deinit(std.testing.allocator);
            switch (launch.requested_resume.?) {
                .id => |id| try std.testing.expectEqualStrings("session.123", id),
                .pick, .last => return error.TestExpectedExactResumeId,
            }
        },
        else => return error.TestExpectedEqual,
    }

    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const exact = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("--resume-session.123")},
        testConfig(),
        capture.deps(),
    );
    switch (exact) {
        .interactive => |launch_value| {
            var launch = launch_value;
            defer launch.deinit(std.testing.allocator);
            switch (launch.requested_resume.?) {
                .id => |id| try std.testing.expectEqualStrings("session.123", id),
                .pick, .last => return error.TestExpectedExactResumeId,
            }
        },
        else => return error.TestExpectedEqual,
    }

    const nested = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("resume"), @constCast("--resume"), @constCast("--last") },
        testConfig(),
        capture.deps(),
    );
    switch (nested) {
        .interactive => |launch| try std.testing.expectEqual(ResumeTarget.last, launch.requested_resume.?),
        else => return error.TestExpectedEqual,
    }
}

test "runIfRequested rejects malformed resume aliases with canonical usage" {
    const cases = [_][]const [:0]const u8{
        &.{@constCast("--resume-")},
        &.{ @constCast("--resume-last"), @constCast("unexpected") },
        &.{ @constCast("--continue"), @constCast("unexpected") },
        &.{ @constCast("--resume"), @constCast("   ") },
        &.{ @constCast("resume"), @constCast("--resume") },
    };
    for (cases) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(
            std.testing.allocator,
            args,
            testConfig(),
            capture.deps(),
        );
        try std.testing.expectEqual(RunResult.handled_failure, result);
        try std.testing.expectEqualStrings(
            "usage: fx session resume [last|<id>] | session resume --id <id> | --resume [last|<id>] | resume [last|<id>] | resume --id <id> | --resume-last | --continue | -c | -r | --resume-<id>\n",
            capture.stderr.written(),
        );
    }
}

test "runIfRequested resume id returns owned id" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("resume"), @constCast("abc123") }, testConfig(), capture.deps());
    switch (result) {
        .interactive => |launch_value| {
            var launch = launch_value;
            defer launch.deinit(std.testing.allocator);
            switch (launch.requested_resume.?) {
                .id => |value| try std.testing.expectEqualStrings("abc123", value),
                else => return error.TestExpectedEqual,
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "runIfRequested invalid resume writes usage" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("resume"), @constCast("a"), @constCast("b") }, testConfig(), capture.deps());
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings(
        "usage: fx session resume [last|<id>] | session resume --id <id> | --resume [last|<id>] | resume [last|<id>] | resume --id <id> | --resume-last | --continue | -c | -r | --resume-<id>\n",
        capture.stderr.written(),
    );
}

test "runIfRequested unknown command writes header and help" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try std.testing.expectError(
        error.UnknownCliCommand,
        runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("wat")}, testConfig(), capture.deps()),
    );
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr.written(), "fx: unknown subcommand: wat\n\n𝒇x v0.0.0\nFast, native coding agent for the terminal.\n"));
}

test "runIfRequested bare version subcommand remains unknown" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try std.testing.expectError(
        error.UnknownCliCommand,
        runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("version")}, testConfig(), capture.deps()),
    );
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr.written(), "fx: unknown subcommand: version\n\n𝒇x v0.0.0\nFast, native coding agent for the terminal.\n"));
}

test "runIfRequested model fetch failure is handled" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = ModelFetchProbe{ .outcome = .failure };
    var cfg = testConfig();
    cfg.provider_set.gateway.cli_model_catalog = probe.provider();

    var deps = capture.deps();
    deps.load_startup_state = stubLoadStartupState;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("models")}, cfg, deps);
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings(
        "fx models: could not list models: Unavailable\n",
        capture.stderr.written(),
    );
}

test "runIfRequested model fetch failure preserves json output" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = ModelFetchProbe{ .outcome = .failure };
    var cfg = testConfig();
    cfg.provider_set.gateway.cli_model_catalog = probe.provider();

    var deps = capture.deps();
    deps.load_startup_state = stubLoadStartupState;

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("models"), @constCast("--json") },
        cfg,
        deps,
    );
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"models\",\"error\":\"could not list models: Unavailable\",\"code\":\"Unavailable\"}\n",
        capture.stdout.written(),
    );
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "runIfRequested model provider cancellation is handled" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = ModelFetchProbe{ .outcome = .cancelled };
    var cfg = testConfig();
    cfg.provider_set.gateway.cli_model_catalog = probe.provider();

    var deps = capture.deps();
    deps.load_startup_state = stubLoadStartupState;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("models")}, cfg, deps);
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings(
        "fx models: could not list models: the request was cancelled\n",
        capture.stderr.written(),
    );
}

test "runIfRequested models passes startup team to fetch seam" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = ModelFetchProbe{};
    var cfg = testConfig();
    cfg.provider_set.gateway.cli_model_catalog = probe.provider();

    var deps = capture.deps();
    deps.load_startup_state = stubLoadStartupState;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("models"), @constCast("--json") }, cfg, deps);
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expect(probe.called);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"models\",\"count\":1,\"shown_count\":1,\"more_count\":0,\"private_models_hidden\":false,\"ids\":[\"private/blue-hornbill\"]}\n",
        capture.stdout.written(),
    );
}

test "runIfRequested credits renders through the configured provider" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = CreditsProviderProbe{ .outcome = .success };
    var cfg = testConfig();
    cfg.provider_set.gateway.credits = probe.provider();

    var deps = capture.deps();
    deps.load_startup_state = stubLoadStartupState;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("credits"), @constCast("--json") }, cfg, deps);
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.saw_expected_input);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"credits\",\"balance\":\"10\",\"used\":\"2\",\"plan\":\"pro\"}\n",
        capture.stdout.written(),
    );
}

test "runIfRequested credits failures use nonzero text and json contracts" {
    var text_capture = CaptureOutput.init(std.testing.allocator);
    defer text_capture.deinit();
    var text_probe = CreditsProviderProbe{ .outcome = .failure };
    var text_cfg = testConfig();
    text_cfg.provider_set.gateway.credits = text_probe.provider();
    var text_deps = text_capture.deps();
    text_deps.load_startup_state = stubLoadStartupState;

    const text_result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("credits")},
        text_cfg,
        text_deps,
    );
    try std.testing.expectEqual(RunResult.handled_failure, text_result);
    try std.testing.expectEqualStrings("", text_capture.stdout.written());
    try std.testing.expectEqualStrings(
        "[credits] error: gateway unavailable\n",
        text_capture.stderr.written(),
    );

    var json_capture = CaptureOutput.init(std.testing.allocator);
    defer json_capture.deinit();
    var json_probe = CreditsProviderProbe{ .outcome = .failure };
    var json_cfg = testConfig();
    json_cfg.provider_set.gateway.credits = json_probe.provider();
    var json_deps = json_capture.deps();
    json_deps.load_startup_state = stubLoadStartupState;

    const json_result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("credits"), @constCast("--json") },
        json_cfg,
        json_deps,
    );
    try std.testing.expectEqual(RunResult.handled_failure, json_result);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"credits\",\"error\":\"gateway unavailable\"}\n",
        json_capture.stdout.written(),
    );
    try std.testing.expectEqualStrings("", json_capture.stderr.written());
}

test "runIfRequested local json success appends exactly one newline" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    var deps = capture.deps();
    deps.load_startup_status = stubLoadStartupStatus;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("status"), @constCast("--json") }, testConfig(), deps);
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"status\",\"model\":\"test-model\",\"update_channel\":\"stable\",\"build_channel\":\"stable\",\"build_revision\":\"\",\"auth\":\"missing\",\"auth_refreshable\":false,\"auth_help\":\"fx needs access to Vercel AI Gateway. Run fx login to sign in, fx setup to use an API key, or set AI_GATEWAY_API_KEY.\",\"permission_mode\":\"auto\",\"workspace\":\"/tmp/fx\",\"history_turns\":0,\"session_permission_grants\":0,\"agent_step_limit\":42,\"mcp\":{\"connection_check\":\"not_checked\",\"servers\":[],\"configuration_issues\":[],\"inspection_error\":null}}\n",
        capture.stdout.written(),
    );
    try std.testing.expect(!std.mem.endsWith(u8, capture.stdout.written(), "\n\n"));
}

test "status and doctor inspect MCP configuration once per command" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    try environ.put("HOME", home);
    try environ.put("PATH", "");
    const stable_environ = try stableCliTestEnviron();
    io_mod.setEnvironMap(&environ);
    defer io_mod.setEnvironMap(stable_environ);

    mcp_local_inspection_calls_for_test = 0;
    var cfg = testConfig();
    cfg.inspect_mcp_local_config = failingMcpLocalInspectionForTest;

    var status_capture = CaptureOutput.init(alloc);
    defer status_capture.deinit();
    var status_deps = status_capture.deps();
    status_deps.load_startup_status = stubLoadStartupStatus;
    const status_result = try runIfRequestedWithDeps(
        alloc,
        &.{ @constCast("status"), @constCast("--json") },
        cfg,
        status_deps,
    );
    try std.testing.expectEqual(RunResult.handled_success, status_result);
    try std.testing.expectEqual(@as(usize, 1), mcp_local_inspection_calls_for_test);
    try std.testing.expect(std.mem.find(
        u8,
        status_capture.stdout.written(),
        "\"mcp_config_error\":\"McpConfigInvalidJson\"",
    ) != null);

    mcp_local_inspection_calls_for_test = 0;
    var doctor_capture = CaptureOutput.init(alloc);
    defer doctor_capture.deinit();
    const doctor_result = try runIfRequestedWithDeps(
        alloc,
        &.{ @constCast("doctor"), @constCast("--json") },
        cfg,
        doctor_capture.deps(),
    );
    try std.testing.expectEqual(RunResult.handled_success, doctor_result);
    try std.testing.expectEqual(@as(usize, 1), mcp_local_inspection_calls_for_test);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            doctor_capture.stdout.written(),
            "\"name\":\"mcp_config\"",
        ),
    );
    try std.testing.expect(std.mem.find(
        u8,
        doctor_capture.stdout.written(),
        "\"detail\":\"failed to load ~/.fx/mcp.json: McpConfigInvalidJson\"",
    ) != null);
}

test "writeRenderedJsonLine falls back to heap and appends exactly one newline" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    var tiny_buf: [8]u8 = undefined;
    const startup = app_lifecycle.StartupStatus{
        .workspace_root = @constCast("/tmp/fx"),
        .selected_model = "test-model",
        .permission_mode = .ask,
        .agent_step_limit = 42,
    };

    try writeRenderedJsonLine(
        std.testing.allocator,
        capture.deps(),
        tiny_buf[0..],
        .{ .status = statusSnapshotFromStartup(startup) },
    );

    try std.testing.expectEqualStrings(
        "{\"kind\":\"status\",\"model\":\"test-model\",\"update_channel\":\"stable\",\"build_channel\":\"stable\",\"build_revision\":\"\",\"auth\":\"missing\",\"auth_refreshable\":false,\"auth_help\":\"fx needs access to Vercel AI Gateway. Run fx login to sign in, fx setup to use an API key, or set AI_GATEWAY_API_KEY.\",\"permission_mode\":\"ask\",\"workspace\":\"/tmp/fx\",\"history_turns\":0,\"session_permission_grants\":0,\"agent_step_limit\":42}\n",
        capture.stdout.written(),
    );
}

test "writeRenderedJsonLine renders doctor json through output contract" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    var checks = [_]doctor_runtime.Check{
        .{ .name = "auth", .status = .ok, .detail = "AI_GATEWAY_API_KEY is configured" },
        .{ .name = "gh", .status = .warn, .detail = "GitHub CLI not found in PATH" },
    };
    const snapshot = doctor_runtime.Snapshot{
        .workspace_root = @constCast("/tmp/fx"),
        .model = "test-model",
        .auth = .{ .active_source = .ai_gateway_api_key },
        .permission_mode = .auto,
        .agent_step_limit = 42,
        .checks = checks[0..],
    };

    var tiny_buf: [8]u8 = undefined;
    try writeRenderedJsonLine(
        std.testing.allocator,
        capture.deps(),
        tiny_buf[0..],
        .{ .doctor = doctorSnapshotFromRuntime(snapshot) },
    );

    try std.testing.expectEqualStrings(
        "{\"kind\":\"doctor\",\"ok_count\":1,\"warn_count\":1,\"fail_count\":0,\"workspace\":\"/tmp/fx\",\"model\":\"test-model\",\"auth\":\"AI_GATEWAY_API_KEY\",\"auth_refreshable\":false,\"permission_mode\":\"auto\",\"agent_step_limit\":42,\"checks\":[{\"name\":\"auth\",\"status\":\"ok\",\"detail\":\"AI_GATEWAY_API_KEY is configured\"},{\"name\":\"gh\",\"status\":\"warn\",\"detail\":\"GitHub CLI not found in PATH\"}]}\n",
        capture.stdout.written(),
    );
}

const CaptureOutput = struct {
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,
    setup_store_calls: usize = 0,
    setup_read_calls: usize = 0,
    setup_value_matched: bool = false,
    setup_interactive_store: bool = false,
    setup_store_disabled: bool = false,

    fn init(alloc: Allocator) CaptureOutput {
        return .{
            .stdout = .init(alloc),
            .stderr = .init(alloc),
        };
    }

    fn deinit(self: *@This()) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }

    fn deps(self: *@This()) RunDeps {
        return .{
            .stdout_ctx = self,
            .stderr_ctx = self,
            .setup_ctx = self,
            .write_stdout = captureStdout,
            .write_stderr = captureStderr,
            .read_masked_key = captureReadMaskedKey,
            .setup_terminal_available = captureSetupTerminalAvailable,
        };
    }

    fn secretStore(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "test credential store",
            .is_disabled_fn = captureSecretStoreIsDisabled,
            .load_fn = captureSecretStoreLoad,
            .store_fn = captureSecretStoreWrite,
            .store_interactive_fn = captureSecretStoreInteractiveWrite,
        };
    }
};

fn captureStdout(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    try capture.stdout.writer.writeAll(text);
}

fn captureStderr(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    try capture.stderr.writer.writeAll(text);
}

fn captureSetupTerminalAvailable(_: ?*anyopaque) bool {
    return true;
}

fn captureReadMaskedKey(
    ctx: ?*anyopaque,
    alloc: Allocator,
    _: WriteFn,
    _: ?*anyopaque,
) ![]u8 {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    capture.setup_read_calls += 1;
    return alloc.dupe(u8, "paste-only-test-key");
}

fn captureSecretStoreIsDisabled(ctx: ?*anyopaque) bool {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    return capture.setup_store_disabled;
}

fn captureSecretStoreLoad(
    _: ?*anyopaque,
    _: Allocator,
) host.SecretStoreLoadError!?[]u8 {
    return null;
}

fn captureSecretStoreWrite(
    ctx: ?*anyopaque,
    _: Allocator,
    value: []const u8,
) host.SecretStoreWriteError!void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    capture.setup_store_calls += 1;
    capture.setup_value_matched = std.mem.eql(u8, value, "paste-only-test-key");
}

fn captureSecretStoreInteractiveWrite(
    ctx: ?*anyopaque,
) host.SecretStoreWriteError!bool {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    if (!capture.setup_interactive_store) return false;
    capture.setup_store_calls += 1;
    return true;
}

fn gatherNoopContextForTest(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopStaticContextForTest(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContextForTest(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

const test_surface_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.surface_context",
    .gather_project_context_fn = gatherNoopContextForTest,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContextForTest,
    .append_transient_fn = appendNoopTransientContextForTest,
} };

fn noMcpRuntimeForTest(_: Allocator, _: []const u8, _: @import("../mcp/elicitation.zig").Capabilities) !?*mcp_runtime.McpRuntime {
    return null;
}

fn clearMcpConfigInspectionForTest(
    _: Allocator,
) error{OutOfMemory}!mcp_contract.ProfileConfigDiagnostic {
    return .clear;
}

var mcp_local_inspection_calls_for_test: usize = 0;
var mcp_profile_add_calls_for_test: usize = 0;
var mcp_profile_remove_calls_for_test: usize = 0;

fn captureMcpProfileAddForTest(
    alloc: Allocator,
    intent: mcp_command_provider.AddIntent,
) anyerror!mcp_command_provider.ProfileAddResult {
    mcp_profile_add_calls_for_test += 1;
    switch (intent) {
        .local => |local| {
            try std.testing.expectEqualStrings("fixture", local.name);
            try std.testing.expectEqualStrings("node", local.command);
            try std.testing.expectEqualSlices([]const u8, &.{"server.js"}, local.args);
        },
        .http => return error.TestUnexpectedResult,
    }
    return .{
        .profile_path = try alloc.dupe(u8, "/tmp/test-home/.fx/mcp.json"),
    };
}

fn captureMcpProfileRemoveForTest(
    alloc: Allocator,
    name: []const u8,
) anyerror!mcp_command_provider.ProfileRemoveResult {
    mcp_profile_remove_calls_for_test += 1;
    try std.testing.expectEqualStrings("fixture", name);
    return .{
        .profile_path = try alloc.dupe(u8, "/tmp/test-home/.fx/mcp.json"),
        .removed = true,
    };
}

fn configuredMcpRuntimeForTest(
    alloc: Allocator,
    workspace_root: []const u8,
    _: @import("../mcp/elicitation.zig").Capabilities,
) !?*mcp_runtime.McpRuntime {
    try std.testing.expectEqualStrings("/tmp/fx", workspace_root);
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    errdefer alloc.destroy(runtime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    errdefer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
        .command = try alloc.dupe(u8, "node"),
    });
    return runtime;
}

fn failingMcpLocalInspectionForTest(
    alloc: Allocator,
    workspace_root: []const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    mcp_local_inspection_calls_for_test += 1;
    var result = try mcp_health.inspectLocalConfigUnavailable(
        alloc,
        workspace_root,
    );
    result.profile_diagnostic = .{ .failed = error.McpConfigInvalidJson };
    result.inspection_error = "McpConfigInvalidJson";
    return result;
}

var stable_cli_test_environ: ?*std.process.Environ.Map = null;

fn stableCliTestEnviron() !*const std.process.Environ.Map {
    if (stable_cli_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_cli_test_environ = map;
    return map;
}

fn unexpectedAcpRunForTest(_: ?*anyopaque, _: Allocator, _: acp_runner.Config) anyerror!void {
    return error.TestUnexpectedAcpRun;
}

fn testConfig() Config {
    return .{
        .version = "0.0.0",
        .command_catalog = testCommandCatalog(),
        .default_model = "test-model",
        .default_agent_step_limit = 42,
        .models_path = "/v1/models",
        .gateway_retry_count = 1,
        .gateway_chat_url = "https://example.test/chat",
        .gateway_provider = test_builtin_gateway.provider,
        .provider_set = provider_set.gateway_only(test_builtin_gateway.provider_bundle),
        .url_opener = host.unavailable_url_opener,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "system" },
        .skill_root_policy = .{ .managed_root_source = .global_fx },
        .ignored_list_entries = &.{},
        .max_list_entries = 10,
        .max_read_file_bytes = 1024,
        .max_read_file_lines = 100,
        .max_read_file_line_len = 200,
        .max_command_output_bytes = 4096,
        .max_tool_result_bytes = 4096,
        .max_history_turns = 8,
        .context_registry = test_surface_context_registry,
        .mode_registry = .{ .default_mode_id = "surface" },
        .inspect_mcp_profile_config = clearMcpConfigInspectionForTest,
        .load_mcp_runtime = noMcpRuntimeForTest,
        .acp_runner = .{ .run_fn = unexpectedAcpRunForTest },
        .tool_set = .{
            .registry = .{ .tools = &.{} },
            .order = &.{},
            .read_only_tool_names = &.{},
        },
    };
}

fn stubLoadStartupState(
    alloc: Allocator,
    _: oauth_transport.Provider,
    _: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/fx");
    state.selected_model = try alloc.dupe(u8, default_model);
    state.credential = .{
        .token = try alloc.dupe(u8, "test-key"),
        .source = .ai_gateway_api_key,
    };
    state.credential.?.team_id = try alloc.dupe(u8, "team_123");
    return state;
}

fn stubLoadStartupStateWithoutCredentials(
    alloc: Allocator,
    _: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{
        .agent_step_limit = default_agent_step_limit,
    };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/fx");
    return state;
}

fn failingStartupStateWithoutCredentials(
    _: Allocator,
    _: []const u8,
    _: usize,
) !app_lifecycle.StartupState {
    return error.StartupShouldNotRun;
}

fn stubLoadStartupStatus(
    alloc: Allocator,
    _: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupStatus {
    const workspace_root = try alloc.dupe(u8, "/tmp/fx");
    errdefer alloc.free(workspace_root);
    const selected_model = try alloc.dupe(u8, default_model);
    errdefer alloc.free(selected_model);
    return .{
        .workspace_root = workspace_root,
        .selected_model = selected_model,
        .owned_selected_model = selected_model,
        .permission_mode = config_runtime.default_permission_mode,
        .agent_step_limit = default_agent_step_limit,
    };
}

fn failingStartupState(
    _: Allocator,
    _: oauth_transport.Provider,
    _: host.SecretStore,
    _: []const u8,
    _: usize,
) !app_lifecycle.StartupState {
    return error.StartupShouldNotRun;
}

const ModelFetchProbe = struct {
    const Outcome = enum {
        success,
        failure,
        cancelled,
    };

    called: bool = false,
    outcome: Outcome = .success,

    fn provider(self: *ModelFetchProbe) gateway_provider.CliModelCatalogProvider {
        return .{
            .context = self,
            .fetch_fn = fetch,
        };
    }

    fn failure(
        input: gateway_provider.CliModelCatalogInput,
        category: model_catalog.FailureCategory,
    ) gateway_provider.CliModelCatalogResult {
        return .{ .failure = .{
            .access = .init(input.access),
            .anonymous_fallback_used = false,
            .failure = .{ .category = category },
        } };
    }

    fn fetch(
        raw: ?*anyopaque,
        alloc: Allocator,
        input: gateway_provider.CliModelCatalogInput,
    ) gateway_provider.CliModelCatalogResult {
        const self: *ModelFetchProbe = @ptrCast(@alignCast(raw.?));
        self.called = true;
        if (!std.mem.eql(u8, input.access.authorizationCredential() orelse "", "test-key") or
            !std.mem.eql(u8, input.access.teamContext() orelse "", "team_123") or
            input.access.credentialSource() != .ai_gateway_api_key or
            !std.mem.eql(u8, input.endpoint, "/v1/models") or
            input.cancel_flag != null)
        {
            return failure(input, .runtime);
        }

        switch (self.outcome) {
            .failure => return failure(input, .runtime),
            .cancelled => return failure(input, .cancellation),
            .success => {},
        }

        var ids: std.ArrayList([]u8) = .empty;
        const id = alloc.dupe(u8, "private/blue-hornbill") catch {
            return failure(input, .resource_exhausted);
        };
        ids.append(alloc, id) catch {
            alloc.free(id);
            return failure(input, .resource_exhausted);
        };
        return .{ .loaded = .{
            .ids = ids,
            .provenance = .{ .access = .init(input.access) },
        } };
    }
};

const ChatUrlProbe = struct {
    called: bool = false,

    fn provider(self: *ChatUrlProbe) gateway_provider.ChatUrlProvider {
        return .{
            .context = self,
            .resolve_fn = resolve,
        };
    }

    fn resolve(raw: ?*anyopaque, fallback: []const u8) []const u8 {
        const self: *ChatUrlProbe = @ptrCast(@alignCast(raw.?));
        self.called = std.mem.eql(u8, fallback, "https://example.test/chat");
        return "http://127.0.0.1:43123/chat";
    }
};

const CreditsProviderProbe = struct {
    outcome: enum { success, failure },
    calls: usize = 0,
    saw_expected_input: bool = false,

    fn provider(self: *CreditsProviderProbe) gateway_provider.CreditsProvider {
        return .{
            .context = self,
            .fetch_fn = fetch,
        };
    }

    fn fetch(
        raw: ?*anyopaque,
        alloc: Allocator,
        input: gateway_provider.CreditsLookupInput,
    ) output_contracts.CreditsSnapshot {
        const self: *CreditsProviderProbe = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.saw_expected_input =
            std.mem.eql(u8, input.credential orelse "", "test-key") and
            std.mem.eql(u8, input.tenant orelse "", "team_123");
        if (self.outcome == .failure) {
            return ownedCreditsErrorSnapshot(alloc, "gateway unavailable");
        }

        var snapshot = output_contracts.CreditsSnapshot{};
        snapshot.balance = alloc.dupe(u8, "10") catch return ownedCreditsErrorSnapshot(alloc, "invalid JSON response from gateway");
        snapshot.used = alloc.dupe(u8, "2") catch {
            snapshot.deinit(alloc);
            return ownedCreditsErrorSnapshot(alloc, "invalid JSON response from gateway");
        };
        snapshot.plan = alloc.dupe(u8, "pro") catch {
            snapshot.deinit(alloc);
            return ownedCreditsErrorSnapshot(alloc, "invalid JSON response from gateway");
        };
        return snapshot;
    }
};

fn ownedCreditsErrorSnapshot(alloc: Allocator, message: []const u8) output_contracts.CreditsSnapshot {
    return .{ .err_message = alloc.dupe(u8, message) catch null };
}

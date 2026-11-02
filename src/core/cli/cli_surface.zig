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
const cli_flags = @import("cli_flags.zig");
const completion = @import("completion.zig");
const agent_run_flags = @import("agent_run_flags.zig");
const flag_placement = @import("flag_placement.zig");
const cli_config = @import("cli_config.zig");
const settings_messages = @import("settings_messages.zig");
const settings_entries = @import("../config/settings_entries.zig");
const settings_keys = @import("../config/settings_keys.zig");
const settings_schema = @import("../config/settings_schema.zig");
const builtin_commands = @import("../../builtins/commands.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const collections = @import("../shared/collections.zig");
const config_runtime = @import("../config/config_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const doctor_runtime = @import("doctor_runtime.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_catalog_metadata = @import("../gateway/model_catalog_metadata.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
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
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const session_adapter = @import("../session/session_adapter.zig");
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
const mcp_health = @import("../mcp/health.zig");
const project_config = @import("../mcp/project_config.zig");
const mcp_host = @import("../mcp_host/host.zig");
const mcp_verbs = @import("../mcp_host/verbs.zig");
const text_utils = @import("../shared/text_utils.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");
const usage = @import("../../usage/usage.zig");
const usage_host = @import("../app/usage_host.zig");

const slack_install = @import("../slack/install.zig");
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
    slack: []const [:0]const u8,
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
    config: []const [:0]const u8,
    completion: []const [:0]const u8,
    unknown: []const u8,
};

const ResumeInvocation = struct {
    args: []const [:0]const u8,
    top_level_alias: bool = false,
    /// Set for `fx resume`, which only the upgrade relaunch may still use: an
    /// older fx that installs this version restarts it with
    /// `fx resume <id> --upgrade-relaunch`.
    legacy_command: bool = false,
};

/// Prefix of the removed `--resume-<id>` alias, matched only to explain the
/// replacement.
const resume_id_alias_prefix = "--resume-";
pub const upgrade_relaunch_arg = "--upgrade-relaunch";

pub const UpgradeRelaunch = struct {
    previous_revision: ?[]u8 = null,

    pub fn deinit(self: *UpgradeRelaunch, alloc: Allocator) void {
        if (self.previous_revision) |revision| alloc.free(revision);
        self.* = undefined;
    }
};

// `-r` is the short form of `--resume`. Given no value, either one opens the
// session picker; given `last` or an ID, it resumes that session.
const resume_short_flag = "-r";
const resume_inline_prefix = "--resume=";

pub const ResumeTarget = union(enum) {
    remembered,
    pick,
    last,
    id: []u8,

    pub fn deinit(self: *ResumeTarget, alloc: Allocator) void {
        switch (self.*) {
            .remembered, .pick, .last => {},
            .id => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

pub const LaunchModifiers = struct {
    context_limit_overrides: []config_runtime.context_limits.Override = &.{},
    additional_directories: [][]u8 = &.{},
    saved_directories_suppressed: bool = false,
    provider_override: ?model_provider.ProviderId = null,
    model_override: ?[]u8 = null,
    effort_override: ?types.ReasoningEffort = null,
    fast_override: ?bool = null,
    ultrafast_override: ?bool = null,
    provider_order_override: ?[][]const u8 = null,
    provider_strict_override: ?bool = null,
    /// `--permission-mode` and its shortcuts; never saved.
    permission_override: ?types.PermissionMode = null,

    pub fn deinit(self: *LaunchModifiers, alloc: Allocator) void {
        if (self.context_limit_overrides.len > 0) alloc.free(self.context_limit_overrides);
        for (self.additional_directories) |path| alloc.free(path);
        if (self.additional_directories.len > 0) alloc.free(self.additional_directories);
        if (self.model_override) |model| alloc.free(model);
        if (self.provider_order_override) |order| freeProviderOrderOverride(alloc, order);
        self.* = .{};
    }

    pub fn hasWorkspaceModifiers(self: LaunchModifiers) bool {
        return self.additional_directories.len > 0 or self.saved_directories_suppressed;
    }

    pub fn hasModelOverrides(self: LaunchModifiers) bool {
        return self.provider_override != null or self.model_override != null or
            self.effort_override != null or self.fast_override != null or
            self.ultrafast_override != null or self.provider_order_override != null or
            self.provider_strict_override != null or self.permission_override != null;
    }

    pub fn hasOnlyUltrafastOverride(self: LaunchModifiers) bool {
        return self.ultrafast_override != null and self.provider_override == null and
            self.model_override == null and self.effort_override == null and
            self.fast_override != true and self.provider_order_override == null and
            self.provider_strict_override == null;
    }
};

fn freeProviderOrderOverride(alloc: Allocator, order: []const []const u8) void {
    for (order) |slug| alloc.free(@constCast(slug));
    if (order.len > 0) alloc.free(order);
}

/// Parses one `--provider-order` value, replacing any earlier occurrence.
/// The returned slice is owned by `alloc`.
fn parseProviderOrderFlag(alloc: Allocator, raw: []const u8, previous: ?[][]const u8) ![][]const u8 {
    const parsed: [][]const u8 = switch (config_runtime.parseProviderOrderList(alloc, raw)) {
        .ok => |maybe| maybe orelse return error.InvalidProviderOrderValue,
        .invalid => return error.InvalidProviderOrderValue,
    };
    if (previous) |old| freeProviderOrderOverride(alloc, old);
    return parsed;
}

pub const InteractiveLaunch = struct {
    requested_resume: ?ResumeTarget = null,
    upgrade_relaunch: ?UpgradeRelaunch = null,
    modifiers: LaunchModifiers = .{},
    /// Why the session the launch resumes could not be converted from v1
    /// (D61), for the message the launch exits with. Owned.
    resume_refusal: ?[]u8 = null,
    /// `fx "<prompt>"`: sent once the session's first frame is on screen.
    /// Owned by the allocator that parsed the launch.
    initial_prompt: ?[]u8 = null,

    pub fn deinit(self: *InteractiveLaunch, alloc: Allocator) void {
        if (self.resume_refusal) |reason| alloc.free(reason);
        if (self.requested_resume) |*target| target.deinit(alloc);
        if (self.upgrade_relaunch) |*relaunch| relaunch.deinit(alloc);
        self.modifiers.deinit(alloc);
        if (self.initial_prompt) |prompt| alloc.free(prompt);
        self.* = undefined;
    }
};

pub const RunResult = union(enum) {
    interactive: InteractiveLaunch,
    handled_success,
    handled_failure,
    handled_exit: u8,
};

/// Result for a command line fx can't accept; see `output_contracts.usage_exit_code`.
const usage_failure: RunResult = .{ .handled_exit = output_contracts.usage_exit_code };

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
    load_mcp_host: ?mcp_host.LoadFn = null,
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

const LoginArgs = struct {
    provider: ?model_provider.ProviderId = null,
    /// Paste an AI Gateway API key instead of signing in through the browser.
    api_key: bool = false,
};

const LoginFlag = enum { api_key };
const login_flag_ids = cli_flags.idTable(LoginFlag, &builtin_commands.login_options);

/// `fx login [vercel|codex|grok] [--api-key]`, in either order.
fn parseLoginArgs(rest: []const [:0]const u8) error{ InvalidLoginProviderArgs, ApiKeyNeedsVercel }!LoginArgs {
    var parsed: LoginArgs = .{};
    var provider_arg: ?[]const u8 = null;
    var parser: cli_flags.Parser = .init(&builtin_commands.login_options, rest);
    while (parser.next() catch return error.InvalidLoginProviderArgs) |item| switch (item) {
        .positional => |arg| {
            if (provider_arg != null) return error.InvalidLoginProviderArgs;
            provider_arg = arg;
        },
        .option => |match| switch (login_flag_ids[match.index].?) {
            .api_key => parsed.api_key = true,
        },
    };
    if (provider_arg) |name| {
        parsed.provider = provider_catalog.parse(name) orelse return error.InvalidLoginProviderArgs;
    }
    if (parsed.api_key and (parsed.provider orelse .gateway) != .gateway) return error.ApiKeyNeedsVercel;
    return parsed;
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
    period: usage.Period = .month,
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

const SessionRecoveryOptions = struct {
    format: output_contracts.OutputFormat = .text,
    session_id: []u8,

    fn deinit(self: *SessionRecoveryOptions, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const AcpOptions = struct {
    agent: agent_run_flags.Overrides = .{},
    log_file: ?[]const u8 = null,

    fn deinit(self: *AcpOptions, alloc: Allocator) void {
        self.agent.deinit(alloc);
    }
};

const WorkflowOptions = struct {
    agent: agent_run_flags.Overrides = .{},
    create: bool = false,
    context: []u8 = &.{},

    fn deinit(self: *WorkflowOptions, alloc: Allocator) void {
        self.agent.deinit(alloc);
        alloc.free(self.context);
    }
};

/// An agent-run flag given a value it can't take, such as `--effort lots`.
const BadAgentValue = struct { flag: []const u8, value: []const u8 };

/// Applies one agent-run flag `match` from `docs`, noting a value the flag
/// can't take in `bad`.
fn applyAgentFlag(
    alloc: Allocator,
    agent: *agent_run_flags.Overrides,
    flag: agent_run_flags.Flag,
    docs: []const command_specs.OptionDoc,
    match: cli_flags.Match,
    bad: *?BadAgentValue,
) !void {
    const value = match.value orelse "";
    agent.apply(alloc, flag, value) catch |err| switch (err) {
        error.InvalidAgentRunValue => {
            bad.* = .{ .flag = cli_flags.flagName(docs[match.index]), .value = value };
            return err;
        },
        else => |other| return other,
    };
}

fn writeBadAgentValue(alloc: Allocator, deps: RunDeps, command: []const u8, bad: BadAgentValue) !void {
    const message = try alloc.print("fx {s}: invalid value for {s}: {f}\n", .{ command, bad.flag, text_utils.terminalSafe(bad.value) });
    defer alloc.free(message);
    try writeStderr(deps, message);
}

const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const LoadStartupStateFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStateWithoutCredentialsFn = *const fn (Allocator, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStatusFn = *const fn (Allocator, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupStatus;
const LoadStartupStateWithAuthModeFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize, credentials.AuthMode) anyerror!app_lifecycle.StartupState;
const LoadCatalogStartupStateWithAuthModeFn = *const fn (Allocator, host.SecretStore, []const u8, usize, credentials.AuthMode, ?model_provider.ProviderId, ?[]const u8) anyerror!app_lifecycle.StartupState;
const LoadStartupStatusWithAuthModeFn = *const fn (Allocator, host.SecretStore, []const u8, usize, credentials.AuthMode) anyerror!app_lifecycle.StartupStatus;
const GetenvFn = *const fn (?*anyopaque, []const u8) ?[]const u8;
const EnvironMapFn = *const fn (?*anyopaque) ?*const std.process.Environ.Map;
const ReadMaskedKeyFn = *const fn (?*anyopaque, Allocator, WriteFn, ?*anyopaque) anyerror![]u8;
const SetupTerminalAvailableFn = *const fn (?*anyopaque) bool;
const RunDeps = struct {
    stdout_ctx: ?*anyopaque = null,
    stderr_ctx: ?*anyopaque = null,
    env_ctx: ?*anyopaque = null,
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
    read_masked_key: ReadMaskedKeyFn = readMaskedKeyDefault,
    setup_terminal_available: SetupTerminalAvailableFn = setupTerminalAvailableDefault,
};

const GlobalLaunchArgs = struct {
    remaining: []const [:0]const u8,
    modifiers: LaunchModifiers = .{},
    /// The one positional argument of `fx [flags] "<prompt>" [flags]`, borrowed
    /// from the arguments. Only set by `parseLaunchFlags(.around_prompt)`.
    prompt: ?[]const u8 = null,

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

const LaunchFlag = enum {
    context_limit,
    add_dir,
    no_additional_dirs,
    provider,
    provider_order,
    provider_strict,
    no_provider_strict,
    model,
    effort,
    fast,
    no_fast,
    ultrafast,
    no_ultrafast,
    permission_mode,
    ask,
    auto,
    full_access,
    yolo,
};

const launch_flag_ids = cli_flags.idTable(LaunchFlag, &builtin_commands.launch_options);

/// Reads the global flags before a command or an interactive launch. When a
/// flag repeats or conflicts, the last one wins. A malformed flag returns
/// `error.InvalidFlag`; `launchFlagFailure` describes it.
/// How `--model`, `--fast`, `--ultrafast`, and `--effort` reach the first turn
/// is modeled in `tests/tla/cli/LaunchSelection.tla`.
fn parseGlobalLaunchArgs(alloc: Allocator, args: []const [:0]const u8) !GlobalLaunchArgs {
    return parseLaunchFlags(alloc, args, .before_command);
}

const LaunchFlagMode = enum {
    /// `fx [flags] <command> ...`: stop at the first argument that isn't a
    /// launch flag, since it and everything after belong to the command.
    before_command,
    /// `fx [flags] "<prompt>" [flags]`: launch flags anywhere, and exactly one
    /// positional argument, the first prompt.
    around_prompt,
};

fn parseLaunchFlags(alloc: Allocator, args: []const [:0]const u8, comptime mode: LaunchFlagMode) !GlobalLaunchArgs {
    var overrides: std.ArrayList(config_runtime.context_limits.Override) = .empty;
    errdefer overrides.deinit(alloc);
    var directories: std.ArrayList([]u8) = .empty;
    errdefer {
        for (directories.items) |path| alloc.free(path);
        directories.deinit(alloc);
    }
    var modifiers: LaunchModifiers = .{};
    errdefer {
        if (modifiers.model_override) |model| alloc.free(model);
        if (modifiers.provider_order_override) |order| freeProviderOrderOverride(alloc, order);
    }

    var prompt: ?[]const u8 = null;
    var parser: cli_flags.Parser = switch (mode) {
        .before_command => .initPrefix(&builtin_commands.launch_options, args),
        .around_prompt => .init(&builtin_commands.launch_options, args),
    };
    while (try parser.next()) |item| {
        // Prefix mode stops at positionals, so only the prompt mode sees one.
        const match = switch (item) {
            .option => |option| option,
            .positional => |positional| {
                if (prompt != null) return error.UnquotedPrompt;
                prompt = positional;
                continue;
            },
        };
        const value = match.value orelse "";
        switch (launch_flag_ids[match.index].?) {
            .context_limit => try overrides.append(alloc, try config_runtime.context_limits.parseOverride(value)),
            .add_dir => {
                if (value.len == 0) return error.MissingAddDirectoryValue;
                try directories.append(alloc, try alloc.dupe(u8, value));
            },
            .no_additional_dirs => modifiers.saved_directories_suppressed = true,
            .provider => modifiers.provider_override = model_provider.parse(value) orelse
                return error.InvalidProviderValue,
            .model => {
                const model = std.mem.trim(u8, value, " \t\r\n");
                if (model.len == 0) return error.MissingModelValue;
                const owned_model = try alloc.dupe(u8, model);
                if (modifiers.model_override) |old| alloc.free(old);
                modifiers.model_override = owned_model;
            },
            .effort => modifiers.effort_override = types.ReasoningEffort.parse(value) orelse
                return error.InvalidEffortValue,
            .fast => {
                modifiers.fast_override = true;
                modifiers.ultrafast_override = false;
            },
            .no_fast => modifiers.fast_override = false,
            .ultrafast => {
                modifiers.ultrafast_override = true;
                modifiers.fast_override = false;
            },
            .no_ultrafast => modifiers.ultrafast_override = false,
            .provider_order => modifiers.provider_order_override = try parseProviderOrderFlag(alloc, value, modifiers.provider_order_override),
            .provider_strict => modifiers.provider_strict_override = true,
            .no_provider_strict => modifiers.provider_strict_override = false,
            .permission_mode => modifiers.permission_override = types.PermissionMode.parse(value) orelse
                return error.InvalidPermissionModeValue,
            .ask => modifiers.permission_override = .ask,
            .auto => modifiers.permission_override = .auto,
            .full_access, .yolo => modifiers.permission_override = .yolo,
        }
    }

    const override_slice = try overrides.toOwnedSlice(alloc);
    errdefer if (override_slice.len > 0) alloc.free(override_slice);
    modifiers.context_limit_overrides = override_slice;
    modifiers.additional_directories = try directories.toOwnedSlice(alloc);
    return .{ .remaining = args[parser.index..], .modifiers = modifiers, .prompt = prompt };
}

/// Returns the command that follows the supported global launch modifiers.
/// Startup uses this same surface to select the full runtime configuration
/// before the allocating parser runs.
pub fn commandAfterGlobalLaunchArgs(args: []const [:0]const u8) ?[]const u8 {
    const remaining = argsAfterGlobalLaunchArgs(args);
    return if (remaining.len > 0) remaining[0] else null;
}

/// Why the global flags in `args` failed to parse, or null when they parse.
/// A flag after a first prompt, as in `fx "fix it" --jsno`, is past the
/// launch prefix, so the whole line is checked as well.
fn launchFlagFailure(args: []const [:0]const u8) ?cli_flags.Failure {
    var parser: cli_flags.Parser = .initPrefix(&builtin_commands.launch_options, args);
    while (parser.next() catch return parser.failure) |_| {}
    // Flags may also follow a resume word and its target, as in `fx -c --model x`.
    const rest = args[parser.index..];
    if (rest.len > 0 and isResumeWord(rest[0])) {
        return cli_flags.firstFailure(&builtin_commands.launch_options, rest[resumeHeadLen(rest, true)..]);
    }
    return cli_flags.firstFailure(&builtin_commands.launch_options, args);
}

/// Every flag plain `fx` reads, so an unknown one can get a suggestion.
const launch_suggestion_options = builtin_commands.launch_options ++ [_]command_specs.OptionDoc{
    .{ .flag = "--help", .description = "" },
    .{ .flag = "--version", .description = "" },
    .{ .flag = "--continue", .description = "" },
    .{ .flag = "--resume", .description = "" },
};

/// The unknown flag that follows the launch flags in `args`, with the
/// nearest flag `fx` knows. Slices borrow from `args`.
fn unknownLaunchFlagFailure(args: []const [:0]const u8) ?cli_flags.Failure {
    const remaining = argsAfterGlobalLaunchArgs(args);
    if (remaining.len == 0) return null;
    return cli_flags.firstFailure(&launch_suggestion_options, remaining[0..1]) orelse
        .{ .unknown = .{ .flag = remaining[0], .suggestion = null } };
}

/// Writes the line for a first argument that plain `fx` can't take as a
/// command, a flag, or a prompt.
fn writeLaunchWordProblem(
    writer: *std.Io.Writer,
    command_catalog: CommandCatalog,
    args: []const [:0]const u8,
    err: anyerror,
) std.Io.Writer.Error!void {
    const remaining = argsAfterGlobalLaunchArgs(args);
    const word: []const u8 = if (remaining.len > 0) remaining[0] else "";
    switch (err) {
        error.PrintFlagUseAsk => {
            const flag = if (std.mem.findScalar(u8, word, '=')) |at| word[0..at] else word;
            try writer.print("fx: {s} isn't an fx flag; to run one request and exit, use fx ask ", .{flag});
            if (printFlagPrompt(remaining)) |prompt| {
                try writer.print("\"{f}\"\n", .{text_utils.terminalSafe(prompt)});
            } else {
                try writer.writeAll("\"<prompt>\"\n");
            }
        },
        error.UnknownCommandTypo => {
            try writer.print("fx: unknown command {f}", .{text_utils.terminalSafe(word)});
            if (launchWordSuggestion(command_catalog, word)) |suggestion| {
                try writer.print(" (did you mean {s}?)", .{suggestion});
            }
            try writer.writeAll("\n");
        },
        error.EmptyLaunchPrompt => try writer.writeAll("fx: the prompt is empty\n"),
        error.UnquotedPrompt => {
            // The shell split the prompt into words; show them quoted.
            try writer.writeAll("fx: put the prompt in quotes: fx \"");
            var parser: cli_flags.Parser = .init(&builtin_commands.launch_options, args);
            var first = true;
            while (parser.next() catch null) |item| switch (item) {
                .option => {},
                .positional => |positional| {
                    if (!first) try writer.writeByte(' ');
                    try writer.writeAll(positional);
                    first = false;
                },
            };
            try writer.writeAll("\"\n");
        },
        else => {},
    }
}

/// The prompt given with `-p` or `--print`, for the `fx ask` hint.
fn printFlagPrompt(remaining: []const [:0]const u8) ?[]const u8 {
    if (remaining.len == 0) return null;
    if (std.mem.startsWith(u8, remaining[0], "--print=")) {
        const value = remaining[0]["--print=".len..];
        return if (value.len > 0) value else null;
    }
    if (remaining.len < 2 or remaining[1].len == 0 or remaining[1][0] == '-') return null;
    return remaining[1];
}

pub fn argsAfterGlobalLaunchArgs(args: []const [:0]const u8) []const [:0]const u8 {
    var parser: cli_flags.Parser = .initPrefix(&builtin_commands.launch_options, args);
    while (parser.next() catch return &.{}) |_| {}
    return args[parser.index..];
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
                std.mem.startsWith(u8, command, resume_inline_prefix) or
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
            if (command_specs.matchesTopLevel(command_catalog, command, .config)) return .{ .config = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .completion)) return .{ .completion = args[1..] };
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
            if (command_specs.matchesTopLevel(command_catalog, command, .@"resume")) return .{ .resume_session = .{ .args = args[1..], .legacy_command = true } };
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
            if (command_specs.matchesTopLevel(command_catalog, command, .slack)) return .{ .slack = args[1..] };
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
            if (invocation.legacy_command and !has_upgrade_relaunch) return error.RemovedResumeCommand;
            var upgrade_relaunch: ?UpgradeRelaunch = null;
            errdefer if (upgrade_relaunch) |*relaunch| relaunch.deinit(alloc);
            if (has_upgrade_relaunch) {
                const previous_revision = if (resume_args.len == 3) revision: {
                    if (!update_target.isValidRevision(resume_args[2])) return error.InvalidResumeArgs;
                    break :revision try alloc.dupe(u8, resume_args[2]);
                } else null;
                upgrade_relaunch = .{ .previous_revision = previous_revision };
            }
            const resume_line = if (has_upgrade_relaunch) resume_args[0..1] else resume_args;
            const head_len = if (has_upgrade_relaunch) resume_line.len else resumeHeadLen(resume_line, invocation.top_level_alias);
            var prompt: ?[]const u8 = null;
            if (resume_line.len > head_len) {
                // Launch flags may follow the resume word and its target, as in
                // `fx -c --model x` or `fx session resume last --fast`. They're
                // read together with the flags before the resume word, so the
                // last one still wins.
                const before = args[0 .. args.len - effective_args.len];
                const after = resume_line[head_len..];
                const line = try alloc.alloc([:0]const u8, before.len + after.len);
                defer alloc.free(line);
                @memcpy(line[0..before.len], before);
                @memcpy(line[before.len..], after);
                var launch = parseLaunchFlags(alloc, line, .around_prompt) catch |err| {
                    // A second word after the target is a malformed resume,
                    // not an unquoted prompt.
                    if (err == error.UnquotedPrompt) return error.InvalidResumeArgs;
                    // A removed resume spelling, such as `--id`, keeps its own
                    // hint instead of reading as an unknown launch flag.
                    if (err == error.InvalidFlag) {
                        if (parseResumeArgs(alloc, resume_line, invocation.top_level_alias)) |parsed_target| {
                            var unused = parsed_target;
                            unused.deinit(alloc);
                        } else |resume_err| if (removedResumeHint(resume_err) != null) return resume_err;
                    }
                    return err;
                };
                // `fx -c` and `fx -r` take a first prompt; `fx session resume`
                // doesn't.
                if (launch.prompt != null and !invocation.top_level_alias) {
                    launch.deinit(alloc);
                    return error.InvalidResumeArgs;
                }
                prompt = launch.prompt;
                launch.remaining = &.{};
                global_args.deinit(alloc);
                global_args = launch;
            }
            if (prompt) |text| {
                if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.EmptyLaunchPrompt;
            }
            var target = try parseResumeArgs(
                alloc,
                resume_line[0..head_len],
                invocation.top_level_alias,
            );
            errdefer target.deinit(alloc);
            const initial_prompt: ?[]u8 = if (prompt) |text| try alloc.dupe(u8, text) else null;
            const relaunch = upgrade_relaunch;
            upgrade_relaunch = null;
            return .{ .interactive = .{
                .requested_resume = target,
                .upgrade_relaunch = relaunch,
                .modifiers = global_args.takeModifiers(),
                .initial_prompt = initial_prompt,
            } };
        },
        .unknown => |word| switch (classifyLaunchWord(command_catalog, word)) {
            .command_line => {},
            .print_flag => return error.PrintFlagUseAsk,
            .unknown_flag => return error.UnknownLaunchFlag,
            .command_typo => return error.UnknownCommandTypo,
            .prompt => {
                // Read the whole line again so launch flags may also follow
                // the prompt, as in `fx "fix the bug" --model x`.
                var with_prompt = try parseLaunchFlags(alloc, args, .around_prompt);
                errdefer with_prompt.deinit(alloc);
                var initial_prompt: ?[]u8 = null;
                if (with_prompt.prompt) |prompt| {
                    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) return error.EmptyLaunchPrompt;
                    initial_prompt = try alloc.dupe(u8, prompt);
                }
                global_args.deinit(alloc);
                return .{ .interactive = .{
                    .modifiers = with_prompt.takeModifiers(),
                    .initial_prompt = initial_prompt,
                } };
            },
        },
        else => {},
    }
    return .{ .noninteractive = .{
        .global_args = global_args,
        .effective_args = effective_args,
        .command = command,
    } };
}

/// How many leading words of a resume line name what to resume: the resume
/// word, when `has_resume_word` (`-c`, `-r`, `--resume`), and its target.
/// `-c`, `--continue`, and `--resume=<id>` carry their target. `-r` and
/// `--resume` take the next word as theirs unless it's a long flag, because
/// a session ID can start with a single dash; `fx session resume` does the
/// same with its first word. Every word after these is a launch flag or, for
/// the resume flags, the first prompt.
fn resumeHeadLen(line: []const [:0]const u8, has_resume_word: bool) usize {
    var len: usize = 0;
    if (has_resume_word) {
        if (line.len == 0) return 0;
        const word = line[0];
        len = 1;
        if (!std.mem.eql(u8, word, "--resume") and !std.mem.eql(u8, word, resume_short_flag)) return len;
    }
    if (line.len > len and !std.mem.startsWith(u8, line[len], "--")) len += 1;
    return len;
}

fn isResumeWord(word: []const u8) bool {
    return std.mem.eql(u8, word, "-c") or std.mem.eql(u8, word, "--continue") or
        std.mem.eql(u8, word, "--resume") or std.mem.eql(u8, word, resume_short_flag) or
        std.mem.startsWith(u8, word, resume_inline_prefix);
}

const LaunchWord = enum {
    /// Handled by command dispatch, such as `--version`.
    command_line,
    /// `-p` or `--print`, the one-shot flag of other agents.
    print_flag,
    unknown_flag,
    /// A near miss for a command name, such as `stauts`, or a flag name
    /// typed without its dashes, such as `version`.
    command_typo,
    prompt,
};

/// Decides what plain `fx` does with a first argument that isn't a command.
fn classifyLaunchWord(command_catalog: CommandCatalog, word: []const u8) LaunchWord {
    // `fx -- "-x"` lets a prompt start with a dash.
    if (std.mem.eql(u8, word, "--")) return .prompt;
    if (word.len > 0 and word[0] == '-') {
        if (isVersionFlag(word)) return .command_line;
        if (isPrintFlag(word)) return .print_flag;
        return .unknown_flag;
    }
    if (launchWordSuggestion(command_catalog, word) != null) return .command_typo;
    return .prompt;
}

fn isPrintFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print") or
        std.mem.startsWith(u8, arg, "--print=");
}

/// The command or flag a mistyped first word most likely meant, such as
/// `status` for `stauts` or `--version` for `version`. Words of four letters
/// or fewer allow one edit and longer words two, so a short prompt such as
/// `add` isn't taken for a typo of `acp`.
fn launchWordSuggestion(command_catalog: CommandCatalog, word: []const u8) ?[]const u8 {
    // Flag names people type without their dashes.
    const bare_flags = [_]struct { word: []const u8, flag: []const u8 }{
        .{ .word = "version", .flag = "--version" },
        .{ .word = "continue", .flag = "--continue" },
    };
    for (bare_flags) |entry| {
        if (std.mem.eql(u8, word, entry.word)) return entry.flag;
    }
    // Four letters or fewer get one edit, so a prompt word such as `add` isn't
    // taken for a mistyped command.
    var nearest: cli_flags.Nearest = .{ .word = word, .max_edits = if (word.len <= 4) 1 else 2 };
    for (command_catalog.specs) |spec| {
        // `fx resume` is removed; its typos shouldn't point back to it.
        if (spec.kind == .@"resume") continue;
        const names = [_][]const []const u8{ &.{spec.token}, spec.aliases };
        for (names) |group| for (group) |name| {
            if (name.len == 0 or name[0] == '-') continue;
            nearest.offer(name);
        };
    }
    return nearest.best;
}

/// Detects `fx <subcommand> --help` / `-h` and returns the subcommand kind so the
/// caller can render command-specific help. Top-level `fx --help`/`fx help` are
/// handled separately and intentionally excluded here.
fn topLevelHelpRequest(command_catalog: CommandCatalog, args: []const [:0]const u8) ?TopLevelKind {
    if (args.len < 2) return null;
    const kind = command_specs.topLevelKindFromToken(command_catalog, args[0]) orelse return null;
    if (kind == .help) return null;
    // `fx resume` was removed, so its help request gets the removal hint.
    if (kind == .@"resume" and std.mem.eql(u8, args[0], "resume")) return null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return kind;
    }
    return null;
}

pub fn runIfRequested(alloc: Allocator, args: []const [:0]const u8, cfg: Config) !RunResult {
    return runIfRequestedWithDeps(alloc, args, cfg, .{});
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
    const message = try alloc.print(
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
    return activateProviderSelectionFallible(alloc, cfg, deps, target, caller, exact_source) catch |err| {
        switch (err) {
            error.CredentialStorageUnavailable,
            error.CredentialTemporarilyUnavailable,
            error.CredentialRefreshPersistenceUncertain,
            error.CredentialAuthorityChanged,
            => {},
            else => return err,
        }
        const detail = try auth_runtime.preparationFailureText(alloc, target, err);
        defer alloc.free(detail);
        try writeProviderActivationError(alloc, deps, caller, detail);
        return false;
    };
}

fn runProviderLogin(alloc: Allocator, cfg: Config, provider: model_provider.ProviderId) !void {
    switch (provider) {
        .gateway => try login_flow.runLogin(alloc, cfg.gateway_provider.oauth_transport, cfg.url_opener),
        .codex => try chatgpt_oauth.runLogin(alloc, cfg.gateway_provider.oauth_transport, cfg.url_opener),
        .grok => try grok_oauth.runLogin(alloc, cfg.gateway_provider.oauth_transport, cfg.url_opener),
        .configured => return error.ConfiguredProviderUsesEnvironmentAuth,
    }
}

fn writeProviderLoginFailure(alloc: Allocator, deps: RunDeps, provider: model_provider.ProviderId, caller: ProviderActivationCaller, err: anyerror) !void {
    debug_trace.logf("auth", "provider sign-in failed provider={t} err={s}", .{ provider, @errorName(err) });
    const failure = auth_runtime.classifyCredentialFailure(provider_catalog.find(provider).login_source, err);
    if (failure.reason == .invalid_storage or failure.reason == .persistence_uncertain) {
        const detail = try auth_runtime.preparationFailureText(alloc, provider, err);
        defer alloc.free(detail);
        try writeProviderActivationError(alloc, deps, caller, detail);
        return;
    }
    try writeProviderActivationError(alloc, deps, caller, switch (err) {
        error.ClientIdMissing => "missing FX_OAUTH_CLIENT_ID; configure the fx Vercel App client id first",
        error.AccessDenied, error.ChatGptAuthorizationFailed, error.GrokAuthorizationFailed => "authorization denied",
        error.ExpiredToken, error.LoginTimedOut, error.ChatGptLoginTimedOut, error.GrokLoginTimedOut => "authorization expired; run fx login again",
        else => "failed to sign in",
    });
}

fn activateProviderSelectionFallible(
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

    if (target == .configured) {
        const bound = target.bind(settings.providers orelse .{}) catch |err| switch (err) {
            error.UnknownConfiguredProvider => {
                const detail = try config_runtime.unknownProviderMessage(alloc, target.label());
                defer alloc.free(detail);
                try writeProviderActivationError(alloc, deps, caller, detail);
                // A name fx doesn't know is a bad argument, so the caller
                // exits as a usage error.
                return error.UnknownConfiguredProvider;
            },
            error.ConfiguredProviderChanged => return err,
        };
        const selected_model = settings.models.get(bound) orelse return error.ConfiguredModelNotSelected;
        var attempt = config_runtime.attemptUserPreferences(alloc, .{
            .provider = bound,
            .model_preference = .{ .provider = bound, .model = selected_model },
        });
        defer attempt.deinit(alloc);
        switch (attempt) {
            .failure => {
                try writeProviderActivationError(alloc, deps, caller, "failed to save provider selection");
                return false;
            },
            .outcome => {},
        }
        const message = try alloc.print("Provider set to {s}.\n", .{bound.label()});
        defer alloc.free(message);
        if (caller == .provider_command) try writeStdout(deps, message);
        return true;
    }
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

    const already_selected = (settings.provider orelse @as(model_provider.ProviderId, .gateway)).eql(target);
    // A selected provider without a persisted model still needs one chosen
    // below; FX_MODEL only covers a single run, so it does not count here.
    const has_persisted_model = if (config_runtime.selectProviderModel(cfg.default_model, &settings, target, null)) |_| true else |_| false;
    if (caller == .provider_command and already_selected and has_persisted_model and
        (cfg.auth_mode == .host_managed or prepared_credential != null))
    {
        try writeStdout(deps, switch (target) {
            .gateway => "Gateway is already selected.\n",
            .codex => "Codex is already selected.\n",
            .grok => "Grok is already selected.\n",
            .configured => "Configured provider is already selected.\n",
        });
        return true;
    }

    var performed_login: ?model_provider.ProviderId = null;
    if (cfg.auth_mode == .local and prepared_credential == null and provider_catalog.find(target).subscription and caller == .provider_command) {
        runProviderLogin(alloc, cfg, target) catch |err| {
            try writeProviderLoginFailure(alloc, deps, target, caller, err);
            return false;
        };
        performed_login = target;
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
                .configured => "configure the provider auth environment variable first",
            },
        );
        return false;
    };
    const catalog_provider = cfg.provider_set.select(target).model_catalog orelse {
        try writeProviderActivationError(alloc, deps, caller, switch (target) {
            .codex => "Codex model catalog is unavailable",
            .grok => "Grok model catalog is unavailable",
            .gateway => "Gateway model catalog is unavailable",
            .configured => "Configured model catalog is unavailable",
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
            const detail = try alloc.print(
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
        .gateway, .configured => unreachable,
    };
    if (caller == .provider_command) {
        try writeStdout(deps, switch (target) {
            .gateway => "Provider set to Gateway.\n",
            .codex => "Provider set to Codex.\n",
            .grok => "Provider set to Grok.\n",
            .configured => "Provider set to configured connection.\n",
        });
    }
    return true;
}

fn runIfRequestedWithDeps(alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !RunResult {
    const parsed_launch = parseInteractiveLaunch(alloc, args, cfg.command_catalog) catch |err| {
        if (err == error.InvalidResumeArgs) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .@"resume");
            return usage_failure;
        }
        if (removedResumeHint(err)) |hint| {
            try writeStderr(deps, hint);
            return usage_failure;
        }
        var writer: std.Io.Writer.Allocating = .init(alloc);
        defer writer.deinit();
        switch (err) {
            error.PrintFlagUseAsk, error.UnknownCommandTypo, error.EmptyLaunchPrompt, error.UnquotedPrompt => {
                try writeLaunchWordProblem(&writer.writer, cfg.command_catalog, args, err);
                try writeStderr(deps, writer.written());
                return usage_failure;
            },
            else => {},
        }
        if (err == error.InvalidFlag or err == error.UnknownLaunchFlag) {
            try writer.writer.writeAll("fx: ");
            const failure = if (err == error.InvalidFlag) launchFlagFailure(args) else unknownLaunchFlagFailure(args);
            if (failure) |found| try found.write(&writer.writer);
            try writer.writer.writeAll("\n");
        } else if (globalLaunchErrorMessage(err)) |message| {
            try writer.writer.print("fx: {s}\n", .{message});
        } else {
            try writer.writer.print("fx: invalid global launch option: {s}\n", .{@errorName(err)});
        }
        try writer.writer.writeAll(builtin_commands.launch_usage);
        try writeStderr(deps, writer.written());
        return usage_failure;
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
        return usage_failure;
    }

    const acp_ultrafast_override = switch (parsed_command) {
        .acp => global_args.modifiers.hasOnlyUltrafastOverride(),
        else => false,
    };
    if (global_args.modifiers.hasModelOverrides() and !acp_ultrafast_override) {
        try writeModelModifierUsage(alloc, deps, parsed_command, global_args.modifiers);
        return usage_failure;
    }

    if (isVersionFlag(effective_args[0])) {
        if (effective_args.len != 1) {
            try writeStderr(deps, version_usage);
            return usage_failure;
        }
        try writeStdout(deps, cfg.version);
        try writeStdout(deps, "\n");
        return .handled_success;
    }

    // The MCP verbs print their own help, and pass `-h` after `--` to the server.
    if (topLevelHelpRequest(cfg.command_catalog, effective_args)) |kind| if (kind != .mcp) {
        const text = try command_specs.renderTopLevelCommandHelp(alloc, cfg.command_catalog, kind);
        defer alloc.free(text);
        try writeStdout(deps, text);
        return .handled_success;
    };

    switch (parsed_command) {
        .interactive, .resume_session => unreachable,
        .help => {
            try writeTopLevelHelp(alloc, cfg.command_catalog, deps, cfg.version, .stdout);
            return .handled_success;
        },
        .ask => |rest| {
            try writeMcpProfileWarningIfPresent(alloc, cfg, deps);
            const exit_code = try cli_ask.run(alloc, rest, workflowConfigWithLaunchModifiers(cfg, global_args.modifiers), cfg.context_registry, cfg.tool_set);
            return if (exit_code == 0) .handled_success else .{ .handled_exit = exit_code };
        },
        .acp => |rest| {
            var bad: ?BadAgentValue = null;
            var acp_opts = parseAcpArgs(alloc, rest, &bad) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    if (bad) |value| {
                        try writeBadAgentValue(alloc, deps, "acp", value);
                    } else {
                        try writeFlagFailure(alloc, deps, .acp, rest);
                    }
                    try writeStderr(deps, "usage: fx " ++ builtin_commands.acp_usage ++ "\n");
                    return usage_failure;
                },
            };
            defer acp_opts.deinit(alloc);
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
                .model_override = acp_opts.agent.model,
                .effort_override = if (acp_opts.agent.effort) |*effort| effort.label() else null,
                .fast_override = acp_opts.agent.fast,
                .ultrafast_override = acp_opts.agent.ultrafast orelse global_args.modifiers.ultrafast_override,
                .provider_override = acp_opts.agent.provider,
                .permission_override = acp_opts.agent.permission,
                .log_file = acp_opts.log_file,
            });
            return .handled_success;
        },
        .pr => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .pull_request),
        .issue => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .issue),
        .login => |rest| {
            const login_args = parseLoginArgs(rest) catch |err| {
                switch (err) {
                    error.ApiKeyNeedsVercel => try writeStderr(deps, "fx login: --api-key works only with vercel\n"),
                    error.InvalidLoginProviderArgs => {
                        try writeFlagFailure(alloc, deps, .login, rest);
                        try writeStderr(deps, "usage: fx login [vercel|codex|grok] [--api-key]\n");
                    },
                }
                return usage_failure;
            };
            if (cfg.auth_mode == .host_managed) {
                try writeHostManagedAuthResult(deps);
                return .handled_success;
            }
            if (login_args.api_key) {
                return if (try runPasteSetup(alloc, cfg.secret_store, deps, "fx login")) .handled_success else .handled_failure;
            }
            // Preserve the original `fx login` behavior for scripts and users.
            const login_provider = login_args.provider orelse .gateway;
            runProviderLogin(alloc, cfg, login_provider) catch |err| {
                try writeProviderLoginFailure(alloc, deps, login_provider, .provider_login, err);
                return .handled_failure;
            };
            if (!try activateProviderSelection(
                alloc,
                cfg,
                deps,
                login_provider,
                .provider_login,
                if (login_provider == .gateway) .fx_login else null,
            )) return .handled_failure;
            try writeStdout(deps, switch (login_provider) {
                .gateway => "Signed in to Vercel.\nAI Gateway access may still require billing or API setup for the selected account.\n",
                .codex => "Signed in with Codex.\n",
                .grok => "Signed in with Grok.\n",
                .configured => "Configured providers use settings.json authentication.\n",
            });
            return .handled_success;
        },
        .logout => |rest| {
            const maybe_login_provider = parseLoginProvider(rest) catch {
                try writeStderr(deps, "usage: fx logout [vercel|codex|grok]\n");
                return usage_failure;
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
                return usage_failure;
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
                try writeStderr(deps, "usage: fx provider <name>\n");
                return usage_failure;
            }
            const target = model_provider.parse(rest[0]) orelse {
                try writeStderr(deps, "fx provider: expected gateway, codex, grok, or a configured name\n");
                return usage_failure;
            };
            const activated = activateProviderSelection(alloc, cfg, deps, target, .provider_command, null) catch |err| switch (err) {
                error.UnknownConfiguredProvider => return usage_failure,
                else => return err,
            };
            return if (activated) .handled_success else .handled_failure;
        },
        .setup => |rest| {
            if (try command_specs.deprecationWarning(alloc, cfg.command_catalog, .setup)) |warning| {
                defer alloc.free(warning);
                try writeStderr(deps, warning);
            }
            if (rest.len != 0) {
                try writeTopLevelUsage(cfg.command_catalog, deps, .setup);
                return usage_failure;
            }
            if (cfg.auth_mode == .host_managed) {
                try writeHostManagedAuthResult(deps);
                return .handled_success;
            }
            return if (try runPasteSetup(alloc, cfg.secret_store, deps, "fx setup")) .handled_success else .handled_failure;
        },
        .status => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .status, "status", err, rest);
                return usage_failure;
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
            snapshot.provider_endpoint = startup.provider_endpoint;
            snapshot.modes = statusModes(cfg.mode_registry, snapshot.permission_mode);
            const fx_home = try profile_paths.activeRoot(alloc, io_mod.getenv("HOME"));
            defer if (fx_home) |path| alloc.free(path);
            snapshot.fx_home = fx_home;
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
                return usage_failure;
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
        .slack => |rest| {
            if (rest.len == 0) {
                const help = try command_specs.renderTopLevelCommandHelp(alloc, cfg.command_catalog, .slack);
                defer alloc.free(help);
                try writeStdout(deps, help);
                return .handled_success;
            }
            const opts = slack_install.parse(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .slack, "slack", err, rest);
                return usage_failure;
            };
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();
            const snapshot = slack_install.run(arena.allocator(), opts.action, cfg.gateway_provider.oauth_transport, cfg.url_opener) catch |err| {
                try writeCommandFailure(alloc, deps, "slack", err, opts.format);
                return .handled_failure;
            };
            const text = try snapshot.render(alloc, opts.format);
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
                return usage_failure;
            };

            var startup = if (cfg.auth_mode == .host_managed)
                try deps.load_catalog_startup_state_with_auth_mode(
                    alloc,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                    cfg.auth_mode,
                    null,
                    null,
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
            var available_providers = cfg.provider_set;
            available_providers.definitions = startup.configured_providers.definitions;
            const catalog_provider = available_providers.select(startup.provider).cli_model_catalog orelse {
                try writeStderr(deps, switch (startup.provider) {
                    .gateway => "fx models: Gateway model catalog is unavailable\n",
                    .codex => "fx models: Codex model catalog is unavailable\n",
                    .grok => "fx models: Grok model catalog is unavailable\n",
                    .configured => "fx models: Configured model catalog is unavailable\n",
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
                    const message = try alloc.print(
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
            var entries = loaded.entries;
            defer model_catalog.freeModelCatalog(alloc, &entries);
            const details = try modelDetails(
                alloc,
                ids.items,
                entries.items,
                available_providers.select(startup.provider),
                startup.provider,
            );
            defer alloc.free(details);

            const text = try (output_contracts.ModelListSnapshot{
                .ids = ids.items,
                .details = details,
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
                return usage_failure;
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
                    return usage_failure;
                };
                defer recovery.deinit(alloc);
                return runSessionRecovery(alloc, deps, recovery);
            }

            var opts = parseSessionDetailArgs(alloc, rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", err, rest);
                return usage_failure;
            };
            defer opts.deinit(alloc);

            const target = opts.target orelse {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", error.InvalidSessionDetailArgs, rest);
                return usage_failure;
            };
            return runSessionDetail(alloc, deps, target, opts.format);
        },
        .sessions => |rest| {
            if (rest.len > 0 and std.mem.eql(u8, rest[0], "convert")) {
                const format = parseSessionConvertArgs(rest[1..]) catch |err| {
                    try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .sessions, "sessions", err, rest);
                    return usage_failure;
                };
                return runSessionConvert(alloc, deps, format);
            }
            const opts = parseSessionListArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .sessions, "sessions", err, rest);
                return usage_failure;
            };
            return runSessionList(alloc, deps, opts);
        },
        .workspace => |rest| {
            const opts = parseWorkspaceArgs(rest) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return usage_failure;
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
                return usage_failure;
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
                return usage_failure;
            };
            // A relative $HOME counts as unset, as everywhere else in fx, and
            // with HOME unset FX_HOME's parent serves.
            const home = deps.getenv(deps.env_ctx, "HOME") orelse profile_paths.fxHomeParent() orelse "";
            if (!std.Io.Dir.path.isAbsolute(home)) {
                try writeUsageCommandFailure(alloc, deps, error.HomeNotSet, opts.format);
                return .handled_failure;
            }
            var startup = (if (cfg.auth_mode == .host_managed)
                deps.load_startup_state_with_auth_mode(
                    alloc,
                    cfg.gateway_provider.oauth_transport,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                    cfg.auth_mode,
                )
            else
                deps.load_startup_state(
                    alloc,
                    cfg.gateway_provider.oauth_transport,
                    cfg.secret_store,
                    cfg.default_model,
                    cfg.default_agent_step_limit,
                )) catch |err| {
                try writeUsageCommandFailure(alloc, deps, err, opts.format);
                return .handled_failure;
            };
            defer startup.deinit(alloc);

            var dashboard = usage.Dashboard.init(alloc, usage_host.host(home));
            defer dashboard.deinit();
            var label_buf: usage_host.LabelBuffer = undefined;
            if (startup.credential) |c| {
                if (usage_host.fromCredential(c, &label_buf)) |credential| {
                    dashboard.open(credential);
                } else {
                    dashboard.openUnavailable(.unsupported_provider);
                }
            } else {
                dashboard.openUnavailable(.no_gateway_sign_in);
            }
            dashboard.waitForFetch();
            var snapshot = try dashboard.snapshot(alloc);
            defer snapshot.deinit();
            const text = try (output_contracts.UsageSnapshot{ .snapshot = &snapshot, .period = opts.period }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return if (snapshot.status == .ready) .handled_success else .handled_failure;
        },
        .upgrade => |rest| {
            const upgrade_runtime = @import("../upgrade/upgrade_runtime.zig");
            var rejected_channel: ?[]const u8 = null;
            const opts = parseUpgradeArgs(rest, &rejected_channel) catch |err| {
                if (rejected_channel) |value| if (!argsContainJson(rest)) {
                    const line = try alloc.print("fx upgrade: invalid value for --channel: {f}\n", .{text_utils.terminalSafe(value)});
                    defer alloc.free(line);
                    try writeStderr(deps, line);
                };
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .upgrade, "upgrade", err, rest);
                return usage_failure;
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
                if (opts.format == .text) {
                    const line = try channelSavedLine(alloc, selected, outcome);
                    defer alloc.free(line);
                    try writeStdout(deps, line);
                }
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
        .completion => |rest| {
            const shell = if (rest.len == 1) completion.parseShell(rest[0]) else null;
            if (shell == null) {
                if (rest.len == 1) {
                    try writeStderrLine(alloc, deps, "fx completion: unknown shell {s}; choose bash, zsh, or fish\n", rest[0]);
                }
                try writeTopLevelUsage(cfg.command_catalog, deps, .completion);
                return usage_failure;
            }
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try completion.writeScript(alloc, &out.writer, shell.?, cfg.command_catalog, &builtin_commands.launch_options);
            try writeStdout(deps, out.written());
            return .handled_success;
        },
        .config => |rest| {
            var unknown_key: ?settings_keys.UnknownPart = null;
            var problem: ?[]const u8 = null;
            const opts = cli_config.parseArgs(rest, &unknown_key, &problem) catch |err| {
                if (problem) |text| {
                    if (argsContainJson(rest)) {
                        try writeJsonCommandFailure(alloc, deps, "config", err, text);
                        return usage_failure;
                    }
                    try writeStderrLine(alloc, deps, "fx config: {s}\n", text);
                }
                if (!argsContainJson(rest)) {
                    if (unknown_key) |part| {
                        const message = try settings_messages.formatUnknownPath(alloc, part);
                        defer alloc.free(message);
                        try writeStderrLine(alloc, deps, "fx config: {s}\n", message);
                    } else if (err == error.WorkspaceConfigWrite) {
                        try writeStderr(deps, "fx config: " ++ workspace_write_message ++ "\n");
                    }
                }
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .config, "config", err, rest);
                return usage_failure;
            };
            return switch (opts.action) {
                .list, .get => runConfig(alloc, cfg, deps, opts),
                .set, .unset => runConfigWrite(alloc, deps, opts),
                .schema => runConfigSchema(alloc, deps, opts),
            };
        },
        .replay => |rest| {
            const exit_code = try cli_replay.run(alloc, rest);
            return if (exit_code == 0) .handled_success else .{ .handled_exit = exit_code };
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
    var bad: ?BadAgentValue = null;
    var opts = parseWorkflowArgs(alloc, args, &bad) catch |err| switch (err) {
        error.InvalidWorkflowArgs, error.InvalidAgentRunValue => {
            const kind: TopLevelKind = switch (workflow) {
                .pull_request => .pr,
                .issue => .issue,
            };
            if (bad) |value| {
                try writeBadAgentValue(alloc, deps, @tagName(kind), value);
            } else {
                try writeFlagFailure(alloc, deps, kind, args);
            }
            try writeTopLevelUsage(cfg.command_catalog, deps, kind);
            return usage_failure;
        },
        else => return err,
    };
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
        const exit_code = try cli_ask.runPrompt(alloc, prompt, opts.agent, workflow_cfg, cfg.context_registry, cfg.tool_set);
        return if (exit_code == 0) .handled_success else .handled_failure;
    }

    const run_result = try cli_ask.runPromptCapture(alloc, prompt, opts.agent, workflow_cfg, cfg.context_registry, cfg.tool_set);
    defer run_result.deinit(alloc);
    if (run_result.exit_code != 0) return .handled_failure;

    const draft = draftFromRun(alloc, run_result) catch {
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

/// Parses the draft from the completed final response only, so text the model
/// wrote before a tool call never becomes the title or body.
fn draftFromRun(alloc: Allocator, run_result: cli_ask.PromptRunResult) !github_publish.Draft {
    return github_publish.parseDraft(alloc, run_result.final_source);
}

fn writeStdout(deps: RunDeps, text: []const u8) !void {
    try deps.write_stdout(deps.stdout_ctx, text);
}

fn writeStderr(deps: RunDeps, text: []const u8) !void {
    try deps.write_stderr(deps.stderr_ctx, text);
}

/// Reads and stores an AI Gateway API key. `command` names the command in
/// failure messages: `fx login` for `fx login --api-key`, `fx setup` for the
/// deprecated spelling.
fn runPasteSetup(
    alloc: Allocator,
    secret_store: host.SecretStore,
    deps: RunDeps,
    command: []const u8,
) !bool {
    if (secret_store.isDisabled()) {
        try writePasteFailure(alloc, deps, command, "stored API keys are disabled by FX_DISABLE_KEYCHAIN");
        return false;
    }
    if (!deps.setup_terminal_available(deps.setup_ctx)) {
        try writePasteFailure(alloc, deps, command, "an interactive terminal is required to paste an API key");
        return false;
    }

    try writeStderr(deps, "Paste AI Gateway API key (input hidden): ");
    const stored_interactively = secret_store.storeInteractive() catch {
        try writeStderr(deps, "\n");
        try writePasteFailure(alloc, deps, command, "API key was not saved");
        return false;
    };
    if (!stored_interactively) {
        const key = deps.read_masked_key(
            deps.setup_ctx,
            alloc,
            deps.write_stderr,
            deps.stderr_ctx,
        ) catch {
            try writeStderr(deps, "\n");
            try writePasteFailure(alloc, deps, command, "API key was not saved");
            return false;
        };
        defer secret.zeroAndFree(alloc, key);
        try writeStderr(deps, "\n");
        secret_store.store(alloc, key) catch {
            try writePasteFailure(alloc, deps, command, "API key was not saved");
            return false;
        };
    }

    const message = try alloc.print(
        "Saved API key to {s}.\n",
        .{secret_store.backend_label},
    );
    defer alloc.free(message);
    try writeStdout(deps, message);
    return true;
}

fn writePasteFailure(alloc: Allocator, deps: RunDeps, command: []const u8, problem: []const u8) !void {
    const message = try alloc.print("{s}: {s}\n", .{ command, problem });
    defer alloc.free(message);
    try writeStderr(deps, message);
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
        self.original = try io_mod.tcgetattr(std.posix.STDIN_FILENO);
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
        const vmin_idx = switch (builtin.target.os.tag) {
            .linux => 6,
            else => 16,
        };
        const vtime_idx = switch (builtin.target.os.tag) {
            .linux => 5,
            else => 17,
        };
        if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
            raw.cc[vmin_idx] = 1;
            raw.cc[vtime_idx] = 0;
        }
        try io_mod.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        self.active = true;
        return self;
    }

    fn disable(self: *MaskedKeyRawMode) void {
        if (!self.active) return;
        io_mod.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

fn writeConfigDiagnostics(
    alloc: Allocator,
    deps: RunDeps,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        const note = diagnostic.note();
        if (note == null and !diagnostic.reportAtStartup()) continue;
        var notice_writer: std.Io.Writer.Allocating = .init(alloc);
        defer notice_writer.deinit();
        if (note) |text| {
            try notice_writer.writer.print("fx: note: {s}", .{text});
        } else {
            try notice_writer.writer.print(
                "fx: config {s}: {s}",
                .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
            );
            try config_runtime.writeDiagnosticMetadata(&notice_writer.writer, diagnostic);
        }
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
        .model_origin = startup.model_origin.label(),
        .effort = startup.effort,
        .provider = startup.provider,
        .auth = startup.auth,
        .auth_help = startup.auth.missingHelp(.cli),
        .permission_mode = permissionModeForSnapshot(startup.permission_mode),
        .workspace_root = startup.workspace_root,
        .history_turns = 0,
        .session_permission_grants = 0,
        .agent_step_limit = startup.agent_step_limit,
        .ultrafast_requested = startup.ultrafast_mode,
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
    if (comptime builtin.target.os.tag != .windows) {
        return writeFdAll(std.posix.STDOUT_FILENO, text);
    }
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeRealStderr(_: ?*anyopaque, text: []const u8) !void {
    if (comptime builtin.target.os.tag != .windows) {
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

fn writeTopLevelUsage(command_catalog: CommandCatalog, deps: RunDeps, kind: TopLevelKind) !void {
    try writeStderr(deps, "usage: fx ");
    try writeStderr(deps, command_specs.topLevelUsage(command_catalog, kind));
    try writeStderr(deps, "\n");
}

fn localMcpView(
    inspection: *const mcp_health.LocalConfigInspection,
) output_contracts.McpLocalSnapshot {
    return .{
        .servers = inspection.snapshot.servers,
        .configuration_issues = inspection.snapshot.configuration_issues,
        .inspection_error = inspection.inspection_error,
    };
}

fn runTopLevelMcp(
    alloc: Allocator,
    rest: []const [:0]const u8,
    cfg: Config,
    deps: RunDeps,
) !RunResult {
    return runMcpVerbs(alloc, rest, cfg, deps);
}

/// `fx mcp`: the verbs `/mcp` shares.
fn runMcpVerbs(alloc: Allocator, rest: []const [:0]const u8, cfg: Config, deps: RunDeps) !RunResult {
    // With HOME unset, FX_HOME alone names fx's files, so its parent serves.
    const home = deps.getenv(deps.env_ctx, "HOME") orelse profile_paths.fxHomeParent() orelse {
        try writeStderr(deps, "fx mcp: HOME isn't set\n");
        return .handled_failure;
    };
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    // `FX_TRACE` and `FX_TRACE_LOG` keep a trace here, as in the shell.
    debug_trace.configureFromEnv(alloc, workspace_root);
    const args = try alloc.alloc([]const u8, rest.len);
    defer alloc.free(args);
    for (rest, args) |r, *a| a.* = r;
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out: DepsWriter = .init(deps, .stdout, &out_buffer);
    var err: DepsWriter = .init(deps, .stderr, &err_buffer);
    var hosts: CliMcpHosts = .{ .alloc = alloc, .cfg = cfg, .workspace_root = workspace_root };
    const code = mcp_verbs.run(.{
        .gpa = alloc,
        .out = &out.interface,
        .err = &err.interface,
        .surface = .cli,
        .home = home,
        .workspace_root = workspace_root,
        .hosts = .{ .context = &hosts, .get = CliMcpHosts.get, .release = CliMcpHosts.release, .changed = CliMcpHosts.changed },
    }, args);
    return switch (code) {
        0 => .handled_success,
        1 => .handled_failure,
        else => .{ .handled_exit = code },
    };
}

/// A host made for one `fx mcp` command.
const CliMcpHosts = struct {
    alloc: Allocator,
    cfg: Config,
    workspace_root: []const u8,

    fn get(context: *anyopaque, notify: ?mcp_verbs.Notify) anyerror!?*mcp_host.Host {
        const self: *CliMcpHosts = @ptrCast(@alignCast(context));
        const load = self.cfg.load_mcp_host orelse return null;
        return load(self.alloc, self.workspace_root, self.cfg.tool_set.registry, .{ .notify = notify });
    }

    /// `fx mcp` exits after its one command, so nothing waits for the
    /// servers; a logout already waited for its revocation.
    fn release(_: *anyopaque, _: *mcp_host.Host) void {
        mcp_host.signalServersForExit();
    }

    fn changed(_: *anyopaque) void {}
};

/// Streams through `deps`, so `login` shows its address while it waits.
const DepsWriter = struct {
    deps: RunDeps,
    stream: enum { stdout, stderr },
    interface: std.Io.Writer,

    fn init(deps: RunDeps, stream: @FieldType(DepsWriter, "stream"), buffer: []u8) DepsWriter {
        return .{ .deps = deps, .stream = stream, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn emit(self: *DepsWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        const written = switch (self.stream) {
            .stdout => writeStdout(self.deps, bytes),
            .stderr => writeStderr(self.deps, bytes),
        };
        written catch return error.WriteFailed;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DepsWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.emit(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.emit(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.emit(last);
        return n + last.len * splat;
    }
};

const McpCliAuthorization = struct {
    opener: host.UrlOpener,
    deps: RunDeps,
};

fn openTopLevelMcpUrl(
    raw: ?*anyopaque,
    alloc: Allocator,
    url: []const u8,
) anyerror!bool {
    const presentation: *const McpCliAuthorization = @ptrCast(@alignCast(raw.?));
    var encoded_url = try text_utils.encodeTerminalSafe(alloc, url, std.math.maxInt(usize));
    defer encoded_url.deinit(alloc);
    try writeStdout(presentation.deps, "Open this URL to authenticate the MCP server:\n");
    try writeStdout(presentation.deps, encoded_url.bytes);
    try writeStdout(presentation.deps, "\n\nWaiting for browser authorization...\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) {
        _ = try presentation.opener.open(alloc, url);
    }
    return true;
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
        "fx: {s}/mcp.json warning: {s}",
        .{ profile_paths.displayRoot(), @tagName(warning.cause) },
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
        if (try flagProblem(alloc, usage_kind, args)) |problem| {
            defer alloc.free(problem);
            return writeJsonCommandFailure(alloc, deps, output_kind, err, problem);
        }
        try writeCommandFailure(alloc, deps, output_kind, err, .json);
    } else {
        try writeFlagFailure(alloc, deps, usage_kind, args);
        try writeTopLevelUsage(command_catalog, deps, usage_kind);
    }
}

/// The options a command's parser reads through `cli_flags`, so a usage
/// error can say which flag was wrong. Commands with their own parser are
/// absent.
fn parsedOptions(kind: TopLevelKind) ?[]const command_specs.OptionDoc {
    return switch (kind) {
        .status, .doctor, .models, .permissions, .credits => &builtin_commands.json_only_options,
        .slack => &command_specs.slack_options,
        .sessions => &builtin_commands.sessions_options,
        .login => &builtin_commands.login_options,
        .usage => &builtin_commands.usage_options,
        .upgrade => &builtin_commands.upgrade_options,
        .workspace => &builtin_commands.workspace_options,
        .config => &builtin_commands.config_parse_options,
        .session => &builtin_commands.session_options,
        .acp => &builtin_commands.acp_options,
        .pr, .issue => &builtin_commands.pr_options,
        else => null,
    };
}

/// Writes `fx <command>: <problem>` when `flagProblem` finds one.
fn writeFlagFailure(alloc: Allocator, deps: RunDeps, kind: TopLevelKind, args: anytype) !void {
    const problem = try flagProblem(alloc, kind, args) orelse return;
    defer alloc.free(problem);
    try writeStderrLine(alloc, deps, "fx {s}: ", @tagName(kind));
    try writeStderr(deps, problem);
    try writeStderr(deps, "\n");
}

/// What is wrong with the flags in `args`: a malformed flag, or a value
/// outside the range its placeholder names, such as `--limit <1-100>`.
/// Null when the flags are fine. The caller frees the result.
fn flagProblem(alloc: Allocator, kind: TopLevelKind, args: anytype) !?[]u8 {
    const docs = parsedOptions(kind) orelse return null;
    // `fx session` and `fx config` read operands that may start with a dash,
    // such as an ID or `-5`; report what their parsers hit.
    const parser: cli_flags.Parser = switch (kind) {
        .session, .config => .initDashOperands(docs, args),
        else => .init(docs, args),
    };
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    if (cli_flags.failureOf(parser)) |failure| {
        try failure.write(&writer.writer);
        switch (kind) {
            .acp, .pr, .issue => try flag_placement.writeLaunchFlagHint(&writer.writer, @tagName(kind), failure),
            else => {},
        }
    } else if (!try cli_flags.writeRangeFailure(&writer.writer, parser)) {
        return null;
    }
    return try writer.toOwnedSlice();
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
        => "the ~/.fx folder is unsafe",
        else => "couldn't load the fx profile",
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
        try writeFlagFailure(alloc, deps, .workspace, args);
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

/// The session modes `fx status` reports, so a client can show the mode
/// choice before an ACP session exists. Null for a registry without modes.
fn statusModes(registry: mode_registry.Registry, permission_mode: types.PermissionMode) ?output_contracts.StatusSnapshot.SessionModes {
    if (registry.modes.len == 0) return null;
    return .{ .current = registry.startingModeId(permission_mode), .all = registry.modes };
}

test "status reports the mode a new session starts in" {
    const modes = [_]mode_registry.ModeSpec{
        .{ .id = "auto", .name = "Auto", .permission_mode = .auto },
        .{ .id = "ask", .name = "Ask", .permission_mode = .ask },
        .{ .id = "full-access", .name = "Full access", .permission_mode = .yolo },
    };
    const registry = mode_registry.Registry{ .default_mode_id = "auto", .modes = modes[0..] };

    const full = statusModes(registry, .yolo) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("full-access", full.current);
    try std.testing.expectEqual(@as(usize, 3), full.all.len);
    try std.testing.expectEqualStrings("ask", statusModes(registry, .ask).?.current);
    try std.testing.expect(statusModes(.{ .default_mode_id = "surface" }, .auto) == null);
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

/// One detail per id when the provider described its models, by the same capability merge a
/// session uses for its effort and speed options; Ultrafast is a Gateway-only lane. Empty when
/// there are no entries. Names borrow from `entries`. Caller frees the returned slice.
fn modelDetails(
    alloc: Allocator,
    ids: []const []const u8,
    entries: []const model_catalog.ModelCatalogEntry,
    bundle: provider_set.Bundle,
    provider: model_provider.ProviderId,
) ![]const output_contracts.ModelDetail {
    if (entries.len == 0) return &.{};
    const details = try alloc.alloc(output_contracts.ModelDetail, ids.len);
    for (ids, details) |id, *detail| {
        const entry = for (entries) |candidate| {
            if (std.mem.eql(u8, candidate.id, id)) break candidate;
        } else null;
        const capabilities = model_capabilities.mergeCapabilities(
            bundle.fallbackModelCapabilities(id),
            if (entry) |found| model_catalog_metadata.fromCatalogEntry(found) else null,
        );
        detail.* = .{
            .name = if (entry) |found| found.name else null,
            .efforts = capabilities.reasoning_efforts,
            .fast = capabilities.supports_fast_mode,
            .ultrafast = provider == .gateway and capabilities.supports_ultrafast_mode,
        };
    }
    return details;
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

fn writeSessionList(
    alloc: Allocator,
    deps: RunDeps,
    page: session_store.SessionListPage,
    opts: SessionListOptions,
) !RunResult {
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
}

fn writeSessionSummary(
    alloc: Allocator,
    deps: RunDeps,
    summary: session_store.SessionSummary,
    format: output_contracts.OutputFormat,
) !RunResult {
    const text = try (output_contracts.SessionSummarySnapshot{ .summary = summary }).render(alloc, format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, format);
    return .handled_success;
}

fn writeSessionDetail(
    alloc: Allocator,
    deps: RunDeps,
    state: session_codec.DurableSessionState,
    format: output_contracts.OutputFormat,
) !RunResult {
    const text = try (output_contracts.SessionDetailSnapshot{ .state = state }).render(alloc, format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, format);
    return .handled_success;
}

fn writeSessionRecovery(
    alloc: Allocator,
    deps: RunDeps,
    result: session_store.SessionRecoveryResult,
    format: output_contracts.OutputFormat,
) !RunResult {
    const text = try (output_contracts.SessionRecoverySnapshot{ .result = result }).render(alloc, format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, format);
    return if (result.status == .recovered) .handled_success else .handled_failure;
}

/// `fx sessions` on v2: the page v1 shows, from the v2 catalog.
fn runSessionList(alloc: Allocator, deps: RunDeps, opts: SessionListOptions) !RunResult {
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), opts.format);
        return .handled_failure;
    };
    defer store.deinit(alloc);
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    const scope: ?[]const u8 = switch (opts.scope) {
        .current_workspace => workspace_root,
        .all_workspaces => null,
    };
    var page = session_adapter.listPage(&store, alloc, scope, opts.continuation, opts.limit) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), opts.format);
        return .handled_failure;
    };
    defer page.deinit(alloc);
    return writeSessionList(alloc, deps, page, opts);
}

const SessionConvertFlag = enum { json };
const session_convert_flag_ids = cli_flags.idTable(SessionConvertFlag, &builtin_commands.sessions_convert_options);

fn parseSessionConvertArgs(args: []const [:0]const u8) !output_contracts.OutputFormat {
    var format: output_contracts.OutputFormat = .text;
    var parser: cli_flags.Parser = .init(&builtin_commands.sessions_convert_options, args);
    while (parser.next() catch return error.InvalidLocalSurfaceArgs) |item| switch (item) {
        .positional => return error.InvalidLocalSurfaceArgs,
        .option => |match| switch (session_convert_flag_ids[match.index].?) {
            .json => format = .json,
        },
    };
    return format;
}

test "sessions convert reads its flags through the shared parser" {
    try std.testing.expectEqual(output_contracts.OutputFormat.text, try parseSessionConvertArgs(&.{}));
    try std.testing.expectEqual(output_contracts.OutputFormat.json, try parseSessionConvertArgs(&.{"--json"}));
    try std.testing.expectEqual(output_contracts.OutputFormat.json, try parseSessionConvertArgs(&.{ "--json", "--json" }));
    try std.testing.expectError(error.InvalidLocalSurfaceArgs, parseSessionConvertArgs(&.{"--jsno"}));
    try std.testing.expectError(error.InvalidLocalSurfaceArgs, parseSessionConvertArgs(&.{"extra"}));
}

/// `fx sessions convert`: converts every v1 session v2 does not hold yet,
/// and fails when it skipped any (D61).
fn runSessionConvert(alloc: Allocator, deps: RunDeps, format: output_contracts.OutputFormat) !RunResult {
    // Each conversion is traced (`[convert]`), as an open's is.
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    debug_trace.configureFromEnv(alloc, workspace_root);
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), format);
        return .handled_failure;
    };
    defer store.deinit(alloc);
    var report = session_adapter.convertAll(&store, alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "sessions", session_adapter.commandError(err), format);
        return .handled_failure;
    };
    defer report.deinit(alloc);
    const skipped = try alloc.alloc(output_contracts.SessionConvertSnapshot.Skipped, report.skipped.items.len);
    defer alloc.free(skipped);
    for (report.skipped.items, skipped) |from, *to| to.* = .{ .id = from.id, .code = from.code, .reason = from.reason };
    const left_out = try alloc.alloc(output_contracts.SessionConvertSnapshot.LeftOut, report.left_out.items.len);
    defer alloc.free(left_out);
    var reasons = std.heap.ArenaAllocator.init(alloc);
    defer reasons.deinit();
    for (report.left_out.items, left_out) |from, *to| to.* = .{
        .id = from.id,
        .member = from.file.member,
        .file = from.file.file,
        .cause = @tagName(from.file.cause),
        .reason = try from.file.reason(reasons.allocator()),
        .bytes = from.file.bytes,
        .limit = session_adapter.ConvertReport.file_limit_bytes,
    };
    const kept = try alloc.alloc(output_contracts.SessionConvertSnapshot.Kept, report.kept_children.len);
    defer alloc.free(kept);
    for (report.kept_children, kept) |from, *to| to.* = .{ .id = from.id, .reason = from.reason };
    const snapshot: output_contracts.SessionConvertSnapshot = .{
        .converted = report.converted,
        .busy = report.busy,
        .unreadable = report.unreadable,
        .skipped = skipped,
        .left_out = left_out,
        .kept = kept,
    };
    const text = try snapshot.render(alloc, format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, format);
    return if (skipped.len == 0) .handled_success else .handled_failure;
}

/// `fx session last|{id}` on v2, read without the session's lock (D37).
fn runSessionDetail(
    alloc: Allocator,
    deps: RunDeps,
    target: SessionDetailTarget,
    format: output_contracts.OutputFormat,
) !RunResult {
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "session", session_adapter.commandError(err), format);
        return .handled_failure;
    };
    defer store.deinit(alloc);
    switch (target) {
        .last => {
            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);
            var page = session_adapter.listPage(&store, alloc, workspace_root, null, 1) catch |err| {
                try writeLookupFailure(alloc, deps, "session", session_adapter.commandError(err), format);
                return .handled_failure;
            };
            defer page.deinit(alloc);
            if (page.summaries.items.len == 0) {
                try writeLookupFailure(alloc, deps, "session", session_adapter.noLatestError(&store, alloc), format);
                return .handled_failure;
            }
            return writeSessionSummary(alloc, deps, page.summaries.items[0], format);
        },
        .id => |id| {
            var resumed = session_adapter.readSession(&store, alloc, id) catch |err| {
                try writeSessionDetailFailure(alloc, deps, id, session_adapter.commandError(err), store.problem.text(), format);
                return .handled_failure;
            };
            defer resumed.deinit(alloc);
            return writeSessionDetail(alloc, deps, resumed.state, format);
        },
    }
}

/// `fx session recover` on v2 (D15): a copy up to the last good turn.
fn runSessionRecovery(alloc: Allocator, deps: RunDeps, recovery: SessionRecoveryOptions) !RunResult {
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        try writeLookupFailure(alloc, deps, "session", session_adapter.commandError(err), recovery.format);
        return .handled_failure;
    };
    defer store.deinit(alloc);
    var recovered = session_adapter.recover(&store, alloc, recovery.session_id) catch |err| {
        try writeLookupFailure(alloc, deps, "session", session_adapter.commandError(err), recovery.format);
        return .handled_failure;
    };
    defer recovered.deinit(alloc);
    const source_id = try alloc.dupe(u8, recovery.session_id);
    const recovered_id = alloc.dupe(u8, recovered.id) catch |err| {
        alloc.free(source_id);
        return err;
    };
    var result: session_store.SessionRecoveryResult = .{
        .source_session_id = source_id,
        .recovered_session_id = recovered_id,
        .history_len = recovered.history_len,
        .status = if (recovered.files_complete) .recovered else .recovered_with_unverified_artifacts,
        .permission_rules_dropped = recovered.permission_rules_dropped,
    };
    defer result.deinit(alloc);
    return writeSessionRecovery(alloc, deps, result, recovery.format);
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
        error.SessionRecoveryNotNeeded => {
            try writeStderr(
                deps,
                "fx session: recovery was refused because the session has a valid commit boundary; resume it normally\n",
            );
        },
        error.SessionRecoveryBoundaryInvalid => {
            try writeStderr(
                deps,
                "fx session: no exact trustworthy recovery boundary was found; the source was left unchanged\n",
            );
        },
        error.SessionBusy => {
            try writeStderr(
                deps,
                "fx session: session is busy or the filesystem cannot provide the required lock\n",
            );
        },
        error.DurablePathUnsafe => {
            try writeStderr(
                deps,
                "fx session: durable session storage is unsafe or does not support required private permissions\n",
            );
        },
        error.SessionStoreUnavailable => {
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

/// `reason` names the file and the problem of a v1 session v1's reader
/// refuses (D78), and is empty otherwise.
fn writeSessionDetailFailure(
    alloc: Allocator,
    deps: RunDeps,
    session_id: []const u8,
    err: anyerror,
    reason: []const u8,
    format: output_contracts.OutputFormat,
) !void {
    const message = switch (err) {
        error.InvalidSessionFormat => if (reason.len > 0) try alloc.print(
            "session {s} can't be read: {s}; run `fx doctor`",
            .{ session_id, reason },
        ) else try alloc.print(
            "session {s} is corrupt; run `fx session recover {s}`",
            .{ session_id, session_id },
        ),
        error.UnsupportedSessionSchema => try alloc.print(
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
        error.InvalidUpgradeArgs,
        error.InvalidConfigArgs,
        error.InvalidSlackArguments,
        => "invalid arguments",
        error.UnknownConfigSetting => "unknown setting",
        error.WorkspaceConfigWrite => workspace_write_message,
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
        error.SessionRecoveryNotNeeded => "recovery was refused because the session has a valid commit boundary; resume it normally",
        error.SessionRecoveryBoundaryInvalid => "no exact trustworthy recovery boundary was found; the source was left unchanged",
        error.SessionBusy => "session is busy or the filesystem cannot provide the required lock",
        error.SessionPathUnsafe,
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => "durable session storage is unsafe or does not support required private permissions",
        error.SessionStoreUnavailable => "durable session store is unavailable",
        error.HomeNotSet => "HOME is not set",
        else => null,
    };
}

test "session detail failure names an older fx's damaged file and points at doctor (D78)" {
    var text = CaptureOutput.init(std.testing.allocator);
    defer text.deinit();
    try writeSessionDetailFailure(std.testing.allocator, text.deps(), "old-session", error.InvalidSessionFormat, "events.jsonl can't be read (AccessDenied)", .text);
    try std.testing.expectEqualStrings(
        "fx session: session old-session can't be read: events.jsonl can't be read (AccessDenied); run `fx doctor`\n",
        text.stderr.written(),
    );
    var json = CaptureOutput.init(std.testing.allocator);
    defer json.deinit();
    try writeSessionDetailFailure(std.testing.allocator, json.deps(), "old-session", error.InvalidSessionFormat, "events.jsonl can't be read (AccessDenied)", .json);
    try std.testing.expect(std.mem.find(u8, json.stdout.written(), "\"code\":\"InvalidSessionFormat\"") != null);
    try std.testing.expect(std.mem.find(u8, json.stdout.written(), "run `fx doctor`") != null);
}

test "session detail failures separate corruption from unsupported schema" {
    var corrupt_text = CaptureOutput.init(std.testing.allocator);
    defer corrupt_text.deinit();
    try writeSessionDetailFailure(
        std.testing.allocator,
        corrupt_text.deps(),
        "broken-session",
        error.InvalidSessionFormat,
        "",
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
        "",
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
        "",
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
        .load_mcp_host = cfg.load_mcp_host,
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

/// For an agent-run flag before a command, says where it goes, as in
/// `fx: put agent-run flags after the command, as in fx ask --model <id>`.
fn writeModelModifierUsage(alloc: Allocator, deps: RunDeps, command: Command, modifiers: LaunchModifiers) !void {
    const example = firstAgentRunFlag(modifiers);
    const routing = modifiers.provider_order_override != null or modifiers.provider_strict_override != null;
    const target: ?[]const u8 = switch (command) {
        .ask => "ask",
        .pr => "pr",
        .issue => "issue",
        // ACP sessions don't apply gateway provider routing.
        .acp => if (routing) null else "acp",
        else => null,
    };
    const message = if (target) |name|
        try alloc.print("fx: put agent-run flags after the command, as in fx {s} {s}\n", .{ name, example })
    else
        try alloc.print("fx: agent-run flags such as {s} apply to a session and to fx ask, fx pr, fx issue, and fx acp\n", .{example[0 .. std.mem.findScalar(u8, example, ' ') orelse example.len]});
    defer alloc.free(message);
    try writeStderr(deps, message);
}

/// The documented spelling of the first agent-run flag set before a command.
fn firstAgentRunFlag(modifiers: LaunchModifiers) []const u8 {
    if (modifiers.permission_override != null) return "--permission-mode <mode>";
    if (modifiers.provider_override != null) return "--provider <name>";
    if (modifiers.model_override != null) return "--model <id>";
    if (modifiers.effort_override != null) return "--effort <level>";
    if (modifiers.fast_override) |fast| return if (fast) "--fast" else "--no-fast";
    if (modifiers.ultrafast_override) |ultrafast| return if (ultrafast) "--ultrafast" else "--no-ultrafast";
    if (modifiers.provider_order_override != null) return "--provider-order <a,b,...>";
    return if (modifiers.provider_strict_override == true) "--provider-strict" else "--no-provider-strict";
}

fn globalLaunchErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MissingAddDirectoryValue => "--add-dir requires a directory path",
        error.MissingModelValue => "--model requires a model id",
        error.InvalidEffortValue => "--effort value is not a valid reasoning effort",
        error.InvalidProviderValue => "--provider accepts gateway, codex, grok, or a configured provider name",
        error.InvalidProviderOrderValue => "--provider-order accepts comma-separated provider slugs (letters, digits, '-')",
        error.InvalidPermissionModeValue => "--permission-mode accepts ask, auto, or full-access",
        else => null,
    };
}

const AcpFlag = enum { permission_mode, ask, auto, full_access, yolo, provider, model, effort, fast, no_fast, ultrafast, no_ultrafast, log_file };
const acp_flag_ids = cli_flags.idTable(AcpFlag, &builtin_commands.acp_options);

fn parseAcpArgs(alloc: Allocator, args: []const [:0]const u8, bad: *?BadAgentValue) !AcpOptions {
    var opts = AcpOptions{};
    errdefer opts.deinit(alloc);
    var parser: cli_flags.Parser = .init(&builtin_commands.acp_options, args);
    while (parser.next() catch return error.InvalidAcpArgs) |item| switch (item) {
        .positional => return error.InvalidAcpArgs,
        .option => |match| {
            const id = acp_flag_ids[match.index].?;
            if (agent_run_flags.fromId(id)) |flag| {
                try applyAgentFlag(alloc, &opts.agent, flag, &builtin_commands.acp_options, match, bad);
                continue;
            }
            switch (id) {
                .log_file => opts.log_file = match.value.?,
                else => unreachable,
            }
        },
    };
    return opts;
}

test "ACP arguments take the agent-run flags and a log file" {
    const alloc = std.testing.allocator;
    var bad: ?BadAgentValue = null;
    var enabled = try parseAcpArgs(alloc, &.{ "--model", "provider/astra", "--ultrafast" }, &bad);
    defer enabled.deinit(alloc);
    try std.testing.expectEqualStrings("provider/astra", enabled.agent.model.?);
    try std.testing.expectEqual(@as(?bool, true), enabled.agent.ultrafast);

    var last = try parseAcpArgs(alloc, &.{ "--ultrafast", "--no-ultrafast", "--model=a", "--model", "b", "--effort", "high", "--fast", "--ask", "--provider", "codex", "--log-file", "/tmp/acp.log" }, &bad);
    defer last.deinit(alloc);
    try std.testing.expectEqual(@as(?bool, false), last.agent.ultrafast);
    try std.testing.expectEqualStrings("b", last.agent.model.?);
    try std.testing.expectEqualStrings("high", last.agent.effort.?.label());
    try std.testing.expect(last.agent.fast.?);
    try std.testing.expectEqual(types.PermissionMode.ask, last.agent.permission.?);
    try std.testing.expectEqualStrings("codex", last.agent.provider.?.label());
    try std.testing.expectEqualStrings("/tmp/acp.log", last.log_file.?);

    try std.testing.expectError(error.InvalidAgentRunValue, parseAcpArgs(alloc, &.{ "--effort", "high effort" }, &bad));
    try std.testing.expectEqualStrings("--effort", bad.?.flag);
    try std.testing.expectEqualStrings("high effort", bad.?.value);
    // ACP sessions don't apply gateway provider routing, so the flag isn't offered.
    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(alloc, &.{ "--provider-order", "a" }, &bad));
}

test "pr and issue take the agent-run flags before their context" {
    const alloc = std.testing.allocator;
    var bad: ?BadAgentValue = null;
    var opts = try parseWorkflowArgs(alloc, &.{ "--auto", "--model", "m", "--effort=low", "--provider-order", "a,b", "--create", "fix", "the", "--model", "x" }, &bad);
    defer opts.deinit(alloc);
    try std.testing.expectEqual(types.PermissionMode.auto, opts.agent.permission.?);
    try std.testing.expectEqualStrings("m", opts.agent.model.?);
    try std.testing.expectEqual(@as(usize, 2), opts.agent.provider_order.?.len);
    try std.testing.expect(opts.create);
    // Flags after the context are part of it.
    try std.testing.expectEqualStrings("fix the --model x", opts.context);

    try std.testing.expectError(error.InvalidAgentRunValue, parseWorkflowArgs(alloc, &.{ "--permission-mode", "sometimes" }, &bad));
    try std.testing.expectEqualStrings("--permission-mode", bad.?.flag);
}

/// Prints the settings `fx config list` or `fx config get` asks for. `get` of a
/// key that isn't set prints nothing and fails, as `git config get` does.
fn runConfigSchema(alloc: Allocator, deps: RunDeps, opts: cli_config.Options) !RunResult {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try settings_schema.write(&out.writer, if (opts.project) .project else .profile);
    try writeStdout(deps, out.written());
    return .handled_success;
}

fn runConfig(alloc: Allocator, cfg: Config, deps: RunDeps, opts: cli_config.Options) !RunResult {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    var paths = try config_runtime.discoverPaths(alloc, workspace_root);
    defer paths.deinit(alloc);

    var failed_file: ?[]const u8 = null;
    var loaded = cli_config.load(alloc, paths, workspace_root, opts.scope, &failed_file) catch |err| {
        const file = failed_file orelse return err;
        const message = try alloc.print("{s} {s}", .{ file, cli_config.loadFailureReason(err) });
        defer alloc.free(message);
        if (opts.format == .json) {
            try writeJsonCommandFailure(alloc, deps, "config", err, message);
        } else {
            try writeStderrLine(alloc, deps, "fx config: {s}\n", message);
        }
        return .handled_failure;
    };
    defer loaded.deinit(alloc);

    // list shows what each file sets, as git config --list does. get without a
    // scope reports the value a run uses, defaults included, so it reads the
    // settings the runtime resolves.
    var resolved_arena: std.heap.ArenaAllocator = .init(alloc);
    defer resolved_arena.deinit();
    const shown: []const settings_entries.Entry = if (opts.scope == .all and opts.key != null)
        resolvedConfigEntries(alloc, resolved_arena.allocator(), cfg, deps, opts.format, workspace_root, loaded.entries.items) catch |err| blk: {
            debug_trace.logf("config", "resolving settings failed err={s}; showing file values", .{@errorName(err)});
            break :blk loaded.entries.items;
        }
    else
        loaded.entries.items;

    const matches: ?[]settings_entries.Entry = if (opts.key) |key|
        try settings_entries.lookup(alloc, shown, key)
    else
        null;
    defer if (matches) |found| alloc.free(found);
    const entries = matches orelse shown;
    const snapshot: output_contracts.ConfigSnapshot = .{
        .entries = entries,
        .unknown = if (opts.key == null) loaded.unknown else &.{},
        .workspace_root = workspace_root,
        .show_origin = opts.show_origin,
        .value_only = opts.key != null and entries.len == 1 and std.mem.eql(u8, entries[0].key, opts.key.?),
    };
    if (opts.format == .text) {
        for (snapshot.unknown) |unknown| {
            const message = try settings_messages.formatUnknownSetting(alloc, unknown.key, unknown.file);
            defer alloc.free(message);
            try writeStderrLine(alloc, deps, "fx config: {s}\n", message);
        }
    }

    // Like git config --get, a key with no value prints nothing and exits 1;
    // JSON names the key, so a script can tell why.
    if (opts.format == .json and opts.key != null and entries.len == 0) {
        const message = try alloc.print("{s} isn't set", .{opts.key.?});
        defer alloc.free(message);
        try writeJsonCommandFailureCode(alloc, deps, "config", "ConfigKeyNotSet", message);
        return .handled_failure;
    }
    const text = try snapshot.render(alloc, opts.format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, opts.format);
    return if (opts.key != null and entries.len == 0) .handled_failure else .handled_success;
}

/// The entries `fx config get` looks a key up in without a scope: each value
/// as a run resolves it, through the same `resolveSettings` the session uses.
fn resolvedConfigEntries(
    alloc: Allocator,
    arena: Allocator,
    cfg: Config,
    deps: RunDeps,
    format: output_contracts.OutputFormat,
    workspace_root: []const u8,
    set: []const settings_entries.Entry,
) ![]settings_entries.Entry {
    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, workspace_root);
    defer detailed.deinit(alloc);
    // The same warnings fx status prints, such as a profile fx rejects, which
    // explain a value shown as the default.
    if (format == .text) try writeConfigDiagnostics(alloc, deps, detailed.diagnostics);
    var state = app_lifecycle.StartupState{ .agent_step_limit = cfg.default_agent_step_limit };
    defer state.deinit(alloc);
    state.model_source = detailed.model_source orelse .compiled_default;
    try app_lifecycle.resolveSettings(alloc, &state, &detailed);
    const selection = try config_runtime.selectProviderModel(cfg.default_model, &detailed.settings, null, config_runtime.modelEnvOverride());
    const entries = try cli_config.effectiveEntries(arena, &state, selection.provider, set);
    // Values borrow from `state`, which is freed on return.
    for (entries) |*entry| entry.value = try dupeJsonValue(arena, entry.value);
    return entries;
}

fn dupeJsonValue(arena: Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .string => |text| .{ .string = try arena.dupe(u8, text) },
        .number_string => |text| .{ .number_string = try arena.dupe(u8, text) },
        .array => |array| blk: {
            var copy: std.json.Array = .init(arena);
            for (array.items) |item| try copy.append(try dupeJsonValue(arena, item));
            break :blk .{ .array = copy };
        },
        else => value,
    };
}

const workspace_write_message = "preferences apply to every workspace, so set and unset don't take --workspace";

/// Saves what `fx config set` or `fx config unset` asks for to the profile's
/// top level and prints one line naming the key, the value, and the file.
fn runConfigWrite(alloc: Allocator, deps: RunDeps, opts: cli_config.Options) !RunResult {
    var problem: cli_config.WriteProblem = .none;
    const planned = cli_config.change(opts, &problem) catch |err| {
        const message = try cli_config.formatWriteProblem(alloc, opts.key.?, opts.value, problem, "fx config");
        defer alloc.free(message);
        if (opts.format == .json) {
            try writeJsonCommandFailure(alloc, deps, "config", err, message);
        } else {
            try writeStderrLine(alloc, deps, "fx config: {s}\n", message);
        }
        return usage_failure;
    };

    var outcome = config_runtime.setUserPreferences(alloc, planned.patch) catch |err| {
        const message = try alloc.print("failed to save {s}/settings.json: {s}", .{ profile_paths.displayRoot(), cli_config.saveFailureReason(err) });
        defer alloc.free(message);
        if (opts.format == .json) {
            try writeJsonCommandFailure(alloc, deps, "config", err, message);
        } else {
            try writeStderrLine(alloc, deps, "fx config: {s}\n", message);
        }
        return .handled_failure;
    };
    defer outcome.deinit(alloc);

    const snapshot: output_contracts.ConfigChangeSnapshot = .{
        .unset = opts.action == .unset,
        .key = opts.key.?,
        .value = planned.value,
        .changed = outcome == .committed,
    };
    const text = try snapshot.render(alloc, opts.format);
    defer alloc.free(text);
    try writeFormattedOutput(deps, text, opts.format);
    return .handled_success;
}

fn writeStderrLine(alloc: Allocator, deps: RunDeps, comptime format: []const u8, value: []const u8) !void {
    const line = try alloc.print(format, .{value});
    defer alloc.free(line);
    try writeStderr(deps, line);
}

fn parseLocalSurfaceArgs(args: []const [:0]const u8) !LocalSurfaceOptions {
    var options = LocalSurfaceOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.json_only_options, args);
    while (parser.next() catch return error.InvalidLocalSurfaceArgs) |item| switch (item) {
        .positional => return error.InvalidLocalSurfaceArgs,
        .option => options.format = .json,
    };
    return options;
}

const UpgradeFlag = enum { channel, json };
const upgrade_flag_ids = cli_flags.idTable(UpgradeFlag, &builtin_commands.upgrade_options);

/// On a `--channel` value that names no channel, sets `rejected_channel` to it,
/// borrowed from `args`.
fn parseUpgradeArgs(args: []const [:0]const u8, rejected_channel: *?[]const u8) !UpgradeOptions {
    var options = UpgradeOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.upgrade_options, args);
    while (parser.next() catch return error.InvalidUpgradeArgs) |item| switch (item) {
        .positional => return error.InvalidUpgradeArgs,
        .option => |match| switch (upgrade_flag_ids[match.index].?) {
            .channel => options.channel = update_target.Channel.parse(match.value.?) orelse {
                rejected_channel.* = match.value.?;
                return error.InvalidUpgradeArgs;
            },
            .json => options.format = .json,
        },
    };
    return options;
}

/// The line `fx upgrade --channel` prints after saving, so the user knows the
/// channel persists and where. Caller owns the result.
fn channelSavedLine(
    alloc: Allocator,
    channel: update_target.Channel,
    outcome: config_runtime.CommitOutcome,
) ![]u8 {
    return switch (outcome) {
        .unchanged => alloc.print("Release channel is already {s}.\n", .{channel.label()}),
        .committed => alloc.print("Release channel set to {s} in {s}/settings.json.\n", .{ channel.label(), profile_paths.displayRoot() }),
    };
}

const SessionListFlag = enum { all, limit, cursor, json };
const session_list_flag_ids = cli_flags.idTable(SessionListFlag, &builtin_commands.sessions_options);

fn parseSessionListArgs(args: []const [:0]const u8) !SessionListOptions {
    var options = SessionListOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.sessions_options, args);
    while (parser.next() catch return error.InvalidLocalSurfaceArgs) |item| switch (item) {
        .positional => return error.InvalidLocalSurfaceArgs,
        .option => |match| switch (session_list_flag_ids[match.index].?) {
            .all => options.scope = .all_workspaces,
            .limit => {
                options.limit = std.fmt.parseUnsigned(usize, match.value.?, 10) catch
                    return error.InvalidLocalSurfaceArgs;
                if (options.limit == 0 or options.limit > session_store.session_list_max_limit)
                    return error.InvalidLocalSurfaceArgs;
            },
            .cursor => options.continuation = try parseSessionListCursor(match.value.?),
            .json => options.format = .json,
        },
    };
    return options;
}

const UsageFlag = enum { period, json };
const usage_flag_ids = cli_flags.idTable(UsageFlag, &builtin_commands.usage_options);

fn parseUsageArgs(args: []const [:0]const u8) !UsageOptions {
    var options = UsageOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.usage_options, args);
    while (parser.next() catch return error.InvalidUsageArgs) |item| switch (item) {
        .positional => return error.InvalidUsageArgs,
        .option => |match| switch (usage_flag_ids[match.index].?) {
            .period => {
                const period = match.value.?;
                options.period = if (std.mem.eql(u8, period, "today"))
                    .today
                else if (std.mem.eql(u8, period, "7d"))
                    .days_7
                else if (std.mem.eql(u8, period, "month"))
                    .month
                else
                    return error.InvalidUsageArgs;
            },
            .json => options.format = .json,
        },
    };
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
    const encoded = std.mem.print(
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
    return alloc.print(
        "v1:{d}:{s}",
        .{ summary.updated_at_ms, summary.id },
    );
}

fn parseWorkspaceArgs(args: []const [:0]const u8) !WorkspaceOptions {
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var options = WorkspaceOptions{};
    var parser: cli_flags.Parser = .init(&builtin_commands.workspace_options, args);
    while (parser.next() catch return error.InvalidWorkspaceArgs) |item| switch (item) {
        // `--json` is the only flag.
        .option => options.format = .json,
        .positional => |arg| {
            if (positional_len >= positional.len) return error.InvalidWorkspaceArgs;
            positional[positional_len] = arg;
            positional_len += 1;
        },
    };

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

const SessionFlag = enum { id, json };
const session_flag_ids = cli_flags.idTable(SessionFlag, &builtin_commands.session_options);

/// The flags and the one target shared by `fx session` and
/// `fx session recover`. A repeated `--id` keeps its last value; two
/// targets, or a positional target with `--id`, are an error.
const SessionTargetArgs = struct {
    format: output_contracts.OutputFormat = .text,
    /// Trimmed and non-empty; null when no target was given.
    target: ?[]const u8 = null,
    /// The target came from `--id`, so `last` is a literal ID.
    exact_id: bool = false,
};

fn parseSessionTargetArgs(args: []const [:0]const u8) error{InvalidSessionArgs}!SessionTargetArgs {
    var parsed: SessionTargetArgs = .{};
    var positional: ?[]const u8 = null;
    var id_flag: ?[]const u8 = null;
    var parser: cli_flags.Parser = .initDashOperands(&builtin_commands.session_options, args);
    while (parser.next() catch return error.InvalidSessionArgs) |item| switch (item) {
        .positional => |arg| {
            if (positional != null) return error.InvalidSessionArgs;
            positional = arg;
        },
        .option => |match| switch (session_flag_ids[match.index].?) {
            .id => id_flag = match.value.?,
            .json => parsed.format = .json,
        },
    };
    if (positional != null and id_flag != null) return error.InvalidSessionArgs;
    const raw = id_flag orelse positional orelse return parsed;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidSessionArgs;
    parsed.target = trimmed;
    parsed.exact_id = id_flag != null;
    return parsed;
}

fn parseSessionDetailArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionDetailOptions {
    const parsed = parseSessionTargetArgs(args) catch return error.InvalidSessionDetailArgs;
    var options = SessionDetailOptions{ .format = parsed.format };
    const target = parsed.target orelse return options;
    options.target = if (!parsed.exact_id and std.mem.eql(u8, target, "last"))
        .last
    else
        .{ .id = try alloc.dupe(u8, target) };
    return options;
}

fn parseSessionRecoveryArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionRecoveryOptions {
    const parsed = parseSessionTargetArgs(args) catch return error.InvalidSessionRecoveryArgs;
    const target = parsed.target orelse return error.InvalidSessionRecoveryArgs;
    return .{
        .format = parsed.format,
        .session_id = try alloc.dupe(u8, target),
    };
}

fn parseResumeArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
    top_level_alias: bool,
) !ResumeTarget {
    if (args.len == 0) return .last;

    if (top_level_alias) {
        const flag = args[0];
        if (std.mem.startsWith(u8, flag, resume_inline_prefix)) {
            if (args.len != 1) return error.InvalidResumeArgs;
            return resumeFlagTarget(alloc, flag[resume_inline_prefix.len..]);
        }
        if (std.mem.eql(u8, flag, "--resume") or std.mem.eql(u8, flag, resume_short_flag)) {
            return switch (args.len) {
                1 => .pick,
                2 => resumeFlagTarget(alloc, args[1]),
                else => error.InvalidResumeArgs,
            };
        }
        if (std.mem.eql(u8, flag, "--resume-last")) return error.RemovedResumeLast;
        if (std.mem.startsWith(u8, flag, resume_id_alias_prefix)) return error.RemovedResumeIdAlias;
        if (args.len != 1) return error.InvalidResumeArgs;
        if (std.mem.eql(u8, flag, "-c") or std.mem.eql(u8, flag, "--continue")) return .remembered;
        return error.InvalidResumeArgs;
    }

    if (std.mem.eql(u8, args[0], "--resume")) return error.RemovedResumeLastFlag;
    if (std.mem.eql(u8, args[0], "--id")) return error.RemovedResumeIdFlag;
    if (args.len != 1) return error.InvalidResumeArgs;

    const trimmed = std.mem.trim(u8, args[0], " \t\r\n");
    if (trimmed.len == 0) return error.InvalidResumeArgs;
    if (std.mem.eql(u8, trimmed, "last")) return .last;
    return .{ .id = try alloc.dupe(u8, trimmed) };
}

/// The session a `--resume` or `-r` value names: `last`, or an exact ID.
fn resumeFlagTarget(alloc: Allocator, value: []const u8) !ResumeTarget {
    const id = std.mem.trim(u8, value, " \t\r\n");
    if (id.len == 0) return error.InvalidResumeArgs;
    if (std.mem.eql(u8, id, "last")) return .last;
    return .{ .id = try alloc.dupe(u8, id) };
}

/// The hint for a removed resume spelling, or null for any other error.
fn removedResumeHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.RemovedResumeLast => "fx: --resume-last was removed; use fx --resume last\n",
        error.RemovedResumeIdAlias => "fx: --resume-<id> was removed; use fx --resume <id>\n",
        error.RemovedResumeCommand => "fx: fx resume was removed; use fx --resume [last|<id>] or fx session resume [last|<id>]\n",
        error.RemovedResumeIdFlag => "fx session resume: --id was removed; use fx session resume <id>\n",
        error.RemovedResumeLastFlag => "fx session resume: --resume --last was removed; use fx session resume last\n",
        else => null,
    };
}

const WorkflowFlag = enum { permission_mode, ask, auto, full_access, yolo, provider, model, effort, fast, no_fast, ultrafast, no_ultrafast, provider_order, provider_strict, no_provider_strict, create };
// `fx issue` documents the same flags as `fx pr`.
const workflow_flag_ids = cli_flags.idTable(WorkflowFlag, &builtin_commands.pr_options);

/// Reads `--auto` and `--create`, then joins the rest into the context.
fn parseWorkflowArgs(alloc: Allocator, args: []const [:0]const u8, bad: *?BadAgentValue) !WorkflowOptions {
    var opts: WorkflowOptions = .{};
    errdefer opts.agent.deinit(alloc);
    var parser: cli_flags.Parser = .initPrefix(&builtin_commands.pr_options, args);
    // Prefix mode stops at positionals, so every item is an option.
    while (parser.next() catch return error.InvalidWorkflowArgs) |item| {
        const id = workflow_flag_ids[item.option.index].?;
        if (agent_run_flags.fromId(id)) |flag| {
            try applyAgentFlag(alloc, &opts.agent, flag, &builtin_commands.pr_options, item.option, bad);
            continue;
        }
        switch (id) {
            .create => opts.create = true,
            else => unreachable,
        }
    }
    // Context starts at the first argument that isn't a flag. A dash word
    // there is a flag this command doesn't take, such as a typo, not
    // context: context that starts with a dash follows `--`. Words after the
    // context starts are all context.
    var context_start = parser.index;
    if (context_start < args.len) {
        const arg = args[context_start];
        if (std.mem.eql(u8, arg, "--")) {
            context_start += 1;
        } else if (arg.len >= 2 and arg[0] == '-') {
            return error.InvalidWorkflowArgs;
        }
    }
    opts.context = try joinArgs(alloc, args[context_start..]);
    return opts;
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
    return builtin_commands.top_level_registry;
}

test "launch flags may follow the resume word and its target" {
    const alloc = std.testing.allocator;
    const command_catalog = testCommandCatalog();
    const Case = struct { args: []const [:0]const u8, target: std.meta.Tag(ResumeTarget), model: ?[]const u8 = null, fast: ?bool = null, prompt: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .args = &.{ "-c", "--model", "x" }, .target = .remembered, .model = "x" },
        .{ .args = &.{ "--continue", "--fast" }, .target = .remembered, .fast = true },
        .{ .args = &.{ "--resume", "last", "--model", "x" }, .target = .last, .model = "x" },
        .{ .args = &.{ "-r", "--model", "x" }, .target = .pick, .model = "x" },
        .{ .args = &.{ "-c", "hello world", "--model", "x" }, .target = .remembered, .model = "x", .prompt = "hello world" },
        .{ .args = &.{ "--model", "y", "-c", "--model", "x" }, .target = .remembered, .model = "x" },
        .{ .args = &.{ "session", "resume", "last", "--fast" }, .target = .last, .fast = true },
    };
    for (cases) |case| {
        var parsed = try parseInteractiveLaunch(alloc, case.args, command_catalog);
        switch (parsed) {
            .interactive => |*launch| {
                defer launch.deinit(alloc);
                try std.testing.expectEqual(case.target, std.meta.activeTag(launch.requested_resume.?));
                if (case.model) |model| try std.testing.expectEqualStrings(model, launch.modifiers.model_override.?);
                if (case.fast) |fast| try std.testing.expectEqual(fast, launch.modifiers.fast_override.?);
                if (case.prompt) |prompt| try std.testing.expectEqualStrings(prompt, launch.initial_prompt.?) else try std.testing.expect(launch.initial_prompt == null);
            },
            .noninteractive => |*value| {
                value.deinit(alloc);
                return error.TestExpectedInteractiveLaunch;
            },
        }
    }

    const bad: []const [:0]const u8 = &.{ "-c", "--bogus" };
    try std.testing.expectError(error.InvalidFlag, parseInteractiveLaunch(alloc, bad, command_catalog));
    try std.testing.expectEqualStrings("--bogus", launchFlagFailure(bad).?.unknown.flag);
    try std.testing.expectError(error.InvalidResumeArgs, parseInteractiveLaunch(alloc, &.{ "session", "resume", "last", "hello" }, command_catalog));
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
    switch (parse(command_catalog, &.{ @constCast("update"), @constCast("--channel"), @constCast("dev") })) {
        .upgrade => |rest| try std.testing.expectEqual(@as(usize, 2), rest.len),
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

test "usage arguments accept today, 7d or 30d and one JSON flag" {
    const defaults = try parseUsageArgs(&.{});
    try std.testing.expectEqual(usage.Period.month, defaults.period);
    try std.testing.expectEqual(output_contracts.OutputFormat.text, defaults.format);

    const selected = try parseUsageArgs(&.{
        @constCast("--json"),
        @constCast("--period"),
        @constCast("7d"),
    });
    try std.testing.expectEqual(usage.Period.days_7, selected.period);
    try std.testing.expectEqual(usage.Period.today, (try parseUsageArgs(&.{ @constCast("--period"), @constCast("today") })).period);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, selected.format);

    for ([_][]const [:0]const u8{
        &.{@constCast("--period")},
        &.{ @constCast("--period"), @constCast("session") },
        &.{ @constCast("--period"), @constCast("24h") },
        &.{@constCast("--period=")},
        &.{@constCast("--json=1")},
        &.{@constCast("30d")},
    }) |invalid| {
        try std.testing.expectError(error.InvalidUsageArgs, parseUsageArgs(invalid));
    }

    const last = try parseUsageArgs(&.{ "--period", "today", "--period=7d", "--json", "--json" });
    try std.testing.expectEqual(usage.Period.days_7, last.period);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, last.format);
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
        error.InvalidFlag,
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

test "global launch modifiers own provider model effort and fast overrides before the command" {
    var parsed = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("--provider"),
        @constCast("grok"),
        @constCast("--model"),
        @constCast("provider/launch-model"),
        @constCast("--effort=high"),
        @constCast("--fast"),
        @constCast("--add-dir"),
        @constCast("/tmp/shared"),
    });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?model_provider.ProviderId, .grok), parsed.modifiers.provider_override);
    try std.testing.expectEqualStrings("provider/launch-model", parsed.modifiers.model_override.?);
    try std.testing.expect(parsed.modifiers.effort_override.?.eql(types.ReasoningEffort.literal("high")));
    try std.testing.expectEqual(@as(?bool, true), parsed.modifiers.fast_override);
    try std.testing.expect(parsed.modifiers.hasModelOverrides());
    try std.testing.expectEqual(@as(usize, 1), parsed.modifiers.additional_directories.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.remaining.len);

    var routed = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("--provider-order"),
        @constCast("azure, anthropic"),
        @constCast("--provider-strict"),
    });
    defer routed.deinit(std.testing.allocator);
    const order = routed.modifiers.provider_order_override.?;
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expectEqualStrings("azure", order[0]);
    try std.testing.expectEqualStrings("anthropic", order[1]);
    try std.testing.expectEqual(@as(?bool, true), routed.modifiers.provider_strict_override);

    var spaced = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("--model= provider/spaced "),
        @constCast("--effort"),
        @constCast("low"),
        @constCast("--no-fast"),
    });
    defer spaced.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("provider/spaced", spaced.modifiers.model_override.?);
    try std.testing.expect(spaced.modifiers.effort_override.?.eql(types.ReasoningEffort.literal("low")));
    try std.testing.expectEqual(@as(?bool, false), spaced.modifiers.fast_override);

    var untouched = try parseGlobalLaunchArgs(std.testing.allocator, &.{ @constCast("ask"), @constCast("--fast") });
    defer untouched.deinit(std.testing.allocator);
    try std.testing.expect(!untouched.modifiers.hasModelOverrides());
    try std.testing.expectEqual(@as(usize, 2), untouched.remaining.len);
}

test "global launch modifiers accept configured provider names" {
    var parsed = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("--provider"),
        @constCast("my-llm"),
    });
    defer parsed.deinit(std.testing.allocator);

    const provider = parsed.modifiers.provider_override.?;
    try std.testing.expect(provider == .configured);
    try std.testing.expectEqualStrings("my-llm", provider.label());
}

test "global model overrides fail closed when malformed" {
    try std.testing.expectError(
        error.InvalidFlag,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--provider")}),
    );
    try std.testing.expectError(
        error.InvalidProviderValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{ @constCast("--provider"), @constCast("bogus name") }),
    );
    try std.testing.expectError(
        error.InvalidFlag,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--model")}),
    );
    try std.testing.expectError(
        error.MissingModelValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--model=")}),
    );
    try std.testing.expectError(
        error.InvalidFlag,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--effort")}),
    );
    try std.testing.expectError(
        error.InvalidEffortValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--effort=not an effort")}),
    );
    try std.testing.expectError(
        error.InvalidFlag,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--provider-order")}),
    );
    try std.testing.expectError(
        error.InvalidProviderOrderValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--provider-order=Bad Slug")}),
    );
    try std.testing.expectError(
        error.InvalidProviderOrderValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--provider-order=azure,azure")}),
    );
    try std.testing.expectError(
        error.InvalidPermissionModeValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--permission-mode=never")}),
    );
    try std.testing.expectError(
        error.InvalidFlag,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--fast=1")}),
    );
    try std.testing.expectEqualStrings("--model", launchFlagFailure(&.{@constCast("--model")}).?.missing_value);
    try std.testing.expectEqualStrings("--fast", launchFlagFailure(&.{@constCast("--fast=1")}).?.unexpected_value);
    try std.testing.expect(launchFlagFailure(&.{ @constCast("--fast"), @constCast("ask") }) == null);
}

test "global launch flags let the last one win" {
    const cases = [_]struct {
        args: []const [:0]const u8,
        fast: ?bool = null,
        ultrafast: ?bool = null,
        strict: ?bool = null,
        permission: ?types.PermissionMode = null,
    }{
        .{ .args = &.{ "--fast", "--no-fast" }, .fast = false, .ultrafast = false },
        .{ .args = &.{ "--no-fast", "--fast" }, .fast = true, .ultrafast = false },
        .{ .args = &.{ "--ultrafast", "--fast" }, .fast = true, .ultrafast = false },
        .{ .args = &.{ "--fast", "--ultrafast" }, .fast = false, .ultrafast = true },
        .{ .args = &.{ "--provider-strict", "--no-provider-strict" }, .strict = false },
        .{ .args = &.{ "--ask", "--full-access" }, .permission = .yolo },
        .{ .args = &.{ "--yolo", "--permission-mode", "auto" }, .permission = .auto },
        .{ .args = &.{ "--permission-mode=full-access", "--ask" }, .permission = .ask },
    };
    for (cases) |case| {
        var parsed = try parseGlobalLaunchArgs(std.testing.allocator, case.args);
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.fast, parsed.modifiers.fast_override);
        try std.testing.expectEqual(case.ultrafast, parsed.modifiers.ultrafast_override);
        try std.testing.expectEqual(case.strict, parsed.modifiers.provider_strict_override);
        try std.testing.expectEqual(case.permission, parsed.modifiers.permission_override);
        try std.testing.expectEqual(@as(usize, 0), parsed.remaining.len);
    }

    var repeated = try parseGlobalLaunchArgs(std.testing.allocator, &.{ "--model=a", "--model", "b", "--no-additional-dirs", "--no-additional-dirs", "-c" });
    defer repeated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("b", repeated.modifiers.model_override.?);
    try std.testing.expect(repeated.modifiers.saved_directories_suppressed);
    try std.testing.expectEqualStrings("-c", repeated.remaining[0]);
}

test "argsAfterGlobalLaunchArgs skips provider routing flags" {
    const remaining = argsAfterGlobalLaunchArgs(&.{
        @constCast("--provider-order"),
        @constCast("azure,anthropic"),
        @constCast("--provider-strict"),
        @constCast("ask"),
    });
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("ask", remaining[0]);

    const equals_form = argsAfterGlobalLaunchArgs(&.{
        @constCast("--provider-order=azure"),
        @constCast("--no-provider-strict"),
        @constCast("ask"),
    });
    try std.testing.expectEqual(@as(usize, 1), equals_form.len);
    try std.testing.expectEqualStrings("ask", equals_form[0]);
}

test "additional directory flags fail closed when malformed" {
    try std.testing.expectError(
        error.InvalidFlag,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--add-dir")}),
    );
    try std.testing.expectError(
        error.MissingAddDirectoryValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--add-dir=")}),
    );
}

test "parse acp args extracts known flags and rejects invalid arguments" {
    const alloc = std.testing.allocator;
    var bad: ?BadAgentValue = null;
    var opts = try parseAcpArgs(alloc, &.{ "--model", "openai/gpt-4o", "--log-file", "/tmp/fx.log" }, &bad);
    defer opts.deinit(alloc);
    try std.testing.expectEqualStrings("openai/gpt-4o", opts.agent.model.?);
    try std.testing.expectEqualStrings("/tmp/fx.log", opts.log_file.?);

    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(alloc, &.{"--unknown"}, &bad));
    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(alloc, &.{"--model"}, &bad));
    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(alloc, &.{"--log-file"}, &bad));
    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(alloc, &.{ "--model", "first", "stray" }, &bad));
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
    var rejected: ?[]const u8 = null;
    const defaults = try parseUpgradeArgs(&.{}, &rejected);
    try std.testing.expectEqual(output_contracts.OutputFormat.text, defaults.format);
    try std.testing.expect(defaults.channel == null);

    const selected = try parseUpgradeArgs(&.{
        @constCast("--channel"),
        @constCast("dev"),
        @constCast("--json"),
    }, &rejected);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, selected.format);
    try std.testing.expectEqual(update_target.Channel.dev, selected.channel.?);

    const stable = try parseUpgradeArgs(&.{@constCast("--channel=stable")}, &rejected);
    try std.testing.expectEqual(update_target.Channel.stable, stable.channel.?);
    try std.testing.expect(rejected == null);

    try std.testing.expectError(
        error.InvalidUpgradeArgs,
        parseUpgradeArgs(&.{ @constCast("--channel"), @constCast("nightly") }, &rejected),
    );
    try std.testing.expectEqualStrings("nightly", rejected.?);

    rejected = null;
    const last = try parseUpgradeArgs(&.{ "--channel=dev", "--channel", "stable" }, &rejected);
    try std.testing.expectEqual(update_target.Channel.stable, last.channel.?);
}

test "upgrade channel saved line says whether the file changed" {
    const alloc = std.testing.allocator;
    const set = try channelSavedLine(alloc, .dev, .{ .committed = .{ .scope = .user } });
    defer alloc.free(set);
    try std.testing.expectEqualStrings("Release channel set to dev in ~/.fx/settings.json.\n", set);

    const same = try channelSavedLine(alloc, .stable, .unchanged);
    defer alloc.free(same);
    try std.testing.expectEqualStrings("Release channel is already stable.\n", same);
}

test "runIfRequested names an upgrade channel that does not exist" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("upgrade"), @constCast("--channel=nightly") },
        testConfig(),
        capture.deps(),
    );
    try std.testing.expectEqual(usage_failure, result);
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expect(std.mem.startsWith(
        u8,
        capture.stderr.written(),
        "fx upgrade: invalid value for --channel: nightly\nusage: fx upgrade",
    ));
}

test "runIfRequested reports bad upgrade arguments as json with --json" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("upgrade"), @constCast("--json"), @constCast("--channel=nightly") },
        testConfig(),
        capture.deps(),
    );
    try std.testing.expectEqual(usage_failure, result);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"upgrade\",\"error\":\"invalid arguments\",\"code\":\"InvalidUpgradeArgs\"}\n",
        capture.stdout.written(),
    );
    try std.testing.expectEqualStrings("", capture.stderr.written());
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

    const repeated = try parseSessionListArgs(&.{ "--all", "--all", "--limit=5", "--limit", "3" });
    try std.testing.expectEqual(session_store.SessionListScope.all_workspaces, repeated.scope);
    try std.testing.expectEqual(@as(usize, 3), repeated.limit);
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

test "session target flags keep the last --id and reject two targets" {
    var repeated = try parseSessionDetailArgs(std.testing.allocator, &.{ "--id=a", "--id", "last", "--json" });
    defer repeated.deinit(std.testing.allocator);
    switch (repeated.target.?) {
        .id => |value| try std.testing.expectEqualStrings("last", value),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(output_contracts.OutputFormat.json, repeated.format);

    try std.testing.expectError(error.InvalidSessionDetailArgs, parseSessionDetailArgs(std.testing.allocator, &.{ "last", "--id", "a" }));
}

test "session targets accept a generated id that starts with a dash" {
    const alloc = std.testing.allocator;
    const id = "-_u88j00skyI";

    var detail = try parseSessionDetailArgs(alloc, &.{ "--json", id });
    defer detail.deinit(alloc);
    try std.testing.expectEqualStrings(id, detail.target.?.id);

    var recovery = try parseSessionRecoveryArgs(alloc, &.{ id, "--json" });
    defer recovery.deinit(alloc);
    try std.testing.expectEqualStrings(id, recovery.session_id);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, recovery.format);

    try std.testing.expectError(error.InvalidSessionRecoveryArgs, parseSessionRecoveryArgs(alloc, &.{ id, "--jsno" }));
    try std.testing.expectError(error.InvalidSessionDetailArgs, parseSessionDetailArgs(alloc, &.{ id, "-other" }));
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
    const implicit = try parseResumeArgs(std.testing.allocator, &.{}, false);
    try std.testing.expectEqual(ResumeTarget.last, implicit);

    const explicit = try parseResumeArgs(std.testing.allocator, &.{@constCast("last")}, false);
    try std.testing.expectEqual(ResumeTarget.last, explicit);

    var target = try parseResumeArgs(std.testing.allocator, &.{@constCast(" session-123 ")}, false);
    defer target.deinit(std.testing.allocator);
    switch (target) {
        .id => |value| try std.testing.expectEqualStrings("session-123", value),
        else => return error.TestExpectedEqual,
    }

    try std.testing.expectError(error.InvalidResumeArgs, parseResumeArgs(std.testing.allocator, &.{ @constCast("a"), @constCast("b") }, false));
    try std.testing.expectError(error.InvalidResumeArgs, parseResumeArgs(std.testing.allocator, &.{@constCast("   ")}, false));
}

test "removed resume spellings fail with a hint" {
    const cases = [_]struct { args: []const [:0]const u8, top_level_alias: bool, err: anyerror }{
        .{ .args = &.{ "--id", "release.2026.06" }, .top_level_alias = false, .err = error.RemovedResumeIdFlag },
        .{ .args = &.{ "--resume", "--last" }, .top_level_alias = false, .err = error.RemovedResumeLastFlag },
        .{ .args = &.{"--resume-last"}, .top_level_alias = true, .err = error.RemovedResumeLast },
        .{ .args = &.{"--resume-session.123"}, .top_level_alias = true, .err = error.RemovedResumeIdAlias },
    };
    for (cases) |case| {
        try std.testing.expectError(case.err, parseResumeArgs(std.testing.allocator, case.args, case.top_level_alias));
        try std.testing.expect(removedResumeHint(case.err) != null);
    }
}

test "parse resume args accepts an operand on the top-level resume flag" {
    var target = try parseResumeArgs(std.testing.allocator, &.{
        @constCast("--resume"),
        @constCast("session-123"),
    }, true);
    defer target.deinit(std.testing.allocator);

    switch (target) {
        .remembered, .pick, .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("session-123", id),
    }

    const latest = try parseResumeArgs(std.testing.allocator, &.{
        @constCast("--resume"),
        @constCast("last"),
    }, true);
    try std.testing.expectEqual(ResumeTarget.last, latest);
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
        .{ .args = &.{ @constCast("--resume"), @constCast("last") }, .expected_id = null },
        .{ .args = &.{ @constCast("--resume"), @constCast("session-123") }, .expected_id = "session-123" },
        .{ .args = &.{@constCast("--resume=session-123")}, .expected_id = "session-123" },
        .{ .args = &.{ @constCast("-r"), @constCast("last") }, .expected_id = null },
        .{ .args = &.{ @constCast("-r"), @constCast("session-123") }, .expected_id = "session-123" },
        .{ .args = &.{ @constCast("session"), @constCast("resume"), @constCast("last") }, .expected_id = null },
        .{ .args = &.{ @constCast("session"), @constCast("resume"), @constCast("session.v3") }, .expected_id = "session.v3" },
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
                    .remembered, .pick, .last => return error.TestExpectedExactResumeId,
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
            &.{ @constCast("--resume"), @constCast("one"), @constCast("a prompt"), @constCast("three") },
            command_catalog,
        ),
    );
    try std.testing.expectError(
        error.InvalidFlag,
        parseInteractiveLaunch(alloc, &.{@constCast("--add-dir")}, command_catalog),
    );
}

test "workflow drafts come only from the completed final response" {
    const alloc = std.testing.allocator;
    const final = "Add greeting constant\n\n## Summary\n\n- Export `greeting` from **greeting.ts**.";

    const draft = try draftFromRun(alloc, .{
        .exit_code = 0,
        .assistant_output = @constCast("Let me look at the branch first.\n\n" ++ final),
        .final_source = @constCast(final),
    });
    defer draft.deinit(alloc);
    try std.testing.expectEqualStrings("Add greeting constant", draft.title);
    try std.testing.expectEqualStrings("## Summary\n\n- Export `greeting` from **greeting.ts**.", draft.body);

    for ([_][]const u8{ "", "Done." }) |final_source| {
        try std.testing.expectError(error.InvalidGithubDraft, draftFromRun(alloc, .{
            .exit_code = 0,
            .assistant_output = @constCast("Let me look at the branch first."),
            .final_source = @constCast(final_source),
        }));
    }
}

test "parse workflow args consumes leading flags and joins remaining context exactly" {
    var bad: ?BadAgentValue = null;
    var opts = try parseWorkflowArgs(std.testing.allocator, &.{ "--auto", "--create", "ready", "for", "review" }, &bad);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.PermissionMode.auto, opts.agent.permission.?);
    try std.testing.expect(opts.create);
    try std.testing.expectEqualStrings("ready for review", opts.context);

    var later_flag = try parseWorkflowArgs(std.testing.allocator, &.{ "context", "--auto" }, &bad);
    defer later_flag.deinit(std.testing.allocator);
    try std.testing.expect(later_flag.agent.permission == null);
    try std.testing.expect(!later_flag.create);
    try std.testing.expectEqualStrings("context --auto", later_flag.context);

    var empty = try parseWorkflowArgs(std.testing.allocator, &.{}, &bad);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", empty.context);
}

test "pr and issue reject a flag they don't take instead of sending it as context" {
    var bad: ?BadAgentValue = null;
    try std.testing.expectError(error.InvalidWorkflowArgs, parseWorkflowArgs(std.testing.allocator, &.{ "--modle", "x" }, &bad));
    try std.testing.expectError(error.InvalidWorkflowArgs, parseWorkflowArgs(std.testing.allocator, &.{ "--auto", "--add-dir", "/tmp" }, &bad));
    try std.testing.expectError(error.InvalidWorkflowArgs, parseWorkflowArgs(std.testing.allocator, &.{ "--config", "fast_mode=true" }, &bad));

    var dashed = try parseWorkflowArgs(std.testing.allocator, &.{ "--create", "--", "--verbose", "is", "gone" }, &bad);
    defer dashed.deinit(std.testing.allocator);
    try std.testing.expect(dashed.create);
    try std.testing.expectEqualStrings("--verbose is gone", dashed.context);
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

// `builtins/mcp.zig` "fx mcp approve saves the approval of a project server"
// checks what approving saves.
test "top-level MCP approve runs without interactive startup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    try environ.put("HOME", home);
    try environ.put("PATH", "");
    io_mod.setEnvironMap(&environ);
    defer io_mod.resetEnvironForTest();

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();
    var deps = capture.deps();
    deps.load_startup_state_without_credentials = failingStartupStateWithoutCredentials;

    const result = try runIfRequestedWithDeps(
        alloc,
        &.{ @constCast("mcp"), @constCast("approve"), @constCast("fixture") },
        testConfig(),
        deps,
    );
    // The test config loads no host, so there is no project server to approve.
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expectEqualStrings("No project server named fixture in .mcp.json.\n", capture.stderr.written());
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
    try std.testing.expectEqual(usage_failure, result);
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
            .expected = "fx: --add-dir needs a value\n",
        },
        .{
            .args = &.{@constCast("--add-dir=")},
            .expected = "fx: --add-dir requires a directory path\n",
        },
        .{
            .args = &.{@constCast("--fast=on")},
            .expected = "fx: --fast doesn't take a value\n",
        },
    };

    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();
        const deps = capture.deps();

        const result = try runIfRequestedWithDeps(std.testing.allocator, case.args, testConfig(), deps);
        try std.testing.expectEqual(usage_failure, result);
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
        try std.testing.expectEqual(usage_failure, result);
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
        "fx setup is deprecated and stops working in fx 0.0.17; use fx login vercel --api-key\n" ++
            "fx setup: stored API keys are disabled by FX_DISABLE_KEYCHAIN\n",
        capture.stderr.written(),
    );
}

test "login --api-key stores a pasted key like setup, without the deprecation warning" {
    for ([_][]const [:0]const u8{
        &.{"--api-key"},
        &.{ "vercel", "--api-key" },
        &.{ "--api-key", "vercel" },
    }) |rest| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();
        var cfg = testConfig();
        cfg.secret_store = capture.secretStore();
        var argv: [3][:0]const u8 = undefined;
        argv[0] = "login";
        @memcpy(argv[1 .. rest.len + 1], rest);

        const result = try runIfRequestedWithDeps(std.testing.allocator, argv[0 .. rest.len + 1], cfg, capture.deps());
        try std.testing.expectEqual(RunResult.handled_success, result);
        try std.testing.expectEqual(@as(usize, 1), capture.setup_store_calls);
        try std.testing.expect(capture.setup_value_matched);
        try std.testing.expect(std.mem.find(u8, capture.stderr.written(), "deprecated") == null);
        try std.testing.expect(std.mem.find(u8, capture.stdout.written(), cfg.secret_store.backend_label) != null);
    }

    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    capture.setup_store_disabled = true;
    var cfg = testConfig();
    cfg.secret_store = capture.secretStore();
    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ "login", "--api-key" }, cfg, capture.deps());
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("fx login: stored API keys are disabled by FX_DISABLE_KEYCHAIN\n", capture.stderr.written());
}

test "login arguments take one provider and --api-key only for vercel" {
    try std.testing.expectEqual(LoginArgs{}, try parseLoginArgs(&.{}));
    try std.testing.expectEqual(LoginArgs{ .provider = .codex }, try parseLoginArgs(&.{"codex"}));
    try std.testing.expectEqual(LoginArgs{ .provider = .gateway, .api_key = true }, try parseLoginArgs(&.{ "--api-key", "vercel" }));
    try std.testing.expectError(error.ApiKeyNeedsVercel, parseLoginArgs(&.{ "codex", "--api-key" }));
    try std.testing.expectError(error.InvalidLoginProviderArgs, parseLoginArgs(&.{ "vercel", "codex" }));
    try std.testing.expectError(error.InvalidLoginProviderArgs, parseLoginArgs(&.{"--bogus"}));
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

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("--record")},
        testConfig(),
        capture.deps(),
    );
    try std.testing.expectEqual(usage_failure, result);
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr.written(), "fx: unknown flag --record\nusage: fx "));
}

test "global ultrafast launch modifier is ACP-only" {
    var acp = try parseGlobalLaunchArgs(
        std.testing.allocator,
        &.{ @constCast("--ultrafast"), @constCast("acp") },
    );
    defer acp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, true), acp.modifiers.ultrafast_override);
    try std.testing.expect(acp.modifiers.hasOnlyUltrafastOverride());
    try std.testing.expectEqualStrings("acp", acp.remaining[0]);
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
    try std.testing.expectEqual(usage_failure, result);
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
}
test "runIfRequested invalid local flags write usage" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("status"), @constCast("--wat") }, testConfig(), capture.deps());
    try std.testing.expectEqual(usage_failure, result);
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expectEqualStrings("fx status: unknown flag --wat\nusage: fx status [--json]\n", capture.stderr.written());
}

test "runIfRequested names the bad flag after a session id that starts with a dash" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("session"), @constCast("recover"), @constCast("-_u88j00skyI"), @constCast("--jsno") },
        testConfig(),
        capture.deps(),
    );
    try std.testing.expectEqual(usage_failure, result);
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr.written(), "fx session: unknown flag --jsno (did you mean --json?)\n"));
}

test "runIfRequested invalid json local flags write json error" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("status"), @constCast("--json"), @constCast("--wat") }, testConfig(), capture.deps());
    try std.testing.expectEqual(usage_failure, result);
    try std.testing.expectEqualStrings("", capture.stderr.written());
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"kind\":\"status\"") != null);
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"code\":\"InvalidLocalSurfaceArgs\"") != null);
}

test "runIfRequested resume no args returns last target" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("session"), @constCast("resume") }, testConfig(), capture.deps());
    switch (result) {
        .interactive => |launch| try std.testing.expectEqual(ResumeTarget.last, launch.requested_resume.?),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "runIfRequested -r and a bare --resume ask which session to resume" {
    const spellings = [_][]const [:0]const u8{
        &.{@constCast("-r")},
        &.{@constCast("--resume")},
    };
    for (spellings) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(
            std.testing.allocator,
            args,
            testConfig(),
            capture.deps(),
        );
        switch (result) {
            .interactive => |launch| try std.testing.expectEqual(ResumeTarget.pick, launch.requested_resume.?),
            else => return error.TestExpectedEqual,
        }
        try std.testing.expectEqualStrings("", capture.stdout.written());
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }

    var extra_capture = CaptureOutput.init(std.testing.allocator);
    defer extra_capture.deinit();
    const extra = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("-r"), @constCast("session.123"), @constCast("a prompt"), @constCast("extra") },
        testConfig(),
        extra_capture.deps(),
    );
    try std.testing.expectEqual(usage_failure, extra);
}

test "runIfRequested top-level resume aliases return the existing target" {
    const aliases = [_][]const [:0]const u8{
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
            .interactive => |launch| {
                try std.testing.expectEqual(ResumeTarget.remembered, launch.requested_resume.?);
            },
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
                .remembered, .pick, .last => return error.TestExpectedExactResumeId,
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "runIfRequested removed resume spellings exit with the replacement" {
    const cases = [_]struct { args: []const [:0]const u8, stderr: []const u8 }{
        .{ .args = &.{"--resume-session.123"}, .stderr = "fx: --resume-<id> was removed; use fx --resume <id>\n" },
        .{ .args = &.{"--resume-"}, .stderr = "fx: --resume-<id> was removed; use fx --resume <id>\n" },
        .{ .args = &.{ "--resume-last", "unexpected" }, .stderr = "fx: --resume-last was removed; use fx --resume last\n" },
        .{ .args = &.{ "resume", "--resume", "--last" }, .stderr = "fx: fx resume was removed; use fx --resume [last|<id>] or fx session resume [last|<id>]\n" },
        .{ .args = &.{ "resume", "--resume" }, .stderr = "fx: fx resume was removed; use fx --resume [last|<id>] or fx session resume [last|<id>]\n" },
    };
    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(std.testing.allocator, case.args, testConfig(), capture.deps());
        try std.testing.expectEqual(usage_failure, result);
        try std.testing.expectEqualStrings(case.stderr, capture.stderr.written());
    }
}

test "runIfRequested rejects malformed resume aliases with canonical usage" {
    const cases = [_][]const [:0]const u8{
        &.{ @constCast("--continue"), @constCast("unexpected"), @constCast("extra") },
        &.{ @constCast("--resume"), @constCast("   ") },
        &.{ @constCast("session"), @constCast("resume"), @constCast("a"), @constCast("b") },
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
        try std.testing.expectEqual(usage_failure, result);
        try std.testing.expectEqualStrings(
            "usage: fx session resume [last|<id>] | -r, --resume [last|<id>] | --continue | -c\n",
            capture.stderr.written(),
        );
    }
}

test "runIfRequested resume id returns owned id" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("--resume"), @constCast("abc123") }, testConfig(), capture.deps());
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

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("--resume"), @constCast("a"), @constCast("b"), @constCast("c") }, testConfig(), capture.deps());
    try std.testing.expectEqual(usage_failure, result);
    try std.testing.expectEqualStrings(
        "usage: fx session resume [last|<id>] | -r, --resume [last|<id>] | --continue | -c\n",
        capture.stderr.written(),
    );
}

test "runIfRequested takes one argument that isn't a command as the first prompt" {
    const cases = [_]struct {
        args: []const [:0]const u8,
        prompt: []const u8,
        model: ?[]const u8 = null,
    }{
        .{ .args = &.{@constCast("wat")}, .prompt = "wat" },
        .{ .args = &.{@constCast("fix the login bug")}, .prompt = "fix the login bug" },
        // Short words stay prompts rather than typos of short commands.
        .{ .args = &.{@constCast("add")}, .prompt = "add" },
        .{ .args = &.{ @constCast("--model"), @constCast("a"), @constCast("fix it") }, .prompt = "fix it", .model = "a" },
        .{ .args = &.{ @constCast("fix it"), @constCast("--model=b") }, .prompt = "fix it", .model = "b" },
        .{ .args = &.{ @constCast("--model=a"), @constCast("fix it"), @constCast("--model"), @constCast("b") }, .prompt = "fix it", .model = "b" },
        .{ .args = &.{ @constCast("--"), @constCast("-p is a flag?") }, .prompt = "-p is a flag?" },
    };
    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(std.testing.allocator, case.args, testConfig(), capture.deps());
        var launch = switch (result) {
            .interactive => |value| value,
            else => return error.TestExpectedInteractiveLaunch,
        };
        defer launch.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.prompt, launch.initial_prompt.?);
        try std.testing.expect(launch.requested_resume == null);
        if (case.model) |model| {
            try std.testing.expectEqualStrings(model, launch.modifiers.model_override.?);
        } else {
            try std.testing.expect(launch.modifiers.model_override == null);
        }
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }
}

test "runIfRequested takes a first prompt after a resume target" {
    const cases = [_]struct {
        args: []const [:0]const u8,
        target: std.meta.Tag(ResumeTarget),
        id: ?[]const u8 = null,
    }{
        .{ .args = &.{ @constCast("-c"), @constCast("fix it") }, .target = .remembered },
        .{ .args = &.{ @constCast("--continue"), @constCast("fix it") }, .target = .remembered },
        .{ .args = &.{ @constCast("-r"), @constCast("last"), @constCast("fix it") }, .target = .last },
        .{ .args = &.{ @constCast("-r"), @constCast("session.123"), @constCast("fix it") }, .target = .id, .id = "session.123" },
        .{ .args = &.{ @constCast("--resume"), @constCast("session.123"), @constCast("fix it") }, .target = .id, .id = "session.123" },
        .{ .args = &.{ @constCast("--resume=last"), @constCast("fix it") }, .target = .last },
        .{ .args = &.{ @constCast("--model"), @constCast("a"), @constCast("-c"), @constCast("fix it") }, .target = .remembered },
    };
    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(std.testing.allocator, case.args, testConfig(), capture.deps());
        var launch = switch (result) {
            .interactive => |value| value,
            else => return error.TestExpectedInteractiveLaunch,
        };
        defer launch.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("fix it", launch.initial_prompt.?);
        const target = launch.requested_resume.?;
        try std.testing.expectEqual(case.target, std.meta.activeTag(target));
        if (case.id) |id| try std.testing.expectEqualStrings(id, target.id);
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }

    // A second word after the prompt is a usage error. Launch flags may
    // follow the target or the prompt; another test covers them.
    const rejected = [_][]const [:0]const u8{
        &.{ @constCast("-r"), @constCast("a"), @constCast("b"), @constCast("c") },
        &.{ @constCast("-c"), @constCast("fix it"), @constCast("again") },
    };
    for (rejected) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();
        const result = try runIfRequestedWithDeps(std.testing.allocator, args, testConfig(), capture.deps());
        try std.testing.expectEqual(usage_failure, result);
    }

    var empty_capture = CaptureOutput.init(std.testing.allocator);
    defer empty_capture.deinit();
    const empty = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("-c"), @constCast(" ") }, testConfig(), empty_capture.deps());
    try std.testing.expectEqual(usage_failure, empty);
    try std.testing.expectEqualStrings("fx: the prompt is empty\n", empty_capture.stderr.written());
}

test "runIfRequested explains a first argument that is neither a command nor a prompt" {
    const cases = [_]struct {
        args: []const [:0]const u8,
        stderr: []const u8,
    }{
        .{
            .args = &.{ @constCast("fix"), @constCast("the"), @constCast("login"), @constCast("bug") },
            .stderr = "fx: put the prompt in quotes: fx \"fix the login bug\"\n",
        },
        .{
            .args = &.{ @constCast("--fast"), @constCast("fix"), @constCast("it") },
            .stderr = "fx: put the prompt in quotes: fx \"fix it\"\n",
        },
        .{ .args = &.{@constCast("stauts")}, .stderr = "fx: unknown command stauts (did you mean status?)\n" },
        .{ .args = &.{ @constCast("sesions"), @constCast("--json") }, .stderr = "fx: unknown command sesions (did you mean sessions?)\n" },
        .{ .args = &.{@constCast("version")}, .stderr = "fx: unknown command version (did you mean --version?)\n" },
        .{
            .args = &.{ @constCast("-p"), @constCast("fix the bug") },
            .stderr = "fx: -p isn't an fx flag; to run one request and exit, use fx ask \"fix the bug\"\n",
        },
        .{
            .args = &.{@constCast("--print")},
            .stderr = "fx: --print isn't an fx flag; to run one request and exit, use fx ask \"<prompt>\"\n",
        },
        .{
            .args = &.{@constCast("--print=fix it")},
            .stderr = "fx: --print isn't an fx flag; to run one request and exit, use fx ask \"fix it\"\n",
        },
        .{ .args = &.{@constCast(" ")}, .stderr = "fx: the prompt is empty\n" },
    };
    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(std.testing.allocator, case.args, testConfig(), capture.deps());
        try std.testing.expectEqual(usage_failure, result);
        try std.testing.expectEqualStrings(case.stderr, capture.stderr.written());
        try std.testing.expectEqualStrings("", capture.stdout.written());
    }
}

test "runIfRequested suggests the nearest flag for an unknown one, before or after a prompt" {
    const cases = [_]struct {
        args: []const [:0]const u8,
        first_line: []const u8,
    }{
        .{ .args = &.{ @constCast("--modle"), @constCast("x") }, .first_line = "fx: unknown flag --modle (did you mean --model?)\n" },
        .{ .args = &.{@constCast("--verison")}, .first_line = "fx: unknown flag --verison (did you mean --version?)\n" },
        .{ .args = &.{ @constCast("fix it"), @constCast("--modle=x") }, .first_line = "fx: unknown flag --modle (did you mean --model?)\n" },
    };
    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(std.testing.allocator, case.args, testConfig(), capture.deps());
        try std.testing.expectEqual(usage_failure, result);
        try std.testing.expect(std.mem.startsWith(u8, capture.stderr.written(), case.first_line));
    }
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

test "runIfRequested models json describes each model from its catalog entry" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = ModelFetchProbe{ .outcome = .described };
    var cfg = testConfig();
    cfg.provider_set.gateway.cli_model_catalog = probe.provider();

    var deps = capture.deps();
    deps.load_startup_state = stubLoadStartupState;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("models"), @constCast("--json") }, cfg, deps);
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"models\",\"count\":1,\"shown_count\":1,\"more_count\":0,\"private_models_hidden\":false," ++
            "\"ids\":[\"private/blue-hornbill\"],\"models\":[{\"id\":\"private/blue-hornbill\",\"name\":\"Blue Hornbill\"," ++
            "\"efforts\":[\"low\",\"high\"],\"fast\":true,\"ultrafast\":true}]}\n",
        capture.stdout.written(),
    );
}

test "modelDetails lets the catalog entry decide and keeps Ultrafast to the Gateway" {
    const Fallback = struct {
        fn capabilities(_: []const u8) model_capabilities.Capabilities {
            return .{
                .supports_fast_mode = true,
                .reasoning_efforts = .fromSlice(&.{types.ReasoningEffort.literal("medium")}),
            };
        }
    };
    var bundle = testConfig().provider_set.gateway;
    bundle.fallback_model_capabilities_fn = Fallback.capabilities;
    const entries = [_]model_catalog.ModelCatalogEntry{.{
        .id = @constCast("openai/gpt-6-astra"),
        .name = @constCast("GPT-6 Astra"),
        .model_type = @constCast("language"),
        .supports_ultrafast_mode = true,
    }};
    const ids = [_][]const u8{ "openai/gpt-6-astra", "provider/unlisted" };

    const gateway = try modelDetails(std.testing.allocator, &ids, &entries, bundle, .gateway);
    defer std.testing.allocator.free(gateway);
    try std.testing.expectEqualStrings("GPT-6 Astra", gateway[0].name.?);
    try std.testing.expect(gateway[0].ultrafast);
    try std.testing.expect(!gateway[0].fast);
    try std.testing.expectEqual(@as(usize, 0), gateway[0].efforts.len);
    try std.testing.expectEqual(@as(?[]const u8, null), gateway[1].name);
    try std.testing.expect(gateway[1].fast);
    try std.testing.expectEqualStrings("medium", gateway[1].efforts.slice()[0].label());

    const codex = try modelDetails(std.testing.allocator, &ids, &entries, bundle, .codex);
    defer std.testing.allocator.free(codex);
    try std.testing.expect(!codex[0].ultrafast);

    const undescribed = try modelDetails(std.testing.allocator, &ids, &.{}, bundle, .gateway);
    try std.testing.expectEqual(@as(usize, 0), undescribed.len);
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
        "{\"kind\":\"status\",\"model\":\"test-model\",\"model_origin\":\"default\",\"effort\":\"auto\",\"update_channel\":\"stable\",\"build_channel\":\"stable\",\"build_revision\":\"\",\"auth\":\"missing\",\"auth_refreshable\":false,\"auth_help\":\"fx needs access to Vercel AI Gateway. Run fx login to sign in, fx login vercel --api-key to use an API key, or set AI_GATEWAY_API_KEY.\",\"permission_mode\":\"auto\",\"workspace\":\"/tmp/fx\",\"history_turns\":0,\"session_permission_grants\":0,\"agent_step_limit\":42,\"ultrafast_requested\":false,\"mcp\":{\"connection_check\":\"not_checked\",\"servers\":[],\"configuration_issues\":[],\"inspection_error\":null}}\n",
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
    io_mod.setEnvironMap(&environ);
    defer io_mod.resetEnvironForTest();

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
        .ultrafast_mode = true,
    };

    try writeRenderedJsonLine(
        std.testing.allocator,
        capture.deps(),
        tiny_buf[0..],
        .{ .status = statusSnapshotFromStartup(startup) },
    );

    try std.testing.expectEqualStrings(
        "{\"kind\":\"status\",\"model\":\"test-model\",\"model_origin\":\"default\",\"effort\":\"auto\",\"update_channel\":\"stable\",\"build_channel\":\"stable\",\"build_revision\":\"\",\"auth\":\"missing\",\"auth_refreshable\":false,\"auth_help\":\"fx needs access to Vercel AI Gateway. Run fx login to sign in, fx login vercel --api-key to use an API key, or set AI_GATEWAY_API_KEY.\",\"permission_mode\":\"ask\",\"workspace\":\"/tmp/fx\",\"history_turns\":0,\"session_permission_grants\":0,\"agent_step_limit\":42,\"ultrafast_requested\":true}\n",
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

fn clearMcpConfigInspectionForTest(
    _: Allocator,
) error{OutOfMemory}!mcp_contract.ProfileConfigDiagnostic {
    return .clear;
}

var mcp_local_inspection_calls_for_test: usize = 0;
var mcp_profile_add_calls_for_test: usize = 0;
var mcp_profile_remove_calls_for_test: usize = 0;

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
        /// Succeeds with the catalog entry behind the id, as the Gateway does.
        described,
        failure,
        cancelled,
    };

    called: bool = false,
    outcome: Outcome = .success,

    fn describedEntry(alloc: Allocator) !model_catalog.ModelCatalogEntry {
        const id = try alloc.dupe(u8, "private/blue-hornbill");
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, "Blue Hornbill");
        errdefer alloc.free(name);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer efforts.deinit(alloc);
        try efforts.appendSlice(alloc, &.{ types.ReasoningEffort.literal("low"), types.ReasoningEffort.literal("high") });
        return .{
            .id = id,
            .name = name,
            .model_type = model_type,
            .reasoning_efforts = efforts,
            .supports_fast_mode = true,
            .supports_ultrafast_mode = true,
        };
    }

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
            .success, .described => {},
        }

        var ids: std.ArrayList([]u8) = .empty;
        const id = alloc.dupe(u8, "private/blue-hornbill") catch {
            return failure(input, .resource_exhausted);
        };
        ids.append(alloc, id) catch {
            alloc.free(id);
            return failure(input, .resource_exhausted);
        };
        var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
        if (self.outcome == .described) {
            const entry = describedEntry(alloc) catch {
                collections.freeStringList(alloc, &ids);
                return failure(input, .resource_exhausted);
            };
            entries.append(alloc, entry) catch {
                model_catalog.freeModelCatalogEntry(alloc, entry);
                collections.freeStringList(alloc, &ids);
                return failure(input, .resource_exhausted);
            };
        }
        return .{ .loaded = .{
            .ids = ids,
            .entries = entries,
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

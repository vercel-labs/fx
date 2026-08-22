const std = @import("std");
const std_builtin = @import("builtin");
const command_admission = @import("../permissions/command_admission.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const app_lifecycle = @import("../app/app_lifecycle.zig");
const app_runtime_setup = @import("../app/app_runtime_setup.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const background_runtime = @import("../background/background_runtime.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const background_store = @import("../background/background_store.zig");
const process_supervisor = @import("../background/process_supervisor.zig");
const context_contract = @import("../workspace/context_contract.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const host = @import("../hosts/host.zig");
const pathing = @import("../workspace/pathing.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const gateway_error_format = @import("../shared/gateway_error_format.zig");
const image_attachments = @import("../images/image_attachments.zig");
const hooks = @import("../hooks/hooks.zig");
const notification_sound = @import("../notifications/sound.zig");
const io_mod = @import("../shared/io.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const mcp_elicitation_interaction = @import("../mcp/elicitation_interaction.zig");
const mcp_elicitation = @import("../mcp/elicitation.zig");
const mcp_access_policy = @import("../mcp/access_policy.zig");
const mcp_model_catalog = @import("../mcp/model_catalog.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const permission_gate = @import("../permissions/permission_gate.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permissions = @import("../permissions/permissions.zig");
const session_runtime = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_usage = @import("../session/session_usage.zig");
const usage_report = @import("../session/usage_report.zig");
const session_store = @import("../session/session_store.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_agent_adapter = @import("../subagent/agent_adapter.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_execution = @import("../subagent/execution.zig");
const subagent_manager = @import("../subagent/manager.zig");
const subagent_resume_admission = @import("../subagent/resume_admission.zig");
const parent_delivery_projector = @import("../subagent/parent_delivery_projector.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const text_utils = @import("../shared/text_utils.zig");
const test_builtin_gateway = if (std_builtin.is_test)
    @import("../../builtins/gateway.zig")
else
    struct {};
const builtin_tools = @import("../../builtins/tools.zig");
const tool_advertisement = @import("../tooling/tool_advertisement.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_args = @import("../tooling/tool_args.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const tool_specs = @import("../tooling/tool_specs.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const web_fetch_runtime = @import("../tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../tooling/web_search_runtime.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const ask_presentation = @import("../../ui/ask_presentation.zig");
const url_opener = @import("../hosts/url_opener.zig");

const Allocator = std.mem.Allocator;
const BackgroundRuntime = background_runtime.BackgroundRuntime;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const ImageAttachment = types.ImageAttachment;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const SessionRuntime = session_runtime.SessionRuntime;
const ToolCall = types.ToolCall;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const ToolPermissionDecision = types.ToolPermissionDecision;
const WorkerEvent = worker_runtime.WorkerEvent;
const WorkerRuntime = worker_runtime.WorkerRuntime;
const McpHasToolFn = tool_mcp_runtime.HasToolFn;

const supports_headless_interrupt = switch (std_builtin.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

const HeadlessInterruptInstallError = error{HeadlessInterruptBusy};
const headless_interrupt_exit_code: u8 = 130;
const headless_termination_exit_code: u8 = 143;

const headless_interrupt = if (supports_headless_interrupt) struct {
    var coordinator_mutex: std.Io.Mutex = .init;
    var coordinator_active = false;
    var cancel_requested = std.atomic.Value(bool).init(false);
    var requested_signal = std.atomic.Value(u8).init(0);
    var test_after_reset_before_install: if (std_builtin.is_test) ?*const fn () void else void =
        if (std_builtin.is_test) null else {};
    var test_after_restore: if (std_builtin.is_test) ?*const fn () void else void =
        if (std_builtin.is_test) null else {};

    fn handle(signal: std.posix.SIG) callconv(.c) void {
        _ = requested_signal.cmpxchgStrong(
            0,
            @intCast(@intFromEnum(signal)),
            .seq_cst,
            .seq_cst,
        );
        cancel_requested.store(true, .seq_cst);
    }

    fn exitCode() u8 {
        return switch (@as(std.posix.SIG, @enumFromInt(requested_signal.load(.seq_cst)))) {
            std.posix.SIG.TERM => headless_termination_exit_code,
            else => headless_interrupt_exit_code,
        };
    }

    const Scope = struct {
        old_sigint_action: std.posix.Sigaction = undefined,
        old_sigterm_action: std.posix.Sigaction = undefined,
        installed: bool = false,

        fn install(enabled: bool) HeadlessInterruptInstallError!Scope {
            if (!enabled) return .{};
            coordinator_mutex.lockUncancelable(io_mod.getIo());
            defer coordinator_mutex.unlock(io_mod.getIo());
            if (coordinator_active) return error.HeadlessInterruptBusy;

            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = handle },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            var scope = Scope{};
            requested_signal.store(0, .seq_cst);
            cancel_requested.store(false, .seq_cst);
            if (std_builtin.is_test) {
                if (test_after_reset_before_install) |hook| hook();
            }
            std.posix.sigaction(std.posix.SIG.INT, &action, &scope.old_sigint_action);
            std.posix.sigaction(std.posix.SIG.TERM, &action, &scope.old_sigterm_action);
            coordinator_active = true;
            scope.installed = true;
            return scope;
        }

        fn restore(self: *Scope, redeliver: bool) void {
            if (!self.installed) return;
            coordinator_mutex.lockUncancelable(io_mod.getIo());
            defer coordinator_mutex.unlock(io_mod.getIo());
            std.debug.assert(coordinator_active);
            std.posix.sigaction(std.posix.SIG.INT, &self.old_sigint_action, null);
            std.posix.sigaction(std.posix.SIG.TERM, &self.old_sigterm_action, null);
            if (std_builtin.is_test) {
                if (test_after_restore) |hook| hook();
            }
            if (redeliver and cancel_requested.load(.seq_cst)) {
                const signal: std.posix.SIG = @enumFromInt(requested_signal.load(.seq_cst));
                _ = std.c.raise(signal);
            }
            coordinator_active = false;
            self.installed = false;
        }

        fn deinit(self: *Scope) void {
            self.restore(false);
        }

        fn restoreAndRedeliver(self: *Scope) void {
            self.restore(true);
        }

        fn requested(self: *const Scope) bool {
            return self.installed and cancel_requested.load(.seq_cst);
        }
    };
} else struct {
    fn exitCode() u8 {
        return headless_interrupt_exit_code;
    }

    const Scope = struct {
        fn install(_: bool) HeadlessInterruptInstallError!Scope {
            return .{};
        }

        fn deinit(_: *Scope) void {}

        fn restoreAndRedeliver(_: *Scope) void {}

        fn requested(_: *const Scope) bool {
            return false;
        }
    };
};

pub const Config = struct {
    command_usage: []const u8,
    default_model: []const u8,
    default_agent_step_limit: usize,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_models_path: []const u8,
    gateway_provider: gateway_provider.Provider,
    codex_agent_stream: ?agent_stream_provider.Provider = null,
    codex_model_catalog: ?model_catalog.Provider = null,
    grok_agent_stream: ?agent_stream_provider.Provider = null,
    grok_model_catalog: ?model_catalog.Provider = null,
    claude_agent_stream: ?agent_stream_provider.Provider = null,
    claude_model_catalog: ?model_catalog.Provider = null,
    background_process_provider: background_process_provider.Provider =
        background_process_provider.unavailable_provider,
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
    mode_registry: mode_registry.Registry,
    load_mcp_runtime: mcp_runtime.LoadRuntimeFn,
    permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    codex_permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    grok_permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    claude_permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    context_limit_overrides: []const config_runtime.context_limits.Override = &.{},
    additional_directories: []const []const u8 = &.{},
    saved_directories_suppressed: bool = false,
};

fn runAskChild(
    raw: ?*anyopaque,
    turn: *subagent_execution.TurnContext,
    message: subagent_domain.QueuedMessage,
    admission: subagent_domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) subagent_execution.ServiceError!subagent_execution.RunOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    var child_projection = ctx.cfg.mode_registry.buildGatewayToolProjection(
        ctx.alloc,
        ctx.deps.tool_set,
        ctx.mode_id,
        .{
            .permission_mode = admission.permission_mode,
            .permission_rules = admission.rules,
            .mcp_runtime = ctx.mcp,
            .subagent_available = true,
        },
    ) catch return error.OutOfMemory;
    defer child_projection.deinit(ctx.alloc);
    return subagent_agent_adapter.run(.{
        .host = ctx.subagent_host orelse return error.ProviderFailed,
        .tool_context = ctx.toolContext(),
        .provider_routes = .{
            .gateway = .{
                .agent_stream_provider = ctx.cfg.gateway_provider.agent_stream,
                .permission_reviewer_provider = ctx.cfg.permission_reviewer_provider,
            },
            .codex = .{
                .agent_stream_provider = ctx.cfg.codex_agent_stream orelse agent_stream_provider.unavailable_provider,
                .permission_reviewer_provider = ctx.cfg.codex_permission_reviewer_provider,
            },
            .grok = .{
                .agent_stream_provider = ctx.cfg.grok_agent_stream orelse agent_stream_provider.unavailable_provider,
                .permission_reviewer_provider = ctx.cfg.grok_permission_reviewer_provider,
            },
            .claude = .{
                .agent_stream_provider = ctx.cfg.claude_agent_stream orelse agent_stream_provider.unavailable_provider,
                .permission_reviewer_provider = ctx.cfg.claude_permission_reviewer_provider,
            },
        },
        .system_prompt = ctx.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = ctx.cfg.prompt_policy.modelPromptOverlay(admission.model),
        .skills_prompt_section = ctx.subagent_skills_prompt,
        .explicit_skills_prompt_section = ctx.subagent_explicit_skills_prompt,
        .gateway_tools_json = child_projection.tools_json,
        .custom_tool_guidance = child_projection.custom_guidance,
        .context_registry = ctx.deps.context_registry,
        .context_enabled = ctx.context_enabled,
        .project_context = ctx.modelVisibleProjectContext(),
        .lifecycle_view = ctx.lifecycle_view,
    }, turn, message, admission, cancel);
}

pub const PromptRunResult = struct {
    exit_code: u8,
    assistant_output: []u8,
    interrupted: bool = false,
    model: []u8 = &.{},
    session_id: []u8 = &.{},
    tool_calls: []ToolCallRecord = &.{},
    step_count: usize = 0,
    error_code: ?[]const u8 = null,
    auth_failure: ?auth_runtime.FailureSnapshot = null,
    recovery: ?types.RouteRecoveryStatus = null,
    recovery_durable: bool = false,

    pub fn deinit(self: PromptRunResult, alloc: Allocator) void {
        alloc.free(self.assistant_output);
        if (self.model.len > 0) alloc.free(self.model);
        if (self.session_id.len > 0) alloc.free(self.session_id);
        freeToolCallRecords(alloc, self.tool_calls);
    }
};

/// Resume selector parsed from fx ask --resume.
const ResumeTarget = session_store.ResumeTarget;

const AskOptions = struct {
    prompt: []u8,
    resume_target: ?ResumeTarget = null,
    permission_override: ?PermissionMode = null,
    image_paths: std.ArrayList([]u8) = .empty,
    images: std.ArrayList(ImageAttachment) = .empty,
    system_prompt_override: ?[]u8 = null,
    json_output: bool = false,
    prompt_permissions: bool = false,
    timeout_ms: ?usize = null,
    quiet: bool = false,
    verbose: bool = false,
    no_save: bool = false,
    no_color: bool = false,
    continue_recovery: bool = false,

    fn deinit(self: *AskOptions, alloc: Allocator) void {
        alloc.free(self.prompt);
        for (self.image_paths.items) |p| alloc.free(p);
        self.image_paths.deinit(alloc);
        for (self.images.items) |image| types.freeImageAttachment(alloc, image);
        self.images.deinit(alloc);
        if (self.system_prompt_override) |s| alloc.free(s);
    }
};

const ToolCallRecord = struct {
    name: []u8,
    status: []u8,
    command_result_json: ?[]u8 = null,
    ask_question_text: ?[]u8 = null,
    web_search_completion: ?types.WebSearchCompletion = null,
    web_fetch_completion: ?types.WebFetchCompletion = null,
};

const PendingToolProgress = struct {
    call_id: []u8,
    tool_name: []u8,
    text: ?[]u8 = null,
    visible: bool = false,

    fn deinit(self: PendingToolProgress, alloc: Allocator) void {
        alloc.free(self.call_id);
        alloc.free(self.tool_name);
        if (self.text) |text| alloc.free(text);
    }
};

fn freeToolCallRecord(alloc: Allocator, record: ToolCallRecord) void {
    alloc.free(record.name);
    alloc.free(record.status);
    if (record.command_result_json) |json| alloc.free(json);
    if (record.ask_question_text) |text| alloc.free(text);
}

fn freeToolCallRecords(alloc: Allocator, records: []ToolCallRecord) void {
    for (records) |record| freeToolCallRecord(alloc, record);
    if (records.len > 0) alloc.free(records);
}

const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const PermissionApprovalPromptResult = enum {
    approve,
    deny,
    unavailable,
};
const NotifyAttentionFn = *const fn (?*anyopaque) void;
const PermissionApprovalPromptFn = *const fn (?*anyopaque, ?*anyopaque, WriteFn, []const u8, ?*anyopaque, NotifyAttentionFn) anyerror!PermissionApprovalPromptResult;
const IsTtyFn = *const fn (?*anyopaque) bool;
const LoadStartupStateFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupState;
const InitializeSessionStoresFn = *const fn (*AskContext) anyerror!void;
const LoadSkillsFn = *const fn (
    Allocator,
    []const u8,
    skill_contract.RootPolicy,
) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills;
const ProcessQueuedPromptFn = *const fn (*const agent_runtime.AgentRuntimeDeps, ?agent_runtime.SemanticPresentationSink, agent_runtime.LifecycleContext, agent_runtime.Config, worker_runtime.QueuedPrompt) anyerror!void;
const DiscardPristineSessionFn = *const fn (?*anyopaque, *AskContext, *session_store.LoadedWritableSession) session_store.PristineDiscardDisposition;
const PersistYoloAcknowledgmentFn = *const fn (Allocator) config_runtime.CommitAttempt;

const RunDeps = struct {
    stdin_ctx: ?*anyopaque = null,
    stdout_ctx: ?*anyopaque = null,
    stderr_ctx: ?*anyopaque = null,
    permission_approval_prompt_ctx: ?*anyopaque = null,
    write_stdout: WriteFn = writeRealStdout,
    write_stderr: WriteFn = writeRealStderr,
    permission_approval_prompt: PermissionApprovalPromptFn = promptRealPermissionApproval,
    stdin_is_tty: IsTtyFn = realStdinIsTty,
    stdout_is_tty: IsTtyFn = realStdoutIsTty,
    stderr_is_tty: IsTtyFn = realStderrIsTty,
    load_startup_state: LoadStartupStateFn = loadStartupStateDefault,
    initialize_session_stores: InitializeSessionStoresFn = initializeSessionStoresDefault,
    load_skills: LoadSkillsFn = app_runtime_setup.loadSkills,
    context_registry: context_contract.Registry,
    tool_set: tool_set_contract.ToolSet,
    load_mcp_runtime: mcp_runtime.LoadRuntimeFn,
    process_queued_prompt: ProcessQueuedPromptFn = processQueuedPromptDefault,
    persist_yolo_acknowledgment: PersistYoloAcknowledgmentFn = persistYoloAcknowledgmentDefault,
    discard_pristine_session_ctx: ?*anyopaque = null,
    discard_pristine_session: DiscardPristineSessionFn = discardPristineSessionDefault,
    install_headless_interrupt: bool = false,
    start_subagent_background_recovery: bool = true,
    stdin_source: StdinSource = .real,
};

const OutputMode = enum {
    quiet,
    json,
    raw,
    terminal,
    terminal_no_color,

    fn isTerminal(self: OutputMode) bool {
        return self == .terminal or self == .terminal_no_color;
    }

    fn capturesJson(self: OutputMode) bool {
        return self == .json;
    }
};

const RunOptions = struct {
    output_mode: OutputMode,
    prompt_permissions: bool = false,
    images: []const ImageAttachment = &.{},
    command_timeout_ms: ?usize = null,
    save_session: bool = true,
    resume_target: ?ResumeTarget = null,
    color_enabled: bool = true,
    continue_recovery: bool = false,
    deps: RunDeps,
};

fn buildAskGatewayToolProjection(
    alloc: Allocator,
    registry: mode_registry.Registry,
    tool_set: tool_set_contract.ToolSet,
    mode_id: []const u8,
    options: tool_advertisement.Options,
    has_child_capability: bool,
) !tool_advertisement.EffectiveToolProjection {
    if (has_child_capability) {
        return registry.buildGatewayToolProjection(
            alloc,
            tool_set,
            mode_id,
            options,
        );
    }

    const terminal_index = for (tool_set.registry.tools, 0..) |tool, index| {
        if (tool.executor_kind == .terminal and
            std.mem.eql(u8, tool.name, "terminal"))
        {
            break index;
        }
    } else {
        return registry.buildGatewayToolProjection(
            alloc,
            tool_set,
            mode_id,
            options,
        );
    };

    const projected_tools = try alloc.dupe(
        tool_dispatch.Tool,
        tool_set.registry.tools,
    );
    defer alloc.free(projected_tools);
    projected_tools[terminal_index] = builtin_tools.terminalExecOnlySpec();
    return registry.buildGatewayToolProjection(
        alloc,
        .{
            .registry = .{ .tools = projected_tools },
            .order = tool_set.order,
            .read_only_tool_names = tool_set.read_only_tool_names,
        },
        mode_id,
        options,
    );
}

const StdinSource = union(enum) {
    real,
    tty,
    bytes: []const u8,
    read_error,
};

const stdin_prompt_resource_byte_limit: usize = 8 * 1024 * 1024;

const AskContext = struct {
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
    workspace_root: []const u8,
    workspace_access: workspace_access.WorkspaceAccess = .{},
    api_key: []const u8 = "",
    gateway_team: ?[]const u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    provider: model_provider.ProviderId = .gateway,
    model_catalog_access: credentials.CatalogAccess = .{ .public_only = .no_credential },
    model: []const u8 = "",
    agent_step_limit: usize = 0,
    max_tool_result_bytes: usize = 64 * 1024,
    context_limits: config_runtime.context_limits.Values = .{},
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    first_call_tool_choice: types.ToolChoice = .auto,
    permission_mode: PermissionMode = .ask,
    permission_rules: types.PermissionRuleSet = .{},
    mode_id: []const u8,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    worker: WorkerRuntime = .{},
    use_process_interrupt_flag: bool = false,
    background: BackgroundRuntime = .{},
    terminal_client: terminal_client_runtime.Runtime = .{},
    subagent_host: ?*subagent_tool_host.Runtime = null,
    subagent_skills_prompt: []u8 = &.{},
    subagent_explicit_skills_prompt: []u8 = &.{},
    store: ?session_store.Store = null,
    writable: ?session_store.LoadedWritableSession = null,
    session_write_mutex: std.Io.Mutex = .init,
    requested_resume: ?ResumeTarget = null,
    seed_model: []const u8 = "",
    command_timeout_ms: ?usize = null,
    session: SessionRuntime,
    skills_dir: []u8 = &.{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    context_enabled: bool = true,
    mcp: ?*mcp_runtime.McpRuntime = null,
    mcp_elicitation_capabilities: @import("../mcp/elicitation.zig").Capabilities = .{},
    failed: bool = false,
    typed_error_code: ?[]const u8 = null,
    auth_failure: ?auth_runtime.FailureSnapshot = null,
    output_mode: OutputMode = .raw,
    prompt_permissions: bool = false,
    presenter: ?*ask_presentation.Runtime = null,
    pending_tool_progress: std.ArrayList(PendingToolProgress) = .empty,
    deferred_tool_progress: std.ArrayList([]u8) = .empty,
    pending_tool_progress_mutex: std.Io.Mutex = .init,
    raw_boundary_pending: bool = false,
    raw_trailing_newlines: u8 = 0,
    raw_has_output: bool = false,
    command_output_line_open: bool = false,
    assistant_output: std.ArrayList(u8) = .empty,
    tool_call_records: std.ArrayList(ToolCallRecord) = .empty,
    tool_call_records_mutex: std.Io.Mutex = .init,
    web_search_progress_mutex: std.Io.Mutex = .init,
    step_count: usize = 0,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime,
    capability_resolver: gateway_provider.CapabilityResolver = .{},
    lifecycle_runtime: hooks.Runtime,
    lifecycle_view: hooks.RuntimeView,
    active_turn_id: u64 = 0,
    notification_player: ?notification_sound.Player = null,
    image_snapshot_temp_dir: ?[]u8 = null,
    prompt_snapshot_committed: bool = false,
    last_recovery_status: ?types.RouteRecoveryStatus = null,

    fn init(alloc: Allocator, cfg: Config, deps: RunDeps, workspace_root: []const u8) AskContext {
        const lifecycle_runtime = hooks.Runtime.init(alloc);
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .deps = deps,
            .workspace_root = workspace_root,
            .model = cfg.default_model,
            .seed_model = cfg.default_model,
            .mode_id = cfg.mode_registry.default_mode_id,
            .session = session_runtime.SessionRuntime.init(
                cfg.max_history_turns,
                cfg.gateway_provider.generation_usage,
            ),
            .web_search_runtime = web_search_runtime.Runtime.init(.{
                .provider = cfg.gateway_provider.web_search,
            }),
            .background = BackgroundRuntime.init(
                cfg.background_process_provider,
            ),
            .terminal_client = terminal_client_runtime.Runtime.init(
                cfg.background_process_provider,
            ),
            .lifecycle_runtime = lifecycle_runtime,
            .lifecycle_view = hooks.RuntimeView.empty(),
        };
    }

    fn configureNotifications(
        self: *AskContext,
        turn_end: bool,
        attention_required: bool,
    ) !void {
        self.notification_player = notification_sound.Player.init(.{
            .ctx = self,
            .emit = emitAskNotificationBell,
        });
        if (turn_end) {
            try self.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.sound.turn_end",
                .ctx = self,
                .run = postTurnEndNotification,
            });
        }
        if (attention_required) {
            try self.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.sound.attention_required",
                .ctx = self,
                .run = attentionRequiredNotification,
            });
        }
        self.lifecycle_view = self.lifecycle_runtime.freeze();
    }

    fn dispatchAttentionRequired(self: *AskContext, kind: hooks.AttentionKind) void {
        agent_runtime.dispatchAttentionRequiredCheckpoint(self.lifecycleContext(), .{
            .turn_id = self.active_turn_id,
            .kind = kind,
        });
    }

    fn postTurnEndNotification(
        raw: *anyopaque,
        input: hooks.PostTurnEndInput,
    ) hooks.HandlerError!void {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        if (input.invocation.scope.kind != .ask) return;
        const cue: notification_sound.Cue = switch (input.outcome) {
            .completed => .success,
            .failed => .@"error",
            .interrupted, .paused => return,
        };
        self.playNotification(.turn_end, cue);
    }

    fn attentionRequiredNotification(
        raw: *anyopaque,
        input: hooks.AttentionRequiredInput,
    ) hooks.HandlerError!void {
        const self: *AskContext = @ptrCast(@alignCast(raw));
        if (input.invocation.scope.kind != .ask) return;
        self.playNotification(.attention_required, .success);
    }

    fn playNotification(
        self: *AskContext,
        kind: notification_sound.Kind,
        cue: notification_sound.Cue,
    ) void {
        const player = if (self.notification_player) |*configured|
            configured
        else {
            debug_trace.logf(
                "notifications",
                "notification delivery dropped kind={s} reason=player_not_configured",
                .{@tagName(kind)},
            );
            return;
        };
        debug_trace.logf("notifications", "sound play kind={s} cue={s}", .{ @tagName(kind), @tagName(cue) });
        switch (kind) {
            .attention_required => player.playAttention(cue),
            .turn_end => player.play(cue),
        }
    }

    fn deinit(self: *AskContext) void {
        if (self.subagent_host) |subagent_host| subagent_host.deinit();
        self.subagent_host = null;
        self.terminal_client.deinit();
        self.workspace_access.deinit(self.alloc);
        self.background.deinit(std.heap.c_allocator);
        self.worker.deinit(std.heap.c_allocator);
        self.session.usage.finishReconciliationBeforeShutdown();
        self.session.usage.finishProfilePublicationsBeforeShutdown();
        self.session.usage.configurePublicationSink(null);
        self.session.usage.configureCheckpointSink(null);
        if (self.writable) |*writable| {
            if (writable.needsFinalStateReplacement(
                self.session.usage.isDirty(),
            )) {
                commitAskStateReplacement(self, writable, false) catch |err| {
                    debug_trace.logf(
                        "session",
                        "failed to flush ask session usage err={s}",
                        .{@errorName(err)},
                    );
                };
            }
        }
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.capability_resolver.deinit(self.alloc);
        self.lifecycle_runtime.deinit();
        if (self.writable) |*writable| writable.deinit(self.alloc);
        self.writable = null;
        if (self.store) |*store| store.deinit(self.alloc);
        self.permission_rules.deinit(self.alloc);
        self.session.deinit(self.alloc);
        if (self.skills_dir.len > 0) self.alloc.free(self.skills_dir);
        self.context_snapshot.deinit(self.alloc);
        if (self.mcp) |m| {
            m.retireAndWait();
            m.deinit();
            self.alloc.destroy(m);
        }
        if (self.image_snapshot_temp_dir) |path| {
            image_attachments.cleanupSnapshotDir(path);
            self.alloc.free(path);
        }
        self.assistant_output.deinit(self.alloc);
        for (self.pending_tool_progress.items) |progress| progress.deinit(self.alloc);
        self.pending_tool_progress.deinit(self.alloc);
        for (self.deferred_tool_progress.items) |progress| self.alloc.free(progress);
        self.deferred_tool_progress.deinit(self.alloc);
        for (self.tool_call_records.items) |record| {
            freeToolCallRecord(self.alloc, record);
        }
        self.tool_call_records.deinit(self.alloc);
        if (self.subagent_skills_prompt.len > 0) self.alloc.free(self.subagent_skills_prompt);
        if (self.subagent_explicit_skills_prompt.len > 0) self.alloc.free(self.subagent_explicit_skills_prompt);
    }

    fn lifecycleContext(self: *AskContext) agent_runtime.LifecycleContext {
        return .{
            .view = self.lifecycle_view,
            .scope = .{
                .kind = .ask,
                .workspace_root = self.workspace_root,
                .session_id = if (self.writable) |*writable| writable.active_id else null,
            },
            .outcome_allocator = self.alloc,
        };
    }

    fn cancelFlag(self: *AskContext) *std.atomic.Value(bool) {
        if (comptime supports_headless_interrupt) {
            if (self.use_process_interrupt_flag) {
                return &headless_interrupt.cancel_requested;
            }
        }
        return &self.worker.worker_cancel_requested;
    }

    fn checkCancellation(self: *AskContext) !void {
        if (self.cancelFlag().load(.seq_cst)) return error.Cancelled;
    }

    fn processInterruptRequested(self: *const AskContext) bool {
        if (comptime supports_headless_interrupt) {
            return self.use_process_interrupt_flag and
                headless_interrupt.cancel_requested.load(.seq_cst);
        }
        return false;
    }

    fn imageSnapshotStorageDir(self: *AskContext) ![]u8 {
        const sessions_dir = if (self.store) |*store| store.sessions_dir else null;
        const session_id = if (self.writable) |*writable| writable.active_id else null;
        return session_store.imageSnapshotStorageDir(
            self.alloc,
            sessions_dir,
            session_id,
            &self.image_snapshot_temp_dir,
        );
    }

    fn captureImageAttachment(self: *AskContext, attachment: *ImageAttachment) !void {
        const snapshot_dir = try self.imageSnapshotStorageDir();
        defer self.alloc.free(snapshot_dir);
        try image_attachments.captureImageSnapshotWithBudget(
            self.alloc,
            attachment,
            snapshot_dir,
            .{ .cancel_flag = self.cancelFlag() },
        );
    }

    fn captureImageAttachments(self: *AskContext, attachments: []ImageAttachment) !void {
        const snapshot_dir = try self.imageSnapshotStorageDir();
        defer self.alloc.free(snapshot_dir);
        try image_attachments.captureImageSnapshots(
            self.alloc,
            attachments,
            snapshot_dir,
            .{ .cancel_flag = self.cancelFlag() },
        );
    }

    fn initializeSessionStores(self: *AskContext) !void {
        var store = session_store.Store.init(self.alloc, self.workspace_root) catch |err| {
            if (err == error.OutOfMemory or self.requested_resume != null) return err;
            debug_trace.logf(
                "session",
                "event=ask_session_store_unavailable error={s}",
                .{@errorName(err)},
            );
            try self.writeStderr("fx ask: warning: session persistence unavailable; error=");
            try self.writeStderr(@errorName(err));
            try self.writeStderr("; continuing without saving\n");
            return;
        };
        var store_owned = true;
        errdefer if (store_owned) store.deinit(self.alloc);

        const seed_preferences = session_codec.DurableSessionPreferences{
            .provider = self.provider,
            .model = @constCast(self.seed_model),
            .effort = self.effort,
            .fast_mode = self.fast_mode,
        };
        var writable = if (self.requested_resume) |target|
            try subagent_resume_admission.resumeForExternalPrompt(
                store,
                self.alloc,
                target,
                self.workspace_root,
                .{ .seed_preferences = seed_preferences },
            )
        else blk: {
            var state = try freshAskState(self, seed_preferences);
            defer state.deinit(self.alloc);
            break :blk try store.startWritableSession(self.alloc, state);
        };
        var writable_owned = true;
        errdefer if (writable_owned) writable.deinit(self.alloc);

        if (self.requested_resume != null) {
            try self.session.restoreWithPermissionState(
                self.alloc,
                writable.state.conversation_language,
                writable.state.history,
                writable.state.context_history_start,
                writable.state.permission_state,
            );
            if (writable.state.usage) |usage| {
                try self.session.usage.restore(
                    self.alloc,
                    usage,
                    writable.state.created_at_ms,
                );
            } else {
                self.session.usage.restoreLegacyWallDuration(
                    writable.state.created_at_ms,
                );
            }
        }

        const session_dir = try session_store.sessionDirPath(
            self.alloc,
            store.sessions_dir,
            writable.active_id,
        );
        defer self.alloc.free(session_dir);
        self.session.configureWebFetchArtifacts(self.alloc, session_dir);

        self.store = store;
        self.writable = writable;
        store_owned = false;
        writable_owned = false;

        if (self.requested_resume != null) {
            const preferences = self.writable.?.state.preferences;
            self.provider = preferences.provider;
            self.model = preferences.model;
            self.effort = preferences.effort;
            self.fast_mode = preferences.fast_mode;
        }
        self.subagent_host = try subagent_tool_host.Runtime.create(
            self.alloc,
            &self.store.?,
            self.writable.?.active_id,
            .{ .context = self, .resolve_fn = resolveAskSubagentAuthority },
            .{ .context = self, .run_fn = runAskChild },
        );
        if (self.deps.start_subagent_background_recovery) {
            self.subagent_host.?.requestBackgroundRecovery(
                io_mod.milliTimestamp(),
            ) catch |err| {
                debug_trace.logf(
                    "subagent",
                    "ask background recovery unavailable root_id={s} outcome={s}",
                    .{ self.subagent_host.?.root_id, @errorName(err) },
                );
            };
        }
        const capability = try self.writable.?.childCapability();

        self.background.restoreWorkspaceFromStore(
            std.heap.c_allocator,
            self.store.?,
            self.workspace_root,
            self.writable.?.active_id,
        ) catch |err| {
            debug_trace.logf(
                "background",
                "headless ask workspace background restore failed workspace={s} err={s}",
                .{ self.workspace_root, @errorName(err) },
            );
        };
        self.background.restoreFromManagedPersistence(
            std.heap.c_allocator,
            capability,
            self.writable.?.active_id,
            self.workspace_root,
        ) catch |err| {
            debug_trace.logf(
                "background",
                "headless ask managed background restore failed session={s} err={s}",
                .{ self.writable.?.active_id, @errorName(err) },
            );
        };
    }

    fn toolContext(self: *AskContext) tool_runtime.Context {
        const gateway_features_allowed = model_provider.usesGatewayAuxiliaries(self.provider);
        if (gateway_features_allowed) {
            self.web_search_runtime.configure(.{
                .api_key = self.api_key,
                .gateway_team = self.gateway_team,
                .worker_model = self.model,
                .gateway_retry_count = self.cfg.gateway_retry_count,
                .gateway_chat_url = self.cfg.gateway_chat_url,
                .usage = &self.session.usage,
                .usage_allocator = self.alloc,
            });
        }
        var tc: tool_runtime.Context = .{
            .workspace_root = self.workspace_root,
            .access_scope = self.workspace_access.scope(self.workspace_root),
            .ignored_list_entries = self.cfg.ignored_list_entries,
            .max_list_entries = self.cfg.max_list_entries,
            .max_read_file_bytes = self.cfg.max_read_file_bytes,
            .max_read_file_lines = self.cfg.max_read_file_lines,
            .max_read_file_line_len = self.cfg.max_read_file_line_len,
            .max_command_output_bytes = self.cfg.max_command_output_bytes,
            .max_tool_result_bytes = self.max_tool_result_bytes,
            .api_key = self.api_key,
            .agent_stream_provider = self.agentStreamProvider(),
            .gateway_team = self.gateway_team,
            .credential_source = self.credential_source,
            .account_id = self.account_id,
            .provider = self.provider,
            .oauth_transport = self.cfg.gateway_provider.oauth_transport,
            .secret_store = self.cfg.secret_store,
            .model = self.model,
            .gateway_retry_count = self.cfg.gateway_retry_count,
            .gateway_chat_url = self.cfg.gateway_chat_url,
            .gateway_models_path = self.cfg.gateway_models_path,
            .agent_step_limit = self.agent_step_limit,
            .fast_mode = self.fast_mode,
            .effort = self.effort,
            .first_call_tool_choice = self.first_call_tool_choice,
            .permission_mode = self.permission_mode,
            .permission_grants = &.{},
            .permission_rules = self.permission_rules,
            .tool_registry = self.toolRegistry(),
            .subagent_host = self.subagent_host,
            .subagent_caller_id = if (self.writable) |*writable| writable.active_id else null,
            .auto_classifier = self.admissionAutoClassifier(),
            .worker = &self.worker,
            .cancel_flag = self.cancelFlag(),
            .background = &self.background,
            .session = &self.session,
            .session_allocator = self.alloc,
            .skills_dir = self.skills_dir,
            .context_limits = self.context_limits,
            .context_enabled = self.context_enabled,
            .context_registry = self.deps.context_registry,
            .output_chunk_ctx = @ptrCast(self),
            .on_output_chunk = onCommandOutputChunk,
            .mcp_progress_ctx = @ptrCast(self),
            .on_mcp_progress = onMcpProgress,
            .background_url_ctx = @ptrCast(self),
            .on_background_url_ready = onBackgroundUrlReady,
            .session_child_capability = if (self.writable) |*writable|
                writable.childCapability() catch null
            else
                null,
            .terminal_client = &self.terminal_client,
            .command_timeout_ms = self.command_timeout_ms,
            .web_fetch_runtime = &self.web_fetch_runtime,
            .web_fetch_artifact_store = self.session.webFetchArtifactStore(),
            .web_fetch_artifact_error = self.session.webFetchArtifactError(),
            .web_fetch_progress_ctx = @ptrCast(self),
            .on_web_fetch_progress = onWebFetchProgress,
            .web_search_runtime_ready = false,
            .web_search_backend = if (gateway_features_allowed) self.web_search_runtime.dispatchBackend() else null,
            .web_search_progress_ctx = @ptrCast(self),
            .on_web_search_progress = onWebSearchProgress,
            .model_capability_resolver = .{
                .ctx = @ptrCast(self),
                .resolve_fn = resolveModelCapabilities,
            },
            .interactive = false,
            .lifecycle_view = self.lifecycle_view,
            .lifecycle_scope = self.lifecycleContext().scope,
        };
        if (self.mcp != null) {
            tc.mcp_ctx = @ptrCast(self);
            tc.mcp_has_tool = mcpHasTool;
            tc.mcp_validate_tool = mcpValidateTool;
            tc.mcp_call_tool = mcpCallTool;
            tc.mcp_search_tools = mcpSearchTools;
            tc.mcp_tool_schema = mcpToolSchemaJson;
            tc.mcp_call_feature = mcpCallFeature;
            if (self.mcp_elicitation_capabilities.any()) {
                tc.mcp_input_responder = .{
                    .context = @ptrCast(self),
                    .capabilities = self.mcp_elicitation_capabilities,
                    .legacy_url_manual_completion = true,
                    .callback = respondToAskMcpInput,
                };
            }
        }
        return tc;
    }

    fn modelVisibleProjectContext(self: *const AskContext) []const u8 {
        if (!self.context_enabled) return "";
        return self.context_snapshot.modelVisibleBytes();
    }

    fn toolRegistry(self: *const AskContext) tool_dispatch.Registry {
        return self.deps.tool_set.registry;
    }

    fn admissionAutoClassifier(self: *AskContext) permission_auto_classifier.Classifier {
        if (self.auto_classifier.enabled()) return self.auto_classifier;
        const provider = switch (self.provider) {
            .gateway => self.cfg.permission_reviewer_provider,
            .codex => self.cfg.codex_permission_reviewer_provider,
            .grok => self.cfg.grok_permission_reviewer_provider,
            .claude => self.cfg.claude_permission_reviewer_provider,
        } orelse
            return permission_auto_classifier.Classifier.disabled();
        return permission_auto_classifier.Classifier.withProvider(provider, .{
            .credential = self.api_key,
            .account_id = self.account_id,
            .tenant = self.gateway_team,
            .endpoint = self.cfg.gateway_chat_url,
            .cancel_flag = self.cancelFlag(),
            .usage = &self.session.usage,
            .usage_allocator = self.alloc,
        });
    }

    fn agentStreamProvider(self: *const AskContext) agent_stream_provider.Provider {
        return switch (self.provider) {
            .gateway => self.cfg.gateway_provider.agent_stream,
            .codex => self.cfg.codex_agent_stream orelse agent_stream_provider.unavailable_provider,
            .grok => self.cfg.grok_agent_stream orelse agent_stream_provider.unavailable_provider,
            .claude => self.cfg.claude_agent_stream orelse agent_stream_provider.unavailable_provider,
        };
    }

    fn writeStdout(self: *AskContext, text: []const u8) !void {
        try self.deps.write_stdout(self.deps.stdout_ctx, text);
    }

    fn writeStderr(self: *AskContext, text: []const u8) !void {
        try self.deps.write_stderr(self.deps.stderr_ctx, text);
    }

    fn writeLine(self: *AskContext, text: []const u8) !void {
        try self.writeStderr(text);
        try self.writeStderr("\n");
    }
};

fn freshAskState(
    ctx: *AskContext,
    preferences: session_codec.DurableSessionPreferences,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = try session_store.generateSessionId(ctx.alloc);
    errdefer ctx.alloc.free(id);
    const origin = try ctx.alloc.dupe(u8, ctx.workspace_root);
    errdefer ctx.alloc.free(origin);
    const workspace = try ctx.alloc.dupe(u8, ctx.workspace_root);
    errdefer ctx.alloc.free(workspace);
    const owned_preferences = try preferences.dupe(ctx.alloc);
    errdefer {
        var value = owned_preferences;
        value.deinit(ctx.alloc);
    }
    const history = try ctx.alloc.alloc(HistoryTurn, 0);
    errdefer ctx.alloc.free(history);
    const permission_state = try ctx.session.snapshotPermissionState(ctx.alloc);
    errdefer {
        var value = permission_state;
        value.deinit(ctx.alloc);
    }
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = now,
        .updated_at_ms = now,
        .conversation_language = ctx.session.languageSnapshot(),
        .preferences = owned_preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .permission_state = permission_state,
    };
}

pub fn run(alloc: Allocator, args: []const [:0]const u8, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !u8 {
    return runWithDeps(alloc, args, cfg, .{
        .load_startup_state = app_lifecycle.loadStartupState,
        .context_registry = context_registry,
        .tool_set = tool_set,
        .load_mcp_runtime = cfg.load_mcp_runtime,
        .install_headless_interrupt = true,
    });
}

fn selectOutputMode(quiet: bool, json: bool, stdout_is_tty: bool, no_color: bool) OutputMode {
    if (json) return .json;
    if (quiet) return .quiet;
    if (!stdout_is_tty) return .raw;
    return if (no_color) .terminal_no_color else .terminal;
}

fn askElicitationCapabilities(
    output_mode: OutputMode,
    stdin_is_tty: bool,
    stderr_is_tty: bool,
) @import("../mcp/elicitation.zig").Capabilities {
    if (!output_mode.isTerminal() or !stdin_is_tty or !stderr_is_tty) return .{};
    return .{ .form = true, .url = true };
}

fn checkHeadlessCancellation(deps: RunDeps) !void {
    if (comptime supports_headless_interrupt) {
        if (deps.install_headless_interrupt and
            headless_interrupt.cancel_requested.load(.seq_cst))
        {
            return error.Cancelled;
        }
    }
}

fn writeAskUsage(deps: RunDeps, usage: []const u8) !void {
    try deps.write_stderr(deps.stderr_ctx, "usage: fx ");
    try deps.write_stderr(deps.stderr_ctx, usage);
    try deps.write_stderr(deps.stderr_ctx, "\n");
}

fn askErrorNotice(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ImagePreparationFailed => image_attachments.image_preparation_failed_notice,
        else => null,
    };
}

fn runWithDeps(alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !u8 {
    var interrupt_scope = try headless_interrupt.Scope.install(
        deps.install_headless_interrupt,
    );
    defer interrupt_scope.restoreAndRedeliver();

    var options = parseOptionsWithStdin(alloc, args, deps.stdin_source) catch |err| switch (err) {
        error.MissingPrompt => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: missing prompt\n");
            try writeAskUsage(deps, cfg.command_usage);
            return 1;
        },
        error.NoSaveResumeConflict => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, "InvalidAskArgs");
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: --no-save cannot be used with --resume or --resume-id\n");
            try writeAskUsage(deps, cfg.command_usage);
            return 1;
        },
        error.PromptResourceLimitExceeded => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: prompt exceeds the local input safety limit\n");
            return 1;
        },
        error.PromptInputReadFailed => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: failed to read prompt from stdin\n");
            return 1;
        },
        error.InvalidAskArgs => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try writeAskUsage(deps, cfg.command_usage);
            return 1;
        },
        error.InvalidPromptText => {
            if (hasJsonFlag(args)) {
                const json = try renderErrorJsonResult(alloc, @errorName(err));
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
                return 1;
            }
            try deps.write_stderr(deps.stderr_ctx, "fx ask: prompt must be valid UTF-8 and contain no NUL bytes\n");
            return 1;
        },
        else => return err,
    };
    defer options.deinit(alloc);

    if (interrupt_scope.requested()) return headless_interrupt.exitCode();
    if (options.image_paths.items.len > 0) {
        const workspace_root = try io_mod.realpathAlloc(alloc, ".");
        defer alloc.free(workspace_root);
        if (!try preflightAskImages(alloc, workspace_root, &options, deps)) return 1;
    }
    if (interrupt_scope.requested()) return headless_interrupt.exitCode();

    var effective_cfg = cfg;
    if (options.system_prompt_override) |sp| {
        effective_cfg.prompt_policy.system_prompt = sp;
    }

    const output_mode = selectOutputMode(
        options.quiet,
        options.json_output,
        deps.stdout_is_tty(deps.stdout_ctx),
        options.no_color,
    );
    const result = runPromptInternal(alloc, options.prompt, options.permission_override, effective_cfg, .{
        .output_mode = output_mode,
        .prompt_permissions = options.prompt_permissions,
        .images = if (options.images.items.len > 0) options.images.items else &.{},
        .command_timeout_ms = options.timeout_ms,
        .save_session = !options.no_save,
        .resume_target = options.resume_target,
        .color_enabled = !options.no_color,
        .continue_recovery = options.continue_recovery,
        .deps = deps,
    }) catch |err| {
        if (interrupt_scope.requested()) return headless_interrupt.exitCode();
        if (err == error.OutOfMemory) return err;
        if (err == error.OneOffSessionNotResumable and !options.json_output) {
            try deps.write_stderr(
                deps.stderr_ctx,
                "fx ask: one-off child sessions cannot accept additional prompts; create a persistent child to continue the conversation\n",
            );
            return 1;
        }
        if (!options.json_output) {
            const notice = askErrorNotice(err) orelse return err;
            try deps.write_stderr(deps.stderr_ctx, "fx ask: ");
            try deps.write_stderr(deps.stderr_ctx, notice);
            try deps.write_stderr(deps.stderr_ctx, "\n");
            return 1;
        }
        const json = try renderErrorJsonResult(alloc, @errorName(err));
        defer alloc.free(json);
        try deps.write_stdout(deps.stdout_ctx, json);
        return 1;
    };
    defer result.deinit(alloc);

    if (result.interrupted or interrupt_scope.requested()) {
        return headless_interrupt.exitCode();
    }

    if (options.json_output) {
        const json = try renderFinalJsonResult(alloc, result);
        defer alloc.free(json);
        if (interrupt_scope.requested()) return headless_interrupt.exitCode();
        try deps.write_stdout(deps.stdout_ctx, json);
    }

    return if (interrupt_scope.requested())
        headless_interrupt.exitCode()
    else
        result.exit_code;
}

fn preflightAskImages(
    alloc: Allocator,
    workspace_root: []const u8,
    options: *AskOptions,
    deps: RunDeps,
) !bool {
    for (options.image_paths.items) |image_path| {
        const attachment = image_attachments.loadUserImageAttachment(
            alloc,
            workspace_root,
            image_path,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            const reason = switch (err) {
                error.FileNotFound => "image file not found",
                error.UnsupportedImageType => "unsupported image type",
                error.ImageTooLarge => image_attachments.image_too_large_notice,
                else => @errorName(err),
            };
            if (options.json_output) {
                const detail = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ @errorName(err), image_path });
                defer alloc.free(detail);
                const json = try renderErrorJsonResult(alloc, detail);
                defer alloc.free(json);
                try deps.write_stdout(deps.stdout_ctx, json);
            } else {
                var message: std.Io.Writer.Allocating = .init(alloc);
                defer message.deinit();
                try message.writer.print("fx ask: failed to attach image \"{s}\": {s}\n", .{ image_path, reason });
                try deps.write_stderr(deps.stderr_ctx, message.written());
            }
            return false;
        };
        var attachment_owned = true;
        errdefer if (attachment_owned) types.freeImageAttachment(alloc, attachment);
        try options.images.append(alloc, attachment);
        attachment_owned = false;
    }
    return true;
}

pub fn runPrompt(alloc: Allocator, prompt: []const u8, auto_permission: bool, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !u8 {
    const result = try runPromptInternal(alloc, prompt, if (auto_permission) .auto else null, cfg, .{
        .output_mode = .raw,
        .images = &.{},
        .deps = .{
            .context_registry = context_registry,
            .tool_set = tool_set,
            .load_mcp_runtime = cfg.load_mcp_runtime,
        },
    });
    defer result.deinit(alloc);
    return result.exit_code;
}

pub fn runPromptCapture(alloc: Allocator, prompt: []const u8, auto_permission: bool, cfg: Config, context_registry: context_contract.Registry, tool_set: tool_set_contract.ToolSet) !PromptRunResult {
    return runPromptInternal(alloc, prompt, if (auto_permission) .auto else null, cfg, .{
        .output_mode = .json,
        .images = &.{},
        .deps = .{
            .context_registry = context_registry,
            .tool_set = tool_set,
            .load_mcp_runtime = cfg.load_mcp_runtime,
        },
    });
}

fn missingCredentialResult(
    alloc: Allocator,
    options: RunOptions,
    provider: model_provider.ProviderId,
) !PromptRunResult {
    const message = if (provider == .codex)
        credentials.missing_chatgpt_credential_message
    else if (provider == .grok)
        credentials.missing_grok_credential_message
    else
        credentials.missing_credential_message;
    try options.deps.write_stderr(options.deps.stderr_ctx, "fx ask: ");
    try options.deps.write_stderr(options.deps.stderr_ctx, message);
    try options.deps.write_stderr(options.deps.stderr_ctx, "\n");
    return .{
        .exit_code = 1,
        .assistant_output = try alloc.dupe(u8, ""),
        .error_code = "MissingCredentials",
    };
}

fn runPromptInternal(alloc: Allocator, prompt: []const u8, permission_override: ?PermissionMode, cfg: Config, options: RunOptions) !PromptRunResult {
    var owned_prompt = try alloc.dupe(u8, prompt);
    defer alloc.free(owned_prompt);

    try checkHeadlessCancellation(options.deps);
    var startup = try options.deps.load_startup_state(
        alloc,
        cfg.gateway_provider.oauth_transport,
        cfg.secret_store,
        cfg.default_model,
        cfg.default_agent_step_limit,
    );
    defer startup.deinit(alloc);
    try checkHeadlessCancellation(options.deps);

    var permission_mode = toCorePermissionMode(startup.permission_mode);
    const mode_id: []const u8 = cfg.mode_registry.default_mode_id;
    if (permission_override) |explicit| permission_mode = explicit;

    if (permission_mode == .yolo and !startup.yolo_acknowledged) {
        try emitHeadlessYoloWarning(alloc, options);
    }

    for (startup.config_diagnostics) |diagnostic| {
        var notice_writer: std.Io.Writer.Allocating = .init(alloc);
        defer notice_writer.deinit();
        try notice_writer.writer.print(
            "fx ask: config {s}: {s}",
            .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
        );
        try config_runtime.writeDiagnosticMetadata(&notice_writer.writer, diagnostic);
        try notice_writer.writer.writeByte('\n');
        const notice = try notice_writer.toOwnedSlice();
        defer alloc.free(notice);
        try options.deps.write_stderr(options.deps.stderr_ctx, notice);
    }

    try app_lifecycle.applyWorkspaceLaunch(
        &startup,
        alloc,
        cfg.additional_directories,
        cfg.saved_directories_suppressed,
    );
    try checkHeadlessCancellation(options.deps);

    if (!options.continue_recovery and options.resume_target == null and startup.credential == null) {
        return missingCredentialResult(alloc, options, startup.provider);
    }

    var owned_resumed_model: ?[]u8 = null;
    defer if (owned_resumed_model) |model| alloc.free(model);
    var ctx = AskContext.init(alloc, cfg, options.deps, startup.workspace_root);
    defer ctx.deinit();
    if (options.save_session) {
        _ = try ctx.session.initializeProfileUsage(alloc, io_mod.getenv("HOME"));
        ctx.session.attachProfileUsagePublisher(alloc);
    }
    ctx.use_process_interrupt_flag = options.deps.install_headless_interrupt;
    try ctx.checkCancellation();
    var presenter: ?ask_presentation.Runtime = null;
    defer if (presenter) |*value| value.deinit();
    var worker_events_drained = false;
    ctx.workspace_access = startup.takeWorkspaceAccess();
    ctx.output_mode = options.output_mode;
    ctx.prompt_permissions = options.prompt_permissions;
    ctx.mcp_elicitation_capabilities = askElicitationCapabilities(
        options.output_mode,
        options.deps.stdin_is_tty(options.deps.stdin_ctx),
        options.deps.stderr_is_tty(options.deps.stderr_ctx),
    );
    ctx.command_timeout_ms = options.command_timeout_ms;
    ctx.model = startup.selected_model;
    ctx.provider = startup.provider;
    ctx.seed_model = startup.configured_model;
    ctx.requested_resume = options.resume_target;
    ctx.agent_step_limit = startup.agent_step_limit;
    ctx.max_tool_result_bytes = startup.max_tool_result_bytes;
    ctx.context_limits = startup.context_limits;
    ctx.context_limits.applyCommandLine(cfg.context_limit_overrides);
    ctx.fast_mode = startup.fast_mode;
    ctx.effort = toCoreReasoningEffort(startup.effort);
    ctx.first_call_tool_choice = startup.first_call_tool_choice;
    ctx.permission_mode = permission_mode;
    ctx.mode_id = mode_id;
    ctx.permission_rules = try takeCorePermissionRules(alloc, &startup);
    ctx.context_enabled = startup.context_enabled;
    if (options.output_mode.isTerminal()) {
        presenter = try ask_presentation.Runtime.init(alloc, .{
            .text = owned_prompt,
            .images = @constCast(options.images),
        }, options.output_mode == .terminal_no_color);
        ctx.presenter = &presenter.?;
    }
    try ctx.configureNotifications(
        startup.notification_turn_end,
        startup.notification_attention_required,
    );
    ctx.session.setConversationLanguageFromUserMessage(owned_prompt);
    if (options.save_session) {
        try ctx.checkCancellation();
        try options.deps.initialize_session_stores(&ctx);
        try ctx.checkCancellation();
        if (startup.model_source == .process_override) {
            ctx.model = startup.selected_model;
        } else if (ctx.requested_resume != null) {
            owned_resumed_model = try alloc.dupe(u8, ctx.model);
            ctx.model = owned_resumed_model.?;
        }
        ctx.session.setConversationLanguageFromUserMessage(owned_prompt);
    }

    var recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null;
    defer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    if (options.continue_recovery) {
        const writable = if (ctx.writable) |*value| value else return error.RecoverySessionUnavailable;
        const checkpoint = writable.state.recovery_checkpoint orelse
            return error.NoPendingRecovery;
        recovery_checkpoint = try checkpoint.dupe(alloc);
        alloc.free(owned_prompt);
        owned_prompt = try alloc.dupe(u8, recovery_checkpoint.?.user.text);
        ctx.session.setConversationLanguageFromUserMessage(owned_prompt);
    }

    var routed_credential: ?credentials.Credential = null;
    defer if (routed_credential) |*credential| credential.deinit(alloc);
    const startup_matches_final_model = if (startup.credential) |credential|
        model_provider.authorizesCredential(ctx.provider, credential.source)
    else
        false;
    const credential: *const credentials.Credential = if (startup_matches_final_model)
        &startup.credential.?
    else routed: {
        const preferred = if (startup.credential) |value| value.source else null;
        const resolution = try credentials.resolveForProvider(
            alloc,
            cfg.gateway_provider.oauth_transport,
            cfg.secret_store,
            .refresh_if_needed,
            ctx.provider,
            preferred,
        );
        routed_credential = resolution.credential;
        if (routed_credential == null) {
            return missingCredentialResult(alloc, options, ctx.provider);
        }
        break :routed &routed_credential.?;
    };
    const api_key = credential.token;
    ctx.api_key = api_key;
    ctx.gateway_team = credential.gatewayTeam();
    ctx.credential_source = credential.source;
    ctx.account_id = credential.accountId();
    ctx.model_catalog_access = credentials.catalogAccessForCredentialAndAccount(
        credential.source,
        api_key,
        credential.gatewayTeam(),
        credential.accountId(),
    );

    const restored_image_catalog = try ctx.session.snapshotImageCatalog(alloc, &.{});
    defer types.freeImageAttachmentSlice(alloc, restored_image_catalog);
    const restored_image_bounds = try image_attachments.calculate_next_image_id(restored_image_catalog);

    const current_images = try types.dupeImageAttachmentSlice(
        alloc,
        if (recovery_checkpoint) |checkpoint|
            checkpoint.user.images
        else
            options.images,
    );
    defer types.freeImageAttachmentSlice(alloc, current_images);
    defer if (options.save_session and !ctx.prompt_snapshot_committed) {
        image_attachments.deleteUnreferencedImageSnapshots(current_images, restored_image_catalog);
    };
    if (current_images.len > 0) {
        try ctx.checkCancellation();
        _ = std.math.add(
            usize,
            restored_image_bounds.next_id,
            current_images.len - 1,
        ) catch return error.ImageIdOverflow;
        for (current_images, 0..) |*image, index| image.id = restored_image_bounds.next_id + index;
        try ctx.captureImageAttachments(current_images);
        try ctx.checkCancellation();
    }

    const authorized_image_catalog = try ctx.session.snapshotImageCatalog(alloc, current_images);
    defer types.freeImageAttachmentSlice(alloc, authorized_image_catalog);

    try ctx.checkCancellation();
    var loaded_skills = try options.deps.load_skills(
        alloc,
        startup.workspace_root,
        cfg.skill_root_policy,
    );
    defer loaded_skills.deinit(alloc);
    try ctx.checkCancellation();
    skill_runtime.traceDiagnostics("ask_startup", loaded_skills.diagnostics);
    ctx.skills_dir = loaded_skills.dir;
    loaded_skills.dir = &.{};
    if (startup.context_enabled) {
        try ctx.checkCancellation();
        const context_targets = try context_contract.applicableTargetsForImages(alloc, current_images);
        defer if (context_targets.len > 0) alloc.free(context_targets);
        ctx.context_snapshot = try ctx.deps.context_registry.gatherDefaultSnapshot(alloc, .{
            .workspace_root = startup.workspace_root,
            .access_scope = ctx.workspace_access.scope(ctx.workspace_root),
            .targets = context_targets,
            .context_limits = ctx.context_limits,
        });
        try ctx.checkCancellation();
        for (ctx.context_snapshot.notices) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    }

    try ctx.checkCancellation();
    ctx.mcp = try options.deps.load_mcp_runtime(alloc, ctx.mcp_elicitation_capabilities);
    if (ctx.mcp) |mcp| mcp.connectRequiredForAsk(ctx.toolRegistry());
    try ctx.checkCancellation();
    if (ctx.mcp) |mcp| {
        if (try mcp.requiredStartupFailure(
            alloc,
            @intCast(@max(io_mod.milliTimestamp(), 0)),
        )) |failure| {
            defer alloc.free(failure);
            try ctx.writeStderr("fx ask: ");
            try ctx.writeStderr(failure);
            try ctx.writeStderr("\n");
            return error.McpRequiredServerUnavailable;
        }
    }
    const session_child_capability = if (ctx.writable) |*writable|
        writable.childCapability() catch null
    else
        null;
    var tool_projection = try buildAskGatewayToolProjection(alloc, ctx.cfg.mode_registry, options.deps.tool_set, ctx.mode_id, .{
        .permission_mode = ctx.permission_mode,
        .permission_rules = ctx.permission_rules,
        .mcp_runtime = ctx.mcp,
        .subagent_available = ctx.subagent_host != null,
    }, session_child_capability != null);
    defer tool_projection.deinit(alloc);

    const skills_view = skill_runtime.Runtime{
        .items = loaded_skills.skills,
        .diagnostics = loaded_skills.diagnostics,
    };
    var bounded_skills = try skills_view.buildBoundedSystemPromptSection(alloc, ctx.context_limits);
    defer bounded_skills.deinit(alloc);
    if (bounded_skills.notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    if (bounded_skills.diagnostic_notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    const skills_section = bounded_skills.text;
    var explicit_skills = try skill_invocation.buildExplicitPromptSection(
        alloc,
        .{ .skills = loaded_skills.skills, .diagnostics = loaded_skills.diagnostics },
        owned_prompt,
        &.{},
        ctx.context_limits,
    );
    defer explicit_skills.deinit(alloc);
    if (explicit_skills.notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    if (explicit_skills.diagnostic_notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    ctx.subagent_skills_prompt = try alloc.dupe(u8, skills_section);
    ctx.subagent_explicit_skills_prompt = try alloc.dupe(u8, explicit_skills.text);
    const context_history = try ctx.session.snapshotContextHistory(alloc);
    defer types.freeHistoryTurnSlice(alloc, context_history);
    const root_user_intent_context = try auto_classifier_context.buildCanonicalRootUserContext(
        alloc,
        owned_prompt,
        ctx.session.history.items,
    );
    defer alloc.free(root_user_intent_context);
    ctx.active_turn_id = if (recovery_checkpoint) |checkpoint|
        checkpoint.turn_id
    else
        debug_trace.nextTurnId();

    const job: worker_runtime.QueuedPrompt = .{
        .turn_id = ctx.active_turn_id,
        .prompt = owned_prompt,
        .images = current_images,
        .authorized_image_catalog = authorized_image_catalog,
        .model = @constCast(ctx.model),
        .api_key = api_key,
        .gateway_team = if (credential.gatewayTeam()) |team| @constCast(team) else null,
        .credential_source = credential.source,
        .account_id = if (credential.accountId()) |account_id| @constCast(account_id) else null,
        .provider = ctx.provider,
        .permission_mode = ctx.permission_mode,
        .history = context_history,
        .root_user_intent_context = root_user_intent_context,
        .grants = &.{},
        // process_queued_prompt is synchronous here; AskContext keeps the
        // immutable snapshot allocations alive for the whole call.
        .context_snapshot = ctx.context_snapshot,
        .recovery_checkpoint = recovery_checkpoint,
    };

    const deps = agentRuntimeDeps(&ctx);
    const semantic_presentation = if (ctx.presenter) |value| value.semanticSink() else null;
    try ctx.checkCancellation();
    options.deps.process_queued_prompt(&deps, semantic_presentation, ctx.lifecycleContext(), .{
        .system_prompt = cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = cfg.prompt_policy.modelPromptOverlay(ctx.model),
        .skills_prompt_section = skills_section,
        .explicit_skills_prompt_section = explicit_skills.text,
        .gateway_retry_count = cfg.gateway_retry_count,
        .gateway_chat_url = cfg.gateway_chat_url,
        .gateway_tools_json = tool_projection.tools_json,
        .custom_tool_guidance = tool_projection.custom_guidance,
        .agent_step_limit = startup.agent_step_limit,
        .max_tool_result_bytes = startup.max_tool_result_bytes,
        .cancel_flag = ctx.cancelFlag(),
        .fast_mode = ctx.fast_mode,
        .effort = ctx.effort,
        .first_call_tool_choice = ctx.first_call_tool_choice,
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.workspace_access.scope(ctx.workspace_root),
        .origin = if (ctx.writable) |writable|
            if (writable.external_prompt_origin == .persistent_child) .subagent else .root
        else
            .root,
        .root_user_messages = if (ctx.writable) |writable|
            writable.external_root_user_messages
        else
            &.{},
        .root_user_evidence_complete = if (ctx.writable) |writable|
            writable.external_root_user_evidence_complete
        else
            false,
        .current_prompt_is_root_authority = if (ctx.writable) |writable|
            writable.external_prompt_origin == .persistent_child
        else
            false,
        .context_limits = ctx.context_limits,
        .session_child_capability = session_child_capability,
    }, job) catch |err| switch (err) {
        error.NonInteractivePermissionRequired => {
            const assistant_output = try alloc.dupe(u8, ctx.assistant_output.items);
            errdefer alloc.free(assistant_output);
            const tool_calls = try takeToolCallRecords(&ctx, alloc);
            return .{
                .exit_code = 1,
                .assistant_output = assistant_output,
                .interrupted = ctx.processInterruptRequested(),
                .tool_calls = tool_calls,
                .error_code = "NonInteractivePermissionRequired",
            };
        },
        else => {
            if (!options.output_mode.capturesJson()) return err;
            var failed_result = try takePromptRunResult(&ctx, alloc);
            failed_result.exit_code = 1;
            failed_result.error_code = @errorName(err);
            return failed_result;
        },
    };
    worker_events_drained = true;
    if (ctx.presenter) |value| try value.finish();

    var result = try takePromptRunResult(&ctx, alloc);
    finalizeFreshAuthSession(&ctx, &result);
    return result;
}

fn takePromptRunResult(ctx: *AskContext, alloc: Allocator) !PromptRunResult {
    const assistant_output = try alloc.dupe(u8, ctx.assistant_output.items);
    errdefer alloc.free(assistant_output);
    const model = try alloc.dupe(u8, ctx.model);
    errdefer alloc.free(model);
    const session_id = if (ctx.writable) |writable|
        try alloc.dupe(u8, writable.active_id)
    else
        try alloc.dupe(u8, "");
    errdefer if (session_id.len > 0) alloc.free(session_id);

    const tool_calls = try takeToolCallRecords(ctx, alloc);

    return .{
        .exit_code = if (ctx.failed) 1 else 0,
        .assistant_output = assistant_output,
        .interrupted = ctx.processInterruptRequested(),
        .model = model,
        .session_id = session_id,
        .tool_calls = tool_calls,
        .step_count = ctx.step_count,
        .error_code = ctx.typed_error_code,
        .auth_failure = ctx.auth_failure,
        .recovery = ctx.last_recovery_status,
        .recovery_durable = ctx.writable != null,
    };
}

fn takeToolCallRecords(ctx: *AskContext, alloc: Allocator) ![]ToolCallRecord {
    ctx.tool_call_records_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.tool_call_records_mutex.unlock(io_mod.getIo());
    const owned = if (ctx.tool_call_records.items.len > 0)
        try alloc.dupe(ToolCallRecord, ctx.tool_call_records.items)
    else
        @as([]ToolCallRecord, &.{});
    if (owned.len > 0) ctx.tool_call_records.clearRetainingCapacity();
    return owned;
}

fn finalizeFreshAuthSession(ctx: *AskContext, result: *PromptRunResult) void {
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    if (result.auth_failure == null or
        ctx.requested_resume != null or
        ctx.session.historyLen() != 0 or
        result.step_count != 0 or
        ctx.store == null or
        ctx.writable == null)
    {
        return;
    }

    if (ctx.writable.?.state.recovery_checkpoint != null) {
        _ = ctx.writable.?.appendEvent(
            ctx.alloc,
            .{ .recovery_checkpoint_cleared = .{} },
            io_mod.milliTimestamp(),
            .retry_expected_tail,
            .{},
        ) catch |err| {
            debug_trace.logf(
                "ask",
                "fresh auth session retained because recovery checkpoint clear failed err={s}",
                .{@errorName(err)},
            );
            return;
        };
    }

    const active_id = ctx.writable.?.active_id;
    ctx.background.detachManagedPersistence(std.heap.c_allocator, active_id);
    ctx.session.clearWebFetchArtifacts();
    if (ctx.subagent_host) |subagent_host| subagent_host.deinit();
    ctx.subagent_host = null;

    var loaded = ctx.writable.?;
    ctx.writable = null;
    const disposition = ctx.deps.discard_pristine_session(
        ctx.deps.discard_pristine_session_ctx,
        ctx,
        &loaded,
    );
    if (disposition != .discarded) return;
    if (result.session_id.len > 0) ctx.alloc.free(result.session_id);
    result.session_id = &.{};
}

fn agentRuntimeDeps(ctx: *AskContext) agent_runtime.AgentRuntimeDeps {
    ctx.session.usage.configureCheckpointSink(
        if (ctx.writable != null)
            .{
                .context = @ptrCast(ctx),
                .allocator = ctx.alloc,
                .persist = persistUsageCheckpoint,
            }
        else
            null,
    );
    return .{
        .ctx = @ptrCast(ctx),
        .agent_stream_provider = ctx.agentStreamProvider(),
        .tool_registry = ctx.toolRegistry(),
        .context_registry = ctx.deps.context_registry,
        .context_enabled = ctx.context_enabled,
        .finalize_turn = finalizeTurn,
        .prepare_parent_turn_context = prepareParentTurnContext,
        .acknowledge_parent_turn_context = acknowledgeParentTurnContext,
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,
        .check_tool_availability = checkToolAvailability,
        .request_tool_permission = requestToolPermissionOutcomeWithRequest,
        .request_prepared_file_mutation_permission = requestPreparedFileMutationPermissionOutcomeForRuntime,
        .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
        .describe_tool_action = describeToolAction,
        .describe_tool_action_completed = describeToolActionCompleted,
        .describe_tool_action_denied = describeToolActionDenied,
        .permission_target_for_call = permissionTargetForCall,
        .execute_tool_call = executeToolCallAuthorized,
        .publish_committed_file_handoff = publishCommittedFileHandoff,
        .propagate_history_turn = propagateHistoryTurn,
        .recovery_checkpoint = if (ctx.writable != null)
            .{
                .set = setRecoveryCheckpoint,
            }
        else
            null,
        .propagate_grant = propagateGrant,
        .push_event = pushEvent,
        .push_text = pushText,
        .push_tool_lifecycle = pushToolLifecycle,
        .push_diff_block = pushDiffBlock,
        .push_system_notice = pushSystemNotice,
        .push_context_notice = pushContextNotice,
        .push_route_recovery_status = pushRouteRecoveryStatus,
        .push_command_output_complete = pushCommandOutputComplete,
        .push_http_error = pushHttpError,
        .refresh_gateway_credential = refreshGatewayCredential,
        .available_model_capabilities = availableModelCapabilities,
        .resolve_model_capabilities = resolveModelCapabilities,
        .format_tool_execution_error = formatToolExecutionError,
        .record_tool_call_rejected = recordToolCallRejected,
        .report_usage = reportUsage,
        .usage = &ctx.session.usage,
        .usage_allocator = ctx.alloc,
    };
}

fn refreshGatewayCredential(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    source: credentials.Source,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return auth_runtime.refreshCredentialTokenForAccount(
        ctx.cfg.gateway_provider.oauth_transport,
        alloc,
        source,
        mode,
        expected_account_id,
    );
}

fn persistUsageCheckpoint(
    raw_ctx: *anyopaque,
    snapshot: session_usage.Snapshot,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const store = ctx.store orelse return error.SessionPersistenceUnavailable;
    const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        ctx.alloc,
        writable,
        snapshot,
    );
    if (writable.degradedTail() != null) {
        var current = try currentAskState(
            ctx,
            writable,
            recovery_checkpoint.timestamp_ms,
        );
        defer current.deinit(ctx.alloc);
        try writable.retryDegradedWithStateReplacement(
            ctx.alloc,
            current,
            .{},
        );
    }
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        recovery_checkpoint.timestamp_ms,
        .retry_expected_tail,
        .{ .checkpoint_interval = 0 },
    );
    try store.finishUsageRecoveryCheckpoint(
        writable.active_id,
        recovery_checkpoint,
    );
}

/// Overwrite session totals with the latest completion usage (same semantics as
/// interactive `agentReportUsage`). Gateway `input_tokens` is full-prompt
/// occupancy, not a delta, so overwrite rather than accumulate.
fn reportUsage(raw_ctx: *anyopaque, usage: types.Usage) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value| value else return;
    if (usage.input_tokens) |input| writable.state.total_input_tokens = input;
    if (usage.output_tokens) |output| writable.state.total_output_tokens = output;
}

fn resolveModelCapabilities(raw_ctx: *anyopaque, _: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const catalog = selectModelCatalog(
        ctx.provider,
        ctx.cfg.gateway_provider.model_catalog,
        ctx.cfg.codex_model_catalog,
        ctx.cfg.grok_model_catalog,
        ctx.cfg.claude_model_catalog,
    ) orelse return model_capabilities.capabilitiesForModel(model);
    return ctx.capability_resolver.resolve(
        ctx.alloc,
        catalog,
        .{
            .access = ctx.model_catalog_access,
            .endpoint = ctx.cfg.gateway_models_path,
            .cancel_flag = ctx.cancelFlag(),
        },
        model,
    );
}

fn selectModelCatalog(
    provider: model_provider.ProviderId,
    gateway: model_catalog.Provider,
    codex: ?model_catalog.Provider,
    grok: ?model_catalog.Provider,
    claude: ?model_catalog.Provider,
) ?model_catalog.Provider {
    return switch (provider) {
        .gateway => gateway,
        .codex => codex,
        .grok => grok,
        .claude => claude,
    };
}

fn availableModelCapabilities(raw_ctx: *anyopaque, model: []const u8) model_capabilities.Capabilities {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return ctx.capability_resolver.available(model);
}

test "provider catalog selection never falls back across origins" {
    var gateway_tag: u8 = 0;
    var codex_tag: u8 = 0;
    var gateway = test_builtin_gateway.model_catalog_provider;
    gateway.context = &gateway_tag;
    var codex = test_builtin_gateway.model_catalog_provider;
    codex.context = &codex_tag;
    var grok_tag: u8 = 0;
    var grok = test_builtin_gateway.model_catalog_provider;
    grok.context = &grok_tag;
    var claude_tag: u8 = 0;
    var claude = test_builtin_gateway.model_catalog_provider;
    claude.context = &claude_tag;
    const cases = [_]struct {
        provider: model_provider.ProviderId,
        codex: ?model_catalog.Provider,
        grok: ?model_catalog.Provider,
        claude: ?model_catalog.Provider,
        expected_context: ?*anyopaque,
    }{
        .{ .provider = .gateway, .codex = codex, .grok = grok, .claude = claude, .expected_context = &gateway_tag },
        .{ .provider = .codex, .codex = codex, .grok = grok, .claude = claude, .expected_context = &codex_tag },
        .{ .provider = .codex, .codex = null, .grok = grok, .claude = claude, .expected_context = null },
        .{ .provider = .grok, .codex = codex, .grok = grok, .claude = claude, .expected_context = &grok_tag },
        .{ .provider = .grok, .codex = codex, .grok = null, .claude = claude, .expected_context = null },
        .{ .provider = .claude, .codex = codex, .grok = grok, .claude = claude, .expected_context = &claude_tag },
        .{ .provider = .claude, .codex = codex, .grok = grok, .claude = null, .expected_context = null },
    };

    for (cases) |case| {
        const selected = selectModelCatalog(case.provider, gateway, case.codex, case.grok, case.claude);
        if (case.expected_context) |expected| {
            try std.testing.expect(selected != null);
            try std.testing.expect(selected.?.context.? == expected);
        } else {
            try std.testing.expect(selected == null);
        }
    }
}

fn finalizeTurn(raw_ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, disposition: ?types.ProviderCompletionDisposition) !void {
    std.debug.assert(turn_id != 0);
    _ = disposition;
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (outcome == .failed or outcome == .paused) {
        ctx.failed = true;
    }
}

fn appendRuntimeContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.deps.context_registry.appendDefaultTransient(.{
        .workspace_root = ctx.workspace_root,
        .access_scope = ctx.workspace_access.scope(ctx.workspace_root),
        .interactive = false,
        .permission_mode = ctx.permission_mode,
        .tracker = null,
        .background = &ctx.background,
        .session = &ctx.session,
    }, arena, messages);
}

fn prepareParentTurnContext(
    raw_ctx: *anyopaque,
    arena: Allocator,
) !?agent_runtime.PreparedParentTurnContext {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const subagent_host = ctx.subagent_host orelse return null;
    const writable = if (ctx.writable) |*value| value else return null;
    return parent_delivery_projector.prepare(
        arena,
        subagent_host.sessions,
        writable.active_id,
        subagent_host.manager.options.child_store,
    );
}

fn acknowledgeParentTurnContext(
    raw_ctx: *anyopaque,
    arena: Allocator,
    acknowledgements: []const agent_runtime.ParentTurnDeliveryAck,
) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const subagent_host = ctx.subagent_host orelse return;
    const retirement_ready = parent_delivery_projector
        .acknowledgeWithRetirementSignal(
        arena,
        subagent_host.sessions,
        subagent_host.manager.options.child_store,
        acknowledgements,
    );
    if (retirement_ready) {
        subagent_host.requestRetirementSweep(io_mod.milliTimestamp());
    }
}

fn appendStaticContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.deps.context_registry.appendDefaultStatic(.{
        .project_context = ctx.modelVisibleProjectContext(),
    }, arena, messages);
    var snapshot = if (ctx.mcp) |mcp|
        try mcp.snapshotModelCatalog(arena, ctx.permission_rules, true)
    else
        try mcp_model_catalog.Snapshot.empty(arena);
    defer snapshot.deinit(arena);
    const section = try mcp_model_catalog.render(arena, snapshot);
    if (section.text.len > 0) {
        try messages.append(arena, .{ .role = .system, .content = section.text });
    }
    if (section.notice) |notice| try pushContextNotice(raw_ctx, notice);
}

fn validateToolCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (try ctx.cfg.mode_registry.toolPolicyDeniedJson(arena, ctx.deps.tool_set, ctx.mode_id, call.name)) |reason| {
        return .{ .failure = reason };
    }
    return tool_runtime.validateToolCall(ctx.toolContext(), arena, call);
}

fn checkToolAvailability(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.checkToolAvailability(ctx.toolContext(), arena, call);
}

fn cliAdmissionContext(
    ctx: *AskContext,
    advertised_dynamic_tool_names: []const []const u8,
    review_turn: ?permission_auto_classifier.ReviewTurnContext,
) tool_runtime.Context {
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(
        ctx.toolContext(),
        advertised_dynamic_tool_names,
    );
    tool_ctx.permission_review_turn = review_turn;
    if (cliContextPermissionPromptAllowed(ctx)) {
        tool_ctx.permission_prompter = .{
            .context = @ptrCast(ctx),
            .request_fn = requestCliPermission,
        };
    }
    return tool_ctx;
}

fn requestPreparedFileMutationPermissionOutcomeForRuntime(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = cliAdmissionContext(ctx, advertised_dynamic_tool_names, review_turn);
    return finishCliPermissionOutcome(
        ctx,
        tool_ctx,
        arena,
        call,
        permission_mode,
        try tool_admission.requestPreparedFileMutationPermissionOutcome(
            tool_ctx.admissionInputWithLiveAuthority(live_authority),
            arena,
            call,
            prepared,
            permission_mode,
            local_grants,
        ),
    );
}

fn requestToolPermissionOutcome(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, permission_mode: PermissionMode, local_grants: []const PermissionGrant, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = cliAdmissionContext(ctx, advertised_dynamic_tool_names, null);
    return finishCliPermissionOutcome(
        ctx,
        tool_ctx,
        arena,
        call,
        permission_mode,
        try tool_admission.requestPermissionOutcome(
            tool_ctx.admissionInput(),
            arena,
            call,
            permission_mode,
            local_grants,
        ),
    );
}

fn requestToolPermissionOutcomeWithRequest(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = cliAdmissionContext(ctx, advertised_dynamic_tool_names, review_turn);
    return finishCliPermissionOutcome(
        ctx,
        tool_ctx,
        arena,
        call,
        permission_mode,
        if (revalidation) |request| switch (request) {
            .action => |action| try tool_admission.revalidateLiveActionPermissionOutcome(
                tool_ctx.admissionInputWithLiveAuthority(live_authority),
                arena,
                call,
                permission_mode,
                local_grants,
                action.authority,
                action.human_approval,
            ),
        } else try tool_admission.requestPermissionOutcome(
            tool_ctx.admissionInputWithLiveAuthority(live_authority),
            arena,
            call,
            permission_mode,
            local_grants,
        ),
    );
}

fn finishCliPermissionOutcome(
    ctx: *AskContext,
    tool_ctx: tool_runtime.Context,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    outcome: command_admission.PermissionOutcome,
) !command_admission.PermissionOutcome {
    if (outcome.decision != .permission_required) return outcome;
    const label = try tool_presentation.formatPlainAction(arena, .{
        .tool_registry = tool_ctx.tool_registry,
        .call = call,
        .workspace_root = tool_ctx.workspace_root,
    });
    switch (outcome.requirement orelse .approval_required) {
        .configured_rule => try writeBlockedActionGuidance(
            ctx,
            "fx ask: permission required by configured rule",
            label,
            "noninteractive_permission_prompt_unavailable",
            "fx ask: rerun in the interactive shell to approve this action, or add a narrow matching permission rule before retrying\n",
        ),
        .approval_required => try writeBlockedActionGuidance(
            ctx,
            "fx ask: permission required for tool execution in noninteractive mode",
            label,
            "noninteractive_permission_prompt_unavailable",
            if (permission_mode == .auto)
                "fx ask: human approval is required for this action; use the interactive shell to approve it, or add a narrow matching permission rule\n"
            else
                "fx ask: rerun with --auto to review this exact action automatically, or use the interactive shell to approve it\n",
        ),
    }
    try recordToolCallRejected(
        @ptrCast(ctx),
        arena,
        call,
        "Permission required",
        null,
    );
    return error.NonInteractivePermissionRequired;
}

const TestReviewTurn = struct {
    tool_calls: [1]ToolCall,
    root_messages: [1][]const u8,

    fn init(root_text: []const u8, call: ToolCall) TestReviewTurn {
        return .{
            .tool_calls = .{call},
            .root_messages = .{root_text},
        };
    }

    fn context(self: *const TestReviewTurn) permission_auto_classifier.ReviewTurnContext {
        return .{
            .model = "openai/gpt-5",
            .pending_assistant = .{ .role = .assistant, .tool_calls = &self.tool_calls },
            .target_call_id = self.tool_calls[0].id,
            .origin = .root,
            .current_root_request = self.root_messages[0],
        };
    }
};

fn writeBlockedActionGuidance(
    ctx: *AskContext,
    headline: []const u8,
    label: []const u8,
    reason: []const u8,
    hint: []const u8,
) !void {
    try ctx.writeLine(headline);
    try ctx.writeStderr("fx ask: blocked action: ");
    try ctx.writeStderr(label);
    try ctx.writeStderr("\nfx ask: reason=");
    try ctx.writeStderr(reason);
    try ctx.writeStderr("\n");
    try ctx.writeStderr(hint);
}

fn requestCliPermission(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    _: ToolCall,
    _: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return switch (try promptCliPermissionApproval(ctx, request.label)) {
        .approve => permission_request.OwnedPermissionResponse.init(alloc, .once, null),
        .deny => permission_request.OwnedPermissionResponse.init(alloc, .deny, null),
        .unavailable => error.PermissionPromptUnavailable,
    };
}

fn promptCliPermissionApproval(
    ctx: *AskContext,
    label: []const u8,
) !PermissionApprovalPromptResult {
    if (!cliContextPermissionPromptAllowed(ctx)) return .unavailable;
    return try ctx.deps.permission_approval_prompt(
        ctx.deps.permission_approval_prompt_ctx,
        ctx.deps.stderr_ctx,
        ctx.deps.write_stderr,
        label,
        ctx,
        notifyAskPermissionAttention,
    );
}

fn notifyAskPermissionAttention(raw: ?*anyopaque) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    ctx.dispatchAttentionRequired(.permission);
}

fn emitAskNotificationBell(raw: *anyopaque) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw));
    if (!ctx.deps.stderr_is_tty(ctx.deps.stderr_ctx)) return;
    ctx.writeStderr("\x07") catch |err| {
        debug_trace.logf(
            "notifications",
            "fx ask terminal bell write failed err={s}",
            .{@errorName(err)},
        );
    };
}

fn cliPermissionPromptAllowed(
    output_mode: OutputMode,
    prompt_permissions: bool,
    stdin_is_tty: bool,
) bool {
    return switch (output_mode) {
        .raw, .terminal, .terminal_no_color => true,
        .json, .quiet => prompt_permissions and stdin_is_tty,
    };
}

fn cliContextPermissionPromptAllowed(ctx: *const AskContext) bool {
    return cliPermissionPromptAllowed(
        ctx.output_mode,
        ctx.prompt_permissions,
        ctx.deps.stdin_is_tty(ctx.deps.stdin_ctx),
    );
}

fn describeToolAction(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .workspace_root = ctx.workspace_root,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
}

fn resolveToolActionDisplayTarget(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.resolveTerminalDisplayTarget(
        arena,
        ctx.toolRegistry(),
        ctx.workspace_root,
        &ctx.terminal_client,
        call,
    );
}

fn describeToolActionCompleted(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .workspace_root = ctx.workspace_root,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
}

fn describeToolActionDenied(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const action = try tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .workspace_root = ctx.workspace_root,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ label, action });
}

fn lifecycleDynamicMcpToolAvailable(ctx: *AskContext, name: []const u8, advertised_dynamic_tool_names: []const []const u8) bool {
    const capability = lifecycleDynamicMcpAvailability(ctx);
    return dynamicMcpToolAvailable(ctx.toolRegistry(), name, advertised_dynamic_tool_names, capability.context, capability.has_tool, capability.access);
}

fn lifecycleDynamicMcpAvailability(ctx: *AskContext) tool_mcp_runtime.RuntimeCapabilities {
    if (ctx.mcp == null) return .{};
    return .{ .context = @ptrCast(ctx), .has_tool = mcpHasTool };
}

fn dynamicMcpToolAvailable(registry: tool_dispatch.Registry, name: []const u8, advertised_dynamic_tool_names: []const []const u8, mcp_ctx: ?*anyopaque, has_tool: ?McpHasToolFn, access: tool_mcp_runtime.Access) bool {
    if (!tool_presentation.isAdvertisedDynamicMcpName(registry, name, advertised_dynamic_tool_names)) return false;
    const raw_ctx = mcp_ctx orelse return false;
    const has = has_tool orelse return false;
    return has(raw_ctx, name, access);
}

fn permissionTargetForCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(
        ctx.toolContext(),
        advertised_dynamic_tool_names,
    );
    return tool_admission.permissionTargetForCall(tool_ctx.admissionInput(), arena, call);
}

fn executeToolCallAuthorized(
    raw_ctx: *anyopaque,
    request: agent_runtime.ToolExecutionRequest,
) !ToolExecutionResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = ctx.toolContext();
    tool_ctx.root_user_intent_context = request.root_user_intent_context;
    tool_ctx.root_user_messages = request.root_user_messages;
    tool_ctx.root_user_evidence_complete = request.root_user_evidence_complete;
    tool_ctx.session_grants = request.session_grants;
    tool_ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
    tool_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    const result = tool_runtime.executeToolCallAuthorized(
        tool_ctx,
        request,
    ) catch |err| {
        captureToolExecutionError(ctx, request, err);
        return err;
    };
    captureToolExecutionResult(ctx, request, result);
    return result;
}

fn captureToolExecutionError(
    ctx: *AskContext,
    request: agent_runtime.ToolExecutionRequest,
    _: anyerror,
) void {
    if (ctx.output_mode.capturesJson()) {
        appendToolCallRecordBestEffort(ctx, request.call, "error", null);
    }
}

fn captureToolExecutionResult(
    ctx: *AskContext,
    request: agent_runtime.ToolExecutionRequest,
    result: ToolExecutionResult,
) void {
    if (ctx.output_mode.capturesJson()) {
        appendToolCallRecordBestEffort(
            ctx,
            request.call,
            if (result.status == .failure) "error" else "success",
            result,
        );
    }
    if (result.status == .failure and result.finish_turn) {
        ctx.failed = true;
        ctx.typed_error_code = result.status_detail;
    }
}

fn publishCommittedFileHandoff(
    _: *anyopaque,
    _: file_mutation.CommittedFileHandoff,
) agent_runtime.SecondaryPublicationReport {
    return .{ .diff = .skipped, .tracker = .skipped };
}

fn recordToolCallRejected(
    raw_ctx: *anyopaque,
    _: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!ctx.output_mode.capturesJson()) return;
    appendToolCallRecordBestEffort(ctx, call, "error", .{
        .status = .failure,
        .model_output = model_output,
        .command_result_json = command_result_json,
    });
}

fn appendToolCallRecordBestEffort(
    ctx: *AskContext,
    call: ToolCall,
    status: []const u8,
    result: ?ToolExecutionResult,
) void {
    appendToolCallRecord(ctx, call, status, result) catch |err| {
        debug_trace.logf(
            "cli_ask",
            "tool-call capture dropped name={s} status={s} err={s}",
            .{ call.name, status, @errorName(err) },
        );
    };
}

fn appendToolCallRecord(
    ctx: *AskContext,
    call: ToolCall,
    status: []const u8,
    result: ?ToolExecutionResult,
) !void {
    ctx.tool_call_records_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.tool_call_records_mutex.unlock(io_mod.getIo());

    const name = try ctx.alloc.dupe(u8, call.name);
    errdefer ctx.alloc.free(name);
    const owned_status = try ctx.alloc.dupe(u8, status);
    errdefer ctx.alloc.free(owned_status);
    const command_result_json = if (result) |execution|
        if (execution.command_result_json) |json|
            try ctx.alloc.dupe(u8, json)
        else
            null
    else
        null;
    errdefer if (command_result_json) |json| ctx.alloc.free(json);
    const ask_question_text = try questionTextForAskCall(ctx.alloc, call);
    errdefer if (ask_question_text) |text| ctx.alloc.free(text);

    try ctx.tool_call_records.append(ctx.alloc, .{
        .name = name,
        .status = owned_status,
        .command_result_json = command_result_json,
        .ask_question_text = ask_question_text,
        .web_search_completion = if (result) |execution| execution.web_search_completion else null,
        .web_fetch_completion = if (result) |execution| execution.web_fetch_completion else null,
    });
}

fn questionTextForAskCall(alloc: Allocator, call: ToolCall) !?[]u8 {
    if (!std.mem.eql(u8, call.name, "ask_user_question")) return null;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        call.arguments_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const questions_value = parsed.value.object.get("questions") orelse return null;
    if (questions_value != .array or questions_value.array.items.len == 0) return null;
    const first = questions_value.array.items[0];
    if (first != .object) return null;
    const question_value = first.object.get("question") orelse return null;
    if (question_value != .string) return null;
    const text = std.mem.trim(u8, question_value.string, " \t\r\n");
    if (text.len == 0) return null;
    const max_question_text_bytes: usize = 256;
    return try alloc.dupe(
        u8,
        text_utils.utf8PrefixByBytes(text, max_question_text_bytes),
    );
}

fn propagateHistoryTurn(raw_ctx: *anyopaque, turn: HistoryTurn) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.session.appendHistoryEntry(ctx.alloc, turn);
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value| value else return;
    try subagent_resume_admission.retainExternalRootUserTurn(
        ctx.alloc,
        writable,
        turn,
    );

    if (writable.degradedTail() != null) {
        const now_ms = io_mod.milliTimestamp();
        var current = try currentAskState(ctx, writable, now_ms);
        defer current.deinit(ctx.alloc);
        try writable.retryDegradedWithStateReplacement(
            ctx.alloc,
            current,
            .{},
        );
    }

    _ = writable.appendEvent(
        ctx.alloc,
        .{ .history_turn_committed = .{
            .conversation_language = ctx.session.languageSnapshot(),
            .total_input_tokens = writable.state.total_input_tokens,
            .total_output_tokens = writable.state.total_output_tokens,
            .turn = turn,
        } },
        io_mod.milliTimestamp(),
        .retry_expected_tail,
        .{},
    ) catch |err| switch (err) {
        error.EventFrameTooLarge => {
            try commitAskStateReplacement(ctx, writable, true);
            ctx.prompt_snapshot_committed = true;
            return;
        },
        else => return err,
    };
    ctx.prompt_snapshot_committed = true;
}

fn setRecoveryCheckpoint(
    raw_ctx: *anyopaque,
    checkpoint: session_codec.RecoveryCheckpoint,
) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (ctx.writable) |*value| value else return error.SessionPersistenceUnavailable;
    const now_ms = io_mod.milliTimestamp();
    _ = writable.appendEvent(
        ctx.alloc,
        .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
        now_ms,
        .retry_expected_tail,
        .{},
    ) catch |err| switch (err) {
        error.EventFrameTooLarge => {
            var current = try currentAskState(ctx, writable, now_ms);
            defer current.deinit(ctx.alloc);
            if (current.recovery_checkpoint) |*old| old.deinit(ctx.alloc);
            current.recovery_checkpoint = try checkpoint.dupe(ctx.alloc);
            _ = try writable.commitStateReplacement(
                ctx.alloc,
                current,
                .compaction,
                .retry_expected_tail,
                .{},
            );
        },
        else => return err,
    };
}

fn currentAskState(
    ctx: *AskContext,
    writable: *session_store.LoadedWritableSession,
    now_ms: i64,
) !session_codec.DurableSessionState {
    var state = try writable.state.dupe(ctx.alloc);
    errdefer state.deinit(ctx.alloc);
    const history = try ctx.session.snapshotHistory(ctx.alloc);
    types.freeHistoryTurnSlice(ctx.alloc, state.history);
    state.history = history;
    const permission_state = try ctx.session.snapshotPermissionState(ctx.alloc);
    state.permission_state.deinit(ctx.alloc);
    state.permission_state = permission_state;
    state.conversation_language = ctx.session.languageSnapshot();
    state.updated_at_ms = now_ms;
    const usage = try ctx.session.usage.snapshot(ctx.alloc);
    if (state.usage) |*old| old.deinit(ctx.alloc);
    state.usage = usage;
    return state;
}

fn commitAskStateReplacement(
    ctx: *AskContext,
    writable: *session_store.LoadedWritableSession,
    clear_recovery_checkpoint: bool,
) !void {
    const now_ms = io_mod.milliTimestamp();
    var state = try currentAskState(ctx, writable, now_ms);
    defer state.deinit(ctx.alloc);
    if (clear_recovery_checkpoint) {
        if (state.recovery_checkpoint) |*checkpoint| checkpoint.deinit(ctx.alloc);
        state.recovery_checkpoint = null;
    }
    _ = try writable.commitStateReplacement(
        ctx.alloc,
        state,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    if (state.usage) |usage| {
        ctx.session.usage.markClean(usage);
    }
}

fn propagateGrant(_: *anyopaque, _: []const u8, _: []const u8) !void {}

fn pushEvent(raw_ctx: *anyopaque, event: WorkerEvent) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    switch (event) {
        .clear_route_recovery_status => ctx.last_recovery_status = null,
        else => {},
    }
    worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
}

fn pushText(raw_ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    switch (emission) {
        .assistant_source => |text| switch (ctx.output_mode) {
            .raw, .json => try pushRawAssistantText(ctx, text),
            .quiet, .terminal, .terminal_no_color => {},
        },
        .assistant_rendered => |text| switch (ctx.output_mode) {
            .terminal, .terminal_no_color => try ctx.presenter.?.pushText(text),
            .quiet, .json, .raw => {},
        },
        .operational => |text| switch (ctx.output_mode) {
            .terminal, .terminal_no_color => try ctx.presenter.?.pushText(text),
            .quiet, .json, .raw => try ctx.writeStderr(text),
        },
    }
}

fn pushRawAssistantText(ctx: *AskContext, text: []const u8) !void {
    if (text.len == 0) return;
    if (ctx.raw_boundary_pending and ctx.raw_has_output) {
        const separator = if (ctx.raw_trailing_newlines >= 2)
            ""
        else if (ctx.raw_trailing_newlines == 1)
            "\n"
        else
            "\n\n";
        try writeRawAssistantBytes(ctx, separator);
    }
    ctx.raw_boundary_pending = false;
    try writeRawAssistantBytes(ctx, text);
}

fn writeRawAssistantBytes(ctx: *AskContext, text: []const u8) !void {
    if (ctx.output_mode == .json) try ctx.assistant_output.appendSlice(ctx.alloc, text);
    if (ctx.output_mode == .raw) try ctx.writeStdout(text);
    if (text.len == 0) return;
    ctx.raw_has_output = true;
    var trailing: usize = 0;
    while (trailing < text.len and text[text.len - trailing - 1] == '\n') : (trailing += 1) {}
    ctx.raw_trailing_newlines = if (trailing == text.len)
        @min(2, ctx.raw_trailing_newlines + @as(u8, @intCast(@min(trailing, 2))))
    else
        @intCast(@min(trailing, 2));
}

fn pushToolLifecycle(raw_ctx: *anyopaque, event: types.ToolLifecycleEvent) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) {
        try ctx.presenter.?.pushToolLifecycle(event);
    }
    switch (event) {
        .provisional => |provisional| if (!ctx.output_mode.isTerminal()) {
            if (provisional.tool_name) |tool_name| {
                try beginPendingToolProgress(ctx, provisional.id.call_id, tool_name);
            }
        },
        .authoritative_started => |started| {
            ctx.step_count += 1;
            if (!ctx.output_mode.isTerminal()) {
                try beginPendingToolProgress(ctx, started.id.call_id, started.tool_name);
            }
            if (ctx.raw_has_output) ctx.raw_boundary_pending = true;
        },
        .progress => |progress| if (!ctx.output_mode.isTerminal()) {
            try publishPendingToolProgress(ctx, progress.id.call_id, progress.text);
        },
        .turn_finished => if (!ctx.output_mode.isTerminal()) clearPendingToolProgress(ctx),
        .terminal => |value| if (!ctx.output_mode.isTerminal()) {
            try settlePendingToolProgress(ctx, value.id.call_id, value.outcome);
        },
    }
}

fn beginPendingToolProgress(ctx: *AskContext, call_id: []const u8, tool_name: []const u8) !void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());
    discardPendingToolProgressLocked(ctx, call_id);

    const owned_id = try ctx.alloc.dupe(u8, call_id);
    errdefer ctx.alloc.free(owned_id);
    const owned_name = try ctx.alloc.dupe(u8, tool_name);
    errdefer ctx.alloc.free(owned_name);
    try ctx.pending_tool_progress.append(ctx.alloc, .{
        .call_id = owned_id,
        .tool_name = owned_name,
    });
}

fn publishPendingToolProgress(ctx: *AskContext, call_id: []const u8, text: []const u8) !void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());

    const pending = findPendingToolProgressLocked(ctx, call_id) orelse return;
    const owned_text = try ctx.alloc.dupe(u8, text);
    if (pending.text) |previous| ctx.alloc.free(previous);
    pending.text = owned_text;
    pending.visible = false;
    if (ctx.toolRegistry().lookup(pending.tool_name)) |tool| {
        if (tool.executor_kind == .web_fetch) return;
    }
    if (consumeDeferredToolProgressLocked(ctx, text)) {
        pending.visible = true;
        return;
    }
    try ctx.writeStderr(text);
    try ctx.writeStderr("\n");
    pending.visible = true;
}

fn settlePendingToolProgress(ctx: *AskContext, call_id: []const u8, outcome: types.ToolOutcome) !void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());
    var pending = takePendingToolProgressLocked(ctx, call_id) orelse return;
    defer pending.deinit(ctx.alloc);
    const context_deferred = outcome.kind == .deferred and
        std.mem.startsWith(u8, outcome.summary, types.context_deferred_tool_status_label ++ ": ");
    const legacy_deferred = outcome.kind == .denied and
        std.mem.startsWith(u8, outcome.summary, types.deferred_tool_result_output ++ ": ");
    if (!context_deferred and !legacy_deferred) return;
    if (!pending.visible) return;
    const text = pending.text orelse return;
    try ctx.deferred_tool_progress.append(ctx.alloc, text);
    pending.text = null;
}

fn discardPendingToolProgressLocked(ctx: *AskContext, call_id: []const u8) void {
    for (ctx.pending_tool_progress.items, 0..) |pending, index| {
        if (!std.mem.eql(u8, pending.call_id, call_id)) continue;
        const removed = ctx.pending_tool_progress.swapRemove(index);
        removed.deinit(ctx.alloc);
        return;
    }
}

fn takePendingToolProgressLocked(ctx: *AskContext, call_id: []const u8) ?PendingToolProgress {
    for (ctx.pending_tool_progress.items, 0..) |pending, index| {
        if (std.mem.eql(u8, pending.call_id, call_id)) {
            return ctx.pending_tool_progress.swapRemove(index);
        }
    }
    return null;
}

fn findPendingToolProgressLocked(ctx: *AskContext, call_id: []const u8) ?*PendingToolProgress {
    for (ctx.pending_tool_progress.items) |*pending| {
        if (std.mem.eql(u8, pending.call_id, call_id)) return pending;
    }
    return null;
}

fn consumeDeferredToolProgressLocked(ctx: *AskContext, text: []const u8) bool {
    for (ctx.deferred_tool_progress.items, 0..) |progress, index| {
        if (!std.mem.eql(u8, progress, text)) continue;
        ctx.alloc.free(ctx.deferred_tool_progress.swapRemove(index));
        return true;
    }
    return false;
}

fn clearPendingToolProgress(ctx: *AskContext) void {
    ctx.pending_tool_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.pending_tool_progress_mutex.unlock(io_mod.getIo());
    for (ctx.pending_tool_progress.items) |progress| progress.deinit(ctx.alloc);
    ctx.pending_tool_progress.clearRetainingCapacity();
    for (ctx.deferred_tool_progress.items) |progress| ctx.alloc.free(progress);
    ctx.deferred_tool_progress.clearRetainingCapacity();
}

fn onWebSearchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebSearchProgress) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) return;
    const alloc = std.heap.c_allocator;
    const line = tool_presentation.formatWebSearchProgressPlain(alloc, progress) catch return;
    defer alloc.free(line);
    ctx.web_search_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.web_search_progress_mutex.unlock(io_mod.getIo());
    ctx.writeLine(line) catch {};
}

fn onWebFetchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebFetchProgress) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) return;
    const alloc = std.heap.c_allocator;
    const line = tool_presentation.formatWebFetchProgressPlain(alloc, progress) catch return;
    defer alloc.free(line);
    ctx.web_search_progress_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.web_search_progress_mutex.unlock(io_mod.getIo());
    ctx.writeLine(line) catch {};
}

fn pushSystemNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.presenter) |presenter| return presenter.pushNotice(.{
        .topic = "system",
        .tone = .neutral,
        .body = text,
    });
    try ctx.writeStderr("[notice] ");
    try ctx.writeStderr(text);
    try ctx.writeStderr("\n");
}

fn pushContextNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!try ctx.session.claimContextNotice(ctx.alloc, text)) return;
    if (ctx.presenter) |presenter| {
        const body = try types.renderContextNoticeBody(ctx.alloc, text);
        defer ctx.alloc.free(body);
        return presenter.pushNotice(.{
            .topic = "context",
            .tone = .warning,
            .body = body,
            .visibility = .full_only,
        });
    }
    try pushSystemNotice(raw_ctx, text);
}

fn pushRouteRecoveryStatus(raw_ctx: *anyopaque, status: types.RouteRecoveryStatus) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.last_recovery_status = status;
    const terminal = status.kind == .terminal_provider_error;
    const json_progress = switch (status.kind) {
        .auto_retry,
        .auto_recovered,
        .manual_retry_without_fast,
        .manual_recovered_without_fast,
        .terminal_provider_error,
        => true,
        .unsafe_assistant_output,
        .unsafe_tool_start,
        .content_filter,
        => false,
    };
    if ((ctx.output_mode == .json and !json_progress) or
        (ctx.output_mode == .quiet and !terminal)) return;
    var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try pushSystemNotice(raw_ctx, status.label(&label_buf));
    if (terminal and ctx.writable == null) {
        try pushSystemNotice(
            raw_ctx,
            "This run was started with --no-save, so its recovery context cannot be resumed after exit.",
        );
    }
}

fn pushDiffBlock(raw_ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.presenter) |presenter| return presenter.pushDiffBlock(payload);
    defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    try ctx.writeStderr(payload.preview);
}

fn pushCommandOutputComplete(raw_ctx: *anyopaque, _: ?types.ToolLifecycleId) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal() or !ctx.command_output_line_open) return;
    try ctx.writeStderr("\n");
    ctx.command_output_line_open = false;
}

fn pushHttpError(raw_ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.failed = true;
    const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
    ctx.auth_failure = auth_failure;
    const message = if (auth_failure) |failure|
        try failure.renderText(ctx.alloc)
    else
        try gateway_error_format.formatHttpErrorMessage(ctx.alloc, status, detail);
    defer ctx.alloc.free(message);
    try ctx.writeStderr("fx ask: ");
    try ctx.writeStderr(message);
    try ctx.writeStderr("\n");
    if (ctx.output_mode.capturesJson()) {
        try ctx.assistant_output.appendSlice(ctx.alloc, message);
        try ctx.assistant_output.append(ctx.alloc, '\n');
    }
}

fn formatToolExecutionError(_: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return tool_result_errors.formatToolExecutionErrorJson(arena, tool_name, err);
}

fn onCommandOutputChunk(raw_ctx: *anyopaque, _: ?types.ToolLifecycleId, _: command_output_content.Stream, chunk: []const u8) !void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.output_mode.isTerminal()) return;
    try ctx.writeStderr(chunk);
    if (chunk.len > 0) ctx.command_output_line_open = chunk[chunk.len - 1] != '\n';
}

fn onMcpProgress(raw_ctx: *anyopaque, lifecycle_id: types.ToolLifecycleId, text: []const u8) void {
    pushToolLifecycle(raw_ctx, .{ .progress = .{
        .id = lifecycle_id,
        .text = text,
    } }) catch |err| {
        debug_trace.logf("mcp", "failed to publish ask MCP progress err={s}", .{@errorName(err)});
    };
}

fn activateAskMcp(ctx: *AskContext) anyerror!*mcp_runtime.McpRuntime {
    const runtime = ctx.mcp orelse return error.McpRuntimeUnavailable;
    try runtime.connectDeferredForAsk(ctx.toolRegistry());
    return runtime;
}

fn mcpHasTool(raw_ctx: *anyopaque, name: []const u8, access: tool_mcp_runtime.Access) bool {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activateAskMcp(ctx) catch return false;
    return mcp.hasToolWithAccess(name, access);
}

fn mcpValidateTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.ValidationResult {
    const self: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const runtime = activateAskMcp(self) catch |err| {
        if (err == error.McpRuntimeUnavailable) return .not_available;
        return err;
    };
    return runtime.validateToolArgumentsByNameWithAccess(arena, name, arguments_json, access);
}

fn mcpCallTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, max_tool_result_bytes: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activateAskMcp(ctx) catch |err| {
        if (err == error.McpRuntimeUnavailable) return null;
        return err;
    };
    return mcp.callToolByNameWithOptions(
        arena,
        name,
        arguments_json,
        max_tool_result_bytes,
        options,
    );
}

fn mcpSearchTools(raw_ctx: *anyopaque, arena: Allocator, query: []const u8, limit: usize, permission_rules: types.PermissionRuleSet, limits: config_runtime.context_limits.Values, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.SearchResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = try activateAskMcp(ctx);
    return mcp.searchTools(arena, query, limit, permission_rules, limits, access);
}

fn mcpToolSchemaJson(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, permission_rules: types.PermissionRuleSet, limits: config_runtime.context_limits.Values, access: tool_mcp_runtime.Access) anyerror!?tool_mcp_runtime.ToolSchemaResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const runtime = try activateAskMcp(ctx);
    return runtime.toolSchemaJsonByNameWithAccess(arena, name, permission_rules, limits, access);
}

fn mcpCallFeature(
    raw_ctx: *anyopaque,
    arena: Allocator,
    request: tool_mcp_runtime.FeatureRequest,
    options: tool_mcp_runtime.FeatureCallOptions,
) anyerror!tool_mcp_runtime.FeatureResult {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = try activateAskMcp(ctx);
    if (!options.access.allowsFeatureServer(mcp.generation, request.server_name)) return error.McpServerNotFound;
    return mcp.callFeatureForModel(arena, request, options);
}

fn respondToAskMcpInput(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    required: tool_mcp_runtime.InputRequired,
) anyerror![]const u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!ctx.mcp_elicitation_capabilities.any()) return error.McpInputRequired;
    return mcp_elicitation_interaction.respond(alloc, origin, required, .{
        .questioner = .{ .context = raw_ctx, .ask_fn = askTerminalMcpQuestion },
        .browser = .{ .context = raw_ctx, .open_fn = openAskMcpUrl },
        .capabilities = ctx.mcp_elicitation_capabilities,
    });
}

fn askTerminalMcpQuestion(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    entries: []const types.QuestionBatchEntry,
    deadline_ms: i64,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
) anyerror!?[][]u8 {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    if (!ctx.mcp_elicitation_capabilities.any()) return null;
    const answers = try alloc.alloc([]u8, entries.len);
    var answered: usize = 0;
    errdefer {
        for (answers[0..answered]) |answer| alloc.free(answer);
        alloc.free(answers);
    }
    for (entries) |entry| {
        try ctx.writeStderr("\n");
        try ctx.writeStderr(entry.question);
        try ctx.writeStderr("\n");
        for (entry.options, 0..) |option, index| {
            var number_buffer: [32]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&number_buffer, "  {d}. ", .{index + 1});
            try ctx.writeStderr(prefix);
            try ctx.writeStderr(option.label);
            if (option.description) |description| {
                try ctx.writeStderr(" — ");
                try ctx.writeStderr(description);
            }
            try ctx.writeStderr("\n");
        }
        if (entry.options.len > 0) {
            try ctx.writeStderr("Choose a number or enter a value: ");
        } else {
            try ctx.writeStderr("Enter a value: ");
        }
        ctx.dispatchAttentionRequired(.question);
        const line = try readAskTerminalLine(
            ctx,
            alloc,
            deadline_ms,
            lifecycle_cancel_flag,
        ) orelse {
            if (askAwakeMillis() >= deadline_ms) return error.McpInputTimedOut;
            return null;
        };
        defer alloc.free(line);
        answers[answered] = try mapTerminalAnswer(alloc, entry.options, line);
        answered += 1;
    }
    return answers;
}

fn mapTerminalAnswer(
    alloc: Allocator,
    options: []const types.QuestionOption,
    line: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    const ordinal = std.fmt.parseInt(usize, trimmed, 10) catch 0;
    if (ordinal > 0 and ordinal <= options.len) return alloc.dupe(u8, options[ordinal - 1].label);
    for (options) |option| {
        if (std.mem.eql(u8, trimmed, option.label)) return alloc.dupe(u8, option.label);
    }
    return alloc.dupe(u8, trimmed);
}

fn openAskMcpUrl(_: ?*anyopaque, alloc: Allocator, url: []const u8) anyerror!bool {
    return url_opener.native_opener.open(alloc, url);
}

const AskReadEvent = union(enum) {
    line: anyerror![]u8,
    deadline: anyerror!void,
    cancelled: anyerror!void,
};

fn readAskTerminalLine(
    ctx: *AskContext,
    alloc: Allocator,
    deadline_ms: i64,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
) !?[]u8 {
    const Cleanup = struct {
        fn drain(result_alloc: Allocator, select: *std.Io.Select(AskReadEvent)) void {
            while (select.cancel()) |item| switch (item) {
                .line => |line_result| {
                    const line = line_result catch continue;
                    result_alloc.free(line);
                },
                .deadline, .cancelled => {},
            };
        }
    };

    var select_buffer: [3]AskReadEvent = undefined;
    var select: std.Io.Select(AskReadEvent) = .init(io_mod.getIo(), &select_buffer);
    try select.concurrent(.line, readOwnedStdinLine, .{alloc});
    select.concurrent(.deadline, waitForAskDeadline, .{deadline_ms}) catch |err| {
        Cleanup.drain(alloc, &select);
        return err;
    };
    select.concurrent(.cancelled, waitForAskCancellation, .{ ctx, lifecycle_cancel_flag }) catch |err| {
        Cleanup.drain(alloc, &select);
        return err;
    };
    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select);
        return err;
    };
    return switch (event) {
        .line => |line_result| result: {
            const line = line_result catch {
                Cleanup.drain(alloc, &select);
                break :result null;
            };
            Cleanup.drain(alloc, &select);
            break :result line;
        },
        .deadline, .cancelled => result: {
            Cleanup.drain(alloc, &select);
            break :result null;
        },
    };
}

fn readOwnedStdinLine(alloc: Allocator) anyerror![]u8 {
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io_mod.getIo(), &read_buffer);
    const line = try reader.interface.takeDelimiter('\n') orelse return error.EndOfStream;
    return alloc.dupe(u8, line);
}

fn waitForAskDeadline(deadline_ms: i64) anyerror!void {
    while (askAwakeMillis() < deadline_ms) {
        const remaining = deadline_ms - askAwakeMillis();
        const delay_ms: i64 = @min(remaining, 20);
        try io_mod.getIo().sleep(.fromMilliseconds(@intCast(@max(delay_ms, 1))), .awake);
    }
}

fn askAwakeMillis() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

fn waitForAskCancellation(
    ctx: *AskContext,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
) anyerror!void {
    while (!ctx.cancelFlag().load(.acquire) and
        (lifecycle_cancel_flag == null or !lifecycle_cancel_flag.?.load(.acquire)))
    {
        try io_mod.getIo().sleep(.fromMilliseconds(10), .awake);
    }
}

fn resolveAskSubagentAuthority(
    raw: ?*anyopaque,
    alloc: Allocator,
    root_id: []const u8,
) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
    const ctx: *AskContext = @ptrCast(@alignCast(raw.?));
    const writable = if (ctx.writable) |*value| value else return error.HostAuthorityUnavailable;
    if (!std.mem.eql(u8, writable.active_id, root_id)) {
        return error.HostAuthorityUnavailable;
    }
    if (ctx.mcp != null) {
        _ = activateAskMcp(ctx) catch return error.HostAuthorityUnavailable;
    }
    const integrations = if (ctx.mcp) |mcp|
        mcp.snapshotToolNames(alloc, ctx.permission_rules)
    else
        alloc.alloc([]u8, 0);
    const owned_integrations = integrations catch return error.OutOfMemory;
    defer {
        for (owned_integrations) |name| alloc.free(name);
        alloc.free(owned_integrations);
    }
    var mcp_view = if (ctx.mcp) |mcp|
        try mcp.snapshotAccessView(
            alloc,
            root_id,
            root_id,
            ctx.permission_rules,
            ctx.cfg.mode_registry.toolAllowed(ctx.deps.tool_set, ctx.mode_id, "mcp_features") and
                !permissions.rulesDenyAllTargetsForTool(ctx.permission_rules, "mcp_features"),
        )
    else
        null;
    defer if (mcp_view) |*view| view.deinit(alloc);
    var permission_state = ctx.session.snapshotPermissionState(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HostAuthorityUnavailable,
    };
    defer permission_state.deinit(alloc);
    return subagent_tool_host.captureHostAuthorityWithMcpView(
        alloc,
        .{
            .tool_set = ctx.deps.tool_set,
            .mode = .{
                .active = .{
                    .registry = ctx.cfg.mode_registry,
                    .id = ctx.mode_id,
                },
            },
        },
        owned_integrations,
        ctx.permission_rules,
        &.{},
        permission_state,
        if (mcp_view) |*view| view else null,
    );
}

fn onBackgroundUrlReady(raw_ctx: *anyopaque, task_id: u64, url: []const u8) void {
    const ctx: *AskContext = @ptrCast(@alignCast(raw_ctx));
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[notice] task #{d} server ready at {s}\n", .{ task_id, url }) catch return;
    ctx.writeStderr(line) catch {};
}

fn parseOptionsWithStdin(alloc: Allocator, args: []const [:0]const u8, stdin: StdinSource) !AskOptions {
    var opts: AskOptions = .{ .prompt = &.{} };
    errdefer opts.deinit(alloc);

    var prompt_parts: std.ArrayList([]const u8) = .empty;
    defer prompt_parts.deinit(alloc);

    var options_ended = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (options_ended) {
            try prompt_parts.append(alloc, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            options_ended = true;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            if (opts.permission_override != null) return error.InvalidAskArgs;
            opts.permission_override = .auto;
        } else if (std.mem.eql(u8, arg, "--yolo")) {
            if (opts.permission_override != null) return error.InvalidAskArgs;
            opts.permission_override = .yolo;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "--resume-id")) {
            if (opts.resume_target != null) return error.InvalidAskArgs;
            const exact_id = std.mem.eql(u8, arg, "--resume-id");
            i += 1;
            if (i >= args.len) return error.InvalidAskArgs;
            const target = std.mem.trim(u8, args[i], " \t\r\n");
            if (target.len == 0) return error.InvalidAskArgs;
            opts.resume_target = if (!exact_id and std.mem.eql(u8, target, "last"))
                .last
            else
                .{ .id = target };
        } else if (std.mem.eql(u8, arg, "--image")) {
            i += 1;
            if (i >= args.len) return error.MissingPrompt;
            try opts.image_paths.append(alloc, try alloc.dupe(u8, args[i]));
        } else if (std.mem.eql(u8, arg, "--system")) {
            i += 1;
            if (i >= args.len) return error.MissingPrompt;
            if (opts.system_prompt_override) |old| alloc.free(old);
            opts.system_prompt_override = try alloc.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json_output = true;
        } else if (std.mem.eql(u8, arg, "--prompt-permissions")) {
            opts.prompt_permissions = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return error.MissingPrompt;
            opts.timeout_ms = parseTimeoutMs(args[i]);
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-save")) {
            opts.no_save = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, arg, "--continue-recovery")) {
            if (opts.continue_recovery) return error.InvalidAskArgs;
            opts.continue_recovery = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            return error.InvalidAskArgs;
        } else {
            try prompt_parts.append(alloc, arg);
        }
    }

    if (opts.continue_recovery) {
        if (opts.resume_target == null or opts.no_save or
            prompt_parts.items.len != 0 or opts.image_paths.items.len != 0)
        {
            return error.InvalidAskArgs;
        }
        opts.prompt = try alloc.dupe(u8, "");
    } else if (prompt_parts.items.len > 0) {
        opts.prompt = try joinPromptSlices(alloc, prompt_parts.items);
    } else {
        opts.prompt = try readPromptFromStdinSource(alloc, stdin);
    }
    if (!text_utils.isModelSafeText(opts.prompt)) return error.InvalidPromptText;
    if (opts.no_save and opts.resume_target != null) return error.NoSaveResumeConflict;

    return opts;
}

fn emitHeadlessYoloWarning(alloc: Allocator, options: RunOptions) !void {
    if (options.color_enabled and options.deps.stderr_is_tty(options.deps.stderr_ctx)) {
        try options.deps.write_stderr(
            options.deps.stderr_ctx,
            "\x1b[38;5;252m" ++ permissions.yolo_warning_text ++ "\x1b[0m\n",
        );
    } else {
        try options.deps.write_stderr(options.deps.stderr_ctx, permissions.yolo_warning_text ++ "\n");
    }

    var attempt = options.deps.persist_yolo_acknowledgment(alloc);
    defer attempt.deinit(alloc);
    switch (attempt) {
        .outcome => {},
        .failure => |failure| {
            var message: std.Io.Writer.Allocating = .init(alloc);
            defer message.deinit();
            try message.writer.print(
                "fx ask: failed to save YOLO acknowledgment: {s}\n",
                .{@errorName(failure.err)},
            );
            try options.deps.write_stderr(options.deps.stderr_ctx, message.written());
        },
    }
}

fn persistYoloAcknowledgmentDefault(alloc: Allocator) config_runtime.CommitAttempt {
    return config_runtime.attemptUserPreferences(
        alloc,
        .{ .yolo_acknowledged = true },
    );
}

fn hasJsonFlag(args: []const [:0]const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn parseTimeoutMs(raw: []const u8) ?usize {
    const seconds = std.fmt.parseInt(usize, raw, 10) catch return null;
    return std.math.mul(usize, seconds, std.time.ms_per_s) catch null;
}

fn joinPromptSlices(alloc: Allocator, args: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (args, 0..) |arg, idx| {
        if (idx > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    return try out.toOwnedSlice();
}

fn readPromptFromStdinSource(alloc: Allocator, stdin: StdinSource) ![]u8 {
    return readPromptFromStdinSourceWithLimit(alloc, stdin, stdin_prompt_resource_byte_limit);
}

fn readPromptFromStdinSourceWithLimit(
    alloc: Allocator,
    stdin: StdinSource,
    resource_byte_limit: usize,
) ![]u8 {
    const input = switch (stdin) {
        .real => blk: {
            if (try std.Io.File.stdin().isTty(io_mod.getIo())) return error.MissingPrompt;
            break :blk try readPromptFromStdin(alloc, resource_byte_limit);
        },
        .tty => return error.MissingPrompt,
        .bytes => |bytes| blk: {
            if (bytes.len > resource_byte_limit) return error.PromptResourceLimitExceeded;
            break :blk try alloc.dupe(u8, bytes);
        },
        .read_error => return error.PromptInputReadFailed,
    };
    errdefer alloc.free(input);

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.MissingPrompt;
    if (trimmed.len == input.len) return input;

    const owned = try alloc.dupe(u8, trimmed);
    alloc.free(input);
    return owned;
}

fn readPromptFromStdin(alloc: Allocator, resource_byte_limit: usize) ![]u8 {
    const zio = io_mod.getIo();
    var read_buf: [8192]u8 = undefined;
    var r = std.Io.File.stdin().reader(zio, &read_buf);
    return readPromptFromReader(alloc, &r.interface, resource_byte_limit);
}

fn readPromptFromReader(
    alloc: Allocator,
    reader: *std.Io.Reader,
    resource_byte_limit: usize,
) ![]u8 {
    const detection_limit = std.math.add(usize, resource_byte_limit, 1) catch
        return error.PromptResourceLimitExceeded;
    const input = reader.allocRemaining(alloc, .limited(detection_limit)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.PromptResourceLimitExceeded,
        else => return error.PromptInputReadFailed,
    };
    if (input.len > resource_byte_limit) {
        alloc.free(input);
        return error.PromptResourceLimitExceeded;
    }
    return input;
}

fn renderFinalJsonResult(alloc: Allocator, result: PromptRunResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"output\":");
    try std.json.Stringify.value(result.assistant_output, .{}, &out.writer);
    try out.writer.print(",\"exit_code\":{d}", .{result.exit_code});
    try out.writer.writeAll(",\"model\":");
    try std.json.Stringify.value(result.model, .{}, &out.writer);
    try out.writer.writeAll(",\"session_id\":");
    try std.json.Stringify.value(result.session_id, .{}, &out.writer);
    try out.writer.print(",\"steps\":{d}", .{result.step_count});
    try out.writer.writeAll(",\"tool_calls\":[");
    for (result.tool_calls, 0..) |tc, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(tc.name, .{}, &out.writer);
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(tc.status, .{}, &out.writer);
        if (tc.command_result_json) |json| {
            try out.writer.writeAll(",\"command_result\":");
            try out.writer.writeAll(json);
        }
        if (tc.ask_question_text) |text| {
            try out.writer.writeAll(",\"question\":");
            try std.json.Stringify.value(text, .{}, &out.writer);
        }
        if (tc.web_search_completion) |completion| {
            try out.writer.print(",\"web_search\":{{\"searches\":{d},\"duration_ms\":{d}}}", .{ completion.searches, completion.duration_ms });
        }
        if (tc.web_fetch_completion) |completion| {
            try out.writer.writeAll(",\"web_fetch\":{\"url\":");
            try std.json.Stringify.value(completion.url(), .{}, &out.writer);
            try out.writer.print(",\"bytes\":{d},\"status\":{d},\"duration_ms\":{d},\"cache_hit\":{s},\"artifact\":\"{s}\"}}", .{
                completion.bytes,
                completion.status,
                completion.duration_ms,
                if (completion.cache_hit) "true" else "false",
                @tagName(completion.artifact_state),
            });
        }
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]");
    if (result.error_code) |error_code| {
        try out.writer.writeAll(",\"error\":");
        try std.json.Stringify.value(error_code, .{}, &out.writer);
    }
    if (result.auth_failure) |failure| {
        try out.writer.writeAll(",\"auth_failure\":");
        try failure.writeJson(&out.writer);
    }
    if (result.recovery) |recovery| {
        var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
        try out.writer.writeAll(",\"recovery\":{\"state\":");
        try std.json.Stringify.value(
            if (recovery.kind == .terminal_provider_error) "paused" else if (recovery.isRecovered()) "recovered" else "active",
            .{},
            &out.writer,
        );
        try out.writer.writeAll(",\"kind\":");
        try std.json.Stringify.value(@tagName(recovery.kind), .{}, &out.writer);
        if (recovery.cause) |cause| {
            try out.writer.writeAll(",\"cause\":");
            try std.json.Stringify.value(@tagName(cause), .{}, &out.writer);
        }
        if (recovery.action) |action| {
            try out.writer.writeAll(",\"action\":");
            try std.json.Stringify.value(@tagName(action), .{}, &out.writer);
        }
        if (recovery.required_action != .none) {
            try out.writer.writeAll(",\"required_action\":");
            try std.json.Stringify.value(@tagName(recovery.required_action), .{}, &out.writer);
        }
        try out.writer.print(",\"attempt\":{d},\"attempt_limit\":{d},\"delay_seconds\":{d},\"durable\":{s},\"message\":", .{
            recovery.reportedAttempt(),
            recovery.attempt_limit,
            recovery.delay_seconds,
            if (result.recovery_durable) "true" else "false",
        });
        try std.json.Stringify.value(recovery.label(&label_buf), .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("}\n");
    return try out.toOwnedSlice();
}

fn renderErrorJsonResult(alloc: Allocator, err_name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"output\":\"\",\"exit_code\":1,\"model\":\"\",\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"error\":");
    try std.json.Stringify.value(err_name, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return try out.toOwnedSlice();
}

fn toCoreReasoningEffort(effort: types.ReasoningEffort) types.ReasoningEffort {
    return effort;
}

fn toCorePermissionMode(mode: anytype) PermissionMode {
    return switch (mode) {
        .ask => .ask,
        .auto => .auto,
        .yolo => .yolo,
    };
}

fn takeCorePermissionRules(_: Allocator, startup: *app_lifecycle.StartupState) !types.PermissionRuleSet {
    return startup.takePermissionRules();
}

fn loadStartupStateDefault(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    return app_lifecycle.loadStartupState(
        alloc,
        transport,
        secret_store,
        default_model,
        default_agent_step_limit,
    );
}

fn initializeSessionStoresDefault(ctx: *AskContext) !void {
    try ctx.initializeSessionStores();
}

fn testInitializeSessionStoresOneOffDenied(_: *AskContext) !void {
    return error.OneOffSessionNotResumable;
}

fn processQueuedPromptDefault(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, config: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    return agent_runtime.processQueuedPrompt(deps, semantic_presentation, lifecycle, config, job);
}

fn discardPristineSessionDefault(
    _: ?*anyopaque,
    ctx: *AskContext,
    loaded: *session_store.LoadedWritableSession,
) session_store.PristineDiscardDisposition {
    return ctx.store.?.discardPristineStartedSession(ctx.alloc, loaded);
}

fn promptRealPermissionApproval(
    _: ?*anyopaque,
    stderr_ctx: ?*anyopaque,
    write_stderr: WriteFn,
    label: []const u8,
    attention_ctx: ?*anyopaque,
    notify_attention: NotifyAttentionFn,
) !PermissionApprovalPromptResult {
    const zio = io_mod.getIo();
    const stdin_tty = std.Io.File.stdin().isTty(zio) catch false;
    if (!stdin_tty) return .unavailable;

    try write_stderr(stderr_ctx, "fx wants to run:\n  ");
    try write_stderr(stderr_ctx, label);
    try write_stderr(stderr_ctx, "\n\nApprove? [y/N] ");
    notify_attention(attention_ctx);

    var read_buf: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(zio, &read_buf);
    const line = reader.interface.takeDelimiter('\n') catch return .deny;
    const answer = std.mem.trim(u8, line orelse "", " \t\r\n");
    if (answer.len == 1 and (answer[0] == 'y' or answer[0] == 'Y')) return .approve;
    return .deny;
}

fn realStderrIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stderr().isTty(io_mod.getIo()) catch false;
}

fn realStdinIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stdin().isTty(io_mod.getIo()) catch false;
}

fn realStdoutIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stdout().isTty(io_mod.getIo()) catch false;
}

fn writeRealStdout(_: ?*anyopaque, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeRealStderr(_: ?*anyopaque, text: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

const TestCapture = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestCapture, alloc: Allocator) void {
        self.bytes.deinit(alloc);
    }

    fn write(raw_ctx: ?*anyopaque, text: []const u8) !void {
        const self: *TestCapture = @ptrCast(@alignCast(raw_ctx.?));
        try self.bytes.appendSlice(std.testing.allocator, text);
    }
};

const TestPermissionPrompt = struct {
    result: PermissionApprovalPromptResult = .unavailable,
    calls: usize = 0,
    label: ?[]const u8 = null,

    fn prompt(
        raw_ctx: ?*anyopaque,
        stderr_ctx: ?*anyopaque,
        write_stderr: WriteFn,
        label: []const u8,
        attention_ctx: ?*anyopaque,
        notify_attention: NotifyAttentionFn,
    ) !PermissionApprovalPromptResult {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.calls += 1;
        self.label = label;
        if (self.result != .unavailable) {
            try write_stderr(stderr_ctx, "fx wants to run:\n  ");
            try write_stderr(stderr_ctx, label);
            try write_stderr(stderr_ctx, "\n\nApprove? [y/N] ");
            notify_attention(attention_ctx);
        }
        return self.result;
    }
};

const TestTty = struct {
    fn yes(_: ?*anyopaque) bool {
        return true;
    }

    fn no(_: ?*anyopaque) bool {
        return false;
    }
};

const TestYoloPersistence = struct {
    var calls: usize = 0;
    var warning_capture: ?*const TestCapture = null;
    var observed_warning_before_persist: bool = false;

    fn reset() void {
        calls = 0;
        warning_capture = null;
        observed_warning_before_persist = false;
    }

    fn persist(_: Allocator) config_runtime.CommitAttempt {
        calls += 1;
        if (warning_capture) |capture| {
            observed_warning_before_persist =
                std.mem.find(u8, capture.bytes.items, permissions.yolo_warning_text) != null;
        }
        return .{ .outcome = .unchanged };
    }
};

const TestFailingStderr = struct {
    fn write(_: ?*anyopaque, _: []const u8) !void {
        return error.TestStderrWriteFailed;
    }
};

const AskAttentionCapture = struct {
    calls: usize = 0,
    turn_id: u64 = 0,
    kind: ?hooks.AttentionKind = null,

    fn run(raw: *anyopaque, input: hooks.AttentionRequiredInput) hooks.HandlerError!void {
        const self: *AskAttentionCapture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.turn_id = input.invocation.turn_id orelse 0;
        self.kind = input.kind;
    }
};

const test_modes = [_]mode_registry.ModeSpec{
    .{
        .id = "inspect",
        .name = "Inspect",
        .permission_mode = .ask,
    },
};

const test_mode_registry = mode_registry.Registry{
    .default_mode_id = "inspect",
    .modes = test_modes[0..],
};

fn testModelPromptOverlay(model: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, model, "model")) "test model overlay" else null;
}

fn testConfig() Config {
    return .{
        .command_usage = "ask [--auto|--yolo] [--image PATH] [--json] [--quiet] [--prompt-permissions] [--no-save] [--no-color] [--resume <last|id>|--resume-id <id>] [--] <prompt>",
        .default_model = "model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 1,
        .gateway_chat_url = "https://example.invalid/chat",
        .gateway_models_path = "/models",
        .gateway_provider = test_builtin_gateway.provider,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "system",
            .model_prompt_overlay_fn = testModelPromptOverlay,
        },
        .skill_root_policy = .{ .managed_root_source = .global_fx },
        .ignored_list_entries = &.{},
        .max_list_entries = 10,
        .max_read_file_bytes = 1024,
        .max_read_file_lines = 100,
        .max_read_file_line_len = 200,
        .max_command_output_bytes = 4096,
        .max_tool_result_bytes = 4096,
        .max_history_turns = 2,
        .mode_registry = test_mode_registry,
        .load_mcp_runtime = testNoMcpRuntime,
    };
}

fn testMissingKeyStartup(alloc: Allocator, _: oauth_transport.Provider, _: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/fx-test");
    state.selected_model = try alloc.dupe(u8, default_model);
    state.context_enabled = false;
    return state;
}

fn testPresentKeyStartup(alloc: Allocator, _: oauth_transport.Provider, _: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/fx-test");
    state.credential = .{
        .token = try alloc.dupe(u8, "key"),
        .source = .ai_gateway_api_key,
    };
    state.selected_model = try alloc.dupe(u8, default_model);
    state.context_enabled = true;
    return state;
}

fn testMissingKeyAcknowledgedStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize) !app_lifecycle.StartupState {
    var state = try testMissingKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit);
    state.yolo_acknowledged = true;
    return state;
}

fn testMissingKeyDiagnosticStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize) !app_lifecycle.StartupState {
    var state = try testMissingKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit);
    errdefer state.deinit(alloc);
    state.config_diagnostics = try alloc.alloc(config_runtime.ConfigDiagnostic, 1);
    state.config_diagnostics[0] = .{
        .layer = .user,
        .cause = .malformed_settings,
    };
    return state;
}

fn testPresentKeySavedStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize) !app_lifecycle.StartupState {
    var state = try testPresentKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit);
    errdefer state.deinit(alloc);
    state.configured_model = try alloc.dupe(u8, default_model);
    return state;
}

fn testPushAssistantText(deps: *const agent_runtime.AgentRuntimeDeps, text: []const u8) !void {
    try deps.push_text(deps.ctx, .{ .assistant_source = text });
    try deps.push_text(deps.ctx, .{ .assistant_rendered = text });
}

fn testProcessQueuedPrompt(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expectEqual(hooks.ScopeKind.ask, lifecycle.scope.kind);
    try std.testing.expectEqualStrings("/tmp/fx-test", lifecycle.scope.workspace_root);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptRecoveryLifecycle(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expectEqual(hooks.ScopeKind.ask, lifecycle.scope.kind);
    try deps.push_route_recovery_status(deps.ctx, .{
        .kind = .auto_retry,
        .failed_attempt = 1,
        .attempt_limit = 10,
        .cause = .network_interrupted,
        .action = .waiting_for_connectivity,
    });
    try deps.push_event(deps.ctx, .clear_route_recovery_status);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptPartialThenReadFailed(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try testPushAssistantText(deps, "partial ");
    try testPushAssistantText(deps, "résumé");
    return error.ReadFailed;
}

fn testProcessQueuedPromptRepeatsSkillDiagnostic(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    const diagnostics = [_]skill_runtime.SkillDiagnostic{.{
        .path = "/tmp/bad-skill/SKILL.md",
        .source = .workspace_shared,
        .scope = .candidate,
        .cause = .{ .invalid_metadata = .missing_name },
    }};
    var notice: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer notice.deinit();
    try skill_runtime.writeDiagnosticSummary(std.testing.allocator, &notice.writer, &diagnostics);
    try deps.push_context_notice.?(deps.ctx, notice.written());
    try testProcessQueuedPrompt(deps, semantic_presentation, lifecycle, cfg, job);
}

fn testProcessQueuedPromptChecksTimeout(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    const ctx: *AskContext = @ptrCast(@alignCast(deps.ctx));
    try std.testing.expectEqual(@as(?usize, std.time.ms_per_s), ctx.command_timeout_ms);
    const tool_ctx = ctx.toolContext();
    try std.testing.expectEqual(@as(?usize, std.time.ms_per_s), tool_ctx.command_timeout_ms);
    try std.testing.expect(!tool_ctx.web_search_runtime_ready);
    try std.testing.expect(tool_ctx.web_search_backend != null);
    try std.testing.expect(tool_ctx.web_fetch_runtime.? == &ctx.web_fetch_runtime);
    try std.testing.expect(tool_ctx.web_fetch_progress_ctx != null);
    try std.testing.expect(tool_ctx.on_web_fetch_progress != null);
    try std.testing.expectEqualStrings(ctx.model, ctx.web_search_runtime.worker_model);
    try std.testing.expectEqual(ctx.cfg.gateway_retry_count, ctx.web_search_runtime.gateway_retry_count);
    try std.testing.expectEqualStrings(ctx.cfg.gateway_chat_url, ctx.web_search_runtime.gateway_chat_url);
    try std.testing.expect(ctx.web_search_runtime.provider.?.execute_fn == ctx.cfg.gateway_provider.web_search.execute_fn);
    try std.testing.expectEqualStrings("/models", tool_ctx.gateway_models_path);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptChecksExecOnlyTerminal(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expect(cfg.session_child_capability == null);
    const ctx: *AskContext = @ptrCast(@alignCast(deps.ctx));
    try std.testing.expectEqualStrings("inspect", ctx.mode_id);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "\"name\":\"terminal\"") != null);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "\"name\":\"run_command\"") == null);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "\"name\":\"web_search\"") == null);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "gateway.perplexity_search") != null);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "Run one captured command and return its result.") != null);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "Use start for commands") == null);
    try std.testing.expectEqualStrings(builtin_tools.web_search.description, cfg.custom_tool_guidance);
    try std.testing.expectEqualStrings("test model overlay", cfg.model_prompt_overlay.?);
    const runtime_terminal = deps.tool_registry.lookup("terminal") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(std.mem.find(u8, runtime_terminal.description, "Use start") != null);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptChecksFullTerminal(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expect(cfg.session_child_capability != null);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "Use start for commands") != null);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptChecksInjectedToolSet(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, cfg.gateway_tools_json, "\"name\":\"run_command\"") == null);
    try std.testing.expectEqualStrings("", cfg.custom_tool_guidance);

    const ctx: *AskContext = @ptrCast(@alignCast(deps.ctx));
    try std.testing.expect(ctx.toolRegistry().lookup("read_file") != null);
    try std.testing.expect(ctx.toolRegistry().lookup("run_command") == null);
    try testPushAssistantText(deps, "assistant text");
}

fn testProcessQueuedPromptHttp413(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try deps.push_http_error(
        deps.ctx,
        .payload_too_large,
        "provider payload rejected\n\nprompt_too_long=true\nProvider rejected the prompt as too large. Latest local tool evidence remains in session history/result handles; no local tool actions were replayed.",
        null,
    );
}

fn testProcessQueuedPromptRestrictedProvider(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, _: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try deps.push_http_error(
        deps.ctx,
        .forbidden,
        "{\"error\":{\"message\":\"Your team has restricted access to this provider. Contact the owner of the account for more details. Providers considered: wafer\",\"type\":\"no_providers_available\",\"param\":{\"name\":\"RestrictedProvidersError\",\"message\":\"Your team has restricted access to this provider. Contact the owner of the account for more details. Providers considered: wafer\"}},\"providerMetadata\":{\"gateway\":{\"routing\":{}}}}",
        null,
    );
}

fn testProcessQueuedPromptUnauthorized(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    try std.testing.expect(semantic_presentation == null);
    try deps.push_http_error(
        deps.ctx,
        .unauthorized,
        "provider rejected secret-key body",
        job.credential_source,
    );
}

fn testProcessQueuedPromptUnauthorizedThenHistory(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    try testProcessQueuedPromptUnauthorized(deps, semantic_presentation, lifecycle, cfg, job);
    const ctx: *AskContext = @ptrCast(@alignCast(deps.ctx));
    const turn = try session_runtime.makeAssistantTurn(ctx.alloc, job.prompt, "retained response");
    defer types.freeHistoryTurn(ctx.alloc, turn);
    try deps.propagate_history_turn(deps.ctx, turn);
}

fn testProcessQueuedPromptToolThenUnauthorized(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    try deps.push_tool_lifecycle(deps.ctx, .{
        .authoritative_started = .{
            .id = .{ .turn_id = job.turn_id, .call_id = "read_1" },
            .reconciles_provisional_call_id = null,
            .tool_name = "read_file",
            .activity_kind = .read,
        },
    });
    try testProcessQueuedPromptUnauthorized(deps, semantic_presentation, lifecycle, cfg, job);
}

fn testProcessQueuedPromptUnauthorizedThenError(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    try testProcessQueuedPromptUnauthorized(deps, semantic_presentation, lifecycle, cfg, job);
    return error.InjectedPromptFailure;
}

const DiscardProbe = struct {
    disposition: session_store.PristineDiscardDisposition,
    calls: usize = 0,
    borrowers_detached: bool = false,

    fn run(
        raw: ?*anyopaque,
        ctx: *AskContext,
        loaded: *session_store.LoadedWritableSession,
    ) session_store.PristineDiscardDisposition {
        const self: *DiscardProbe = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.borrowers_detached = ctx.writable == null and
            ctx.subagent_host == null and
            ctx.background.persisted_store == null and
            ctx.background.borrowed_session_capability == null and
            ctx.background.source_session_id == null and
            ctx.session.webFetchArtifactStore() == null;
        loaded.deinit(ctx.alloc);
        return self.disposition;
    }
};

var test_initialize_session_store_calls: usize = 0;
var test_image_preflight_startup_calls: usize = 0;
var test_image_preflight_process_calls: usize = 0;

fn testCountImagePreflightStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize) !app_lifecycle.StartupState {
    test_image_preflight_startup_calls += 1;
    return testPresentKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit);
}

fn testCountImagePreflightProcess(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, lifecycle: agent_runtime.LifecycleContext, cfg: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
    test_image_preflight_process_calls += 1;
    try testProcessQueuedPrompt(deps, semantic_presentation, lifecycle, cfg, job);
}

fn testProcessQueuedPromptChecksImageAuthority(
    deps: *const agent_runtime.AgentRuntimeDeps,
    semantic_presentation: ?agent_runtime.SemanticPresentationSink,
    lifecycle: agent_runtime.LifecycleContext,
    cfg: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
) !void {
    try std.testing.expectEqual(@as(usize, 1), job.images.len);
    try std.testing.expectEqual(@as(usize, 1), job.images[0].id);
    try std.testing.expectEqual(@as(usize, 1), job.authorized_image_catalog.len);
    try std.testing.expectEqual(@as(usize, 1), job.authorized_image_catalog[0].id);
    try std.testing.expectEqualStrings(job.images[0].path, job.authorized_image_catalog[0].path);
    try testProcessQueuedPrompt(deps, semantic_presentation, lifecycle, cfg, job);
}

var test_no_save_snapshot_path: ?[]u8 = null;

fn testProcessQueuedPromptCapturesNoSaveSnapshot(
    deps: *const agent_runtime.AgentRuntimeDeps,
    semantic_presentation: ?agent_runtime.SemanticPresentationSink,
    lifecycle: agent_runtime.LifecycleContext,
    cfg: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
) !void {
    try std.testing.expectEqual(@as(usize, 1), job.images.len);
    test_no_save_snapshot_path = try std.testing.allocator.dupe(
        u8,
        job.images[0].snapshot_path.?,
    );
    try testProcessQueuedPromptChecksImageAuthority(
        deps,
        semantic_presentation,
        lifecycle,
        cfg,
        job,
    );
}

fn testCountSessionStores(_: *AskContext) !void {
    test_initialize_session_store_calls += 1;
}

fn testSkipSessionStores(_: *AskContext) !void {}

fn testFailSessionStores(_: *AskContext) !void {
    return error.InvalidSessionFormat;
}

fn testLoadNoSkills(
    _: Allocator,
    _: []const u8,
    _: skill_contract.RootPolicy,
) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills {
    return .{};
}

fn testLoadTruncatedSkillsWithDiagnostic(
    alloc: Allocator,
    _: []const u8,
    _: skill_contract.RootPolicy,
) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills {
    const skills = try alloc.alloc(skill_runtime.Skill, 1);
    errdefer alloc.free(skills);
    const name = try alloc.dupe(u8, "visible");
    errdefer alloc.free(name);
    const description = try alloc.dupe(u8, "visible skill");
    errdefer alloc.free(description);
    const path = try alloc.dupe(u8, "/tmp/visible/SKILL.md");
    errdefer alloc.free(path);
    skills[0] = .{
        .name = name,
        .description = description,
        .path = path,
        .source = .workspace_shared,
    };

    const diagnostics = try alloc.alloc(skill_runtime.SkillDiagnostic, 1);
    errdefer alloc.free(diagnostics);
    const diagnostic_path = try alloc.dupe(u8, "/tmp/bad-skill/SKILL.md");
    errdefer alloc.free(diagnostic_path);
    diagnostics[0] = .{
        .path = diagnostic_path,
        .source = .workspace_shared,
        .scope = .candidate,
        .cause = .{ .invalid_metadata = .missing_name },
    };

    return .{
        .skills = skills,
        .diagnostics = diagnostics,
    };
}

fn testPresentKeyTruncatedSkillCatalogStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize) !app_lifecycle.StartupState {
    var state = try testPresentKeyNoContextStartup(alloc, transport, secret_store, default_model, default_agent_step_limit);
    state.context_limits.skill_catalog_bytes = .{
        .value = .{ .bytes = 0 },
        .source = .command_line,
    };
    return state;
}

fn testNoProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn testNoStaticContext(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

fn testNoTransientContext(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

const test_no_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.no_context",
    .gather_project_context_fn = testNoProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = testNoStaticContext,
    .append_transient_fn = testNoTransientContext,
} };

var test_gather_project_context_calls: usize = 0;

fn testCountProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    test_gather_project_context_calls += 1;
    return .{};
}

const test_count_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.count_context",
    .gather_project_context_fn = testCountProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = testNoStaticContext,
    .append_transient_fn = testNoTransientContext,
} };

const test_registry_static_context = "<project-files>\nexact registry bytes\n</project-files>";
const test_registry_transient_context = "transient registry bytes";

const TestContextRegistryFixture = struct {
    const delivered_source = "/workspace/AGENTS.md";
    const evaluated_endpoint = "/workspace";

    var gather_calls: usize = 0;
    var process_calls: usize = 0;
    var gather_error: ?context_contract.ProviderError = null;
    var expected_target_paths: []const []const u8 = &.{};
    var targets_match: bool = false;
    var expected_static_context: ?[]const u8 = null;
    var expected_gather_calls: usize = 0;
    var transient_permission_mode: ?PermissionMode = null;

    fn reset(expected_static: ?[]const u8, expected_calls: usize) void {
        gather_calls = 0;
        process_calls = 0;
        gather_error = null;
        expected_target_paths = &.{};
        targets_match = false;
        expected_static_context = expected_static;
        expected_gather_calls = expected_calls;
        transient_permission_mode = null;
    }

    fn gather(alloc: Allocator, input: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
        gather_calls += 1;
        targets_match = input.targets.len == expected_target_paths.len;
        if (targets_match) {
            for (input.targets, expected_target_paths) |target, expected_path| {
                if (target.kind != .file or !std.mem.eql(u8, target.path, expected_path)) {
                    targets_match = false;
                    break;
                }
            }
        }
        if (gather_error) |err| return err;
        var result: context_contract.ProviderContext = .{
            .content = try alloc.dupe(u8, test_registry_static_context),
        };
        errdefer result.deinit(alloc);
        result.delivered_sources = try dupeStrings(alloc, &.{delivered_source});
        result.evaluated_endpoints = try dupeStrings(alloc, &.{evaluated_endpoint});
        return result;
    }

    fn dupeStrings(alloc: Allocator, values: []const []const u8) Allocator.Error![][]u8 {
        const owned = try alloc.alloc([]u8, values.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |value| alloc.free(value);
            alloc.free(owned);
        }
        for (values, 0..) |value, index| {
            owned[index] = try alloc.dupe(u8, value);
            initialized += 1;
        }
        return owned;
    }

    fn appendStatic(input: context_contract.StaticContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        if (input.project_context.len > 0) {
            try messages.append(alloc, .{ .role = .system, .content = input.project_context });
        }
    }

    fn appendTransient(input: context_contract.TransientContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        transient_permission_mode = input.permission_mode;
        try messages.append(alloc, .{ .role = .system, .content = test_registry_transient_context });
    }

    fn process(deps: *const agent_runtime.AgentRuntimeDeps, semantic_presentation: ?agent_runtime.SemanticPresentationSink, _: agent_runtime.LifecycleContext, _: agent_runtime.Config, job: worker_runtime.QueuedPrompt) !void {
        process_calls += 1;
        try std.testing.expect(semantic_presentation == null);
        try std.testing.expectEqual(expected_gather_calls, gather_calls);
        if (expected_gather_calls > 0) try std.testing.expect(targets_match);
        const ctx: *AskContext = @ptrCast(@alignCast(deps.ctx));
        if (expected_static_context != null) {
            const contribution = ctx.context_snapshot.contribution orelse return error.TestExpectedEqual;
            try std.testing.expectEqualStrings("test.cli_context", contribution.provider_id);
        } else {
            try std.testing.expect(ctx.context_snapshot.contribution == null);
        }
        const tool_context = ctx.toolContext();
        try std.testing.expectEqualStrings("test.cli_context", tool_context.context_registry.defaultProvider().id);
        if (expected_static_context != null) {
            try std.testing.expectEqual(@as(usize, 1), job.context_snapshot.delivered_sources.len);
            try std.testing.expectEqualStrings(delivered_source, job.context_snapshot.delivered_sources[0]);
            try std.testing.expectEqual(@as(usize, 1), job.context_snapshot.evaluated_endpoints.len);
            try std.testing.expectEqualStrings(evaluated_endpoint, job.context_snapshot.evaluated_endpoints[0]);
        } else {
            try std.testing.expectEqual(@as(usize, 0), job.context_snapshot.delivered_sources.len);
            try std.testing.expectEqual(@as(usize, 0), job.context_snapshot.evaluated_endpoints.len);
        }

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var messages: std.ArrayList(ChatMessage) = .empty;
        defer messages.deinit(arena);

        const append_static = deps.append_static_context orelse return error.TestExpectedEqual;
        try append_static(deps.ctx, arena, &messages);
        try deps.append_runtime_context(deps.ctx, arena, &messages);
        try std.testing.expectEqual(
            ctx.permission_mode,
            transient_permission_mode orelse return error.TestExpectedEqual,
        );

        if (expected_static_context) |expected_static| {
            try std.testing.expectEqual(@as(usize, 3), messages.items.len);
            try std.testing.expectEqualStrings(expected_static, messages.items[0].content.?);
            try std.testing.expect(std.mem.find(u8, messages.items[1].content.?, "<mcp_servers>") != null);
            try std.testing.expectEqualStrings(test_registry_transient_context, messages.items[2].content.?);
        } else {
            try std.testing.expectEqual(@as(usize, 2), messages.items.len);
            try std.testing.expect(std.mem.find(u8, messages.items[0].content.?, "<mcp_servers>") != null);
            try std.testing.expectEqualStrings(test_registry_transient_context, messages.items[1].content.?);
        }

        try testPushAssistantText(deps, "assistant text");
    }
};

const test_cli_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.cli_context",
    .gather_project_context_fn = TestContextRegistryFixture.gather,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = TestContextRegistryFixture.appendStatic,
    .append_transient_fn = TestContextRegistryFixture.appendTransient,
} };

fn testPresentKeyNoContextStartup(alloc: Allocator, transport: oauth_transport.Provider, secret_store: host.SecretStore, default_model: []const u8, default_agent_step_limit: usize) !app_lifecycle.StartupState {
    var state = try testPresentKeyStartup(alloc, transport, secret_store, default_model, default_agent_step_limit);
    state.context_enabled = false;
    return state;
}

fn testNoMcpRuntime(_: Allocator, _: mcp_elicitation.Capabilities) !?*mcp_runtime.McpRuntime {
    return null;
}

fn testPromptRunDeps(stdout_capture: *TestCapture, stderr_capture: *TestCapture, load_startup_state: LoadStartupStateFn) RunDeps {
    return .{
        .stdout_ctx = stdout_capture,
        .stderr_ctx = stderr_capture,
        .write_stdout = TestCapture.write,
        .write_stderr = TestCapture.write,
        .load_startup_state = load_startup_state,
        .initialize_session_stores = testSkipSessionStores,
        .load_skills = testLoadNoSkills,
        .context_registry = test_no_context_registry,
        .tool_set = builtin_tools.advertisement_set,
        .load_mcp_runtime = testNoMcpRuntime,
        .process_queued_prompt = testProcessQueuedPrompt,
    };
}

fn testPromptRunDepsWithProcess(stdout_capture: *TestCapture, stderr_capture: *TestCapture, process: ProcessQueuedPromptFn) RunDeps {
    var deps = testPromptRunDeps(stdout_capture, stderr_capture, testPresentKeyStartup);
    deps.process_queued_prompt = process;
    return deps;
}

fn testPermissionRuleSet(alloc: Allocator, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !types.PermissionRuleSet {
    var rules = types.PermissionRuleSet{
        .rules = try alloc.alloc(types.PermissionRule, 1),
    };
    errdefer alloc.free(rules.rules);

    const owned_permission = try alloc.dupe(u8, permission);
    errdefer alloc.free(owned_permission);

    const owned_pattern = try alloc.dupe(u8, pattern);
    rules.rules[0] = .{
        .permission = owned_permission,
        .pattern = owned_pattern,
        .action = action,
    };
    return rules;
}

fn testPermissionRuleSetPair(
    alloc: Allocator,
    permission: []const u8,
    first_pattern: []const u8,
    first_action: types.PermissionAction,
    second_pattern: []const u8,
    second_action: types.PermissionAction,
) !types.PermissionRuleSet {
    const entries = [_]struct {
        pattern: []const u8,
        action: types.PermissionAction,
    }{
        .{ .pattern = first_pattern, .action = first_action },
        .{ .pattern = second_pattern, .action = second_action },
    };
    var rules: types.PermissionRuleSet = .{
        .rules = try alloc.alloc(types.PermissionRule, entries.len),
    };
    errdefer alloc.free(rules.rules);
    var initialized: usize = 0;
    errdefer {
        for (rules.rules[0..initialized]) |rule| {
            alloc.free(rule.permission);
            alloc.free(rule.pattern);
        }
    }

    for (entries, 0..) |entry, index| {
        const owned_permission = try alloc.dupe(u8, permission);
        const owned_pattern = alloc.dupe(u8, entry.pattern) catch |err| {
            alloc.free(owned_permission);
            return err;
        };
        rules.rules[index] = .{
            .permission = owned_permission,
            .pattern = owned_pattern,
            .action = entry.action,
        };
        initialized += 1;
    }
    return rules;
}

test "CLI lifecycle action preserves dynamic MCP availability boundaries" {
    const Fixture = struct {
        calls: usize = 0,
        available: bool = false,

        fn hasTool(raw_ctx: *anyopaque, _: []const u8, _: tool_mcp_runtime.Access) bool {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            return self.available;
        }
    };
    const alloc = std.testing.allocator;
    const advertised = [_][]const u8{"mcp_lookup"};
    var fixture = Fixture{};

    const missing = dynamicMcpToolAvailable(builtin_tools.registry, "mcp_lookup", &advertised, @ptrCast(&fixture), Fixture.hasTool, .unrestricted);
    try std.testing.expect(!missing);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    const missing_label = try tool_presentation.formatPlainAction(alloc, .{
        .tool_registry = builtin_tools.registry,
        .call = .{ .id = "missing", .name = "mcp_lookup", .arguments_json = "{}" },
        .is_available_dynamic_mcp_tool = missing,
    });
    defer alloc.free(missing_label);
    try std.testing.expectEqualStrings("Working: mcp_lookup", missing_label);

    const builtin = dynamicMcpToolAvailable(builtin_tools.registry, "terminal", &.{"terminal"}, @ptrCast(&fixture), Fixture.hasTool, .unrestricted);
    try std.testing.expect(!builtin);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "CLI lifecycle dynamic MCP capability preserves its callback context" {
    var ctx: AskContext = undefined;
    var mcp = mcp_runtime.McpRuntime.init(std.testing.allocator);
    defer mcp.deinit();
    ctx.mcp = &mcp;

    const capability = lifecycleDynamicMcpAvailability(&ctx);

    try std.testing.expect(capability.context != null);
    try std.testing.expectEqual(
        @intFromPtr(&ctx),
        @intFromPtr(capability.context.?),
    );
    try std.testing.expect(capability.has_tool == mcpHasTool);
}

test "Ask MCP adapters revalidate scoped authority before catalog access" {
    const alloc = std.testing.allocator;
    const ViewFactory = struct {
        fn init(factory_alloc: Allocator, runtime_generation: u64) !mcp_access_policy.View {
            const owner_id = try factory_alloc.dupe(u8, "child");
            errdefer factory_alloc.free(owner_id);
            const parent_id = try factory_alloc.dupe(u8, "parent");
            errdefer factory_alloc.free(parent_id);
            const servers = try factory_alloc.alloc(mcp_access_policy.ServerIdentity, 1);
            errdefer factory_alloc.free(servers);
            servers[0] = .{
                .name = try factory_alloc.dupe(u8, "fixture"),
                .source = .profile,
                .scope = .profile,
                .connection_generation = 1,
                .catalog_generation = 1,
                .auth_generation = 0,
            };
            errdefer servers[0].deinit(factory_alloc);
            const tools = try factory_alloc.alloc(mcp_access_policy.ToolIdentity, 1);
            errdefer factory_alloc.free(tools);
            const tool_name = try factory_alloc.dupe(u8, "mcp_fixture_echo");
            errdefer factory_alloc.free(tool_name);
            const tool_server_name = try factory_alloc.dupe(u8, "fixture");
            errdefer factory_alloc.free(tool_server_name);
            tools[0] = .{
                .name = tool_name,
                .server_name = tool_server_name,
            };
            return .{
                .runtime_generation = runtime_generation,
                .owner_id = owner_id,
                .parent_id = parent_id,
                .features_visible = false,
                .servers = servers,
                .tools = tools,
            };
        }
    };
    const LiveProvider = struct {
        view: *const mcp_access_policy.View,
        calls: usize = 0,

        fn resolve(raw: *anyopaque, provider_alloc: Allocator) !tool_mcp_runtime.ResolvedLiveView {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            const view = try self.view.clone(provider_alloc);
            return .{
                .authority_generation = mcp_access_policy.authorityGeneration(view),
                .view = view,
            };
        }
    };

    var runtime = mcp_runtime.McpRuntime.init(alloc);
    defer runtime.deinit();
    var ctx: AskContext = undefined;
    ctx.mcp = &runtime;
    var captured = try ViewFactory.init(alloc, runtime.generation);
    defer captured.deinit(alloc);
    var live = try captured.clone(alloc);
    defer live.deinit(alloc);
    live.tools[0].deinit(alloc);
    alloc.free(live.tools);
    live.tools = try alloc.alloc(mcp_access_policy.ToolIdentity, 0);
    var provider = LiveProvider{ .view = &live };
    const access = tool_mcp_runtime.Access{ .scoped = .{
        .captured = &captured,
        .admission_authority_generation = mcp_access_policy.authorityGeneration(captured),
        .live = .{
            .context = @ptrCast(&provider),
            .resolve_fn = LiveProvider.resolve,
        },
    } };

    try std.testing.expect(!mcpHasTool(@ptrCast(&ctx), "mcp_fixture_echo", access));
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    provider.calls = 0;
    try std.testing.expectError(
        error.McpAuthorityChanged,
        mcpValidateTool(@ptrCast(&ctx), alloc, "mcp_fixture_echo", "{}", access),
    );
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    provider.calls = 0;
    try std.testing.expectError(
        error.McpAuthorityChanged,
        mcpToolSchemaJson(@ptrCast(&ctx), alloc, "mcp_fixture_echo", .{}, .{}, access),
    );
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
}

test "fx ask deps validate malformed registered calls" {
    const alloc = std.testing.allocator;
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();

    const deps = agentRuntimeDeps(&ctx);
    try deps.finalize_turn(deps.ctx, 8, .completed, null);
    try std.testing.expectEqual(@as(usize, 0), ctx.worker.worker_events.items.len);
    const validate = deps.validate_tool_call orelse return error.TestExpectedEqual;
    const result = try validate(deps.ctx, alloc, .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":1}",
    });
    defer alloc.free(result.failure);
    try std.testing.expectEqualStrings("web_fetch field \"url\" must be a string", result.failure);
}

test "CLI prompt projection configures web search then blocks native execution" {
    const alloc = std.testing.allocator;
    const web_search_contract = @import("../tooling/web_search_contract.zig");
    const ProviderState = struct {
        calls: usize = 0,
    };
    const FailingWebSearchProvider = struct {
        fn execute(
            raw_ctx: ?*anyopaque,
            _: Allocator,
            _: web_search_runtime.Inputs,
            _: web_search_contract.ProviderRequest,
            _: ?web_search_contract.ProgressFn,
            _: ?*anyopaque,
        ) anyerror!web_search_contract.ProviderResponse {
            const state: *ProviderState = @ptrCast(@alignCast(raw_ctx orelse return error.TestWebSearchProvider));
            state.calls += 1;
            return error.TestWebSearchProvider;
        }
    };
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();
    var provider_state = ProviderState{};
    var provider = ctx.web_search_runtime.provider orelse return error.TestExpectedEqual;
    provider.context = @ptrCast(&provider_state);
    provider.execute_fn = FailingWebSearchProvider.execute;
    ctx.web_search_runtime = web_search_runtime.Runtime.init(.{
        .provider = provider,
    });

    ctx.web_search_runtime.configure(.{
        .api_key = "stale-key",
        .worker_model = "stale-model",
        .gateway_retry_count = 99,
        .gateway_chat_url = "https://stale.invalid/chat",
    });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(arena);
    const deps = agentRuntimeDeps(&ctx);
    const append_static = deps.append_static_context orelse return error.TestExpectedEqual;
    try append_static(deps.ctx, arena, &messages);
    try deps.append_runtime_context(deps.ctx, arena, &messages);

    try std.testing.expectEqualStrings("stale-key", ctx.web_search_runtime.api_key);

    const validate = deps.validate_tool_call orelse return error.TestExpectedEqual;
    const validation = try validate(deps.ctx, arena, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"x\"}",
    });
    try std.testing.expectEqualStrings("web_search field \"query\" must contain at least two characters", validation.failure);
    try std.testing.expectEqualStrings(ctx.api_key, ctx.web_search_runtime.api_key);
    try std.testing.expectEqualStrings(ctx.model, ctx.web_search_runtime.worker_model);
    try std.testing.expectEqual(ctx.cfg.gateway_retry_count, ctx.web_search_runtime.gateway_retry_count);
    try std.testing.expectEqualStrings(ctx.cfg.gateway_chat_url, ctx.web_search_runtime.gateway_chat_url);

    const execute = deps.execute_tool_call;
    const execution = try execute(deps.ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = .{
            .id = "search-execute",
            .name = "web_search",
            .arguments_json = "{\"query\":\"current Zig release\"}",
        },
        .authority = .ordinary,
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = ctx.max_tool_result_bytes,
    });
    try std.testing.expectEqualStrings(ctx.api_key, ctx.web_search_runtime.api_key);
    try std.testing.expectEqualStrings(ctx.model, ctx.web_search_runtime.worker_model);
    try std.testing.expectEqual(ctx.cfg.gateway_retry_count, ctx.web_search_runtime.gateway_retry_count);
    try std.testing.expectEqualStrings(ctx.cfg.gateway_chat_url, ctx.web_search_runtime.gateway_chat_url);
    try std.testing.expectEqual(.failure, execution.status);
    try std.testing.expectEqual(@as(usize, 0), provider_state.calls);
}

test "fx ask ChatGPT route disables Gateway-backed auxiliary providers" {
    const alloc = std.testing.allocator;
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.api_key = "chatgpt-secret";
    ctx.credential_source = .chatgpt_subscription;
    ctx.provider = .codex;
    ctx.model = "gpt-5.4";

    const tool_ctx = ctx.toolContext();
    try std.testing.expect(tool_ctx.web_search_backend == null);
    try std.testing.expect(!tool_ctx.auto_classifier.enabled());
    try std.testing.expect(tool_ctx.permission_reviewer_provider == null);
}

test "fx ask finalization fails every failed turn" {
    const cases = [_]struct {
        outcome: types.TurnPresentationOutcome,
        disposition: ?types.ProviderCompletionDisposition,
        expected_failed: bool,
    }{
        .{ .outcome = .failed, .disposition = .length_limited, .expected_failed = true },
        .{ .outcome = .completed, .disposition = .length_limited, .expected_failed = false },
        .{ .outcome = .failed, .disposition = null, .expected_failed = true },
    };

    for (cases) |case| {
        const alloc = std.testing.allocator;
        var stdout_capture = TestCapture{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture = TestCapture{};
        defer stderr_capture.deinit(alloc);
        var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
        defer ctx.deinit();
        const deps = agentRuntimeDeps(&ctx);

        try deps.finalize_turn(deps.ctx, 8, case.outcome, case.disposition);

        try std.testing.expectEqual(case.expected_failed, ctx.failed);
        try std.testing.expectEqual(@as(usize, 0), ctx.worker.worker_events.items.len);
    }
}

test "fx ask deps reject malformed native web_search calls" {
    const alloc = std.testing.allocator;
    var stdout_capture = TestCapture{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture = TestCapture{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();

    const deps = agentRuntimeDeps(&ctx);
    const validate = deps.validate_tool_call orelse return error.TestExpectedEqual;
    const result = try validate(deps.ctx, alloc, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"x\"}",
    });
    defer alloc.free(result.failure);
    try std.testing.expectEqualStrings("web_search field \"query\" must contain at least two characters", result.failure);
}

test "parse options preserves active ask flags and operands" {
    var options = try parseOptionsWithStdin(std.testing.allocator, &.{
        "--auto",
        "--image",
        "a.png",
        "--system",
        "first",
        "--system",
        "second",
        "--json",
        "--prompt-permissions",
        "--quiet",
        "--verbose",
        "--no-save",
        "--no-color",
        "--timeout",
        "123",
        "hello",
        "world",
    }, .tty);
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?PermissionMode, .auto), options.permission_override);
    try std.testing.expect(options.json_output);
    try std.testing.expect(options.prompt_permissions);
    try std.testing.expect(options.quiet);
    try std.testing.expect(options.verbose);
    try std.testing.expect(options.no_save);
    try std.testing.expect(options.no_color);
    try std.testing.expectEqual(@as(?usize, 123 * std.time.ms_per_s), options.timeout_ms);
    try std.testing.expectEqualStrings("second", options.system_prompt_override.?);
    try std.testing.expectEqual(@as(usize, 1), options.image_paths.items.len);
    try std.testing.expectEqualStrings("a.png", options.image_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 0), options.images.items.len);
    try std.testing.expectEqualStrings("hello world", options.prompt);
}

test "parse options accepts yolo and rejects permission flag conflicts" {
    var yolo = try parseOptionsWithStdin(
        std.testing.allocator,
        &.{ "--yolo", "hello" },
        .tty,
    );
    defer yolo.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?PermissionMode, .yolo), yolo.permission_override);

    try std.testing.expectError(
        error.InvalidAskArgs,
        parseOptionsWithStdin(
            std.testing.allocator,
            &.{ "--auto", "--yolo", "hello" },
            .tty,
        ),
    );
}

test "headless yolo warning reaches stderr before acknowledgment persistence" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    TestYoloPersistence.reset();
    defer TestYoloPersistence.reset();
    TestYoloPersistence.warning_capture = &stderr_capture;

    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testMissingKeyStartup);
    deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--yolo", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 1), TestYoloPersistence.calls);
    try std.testing.expect(TestYoloPersistence.observed_warning_before_persist);
    try std.testing.expect(std.mem.startsWith(
        u8,
        stderr_capture.bytes.items,
        permissions.yolo_warning_text ++ "\n",
    ));
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, permissions.yolo_warning_text) == null);
}

test "headless yolo warning precedes startup configuration diagnostics" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    TestYoloPersistence.reset();
    defer TestYoloPersistence.reset();

    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyDiagnosticStartup,
    );
    deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    _ = try runWithDeps(
        alloc,
        &.{ "--yolo", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expect(std.mem.startsWith(
        u8,
        stderr_capture.bytes.items,
        permissions.yolo_warning_text ++ "\n" ++
            "fx ask: config user: malformed_settings\n",
    ));
}

test "headless yolo persistence is skipped when warning emission fails" {
    TestYoloPersistence.reset();
    defer TestYoloPersistence.reset();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(std.testing.allocator);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(std.testing.allocator);
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyStartup,
    );
    deps.stderr_ctx = null;
    deps.write_stderr = TestFailingStderr.write;
    deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;

    try std.testing.expectError(
        error.TestStderrWriteFailed,
        emitHeadlessYoloWarning(std.testing.allocator, .{
            .output_mode = .raw,
            .deps = deps,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), TestYoloPersistence.calls);
}

test "headless yolo warning respects acknowledgment and no-color" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    TestYoloPersistence.reset();
    defer TestYoloPersistence.reset();

    var acknowledged_deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyAcknowledgedStartup,
    );
    acknowledged_deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    _ = try runWithDeps(
        alloc,
        &.{ "--yolo", "hello" },
        testConfig(),
        acknowledged_deps,
    );
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, permissions.yolo_warning_text) == null);
    try std.testing.expectEqual(@as(usize, 0), TestYoloPersistence.calls);

    stderr_capture.bytes.clearRetainingCapacity();
    var color_deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyStartup,
    );
    color_deps.stderr_is_tty = TestTty.yes;
    color_deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    _ = try runWithDeps(
        alloc,
        &.{ "--yolo", "hello" },
        testConfig(),
        color_deps,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        stderr_capture.bytes.items,
        "\x1b[38;5;252m" ++ permissions.yolo_warning_text ++ "\x1b[0m\n",
    ));

    stderr_capture.bytes.clearRetainingCapacity();
    var no_color_deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyStartup,
    );
    no_color_deps.stderr_is_tty = TestTty.yes;
    no_color_deps.persist_yolo_acknowledgment = TestYoloPersistence.persist;
    _ = try runWithDeps(
        alloc,
        &.{ "--no-color", "--yolo", "hello" },
        testConfig(),
        no_color_deps,
    );
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "\x1b[31m") == null);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, permissions.yolo_warning_text) != null);
}

test "runWithDeps reports a missing image before startup after cleaning prior attachments" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "valid.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
    }
    const valid_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "valid.png");
    defer alloc.free(valid_path);
    const valid_path_z = try alloc.dupeZ(u8, valid_path);
    defer alloc.free(valid_path_z);
    const missing_path_z = try alloc.dupeZ(u8, "/tmp/fx-ask-missing-image.png");
    defer alloc.free(missing_path_z);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    test_image_preflight_startup_calls = 0;
    test_image_preflight_process_calls = 0;
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testCountImagePreflightStartup);
    deps.process_queued_prompt = testCountImagePreflightProcess;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--image", valid_path_z, "--image", missing_path_z, "describe" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 0), test_image_preflight_startup_calls);
    try std.testing.expectEqual(@as(usize, 0), test_image_preflight_process_calls);
    try std.testing.expectEqual(@as(usize, 0), stdout_capture.bytes.items.len);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, missing_path_z) != null);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "image file not found") != null);
}

test "runWithDeps reports unsupported images in JSON before startup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "not-image.txt", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "plain text");
    }
    const invalid_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "not-image.txt");
    defer alloc.free(invalid_path);
    const invalid_path_z = try alloc.dupeZ(u8, invalid_path);
    defer alloc.free(invalid_path_z);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    test_image_preflight_startup_calls = 0;
    test_image_preflight_process_calls = 0;
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testCountImagePreflightStartup);
    deps.process_queued_prompt = testCountImagePreflightProcess;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--image", invalid_path_z, "describe" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 0), test_image_preflight_startup_calls);
    try std.testing.expectEqual(@as(usize, 0), test_image_preflight_process_calls);
    try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "\"exit_code\":1") != null);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "UnsupportedImageType") != null);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, invalid_path_z) != null);
}

test "runWithDeps assigns image ids and owns the authorized catalog before processing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "valid.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
    }
    const image_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "valid.png");
    defer alloc.free(image_path);
    const image_path_z = try alloc.dupeZ(u8, image_path);
    defer alloc.free(image_path_z);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.process_queued_prompt = testProcessQueuedPromptCapturesNoSaveSnapshot;
    test_no_save_snapshot_path = null;
    defer if (test_no_save_snapshot_path) |path| alloc.free(path);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "--image", image_path_z, "describe" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "assistant text") != null);
    const snapshot_path = test_no_save_snapshot_path orelse return error.TestExpectedEqual;
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(std.testing.io, snapshot_path, .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openDirAbsolute(std.testing.io, std.fs.path.dirname(snapshot_path).?, .{}),
    );
}

test "preflightAskImages resolves image paths from the workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "target.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
    }
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace_root);
    const expected_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target.png");
    defer alloc.free(expected_path);

    var options = AskOptions{ .prompt = try alloc.dupe(u8, "describe") };
    defer options.deinit(alloc);
    try options.image_paths.append(alloc, try alloc.dupe(u8, "target.png"));

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);

    try std.testing.expect(try preflightAskImages(alloc, workspace_root, &options, deps));
    try std.testing.expectEqual(@as(usize, 1), options.images.items.len);
    try std.testing.expectEqualStrings(expected_path, options.images.items[0].path);
}

test "parse options rejects unknown flags and accepts dash prompts after sentinel" {
    try std.testing.expectError(
        error.InvalidAskArgs,
        parseOptionsWithStdin(
            std.testing.allocator,
            &.{ "--timeout", "nope", "--not-a-flag", "prompt" },
            .tty,
        ),
    );

    var options = try parseOptionsWithStdin(std.testing.allocator, &.{ "--timeout", "nope", "--", "--not-a-flag", "prompt" }, .tty);
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?usize, null), options.timeout_ms);
    try std.testing.expectEqualStrings("--not-a-flag prompt", options.prompt);
}

test "parse options reports missing operands and empty tty input as missing prompt" {
    try std.testing.expectError(error.MissingPrompt, parseOptionsWithStdin(std.testing.allocator, &.{"--image"}, .tty));
    try std.testing.expectError(error.MissingPrompt, parseOptionsWithStdin(std.testing.allocator, &.{"--system"}, .tty));
    try std.testing.expectError(error.MissingPrompt, parseOptionsWithStdin(std.testing.allocator, &.{"--timeout"}, .tty));
    try std.testing.expectError(error.MissingPrompt, parseOptionsWithStdin(std.testing.allocator, &.{}, .tty));
}

test "stdin prompt resource limit accepts exact bytes and rejects one over without a partial prompt" {
    const alloc = std.testing.allocator;
    var exact_reader = std.Io.Reader.fixed("12345678");
    const exact = try readPromptFromReader(alloc, &exact_reader, 8);
    defer alloc.free(exact);
    try std.testing.expectEqualStrings("12345678", exact);

    var over_reader = std.Io.Reader.fixed("123456789");
    try std.testing.expectError(
        error.PromptResourceLimitExceeded,
        readPromptFromReader(alloc, &over_reader, 8),
    );

    try std.testing.expectError(
        error.PromptResourceLimitExceeded,
        readPromptFromStdinSourceWithLimit(alloc, .{ .bytes = "123456789" }, 8),
    );
    try std.testing.expectError(
        error.PromptInputReadFailed,
        readPromptFromStdinSourceWithLimit(alloc, .read_error, 8),
    );
}

test "stdin prompt reader propagates allocation failure" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var reader = std.Io.Reader.fixed("prompt");
    try std.testing.expectError(
        error.OutOfMemory,
        readPromptFromReader(failing.allocator(), &reader, 8),
    );
}

test "stdin prompt errors keep exact structured names" {
    const alloc = std.testing.allocator;
    const overflow = try renderErrorJsonResult(alloc, "PromptResourceLimitExceeded");
    defer alloc.free(overflow);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"exit_code\":1,\"model\":\"\",\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"error\":\"PromptResourceLimitExceeded\"}\n",
        overflow,
    );

    const read_failure = try renderErrorJsonResult(alloc, "PromptInputReadFailed");
    defer alloc.free(read_failure);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"exit_code\":1,\"model\":\"\",\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"error\":\"PromptInputReadFailed\"}\n",
        read_failure,
    );
}

test "image preparation failure has stable text and JSON contracts" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings(
        image_attachments.image_preparation_failed_notice,
        askErrorNotice(error.ImagePreparationFailed).?,
    );
    try std.testing.expect(askErrorNotice(error.Cancelled) == null);
    try std.testing.expect(askErrorNotice(error.TimedOut) == null);

    const json = try renderErrorJsonResult(alloc, @errorName(error.ImagePreparationFailed));
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"exit_code\":1,\"model\":\"\",\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"error\":\"ImagePreparationFailed\"}\n",
        json,
    );
}

test "stdin read failure has distinct text and JSON output contracts" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.stdin_source = .read_error;

    try std.testing.expectEqual(
        @as(u8, 1),
        try runWithDeps(alloc, &.{}, testConfig(), deps),
    );
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings(
        "fx ask: failed to read prompt from stdin\n",
        stderr_capture.bytes.items,
    );

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(u8, 1),
        try runWithDeps(alloc, &.{"--json"}, testConfig(), deps),
    );
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"exit_code\":1,\"model\":\"\",\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"error\":\"PromptInputReadFailed\"}\n",
        stdout_capture.bytes.items,
    );
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "runWithDeps threads timeout into ask tool context" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--timeout", "1", "hello" },
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptChecksTimeout),
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("assistant text", stdout_capture.bytes.items);
}

test "cli ask admits default-safe web_search without a rule" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();
    const call = ToolCall{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current news\"}",
    };

    try std.testing.expectEqual(ToolPermissionDecision.once, (try requestToolPermissionOutcome(&ctx, arena, call, .auto, &.{}, &.{})).decision);

    ctx.permission_rules = try testPermissionRuleSet(alloc, "web_search", "*", .allow);
    try std.testing.expectEqual(ToolPermissionDecision.once, (try requestToolPermissionOutcome(&ctx, arena, call, .auto, &.{}, &.{})).decision);
}

test "fx ask default user commands require configured authority or review" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();

    try std.testing.expectError(error.NonInteractivePermissionRequired, requestToolPermissionOutcome(&ctx, arena, .{
        .id = "direct",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"pwd\"}",
    }, .ask, &.{}, &.{}));

    try std.testing.expectError(error.NonInteractivePermissionRequired, requestToolPermissionOutcome(&ctx, arena, .{
        .id = "blocked",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch blocked.txt\"}",
    }, .ask, &.{}, &.{}));

    ctx.permission_rules = try testPermissionRuleSet(alloc, "bash", "touch *", .allow);
    const configured = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "configured",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch configured.txt\"}",
    }, .ask, &.{}, &.{}));
    switch ((configured.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(command_admission.ShellAuthorizationSource.configured_rule, authority.source),
    }

    ctx.permission_rules.deinit(alloc);
    ctx.permission_rules = .{};
    const automatic = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "automatic",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch automatic.txt\"}",
    }, .auto, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.deny, automatic.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, automatic.denial_reason.?);
}

test "fx ask automatic review observes worker cancellation" {
    const Provider = struct {
        fn review(
            _: ?*anyopaque,
            _: Allocator,
            input: permission_auto_classifier.ProviderInput,
            _: permission_auto_classifier.ReviewRequest,
        ) anyerror!permission_auto_classifier.ParseOutcome {
            const cancel_flag = input.cancel_flag orelse return .invalid;
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            return .invalid;
        }
    };

    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var cfg = testConfig();
    cfg.permission_reviewer_provider = .{ .review_fn = Provider.review };
    var ctx = AskContext.init(
        alloc,
        cfg,
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.worker.worker_cancel_requested.store(true, .seq_cst);

    const call: ToolCall = .{
        .id = "cancelled-review",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch cancelled.txt\"}",
    };
    var review_turn = TestReviewTurn.init("Create cancelled.txt.", call);
    try std.testing.expectError(
        error.Cancelled,
        requestToolPermissionOutcomeWithRequest(
            &ctx,
            arena_state.allocator(),
            call,
            review_turn.context(),
            .auto,
            &.{},
            null,
            null,
            &.{},
        ),
    );
}

test "headless ask SIGINT sets process-lifetime cancellation storage" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    var scope = try headless_interrupt.Scope.install(true);
    defer scope.deinit();

    _ = std.c.raise(std.posix.SIG.INT);

    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
}

test "headless ask interrupt installation exposes a typed busy result" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const InstallResult = @TypeOf(headless_interrupt.Scope.install(true));
    try std.testing.expect(
        std.meta.activeTag(@typeInfo(InstallResult)) == .error_union,
    );
}

var test_previous_sigint_count = std.atomic.Value(usize).init(0);
fn testPreviousSigintHandler(_: std.posix.SIG) callconv(.c) void {
    _ = test_previous_sigint_count.fetchAdd(1, .seq_cst);
}

fn testProcessQueuedPromptRaisesSigintAndSucceeds(
    deps: *const agent_runtime.AgentRuntimeDeps,
    semantic_presentation: ?agent_runtime.SemanticPresentationSink,
    lifecycle: agent_runtime.LifecycleContext,
    cfg: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
) !void {
    if (comptime supports_headless_interrupt) {
        _ = std.c.raise(std.posix.SIG.INT);
    }
    try testProcessQueuedPrompt(
        deps,
        semantic_presentation,
        lifecycle,
        cfg,
        job,
    );
}

const StartupCancellationStage = enum {
    after_startup_state,
    during_session_initialization,
    during_context_gather,
    during_mcp_load,
};

var test_startup_cancellation_stage: StartupCancellationStage = .after_startup_state;
var test_startup_cancellation_session_calls: usize = 0;
var test_startup_cancellation_context_calls: usize = 0;
var test_startup_cancellation_mcp_calls: usize = 0;
var test_startup_cancellation_process_calls: usize = 0;

fn requestTestHeadlessInterrupt() void {
    if (comptime supports_headless_interrupt) {
        headless_interrupt.handle(std.posix.SIG.INT);
    }
}

fn testLoadStartupStateWithCancellation(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    const state = try testPresentKeyStartup(
        alloc,
        transport,
        secret_store,
        default_model,
        default_agent_step_limit,
    );
    if (test_startup_cancellation_stage == .after_startup_state) {
        requestTestHeadlessInterrupt();
    }
    return state;
}

fn testInitializeSessionStoresWithCancellation(_: *AskContext) !void {
    test_startup_cancellation_session_calls += 1;
    if (test_startup_cancellation_stage == .during_session_initialization) {
        requestTestHeadlessInterrupt();
    }
}

fn testGatherContextWithCancellation(
    _: Allocator,
    _: context_contract.InitialContextInput,
) context_contract.ProviderError!context_contract.ProviderContext {
    test_startup_cancellation_context_calls += 1;
    if (test_startup_cancellation_stage == .during_context_gather) {
        requestTestHeadlessInterrupt();
    }
    return .{};
}

const test_startup_cancellation_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.startup_cancellation",
    .gather_project_context_fn = testGatherContextWithCancellation,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = testNoStaticContext,
    .append_transient_fn = testNoTransientContext,
} };

fn testLoadMcpRuntimeWithCancellation(_: Allocator, _: mcp_elicitation.Capabilities) !?*mcp_runtime.McpRuntime {
    test_startup_cancellation_mcp_calls += 1;
    if (test_startup_cancellation_stage == .during_mcp_load) {
        requestTestHeadlessInterrupt();
    }
    return null;
}

fn testProcessQueuedPromptAfterStartupCancellation(
    deps: *const agent_runtime.AgentRuntimeDeps,
    semantic_presentation: ?agent_runtime.SemanticPresentationSink,
    lifecycle: agent_runtime.LifecycleContext,
    cfg: agent_runtime.Config,
    job: worker_runtime.QueuedPrompt,
) !void {
    test_startup_cancellation_process_calls += 1;
    try testProcessQueuedPrompt(
        deps,
        semantic_presentation,
        lifecycle,
        cfg,
        job,
    );
}

fn testRaiseSigintAtInstallBoundary() void {
    _ = std.c.raise(std.posix.SIG.INT);
}

fn testRaiseSigintAtTeardownBoundary() void {
    headless_interrupt.cancel_requested.store(false, .seq_cst);
    _ = std.c.raise(std.posix.SIG.INT);
}

const CrossThreadSigintState = struct {
    request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn sendRequestedSigints(state: *CrossThreadSigintState) void {
    if (comptime !supports_headless_interrupt) return;
    while (!state.stop.load(.seq_cst)) {
        if (!state.request.swap(false, .seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
            continue;
        }
        std.posix.kill(std.c.getpid(), std.posix.SIG.INT) catch {
            state.failed.store(true, .seq_cst);
        };
        state.sent.store(true, .seq_cst);
    }
}

test "headless ask rejects concurrent and nested interrupt scopes without overwrite" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    var first = try headless_interrupt.Scope.install(true);
    defer first.deinit();

    try std.testing.expectError(
        error.HeadlessInterruptBusy,
        headless_interrupt.Scope.install(true),
    );

    const ConcurrentAttempt = struct {
        fn run(result: *std.atomic.Value(u8)) void {
            var scope = headless_interrupt.Scope.install(true) catch |err| {
                result.store(
                    if (err == error.HeadlessInterruptBusy) 1 else 2,
                    .seq_cst,
                );
                return;
            };
            defer scope.deinit();
            result.store(3, .seq_cst);
        }
    };
    var result = std.atomic.Value(u8).init(0);
    const thread = try std.Thread.spawn(.{}, ConcurrentAttempt.run, .{&result});
    thread.join();
    try std.testing.expectEqual(@as(u8, 1), result.load(.seq_cst));

    _ = std.c.raise(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
}

test "headless ask restores the exact previous SIGINT handler" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    var scope = try headless_interrupt.Scope.install(true);
    _ = std.c.raise(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), test_previous_sigint_count.load(.seq_cst));
    scope.deinit();

    _ = std.c.raise(std.posix.SIG.INT);
    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
}

test "headless ask redelivers consumed SIGINT after restoring the previous handler" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    var scope = try headless_interrupt.Scope.install(true);
    defer scope.deinit();
    _ = std.c.raise(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), test_previous_sigint_count.load(.seq_cst));

    scope.restoreAndRedeliver();

    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
}

test "headless ask returns nonzero when the restored SIGINT handler returns" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptRaisesSigintAndSucceeds,
    );
    deps.install_headless_interrupt = true;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 130), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
}

test "headless ask startup cancellation prevents later hooks" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);

    const cases = [_]struct {
        stage: StartupCancellationStage,
        session_calls: usize,
        context_calls: usize,
        mcp_calls: usize,
    }{
        .{ .stage = .after_startup_state, .session_calls = 0, .context_calls = 0, .mcp_calls = 0 },
        .{ .stage = .during_session_initialization, .session_calls = 1, .context_calls = 0, .mcp_calls = 0 },
        .{ .stage = .during_context_gather, .session_calls = 1, .context_calls = 1, .mcp_calls = 0 },
        .{ .stage = .during_mcp_load, .session_calls = 1, .context_calls = 1, .mcp_calls = 1 },
    };

    for (cases) |case| {
        test_startup_cancellation_stage = case.stage;
        test_startup_cancellation_session_calls = 0;
        test_startup_cancellation_context_calls = 0;
        test_startup_cancellation_mcp_calls = 0;
        test_startup_cancellation_process_calls = 0;
        test_previous_sigint_count.store(0, .seq_cst);

        const alloc = std.testing.allocator;
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDepsWithProcess(
            &stdout_capture,
            &stderr_capture,
            testProcessQueuedPromptAfterStartupCancellation,
        );
        deps.load_startup_state = testLoadStartupStateWithCancellation;
        deps.initialize_session_stores = testInitializeSessionStoresWithCancellation;
        deps.context_registry = test_startup_cancellation_context_registry;
        deps.load_mcp_runtime = testLoadMcpRuntimeWithCancellation;
        deps.install_headless_interrupt = true;

        const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

        try std.testing.expectEqual(@as(u8, 130), exit_code);
        try std.testing.expectEqual(case.session_calls, test_startup_cancellation_session_calls);
        try std.testing.expectEqual(case.context_calls, test_startup_cancellation_context_calls);
        try std.testing.expectEqual(case.mcp_calls, test_startup_cancellation_mcp_calls);
        try std.testing.expectEqual(@as(usize, 0), test_startup_cancellation_process_calls);
        try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
        try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
    }
}

test "headless ask resets signal-visible cancellation state for each scope" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    var scope = try headless_interrupt.Scope.install(true);
    headless_interrupt.handle(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
    scope.deinit();

    headless_interrupt.handle(std.posix.SIG.INT);
    try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));

    var next = try headless_interrupt.Scope.install(true);
    defer next.deinit();
    try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
}

test "headless ask preserves signal ordering during install and teardown" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    headless_interrupt.test_after_reset_before_install = testRaiseSigintAtInstallBoundary;
    defer headless_interrupt.test_after_reset_before_install = null;
    var scope = try headless_interrupt.Scope.install(true);
    try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));

    headless_interrupt.test_after_reset_before_install = null;
    headless_interrupt.test_after_restore = testRaiseSigintAtTeardownBoundary;
    defer headless_interrupt.test_after_restore = null;
    scope.deinit();

    try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), test_previous_sigint_count.load(.seq_cst));
}

test "headless ask cross-thread SIGINT teardown and reuse target only the active scope" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);

    var state = CrossThreadSigintState{};
    const sender = try std.Thread.spawn(.{}, sendRequestedSigints, .{&state});
    defer {
        state.stop.store(true, .seq_cst);
        sender.join();
    }

    for (0..128) |_| {
        var first = try headless_interrupt.Scope.install(true);
        state.sent.store(false, .seq_cst);
        state.request.store(true, .seq_cst);
        while (!state.sent.load(.seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        first.deinit();

        var next = try headless_interrupt.Scope.install(true);
        for (0..4) |_| {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
        _ = std.c.raise(std.posix.SIG.INT);
        try std.testing.expect(headless_interrupt.cancel_requested.load(.seq_cst));
        next.deinit();
    }
    try std.testing.expect(!state.failed.load(.seq_cst));
}

test "disabled headless ask scope leaves the interactive SIGINT handler untouched" {
    if (comptime !supports_headless_interrupt) return error.SkipZigTest;

    const previous_action: std.posix.Sigaction = .{
        .handler = .{ .handler = testPreviousSigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var original_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &previous_action, &original_action);
    defer std.posix.sigaction(std.posix.SIG.INT, &original_action, null);
    test_previous_sigint_count.store(0, .seq_cst);

    headless_interrupt.cancel_requested.store(false, .seq_cst);
    var scope = try headless_interrupt.Scope.install(false);
    defer scope.deinit();
    _ = std.c.raise(std.posix.SIG.INT);

    try std.testing.expect(!headless_interrupt.cancel_requested.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), test_previous_sigint_count.load(.seq_cst));
}

test "fx ask auto mode applies automatic allow and ask without a prompt" {
    const FakeClassifier = struct {
        calls: usize = 0,
        decision: permission_auto_classifier.Decision = .allow,

        fn classify(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            _: permission_auto_classifier.ReviewRequest,
        ) anyerror!permission_auto_classifier.ParseOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            return .{ .valid = .{
                .risk = if (self.decision == .allow) .low else .high,
                .authorization = .medium,
                .decision = self.decision,
                .rationale = try alloc.dupe(u8, "test automatic review"),
            } };
        }
    };

    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), "/tmp/workspace");
    defer ctx.deinit();
    var fake = FakeClassifier{ .decision = .allow };
    ctx.auto_classifier = permission_auto_classifier.Classifier.withOverride(
        @ptrCast(&fake),
        FakeClassifier.classify,
    );

    const direct_call: ToolCall = .{
        .id = "direct",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"pwd\"}",
    };
    var direct_review = TestReviewTurn.init("Inspect the workspace.", direct_call);
    const direct = try requestToolPermissionOutcomeWithRequest(
        &ctx,
        arena,
        direct_call,
        direct_review.context(),
        .auto,
        &.{},
        null,
        null,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_classifier,
        direct.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    const accepted_call: ToolCall = .{
        .id = "accepted",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch accepted.txt\"}",
    };
    var accepted_review = TestReviewTurn.init("Create accepted.txt.", accepted_call);
    const accepted = try requestToolPermissionOutcomeWithRequest(
        &ctx,
        arena,
        accepted_call,
        accepted_review.context(),
        .auto,
        &.{},
        null,
        null,
        &.{},
    );
    switch ((accepted.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(
            command_admission.ShellAuthorizationSource.auto_classifier,
            authority.source,
        ),
    }
    try std.testing.expectEqual(@as(usize, 2), fake.calls);

    fake.decision = .ask;
    const check_call: ToolCall = .{
        .id = "check",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch check.txt\"}",
    };
    var check_review = TestReviewTurn.init("Check this command.", check_call);
    const blocked = try requestToolPermissionOutcomeWithRequest(
        &ctx,
        arena,
        check_call,
        check_review.context(),
        .auto,
        &.{},
        null,
        null,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.deny, blocked.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, blocked.denial_reason.?);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "fx ask terminal permission prompt approves and denies run_command" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();

    const approved = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "approved",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch approved.txt\"}",
    }, .ask, &.{}, &.{}));
    switch ((approved.execution_authority orelse return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(
            command_admission.ShellAuthorizationSource.interactive_once,
            authority.source,
        ),
    }
    try std.testing.expectEqual(@as(usize, 1), prompt.calls);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "Approve? [y/N]") != null);
    try std.testing.expect(prompt.label != null);

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();
    prompt.result = .deny;

    const denied = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "denied",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch denied.txt\"}",
    }, .ask, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.deny, denied.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.user_denied, denied.denial_reason.?);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 2), prompt.calls);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "Approve? [y/N]") != null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
}

test "fx ask permission attention fires once after a prompt is published" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();
    ctx.active_turn_id = 42;
    var capture = AskAttentionCapture{};
    try ctx.lifecycle_runtime.registerAttentionRequired(.{
        .name = "capture",
        .ctx = &capture,
        .run = AskAttentionCapture.run,
    });
    ctx.lifecycle_view = ctx.lifecycle_runtime.freeze();

    _ = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "attention",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch attention.txt\"}",
    }, .ask, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(u64, 42), capture.turn_id);
    try std.testing.expectEqual(@as(?hooks.AttentionKind, .permission), capture.kind);

    prompt.result = .unavailable;
    try std.testing.expectError(error.NonInteractivePermissionRequired, requestToolPermissionOutcome(&ctx, arena, .{
        .id = "unavailable",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch unavailable.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "fx ask bell writes only to TTY stderr" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.stderr_is_tty = TestTty.yes;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();

    emitAskNotificationBell(&ctx);
    try std.testing.expectEqualStrings("\x07", stderr_capture.bytes.items);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);

    stderr_capture.bytes.clearRetainingCapacity();
    ctx.deps.stderr_is_tty = TestTty.no;
    emitAskNotificationBell(&ctx);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
}

test "fx ask registers notification handlers only when configured" {
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(std.testing.allocator);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(std.testing.allocator);
    var disabled = AskContext.init(
        std.testing.allocator,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer disabled.deinit();
    try disabled.configureNotifications(false, false);
    try std.testing.expect(!disabled.lifecycle_view.hasPostTurnEnd());
    try std.testing.expect(!disabled.lifecycle_view.hasAttentionRequired());

    var enabled = AskContext.init(
        std.testing.allocator,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer enabled.deinit();
    try enabled.configureNotifications(true, true);

    try std.testing.expect(enabled.lifecycle_view.hasPostTurnEnd());
    try std.testing.expect(enabled.lifecycle_view.hasAttentionRequired());
}

test "fx ask captured and quiet permission paths bypass terminal prompt" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();

    ctx.output_mode = .json;
    try std.testing.expectError(error.NonInteractivePermissionRequired, requestToolPermissionOutcome(&ctx, arena, .{
        .id = "captured",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch captured.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 0), prompt.calls);
    try std.testing.expectEqual(@as(usize, 1), ctx.tool_call_records.items.len);
    try std.testing.expectEqualStrings("terminal", ctx.tool_call_records.items[0].name);
    try std.testing.expectEqualStrings("error", ctx.tool_call_records.items[0].status);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "noninteractive_permission_prompt_unavailable") != null);

    stderr_capture.bytes.clearRetainingCapacity();
    ctx.output_mode = .quiet;
    try std.testing.expectError(error.NonInteractivePermissionRequired, requestToolPermissionOutcome(&ctx, arena, .{
        .id = "quiet",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch quiet.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 0), prompt.calls);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "noninteractive_permission_prompt_unavailable") != null);
}

test "fx ask permission prompt policy requires explicit captured-mode opt in and TTY stdin" {
    const Case = struct {
        output_mode: OutputMode,
        prompt_permissions: bool,
        stdin_is_tty: bool,
        expected: bool,
    };
    const cases = [_]Case{
        .{ .output_mode = .raw, .prompt_permissions = false, .stdin_is_tty = false, .expected = true },
        .{ .output_mode = .terminal, .prompt_permissions = false, .stdin_is_tty = false, .expected = true },
        .{ .output_mode = .terminal_no_color, .prompt_permissions = false, .stdin_is_tty = false, .expected = true },
        .{ .output_mode = .json, .prompt_permissions = false, .stdin_is_tty = true, .expected = false },
        .{ .output_mode = .quiet, .prompt_permissions = false, .stdin_is_tty = true, .expected = false },
        .{ .output_mode = .json, .prompt_permissions = true, .stdin_is_tty = false, .expected = false },
        .{ .output_mode = .quiet, .prompt_permissions = true, .stdin_is_tty = false, .expected = false },
        .{ .output_mode = .json, .prompt_permissions = true, .stdin_is_tty = true, .expected = true },
        .{ .output_mode = .quiet, .prompt_permissions = true, .stdin_is_tty = true, .expected = true },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            cliPermissionPromptAllowed(
                case.output_mode,
                case.prompt_permissions,
                case.stdin_is_tty,
            ),
        );
    }
}

test "fx ask captured permission prompt opt in uses the existing prompter" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    deps.stdin_is_tty = TestTty.yes;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();
    ctx.prompt_permissions = true;

    ctx.output_mode = .json;
    const approved = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "captured-approved",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch captured-approved.txt\"}",
    }, .ask, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, approved.decision);
    try std.testing.expectEqual(@as(usize, 1), prompt.calls);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "Approve? [y/N]") != null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);

    prompt.result = .deny;
    ctx.output_mode = .quiet;
    const denied = try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "quiet-denied",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch quiet-denied.txt\"}",
    }, .ask, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.deny, denied.decision);
    try std.testing.expectEqual(@as(usize, 2), prompt.calls);

    ctx.deps.stdin_is_tty = TestTty.no;
    try std.testing.expectError(error.NonInteractivePermissionRequired, requestToolPermissionOutcome(&ctx, arena, .{
        .id = "quiet-non-tty",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch quiet-non-tty.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 2), prompt.calls);
}

test "fx ask terminal permission prompt propagates prompt hook errors" {
    const FailingPrompt = struct {
        fn prompt(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: WriteFn,
            _: []const u8,
            _: ?*anyopaque,
            _: NotifyAttentionFn,
        ) !PermissionApprovalPromptResult {
            return error.PromptFailure;
        }
    };

    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt = FailingPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, "/tmp/workspace");
    defer ctx.deinit();

    try std.testing.expectError(error.PromptFailure, requestToolPermissionOutcome(&ctx, arena, .{
        .id = "prompt-failure",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch prompt-failure.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "noninteractive_permission_prompt_unavailable") == null);
}

test "fx ask prepared file mutation callback preserves terminal permission prompt" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var prompt = TestPermissionPrompt{ .result = .approve };
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.permission_approval_prompt_ctx = @ptrCast(&prompt);
    deps.permission_approval_prompt = TestPermissionPrompt.prompt;
    var ctx = AskContext.init(alloc, testConfig(), deps, workspace);
    defer ctx.deinit();

    const target_path = try std.fs.path.join(arena, &.{ external, "desktop-test.txt" });
    const call: ToolCall = .{
        .id = "external-write",
        .name = "write_file",
        .arguments_json = try std.fmt.allocPrint(
            arena,
            "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
            .{target_path},
        ),
    };
    var prepared = switch (try tool_admission.prepareFileMutationCall(arena, call, .{
        .tool_registry = ctx.toolRegistry(),
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);
    const runtime_deps = agentRuntimeDeps(&ctx);
    const callback = runtime_deps.request_prepared_file_mutation_permission orelse
        return error.TestExpectedPreparedFileMutationCallback;
    var review_turn = TestReviewTurn.init("Approve this prepared mutation.", call);
    const accepted = try callback(
        runtime_deps.ctx,
        arena,
        call,
        &prepared,
        review_turn.context(),
        .ask,
        &.{},
        null,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), prompt.calls);
    try std.testing.expectEqual(ToolPermissionDecision.once, accepted.decision);
    const authorization = switch (accepted.execution_authority orelse return error.TestExpectedEqual) {
        .file_mutation => |authorization| authorization,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqualStrings(target_path, authorization.input.path());
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "Approve? [y/N]") != null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
}

test "fx ask auto mode uses automatic allow for external prepared file mutation" {
    const FakeClassifier = struct {
        calls: usize = 0,
        root_text: []const u8 = "",

        fn classify(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            request: permission_auto_classifier.ReviewRequest,
        ) anyerror!permission_auto_classifier.ParseOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            self.root_text = request.review_turn.current_root_request;
            try std.testing.expect(request.targets.len >= 1);
            const file = switch (request.action) {
                .file_mutation => |value| value,
                else => return error.TestExpectedEqual,
            };
            try std.testing.expectEqualStrings("write_file", file.tool_name);
            return .{ .valid = .{
                .risk = .medium,
                .authorization = .high,
                .decision = .allow,
                .rationale = try alloc.dupe(u8, "test automatic review"),
            } };
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), workspace);
    defer ctx.deinit();
    var fake = FakeClassifier{};
    ctx.auto_classifier = permission_auto_classifier.Classifier.withOverride(
        @ptrCast(&fake),
        FakeClassifier.classify,
    );

    const target_path = try std.fs.path.join(arena, &.{ external, "desktop-test.txt" });
    const arguments_json = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
        .{target_path},
    );
    const call: ToolCall = .{
        .id = "external-write",
        .name = "write_file",
        .arguments_json = arguments_json,
    };
    var review_turn = TestReviewTurn.init("Write hello to desktop-test.txt.", call);
    const accepted = try requestToolPermissionOutcomeWithRequest(&ctx, arena, call, review_turn.context(), .auto, &.{}, null, null, &.{});

    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqualStrings("", fake.root_text);
    try std.testing.expectEqual(ToolPermissionDecision.once, accepted.decision);
    const authorization = switch (accepted.execution_authority orelse return error.TestExpectedEqual) {
        .file_mutation => |authorization| authorization,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqualStrings(target_path, authorization.input.path());
}

test "fx ask preserves CLI headless blocker diagnostics" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    {
        var source = try tmp.dir.createFile(io_mod.getIo(), "workspace/source.txt", .{ .truncate = true });
        defer source.close(io_mod.getIo());
        try source.writeStreamingAll(io_mod.getIo(), "source\n");
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        workspace,
    );
    defer ctx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    ctx.permission_rules = try testPermissionRuleSet(alloc, "bash", "touch configured.txt", .ask);
    const configured_rule_ask = ToolCall{
        .id = "configured-rule-ask",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch configured.txt\"}",
    };
    const configured_label = try tool_presentation.formatPlainAction(arena, .{ .tool_registry = ctx.toolRegistry(), .call = configured_rule_ask });
    try std.testing.expectError(error.NonInteractivePermissionRequired, requestToolPermissionOutcome(
        &ctx,
        arena,
        configured_rule_ask,
        .ask,
        &.{},
        &.{},
    ));
    const expected_configured_stderr = try std.fmt.allocPrint(
        arena,
        "fx ask: permission required by configured rule\n" ++
            "fx ask: blocked action: {s}\n" ++
            "fx ask: reason=noninteractive_permission_prompt_unavailable\n" ++
            "fx ask: rerun in the interactive shell to approve this action, or add a narrow matching permission rule before retrying\n",
        .{configured_label},
    );
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings(expected_configured_stderr, stderr_capture.bytes.items);

    ctx.permission_rules.deinit(alloc);
    ctx.permission_rules = .{};
    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();

    const source = try std.fs.path.join(arena, &.{ workspace, "source.txt" });
    const external_destination = try std.fs.path.join(arena, &.{ external, "copied.txt" });
    const blocked_copy = ToolCall{
        .id = "external-file-mutation",
        .name = "copy_file",
        .arguments_json = try std.fmt.allocPrint(
            arena,
            "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}",
            .{ source, external_destination },
        ),
    };
    const external_outcome = try requestToolPermissionOutcome(
        &ctx,
        arena,
        blocked_copy,
        .auto,
        &.{},
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.deny, external_outcome.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, external_outcome.denial_reason.?);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();

    const approval_required = ToolCall{
        .id = "approval-required",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch approval.txt\"}",
    };
    const approval_label = try tool_presentation.formatPlainAction(arena, .{ .tool_registry = ctx.toolRegistry(), .call = approval_required });
    try std.testing.expectError(error.NonInteractivePermissionRequired, requestToolPermissionOutcome(
        &ctx,
        arena,
        approval_required,
        .ask,
        &.{},
        &.{},
    ));
    const expected_approval_stderr = try std.fmt.allocPrint(
        arena,
        "fx ask: permission required for tool execution in noninteractive mode\n" ++
            "fx ask: blocked action: {s}\n" ++
            "fx ask: reason=noninteractive_permission_prompt_unavailable\n" ++
            "fx ask: rerun with --auto to review this exact action automatically, or use the interactive shell to approve it\n",
        .{approval_label},
    );
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings(expected_approval_stderr, stderr_capture.bytes.items);

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();

    const auto_approval = try requestToolPermissionOutcome(
        &ctx,
        arena,
        approval_required,
        .auto,
        &.{},
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.deny, auto_approval.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, auto_approval.denial_reason.?);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();

    const default_safe_web_search = try requestToolPermissionOutcome(
        &ctx,
        arena,
        .{
            .id = "web-search-default",
            .name = "web_search",
            .arguments_json = "{\"query\":\"current news\"}",
        },
        .auto,
        &.{},
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, default_safe_web_search.decision);
    try std.testing.expect(default_safe_web_search.execution_authority != null);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "fx ask ordinary multi-target admission preserves deny precedence without diagnostics" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    {
        var source = try tmp.dir.createFile(io_mod.getIo(), "workspace/source.txt", .{ .truncate = true });
        defer source.close(io_mod.getIo());
        try source.writeStreamingAll(io_mod.getIo(), "source\n");
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        root,
    );
    defer ctx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct {
        tool_name: []const u8,
        arguments_json: []const u8,
        source_action: types.PermissionAction,
        destination_action: types.PermissionAction,
    }{
        .{
            .tool_name = "copy_file",
            .arguments_json = "{\"source\":\"source.txt\",\"destination\":\"destination.txt\"}",
            .source_action = .ask,
            .destination_action = .deny,
        },
        .{
            .tool_name = "copy_file",
            .arguments_json = "{\"source\":\"source.txt\",\"destination\":\"destination.txt\"}",
            .source_action = .deny,
            .destination_action = .ask,
        },
        .{
            .tool_name = "rename_file",
            .arguments_json = "{\"old_path\":\"source.txt\",\"new_path\":\"destination.txt\"}",
            .source_action = .ask,
            .destination_action = .deny,
        },
        .{
            .tool_name = "rename_file",
            .arguments_json = "{\"old_path\":\"source.txt\",\"new_path\":\"destination.txt\"}",
            .source_action = .deny,
            .destination_action = .ask,
        },
    };

    for (cases, 0..) |case, index| {
        ctx.permission_rules.deinit(alloc);
        ctx.permission_rules = try testPermissionRuleSetPair(
            alloc,
            case.tool_name,
            "source.txt",
            case.source_action,
            "destination.txt",
            case.destination_action,
        );
        const outcome = try requestToolPermissionOutcome(&ctx, arena, .{
            .id = try std.fmt.allocPrint(arena, "multi-target-{d}", .{index}),
            .name = case.tool_name,
            .arguments_json = case.arguments_json,
        }, .ask, &.{}, &.{});
        try std.testing.expectEqual(ToolPermissionDecision.policy_denied, outcome.decision);
        try std.testing.expect(outcome.execution_authority == null);
        try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
        try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
    }
}

test "CLI ask auto mode requires review when only one copy or rename target is configured" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    {
        var workspace_file = try tmp.dir.createFile(io_mod.getIo(), "workspace/source.txt", .{ .truncate = true });
        defer workspace_file.close(io_mod.getIo());
        try workspace_file.writeStreamingAll(io_mod.getIo(), "workspace\n");
    }
    {
        var external_file = try tmp.dir.createFile(io_mod.getIo(), "external/source.txt", .{ .truncate = true });
        defer external_file.close(io_mod.getIo());
        try external_file.writeStreamingAll(io_mod.getIo(), "external\n");
    }

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    const external_pattern = try std.fmt.allocPrint(alloc, "{s}/**", .{external});
    defer alloc.free(external_pattern);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), workspace);
    defer ctx.deinit();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace_source = try std.fs.path.join(arena, &.{ workspace, "source.txt" });
    const workspace_copy = try std.fs.path.join(arena, &.{ workspace, "copied.txt" });
    const workspace_rename = try std.fs.path.join(arena, &.{ workspace, "renamed.txt" });
    const external_source = try std.fs.path.join(arena, &.{ external, "source.txt" });
    const external_copy = try std.fs.path.join(arena, &.{ external, "copied.txt" });
    const external_rename = try std.fs.path.join(arena, &.{ external, "renamed.txt" });

    const cases = [_]struct {
        tool_name: []const u8,
        permission_name: []const u8,
        arguments_json: []const u8,
    }{
        .{
            .tool_name = "copy_file",
            .permission_name = "copy_file",
            .arguments_json = try std.fmt.allocPrint(arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{ workspace_source, external_copy }),
        },
        .{
            .tool_name = "copy_file",
            .permission_name = "copy_file",
            .arguments_json = try std.fmt.allocPrint(arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{ external_source, workspace_copy }),
        },
        .{
            .tool_name = "rename_file",
            .permission_name = "rename_file",
            .arguments_json = try std.fmt.allocPrint(arena, "{{\"old_path\":\"{s}\",\"new_path\":\"{s}\"}}", .{ workspace_source, external_rename }),
        },
        .{
            .tool_name = "rename_file",
            .permission_name = "rename_file",
            .arguments_json = try std.fmt.allocPrint(arena, "{{\"old_path\":\"{s}\",\"new_path\":\"{s}\"}}", .{ external_source, workspace_rename }),
        },
    };

    for (cases, 0..) |case, index| {
        ctx.permission_rules.deinit(alloc);
        ctx.permission_rules = try testPermissionRuleSet(alloc, case.permission_name, external_pattern, .allow);
        const outcome = try requestToolPermissionOutcome(&ctx, arena, .{
            .id = try std.fmt.allocPrint(arena, "mixed-{d}", .{index}),
            .name = case.tool_name,
            .arguments_json = case.arguments_json,
        }, .auto, &.{}, &.{});
        try std.testing.expectEqual(ToolPermissionDecision.deny, outcome.decision);
        try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, outcome.denial_reason.?);
        stdout_capture.bytes.clearRetainingCapacity();
        stderr_capture.bytes.clearRetainingCapacity();
    }
}

test "runWithDeps projects exec-only terminal when saved setup has no capability" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{"hello"},
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptChecksExecOnlyTerminal),
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("assistant text", stdout_capture.bytes.items);
}

test "runWithDeps uses the supplied tool set for advertisement and runtime" {
    const alloc = std.testing.allocator;
    const tools = [_]tool_dispatch.Tool{builtin_tools.read_file};
    const names = [_][]const u8{"read_file"};
    const tool_set: tool_set_contract.ToolSet = .{
        .registry = .{ .tools = tools[0..] },
        .order = names[0..],
        .read_only_tool_names = names[0..],
    };
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptChecksInjectedToolSet,
    );
    deps.tool_set = tool_set;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("assistant text", stdout_capture.bytes.items);
}

test "final ask json keeps terminal tool call shape and adds command result" {
    const alloc = std.testing.allocator;
    const records = try alloc.alloc(ToolCallRecord, 1);
    records[0] = .{
        .name = try alloc.dupe(u8, "terminal"),
        .status = try alloc.dupe(u8, "success"),
        .command_result_json = try alloc.dupe(u8, "{\"kind\":\"foreground\",\"command\":\"printf ok\",\"cwd\":\"/tmp\",\"exit_code\":0,\"signal\":null,\"timed_out\":false,\"stdout_bytes\":2,\"stderr_bytes\":0,\"truncated\":false}"),
    };
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, "ok"),
        .model = try alloc.dupe(u8, "test-model"),
        .session_id = try alloc.dupe(u8, "session-1"),
        .tool_calls = records,
        .step_count = 1,
    };
    defer result.deinit(alloc);

    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();
    const tool_call = parsed.value.object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("terminal", tool_call.get("name").?.string);
    try std.testing.expectEqualStrings("success", tool_call.get("status").?.string);
    const command_result = tool_call.get("command_result").?.object;
    try std.testing.expectEqualStrings("foreground", command_result.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 0), command_result.get("exit_code").?.integer);
    try std.testing.expectEqual(@as(i64, 2), command_result.get("stdout_bytes").?.integer);
}

test "runWithDeps honors no-save by skipping ask session stores" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    test_initialize_session_store_calls = 0;
    var deps = testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptChecksExecOnlyTerminal);
    deps.initialize_session_stores = testCountSessionStores;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--no-save", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), test_initialize_session_store_calls);
}

test "runWithDeps retains full terminal projection with saved capability" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeySavedStartup,
    );
    deps.initialize_session_stores = initializeSessionStoresDefault;
    deps.process_queued_prompt = testProcessQueuedPromptChecksFullTerminal;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("assistant text", stdout_capture.bytes.items);
}

test "exec-only terminal projection propagates view allocation failure" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        buildAskGatewayToolProjection(
            failing.allocator(),
            test_mode_registry,
            builtin_tools.advertisement_set,
            "inspect",
            .{},
            false,
        ),
    );
}

const TestAskHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    var stable_empty: ?*std.process.Environ.Map = null;

    fn stableEmptyEnv() !*const std.process.Environ.Map {
        if (stable_empty) |map| return map;
        const alloc = std.heap.page_allocator;
        const map = try alloc.create(std.process.Environ.Map);
        map.* = std.process.Environ.Map.init(alloc);
        stable_empty = map;
        return map;
    }

    fn install(alloc: Allocator, home: []const u8) !*TestAskHome {
        _ = try stableEmptyEnv();

        const self = try alloc.create(TestAskHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        try self.map.put("HOME", home);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestAskHome) void {
        if (stable_empty) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn testAskDurableState(
    alloc: Allocator,
    workspace: []const u8,
    id: []const u8,
) !session_codec.DurableSessionState {
    return .{
        .id = try alloc.dupe(u8, id),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "model"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = try alloc.alloc(HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

test "saved ask rejects a canonical one-off child during resume initialization" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    for ([_][]const u8{ "ask-parent", "ask-one-off" }) |session_id| {
        var state = try testAskDurableState(alloc, workspace, session_id);
        defer state.deinit(alloc);
        var writable = try store.startWritableSession(alloc, state);
        writable.deinit(alloc);
    }
    var command = try subagent_domain.validateCommand(alloc, .{ .create = .{
        .name = "one-off",
        .mode = .one_off,
        .prompt = "initial work",
    } });
    defer command.deinit(alloc);
    var manager = subagent_manager.Manager{ .sessions = &store };
    var result = try manager.execute(alloc, command, .{
        .actor_id = "ask-parent",
        .operation_id = "create-one-off",
        .created_child_id = "ask-one-off",
        .timestamp_ms = 2,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(subagent_domain.OutcomeCode.created, result.receipt.code);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    defer ctx.deinit();
    ctx.requested_resume = .{ .id = "ask-one-off" };

    try std.testing.expectError(
        error.OneOffSessionNotResumable,
        ctx.initializeSessionStores(),
    );
    try expectAskSessionStoresUnavailable(&ctx);
}

test "fx ask renders one-off resume denial in text and JSON modes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        args: []const [:0]const u8,
        json: bool,
    }{
        .{
            .args = &.{ "--resume-id", "one-off-child", "continue" },
            .json = false,
        },
        .{
            .args = &.{ "--json", "--resume-id", "one-off-child", "continue" },
            .json = true,
        },
    };
    for (cases) |case| {
        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var deps = testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeySavedStartup,
        );
        deps.initialize_session_stores = testInitializeSessionStoresOneOffDenied;

        const exit_code = try runWithDeps(alloc, case.args, testConfig(), deps);

        try std.testing.expectEqual(@as(u8, 1), exit_code);
        if (case.json) {
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                alloc,
                stdout_capture.bytes.items,
                .{},
            );
            defer parsed.deinit();
            try std.testing.expectEqualStrings(
                "OneOffSessionNotResumable",
                parsed.value.object.get("error").?.string,
            );
            try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
        } else {
            try std.testing.expectEqualStrings("", stdout_capture.bytes.items);
            try std.testing.expectEqualStrings(
                "fx ask: one-off child sessions cannot accept additional prompts; create a persistent child to continue the conversation\n",
                stderr_capture.bytes.items,
            );
        }
    }
}

fn expectAskContextManagedBorrowOwnership(ctx: *AskContext) !void {
    const background_capability = if (ctx.background.persisted_store) |store|
        store.capability
    else
        null;
    if (background_capability == null) return;

    try std.testing.expect(ctx.writable != null);
    const owner_capability = try ctx.writable.?.childCapability();
    if (background_capability) |capability| {
        try std.testing.expectEqual(owner_capability, capability);
    }
}

fn expectAskSessionStoresUnavailable(ctx: *const AskContext) !void {
    try std.testing.expect(ctx.store == null);
    try std.testing.expect(ctx.writable == null);
    try std.testing.expect(ctx.subagent_host == null);
    try std.testing.expect(ctx.background.persisted_store == null);
    try std.testing.expect(ctx.background.borrowed_session_capability == null);
}

fn exerciseSavedAskSessionStoreAllocation(
    alloc: Allocator,
    enforce_borrow_invariant: bool,
) !void {
    const setup_alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(setup_alloc, tmp.dir, "home");
    defer setup_alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        setup_alloc,
        tmp.dir,
        "workspace",
    );
    defer setup_alloc.free(workspace);

    const test_home = try TestAskHome.install(setup_alloc, home);
    defer test_home.deinit();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(setup_alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(setup_alloc);
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeyStartup,
    );
    deps.start_subagent_background_recovery = false;
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        deps,
        workspace,
    );
    defer ctx.deinit();
    ctx.session.setConversationLanguageFromUserMessage("persist this turn");

    ctx.initializeSessionStores() catch {
        if (enforce_borrow_invariant) {
            try expectAskContextManagedBorrowOwnership(&ctx);
        }
        return;
    };
    if (enforce_borrow_invariant) {
        try expectAskContextManagedBorrowOwnership(&ctx);
    }
}

test "saved ask allocation failures keep managed borrows owned" {
    const backing = std.testing.allocator;
    var counting = std.testing.FailingAllocator.init(backing, .{});
    try exerciseSavedAskSessionStoreAllocation(counting.allocator(), false);

    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            backing,
            .{ .fail_index = fail_index },
        );
        exerciseSavedAskSessionStoreAllocation(
            failing.allocator(),
            true,
        ) catch |err| {
            std.debug.print(
                "saved ask allocation fail_index={d} violated ownership: {s}\n",
                .{ fail_index, @errorName(err) },
            );
            return err;
        };
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(
            failing.allocated_bytes,
            failing.freed_bytes,
        );
    }
}

fn exerciseCurrentAskStateAllocation(
    ctx: *AskContext,
    writable: *session_store.LoadedWritableSession,
    alloc: Allocator,
) !void {
    const previous_alloc = ctx.alloc;
    ctx.alloc = alloc;
    defer ctx.alloc = previous_alloc;

    var state = try currentAskState(ctx, writable, io_mod.milliTimestamp());
    defer state.deinit(alloc);
}

test "current ask state releases partial snapshots on allocation failure" {
    const setup_alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(setup_alloc, tmp.dir, "home");
    defer setup_alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        setup_alloc,
        tmp.dir,
        "workspace",
    );
    defer setup_alloc.free(workspace);
    const test_home = try TestAskHome.install(setup_alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(setup_alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(setup_alloc);
    var ctx = AskContext.init(
        setup_alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    defer ctx.deinit();
    try ctx.initializeSessionStores();
    try ctx.session.appendAssistantHistoryTurn(
        setup_alloc,
        "question",
        "answer",
    );
    const sequence = try ctx.session.usage.reserveInvocation();
    try ctx.session.usage.finishObservedInvocation(
        setup_alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    const writable = &ctx.writable.?;

    var counting = std.testing.FailingAllocator.init(setup_alloc, .{});
    try exerciseCurrentAskStateAllocation(&ctx, writable, counting.allocator());

    for (0..counting.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            setup_alloc,
            .{ .fail_index = fail_index },
        );
        exerciseCurrentAskStateAllocation(
            &ctx,
            writable,
            failing.allocator(),
        ) catch |err| {
            if (err != error.OutOfMemory) return err;
        };
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(
            failing.allocated_bytes,
            failing.freed_bytes,
        );
    }
}

test "saved ask classifies unsafe store failure by request mode" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var blocker = try tmp.dir.createFile(io_mod.getIo(), "home/.fx", .{});
    blocker.close(io_mod.getIo());

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var fresh_ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    defer fresh_ctx.deinit();

    try fresh_ctx.initializeSessionStores();

    try std.testing.expectEqualStrings(
        "fx ask: warning: session persistence unavailable; error=SessionPathUnsafe; continuing without saving\n",
        stderr_capture.bytes.items,
    );
    try expectAskSessionStoresUnavailable(&fresh_ctx);

    stderr_capture.bytes.clearRetainingCapacity();
    var resume_ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    defer resume_ctx.deinit();
    resume_ctx.requested_resume = .last;

    try std.testing.expectError(
        error.SessionPathUnsafe,
        resume_ctx.initializeSessionStores(),
    );

    try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
    try expectAskSessionStoresUnavailable(&resume_ctx);
}

test "saved ask propagates store allocation failure" {
    const setup_alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(setup_alloc, tmp.dir, "home");
    defer setup_alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        setup_alloc,
        tmp.dir,
        "workspace",
    );
    defer setup_alloc.free(workspace);
    const test_home = try TestAskHome.install(setup_alloc, home);
    defer test_home.deinit();

    var failing = std.testing.FailingAllocator.init(
        setup_alloc,
        .{ .fail_index = 0 },
    );
    const alloc = failing.allocator();
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(setup_alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(setup_alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    defer ctx.deinit();

    try std.testing.expectError(
        error.OutOfMemory,
        ctx.initializeSessionStores(),
    );

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
    try expectAskSessionStoresUnavailable(&ctx);
}

test "saved ask initializes subagent host and background persistence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), workspace);
    defer ctx.deinit();
    ctx.session.setConversationLanguageFromUserMessage("start a background command");

    try ctx.initializeSessionStores();

    try std.testing.expect(ctx.subagent_host != null);
    const deps = agentRuntimeDeps(&ctx);
    try std.testing.expect(deps.prepare_parent_turn_context != null);
    try std.testing.expect(deps.acknowledge_parent_turn_context != null);
    try std.testing.expect(ctx.background.persisted_store != null);
    try std.testing.expect(ctx.writable != null);
    try std.testing.expect(ctx.writable.?.state.usage != null);
    try expectAskContextManagedBorrowOwnership(&ctx);

    var prepared = try ctx.background.prepareBackgroundLaunch(
        std.heap.c_allocator,
        .saved_headless,
    );
    defer ctx.background.cancelPreparedBackgroundLaunch(
        std.heap.c_allocator,
        &prepared,
    );

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var sessions = try store.list(alloc);
    defer {
        for (sessions.items) |*summary| summary.deinit(alloc);
        sessions.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), sessions.items.len);
    try std.testing.expectEqualStrings(workspace, sessions.items[0].workspace_root.?);
}

test "headless ask overwrites session usage from latest completion" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), workspace);
    defer ctx.deinit();

    try ctx.initializeSessionStores();
    try std.testing.expect(ctx.writable != null);

    const deps = agentRuntimeDeps(&ctx);
    const report_fn = deps.report_usage orelse return error.TestExpectedEqual;
    report_fn(deps.ctx, .{ .input_tokens = 100, .output_tokens = 20 });
    report_fn(deps.ctx, .{ .input_tokens = 107, .output_tokens = 23 });

    try std.testing.expectEqual(@as(u64, 107), ctx.writable.?.state.total_input_tokens);
    try std.testing.expectEqual(@as(u64, 23), ctx.writable.?.state.total_output_tokens);
}

test "saved ask settles profile publication before persistence teardown" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    var ctx_live = true;
    defer if (ctx_live) ctx.deinit();
    try ctx.initializeSessionStores();
    _ = agentRuntimeDeps(&ctx);

    const PublicationProbe = struct {
        allow_generation: bool = false,
        successful_generations: usize = 0,

        fn publish(
            raw: *anyopaque,
            event: usage_report.ProfileEvent,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .generation => {
                    if (!self.allow_generation) {
                        return error.InjectedPublicationFailure;
                    }
                    self.successful_generations += 1;
                },
                .pending, .incident => {},
            }
        }
    };
    var publication: PublicationProbe = .{};
    ctx.session.usage.configurePublicationSink(.{
        .context = &publication,
        .allocator = alloc,
        .publish = PublicationProbe.publish,
    });

    const generation_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV";
    const sequence = try ctx.session.usage.reserveInvocation();
    try ctx.session.usage.finishObservedInvocation(
        alloc,
        sequence,
        1,
        .observed_generation,
        generation_id,
        "https://ai-gateway.vercel.sh",
        null,
    );
    try ctx.session.usage.applyGeneration(alloc, .{
        .id = generation_id,
        .created_at_ms = 1,
        .model = "provider/model",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 0,
    });
    var pending = try ctx.session.usage.snapshot(alloc);
    defer pending.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), pending.pending.len);
    try std.testing.expectEqual(@as(usize, 1), pending.publication_backlog.len);

    publication.allow_generation = true;
    ctx.deinit();
    ctx_live = false;
    try std.testing.expectEqual(@as(usize, 1), publication.successful_generations);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var resumed = try store.resumeTargetForWrite(
        alloc,
        .last,
        workspace,
        .{},
    );
    defer resumed.deinit(alloc);
    const usage = resumed.state.usage orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(session_usage.Availability.complete, usage.billing);
    try std.testing.expectEqual(@as(usize, 0), usage.pending.len);
    try std.testing.expectEqual(@as(usize, 0), usage.publication_backlog.len);
    try std.testing.expectEqual(@as(u64, 10), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), usage.output_tokens);
}

test "saved ask ignores existing legacy task files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    const session_id = "saved-ask-task-route-failure";
    var state = try testAskDurableState(alloc, workspace, session_id);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    const session_dir = try session_store.sessionDirPath(
        alloc,
        store.sessions_dir,
        session_id,
    );
    defer alloc.free(session_dir);
    const tasks_path = try std.fs.path.join(alloc, &.{ session_dir, "tasks" });
    defer alloc.free(tasks_path);
    var tasks_file = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        tasks_path,
        .{
            .truncate = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        },
    );
    tasks_file.close(io_mod.getIo());

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        workspace,
    );
    defer ctx.deinit();
    ctx.requested_resume = .{ .id = session_id };

    try ctx.initializeSessionStores();
    try std.testing.expect(ctx.writable != null);
    try std.testing.expect(ctx.subagent_host != null);
    try std.testing.expect(ctx.background.persisted_store != null);
}

test "saved ask carries live workspace background records into fresh session runtime" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "logs");

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "logs/dev.log", .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "ready on http://localhost:48765\n");
    }
    const log_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "logs/dev.log");
    defer alloc.free(log_path);

    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var previous_state = try testAskDurableState(
        alloc,
        workspace,
        "saved-ask-prior",
    );
    defer previous_state.deinit(alloc);
    var previous = try store.startWritableSession(alloc, previous_state);
    var previous_owned = true;
    defer if (previous_owned) previous.deinit(alloc);
    var previous_bg_store = background_store.Store.initManaged(
        try previous.childCapability(),
    );

    const Stub = struct {
        fn match(
            pid_text: []const u8,
            _: process_supervisor.ProcessInstanceToken,
        ) process_supervisor.TokenMatch {
            return if (std.mem.eql(u8, pid_text, "12345"))
                .matched
            else
                .missing;
        }
    };
    process_supervisor.process_token_match_for_test = Stub.match;
    defer process_supervisor.process_token_match_for_test = null;
    const pid_text = "12345";
    const process_token = try process_supervisor.ProcessInstanceToken.parse(
        "linux:00112233445566778899aabbccddeeff:12345",
    );
    const stable_id = background_store.StableBackgroundRecordId{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };
    try previous_bg_store.saveRecord(alloc, .{
        .id = 1,
        .background_record_id = stable_id,
        .process_token = @constCast(process_token.view()),
        .pid = @constCast(pid_text),
        .command = @constCast("npm run dev"),
        .cwd = @constCast(workspace),
        .log_path = @constCast(log_path),
        .log_storage = .{ .external = .{
            .path = @constCast(log_path),
        } },
        .expect_url = true,
        .started_at_ms = 1,
        .updated_at_ms = 1,
        .state = .running,
    });
    previous.deinit(alloc);
    previous_owned = false;

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var cfg = testConfig();
    cfg.background_process_provider =
        background_process_provider.process_supervisor_test_provider;
    var ctx = AskContext.init(alloc, cfg, testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), workspace);
    defer ctx.deinit();
    ctx.session.setConversationLanguageFromUserMessage("start a background command");

    try ctx.initializeSessionStores();

    var tasks = try ctx.background.snapshotTasks(alloc);
    defer tasks.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), tasks.items.len);
    try std.testing.expectEqualStrings("npm run dev", tasks.items[0].command);
    try std.testing.expectEqualStrings(workspace, tasks.items[0].cwd);
    try std.testing.expectEqualStrings(log_path, tasks.items[0].log_path);
    try std.testing.expectEqual(background_runtime.TaskState.running, tasks.items[0].state);
    try std.testing.expectEqualStrings("http://localhost:48765", tasks.items[0].server_url.?);

    const current_dir = try session_store.sessionDirPath(
        alloc,
        store.sessions_dir,
        ctx.writable.?.active_id,
    );
    defer alloc.free(current_dir);
    const current_bg_dir = try std.fs.path.join(alloc, &.{ current_dir, "background" });
    defer alloc.free(current_bg_dir);
    var current_bg_store = try background_store.Store.initWithDir(alloc, current_bg_dir);
    defer current_bg_store.deinit(alloc);
    var carried = try current_bg_store.list(alloc);
    defer {
        for (carried.items) |*record| record.deinit(alloc);
        carried.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 0), carried.items.len);
}

test "saved ask leaves unattached source background records unchanged" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "logs");

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "logs/dead.log", .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "server started once\n");
    }
    const log_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "logs/dead.log");
    defer alloc.free(log_path);

    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var previous_state = try testAskDurableState(
        alloc,
        workspace,
        "saved-ask-unattached-prior",
    );
    defer previous_state.deinit(alloc);
    var previous = try store.startWritableSession(alloc, previous_state);
    var previous_bg_store = background_store.Store.initManaged(
        try previous.childCapability(),
    );

    const stable_id = background_store.StableBackgroundRecordId{
        0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
        0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00,
    };
    try previous_bg_store.saveRecord(alloc, .{
        .id = 1,
        .background_record_id = stable_id,
        .process_token = @constCast(
            "linux:00112233445566778899aabbccddeeff:12345",
        ),
        .pid = @constCast("not-a-pid"),
        .command = @constCast("npm run dev"),
        .cwd = @constCast(workspace),
        .log_path = @constCast(log_path),
        .log_storage = .{ .external = .{
            .path = @constCast(log_path),
        } },
        .expect_url = true,
        .started_at_ms = 1,
        .updated_at_ms = 1,
        .state = .running,
    });
    previous.deinit(alloc);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), workspace);
    defer ctx.deinit();
    ctx.session.setConversationLanguageFromUserMessage("start a background command");

    try ctx.initializeSessionStores();

    var tasks = try ctx.background.snapshotTasks(alloc);
    defer tasks.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), tasks.items.len);

    var previous_read_capability = try store.openChildCapabilityReadOnly(
        alloc,
        previous_state.id,
    );
    defer previous_read_capability.deinit();
    var previous_read_store = background_store.Store.initManaged(
        &previous_read_capability,
    );
    var refreshed = try previous_read_store.load(alloc, 1);
    defer refreshed.deinit(alloc);
    try std.testing.expectEqual(
        background_runtime.TaskState.running,
        refreshed.state,
    );
    try std.testing.expect(refreshed.diagnostic == null);

    const current_dir = try session_store.sessionDirPath(
        alloc,
        store.sessions_dir,
        ctx.writable.?.active_id,
    );
    defer alloc.free(current_dir);
    const current_bg_dir = try std.fs.path.join(alloc, &.{ current_dir, "background" });
    defer alloc.free(current_bg_dir);
    var current_bg_store = try background_store.Store.initWithDir(alloc, current_bg_dir);
    defer current_bg_store.deinit(alloc);
    var carried = try current_bg_store.list(alloc);
    defer {
        for (carried.items) |*record| record.deinit(alloc);
        carried.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 0), carried.items.len);
}

test "parse options trims explicit stdin fallback" {
    var options = try parseOptionsWithStdin(std.testing.allocator, &.{}, .{ .bytes = " \n prompt from stdin \t" });
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("prompt from stdin", options.prompt);
}

test "parse options rejects model-unsafe prompt text from arguments and stdin" {
    try std.testing.expectError(
        error.InvalidPromptText,
        parseOptionsWithStdin(std.testing.allocator, &.{"bad\x00prompt"}, .tty),
    );
    try std.testing.expectError(
        error.InvalidPromptText,
        parseOptionsWithStdin(std.testing.allocator, &.{}, .{ .bytes = "bad\xffprompt" }),
    );
}

test "parse options preserves exact resume-id operands" {
    var options = try parseOptionsWithStdin(
        std.testing.allocator,
        &.{ "--resume-id", "last", "continue" },
        .tty,
    );
    defer options.deinit(std.testing.allocator);

    switch (options.resume_target.?) {
        .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("last", id),
    }
    try std.testing.expectEqualStrings("continue", options.prompt);
}

test "parse options requires an explicit saved session for recovery continuation" {
    var options = try parseOptionsWithStdin(
        std.testing.allocator,
        &.{ "--resume-id", "session.v3", "--continue-recovery" },
        .tty,
    );
    defer options.deinit(std.testing.allocator);

    try std.testing.expect(options.continue_recovery);
    try std.testing.expectEqual(@as(usize, 0), options.prompt.len);
    try std.testing.expectError(
        error.InvalidAskArgs,
        parseOptionsWithStdin(
            std.testing.allocator,
            &.{"--continue-recovery"},
            .tty,
        ),
    );
    try std.testing.expectError(
        error.InvalidAskArgs,
        parseOptionsWithStdin(
            std.testing.allocator,
            &.{ "--resume", "last", "--continue-recovery", "new prompt" },
            .tty,
        ),
    );
}

test "parse options rejects repeated resume targets and no-save resume" {
    try std.testing.expectError(
        error.InvalidAskArgs,
        parseOptionsWithStdin(
            std.testing.allocator,
            &.{ "--resume", "last", "--resume-id", "session.v3", "continue" },
            .tty,
        ),
    );
    try std.testing.expectError(
        error.NoSaveResumeConflict,
        parseOptionsWithStdin(
            std.testing.allocator,
            &.{ "--no-save", "--resume", "last", "continue" },
            .tty,
        ),
    );
    try std.testing.expectError(
        error.NoSaveResumeConflict,
        parseOptionsWithStdin(
            std.testing.allocator,
            &.{ "--resume-id", "session.v3", "--no-save", "continue" },
            .tty,
        ),
    );
}

test "render final JSON preserves shape escaping order and newline" {
    const alloc = std.testing.allocator;
    const tool_calls = try alloc.alloc(ToolCallRecord, 1);
    tool_calls[0] = .{
        .name = try alloc.dupe(u8, "read_file"),
        .status = try alloc.dupe(u8, "success"),
    };
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, "hello \"zig\"\n"),
        .model = try alloc.dupe(u8, "model-x"),
        .session_id = try alloc.dupe(u8, "123"),
        .tool_calls = tool_calls,
        .step_count = 2,
    };
    defer result.deinit(alloc);

    const json = try renderFinalJsonResult(alloc, result);
    defer alloc.free(json);

    try std.testing.expectEqualStrings(
        "{\"output\":\"hello \\\"zig\\\"\\n\",\"exit_code\":0,\"model\":\"model-x\",\"session_id\":\"123\",\"steps\":2,\"tool_calls\":[{\"name\":\"read_file\",\"status\":\"success\"}]}\n",
        json,
    );
}

test "render final JSON emits empty tool call array" {
    const alloc = std.testing.allocator;
    const result = PromptRunResult{
        .exit_code = 1,
        .assistant_output = try alloc.dupe(u8, ""),
    };
    defer result.deinit(alloc);

    const json = try renderFinalJsonResult(alloc, result);
    defer alloc.free(json);

    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"exit_code\":1,\"model\":\"\",\"session_id\":\"\",\"steps\":0,\"tool_calls\":[]}\n",
        json,
    );
}

test "render final JSON reports the successful recovery attempt" {
    const alloc = std.testing.allocator;
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, "recovered"),
        .recovery = .{
            .kind = .auto_recovered,
            .succeeded_attempt = 3,
            .attempt_limit = 10,
        },
    };
    defer result.deinit(alloc);

    const json = try renderFinalJsonResult(alloc, result);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const recovery = parsed.value.object.get("recovery").?.object;
    try std.testing.expectEqual(@as(i64, 3), recovery.get("attempt").?.integer);
    try std.testing.expectEqualStrings("recovered", recovery.get("state").?.string);
    try std.testing.expectEqualStrings(
        "✓ recovered · succeeded on attempt 3/10",
        recovery.get("message").?.string,
    );
    try std.testing.expect(std.mem.find(u8, recovery.get("message").?.string, "provider_error") == null);
}

test "render final JSON includes the latest terminal recovery diagnostic" {
    const alloc = std.testing.allocator;
    const result = PromptRunResult{
        .exit_code = 1,
        .assistant_output = try alloc.dupe(u8, ""),
        .recovery = .{
            .kind = .terminal_provider_error,
            .failed_attempt = 2,
            .attempt_limit = 2,
            .cause = .provider_unavailable,
            .diagnostic = types.ModelFailureDiagnostic.init(
                "HTTP 503 · no_available_providers: No providers are currently available",
            ),
        },
    };
    defer result.deinit(alloc);

    const json = try renderFinalJsonResult(alloc, result);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const recovery = parsed.value.object.get("recovery").?.object;
    try std.testing.expectEqualStrings("paused", recovery.get("state").?.string);
    try std.testing.expectEqualStrings(
        "⚠ Provider unavailable · HTTP 503 · no_available_providers: No providers are currently available · recovery paused after 2/2 attempts",
        recovery.get("message").?.string,
    );
}

test "cli json records built in web_search completion" {
    const alloc = std.testing.allocator;
    const records = try alloc.alloc(ToolCallRecord, 1);
    records[0] = .{
        .name = try alloc.dupe(u8, "web_search"),
        .status = try alloc.dupe(u8, "success"),
        .web_search_completion = .{ .searches = 3, .duration_ms = 42 },
    };
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, ""),
        .tool_calls = records,
    };
    defer result.deinit(alloc);

    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();
    const web_search = parsed.value.object.get("tool_calls").?.array.items[0].object.get("web_search").?.object;
    try std.testing.expectEqual(@as(i64, 3), web_search.get("searches").?.integer);
    try std.testing.expectEqual(@as(i64, 42), web_search.get("duration_ms").?.integer);
}

test "fx ask JSON captures HTTP 413 prompt-too-long blocker" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "hello" },
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptHttp413),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "fx ask: HTTP 413: provider payload rejected") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    const output = parsed.value.object.get("output").?.string;
    try std.testing.expect(std.mem.find(u8, output, "HTTP 413") != null);
    try std.testing.expect(std.mem.find(u8, output, "prompt_too_long=true") != null);
    try std.testing.expect(std.mem.find(u8, output, "Provider rejected the prompt as too large") != null);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
}

test "fx ask formats restricted-provider HTTP errors without raw JSON" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "hello" },
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptRestrictedProvider),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "fx ask: API access denied · HTTP 403 · Provider: wafer") != null);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "{\"error\"") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    const output = parsed.value.object.get("output").?.string;
    try std.testing.expect(std.mem.find(u8, output, "API access denied · HTTP 403 · Provider: wafer") != null);
    try std.testing.expect(std.mem.find(u8, output, "{\"error\"") == null);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
}

test "fx ask text and JSON share the selected auth failure facts" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "hello" },
        testConfig(),
        testPromptRunDepsWithProcess(&stdout_capture, &stderr_capture, testProcessQueuedPromptUnauthorized),
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings(
        "fx ask: AI_GATEWAY_API_KEY authentication failed · HTTP 401\n",
        stderr_capture.bytes.items,
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
    try std.testing.expectEqualStrings(
        "AI_GATEWAY_API_KEY authentication failed · HTTP 401\n",
        parsed.value.object.get("output").?.string,
    );
    const auth_failure = parsed.value.object.get("auth_failure").?.object;
    try std.testing.expectEqualStrings("AI_GATEWAY_API_KEY", auth_failure.get("source").?.string);
    try std.testing.expectEqualStrings("http_unauthorized", auth_failure.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 401), auth_failure.get("http_status").?.integer);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "secret-key") == null);
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "secret-key") == null);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "\x1b") == null);
}

test "saved API key 401 discards the fresh pristine session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeySavedStartup,
    );
    deps.process_queued_prompt = testProcessQueuedPromptUnauthorized;
    deps.initialize_session_stores = initializeSessionStoresDefault;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "hello" },
        testConfig(),
        deps,
    );
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        stdout_capture.bytes.items,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "",
        parsed.value.object.get("session_id").?.string,
    );
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("steps").?.integer);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("tool_calls").?.array.items.len);
    try std.testing.expect(parsed.value.object.get("auth_failure") != null);

    var store = try session_store.Store.initFromHome(alloc, home, "/tmp/fx-test");
    defer store.deinit(alloc);
    var sessions = try store.list(alloc);
    defer {
        for (sessions.items) |*summary| summary.deinit(alloc);
        sessions.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 0), sessions.items.len);
    try std.testing.expectError(
        error.NoSavedSessions,
        store.resumeTargetForWrite(alloc, .last, "/tmp/fx-test", .{}),
    );
}

test "saved failures retain ineligible session lifecycles" {
    const Case = struct {
        kind: enum { resumed, committed_history, tool_started, generic_failure },
        process: ProcessQueuedPromptFn,
        expected_history_len: usize,
        expected_steps: usize,
    };
    const cases = [_]Case{
        .{
            .kind = .resumed,
            .process = testProcessQueuedPromptUnauthorized,
            .expected_history_len = 0,
            .expected_steps = 0,
        },
        .{
            .kind = .committed_history,
            .process = testProcessQueuedPromptUnauthorizedThenHistory,
            .expected_history_len = 1,
            .expected_steps = 0,
        },
        .{
            .kind = .tool_started,
            .process = testProcessQueuedPromptToolThenUnauthorized,
            .expected_history_len = 0,
            .expected_steps = 1,
        },
        .{
            .kind = .generic_failure,
            .process = testProcessQueuedPromptHttp413,
            .expected_history_len = 0,
            .expected_steps = 0,
        },
    };

    const alloc = std.testing.allocator;
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        defer alloc.free(home);
        const test_home = try TestAskHome.install(alloc, home);
        defer test_home.deinit();

        if (case.kind == .resumed) {
            var seed_store = try session_store.Store.initFromHome(
                alloc,
                home,
                "/tmp/fx-test",
            );
            defer seed_store.deinit(alloc);
            var seed_state = try testAskDurableState(
                alloc,
                "/tmp/fx-test",
                "cli-protected-resume",
            );
            defer seed_state.deinit(alloc);
            var seed = try seed_store.startWritableSession(alloc, seed_state);
            seed.deinit(alloc);
        }

        var stdout_capture: TestCapture = .{};
        defer stdout_capture.deinit(alloc);
        var stderr_capture: TestCapture = .{};
        defer stderr_capture.deinit(alloc);
        var probe = DiscardProbe{ .disposition = .indeterminate };
        var deps = testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeySavedStartup,
        );
        deps.initialize_session_stores = initializeSessionStoresDefault;
        deps.process_queued_prompt = case.process;
        deps.discard_pristine_session_ctx = &probe;
        deps.discard_pristine_session = DiscardProbe.run;
        const args: []const [:0]const u8 = switch (case.kind) {
            .resumed => &.{ "--json", "--resume-id", "cli-protected-resume", "hello" },
            .committed_history, .tool_started, .generic_failure => &.{ "--json", "hello" },
        };

        const exit_code = try runWithDeps(alloc, args, testConfig(), deps);
        try std.testing.expectEqual(@as(u8, 1), exit_code);
        try std.testing.expectEqual(@as(usize, 0), probe.calls);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            alloc,
            stdout_capture.bytes.items,
            .{},
        );
        defer parsed.deinit();
        const session_id = parsed.value.object.get("session_id").?.string;
        try std.testing.expect(session_id.len > 0);
        try std.testing.expectEqual(
            @as(i64, @intCast(case.expected_steps)),
            parsed.value.object.get("steps").?.integer,
        );

        var store = try session_store.Store.initFromHome(
            alloc,
            home,
            "/tmp/fx-test",
        );
        defer store.deinit(alloc);
        var loaded = try store.loadReadOnly(alloc, session_id);
        defer loaded.deinit(alloc);
        try std.testing.expectEqual(case.expected_history_len, loaded.history.len);
    }
}

test "saved auth fact followed by a prompt error retains the session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var probe = DiscardProbe{ .disposition = .discarded };
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeySavedStartup,
    );
    deps.initialize_session_stores = initializeSessionStoresDefault;
    deps.process_queued_prompt = testProcessQueuedPromptUnauthorizedThenError;
    deps.discard_pristine_session_ctx = &probe;
    deps.discard_pristine_session = DiscardProbe.run;

    try std.testing.expectError(
        error.InjectedPromptFailure,
        runWithDeps(alloc, &.{"hello"}, testConfig(), deps),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    var store = try session_store.Store.initFromHome(alloc, home, "/tmp/fx-test");
    defer store.deinit(alloc);
    var sessions = try store.list(alloc);
    defer {
        for (sessions.items) |*summary| summary.deinit(alloc);
        sessions.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), sessions.items.len);
}

test "indeterminate saved auth cleanup keeps the primary result and session id" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var probe = DiscardProbe{ .disposition = .indeterminate };
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeySavedStartup,
    );
    deps.initialize_session_stores = initializeSessionStoresDefault;
    deps.process_queued_prompt = testProcessQueuedPromptUnauthorized;
    deps.discard_pristine_session_ctx = &probe;
    deps.discard_pristine_session = DiscardProbe.run;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "hello" },
        testConfig(),
        deps,
    );
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.borrowers_detached);
    try std.testing.expectEqualStrings(
        "fx ask: AI_GATEWAY_API_KEY authentication failed · HTTP 401\n",
        stderr_capture.bytes.items,
    );
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        stdout_capture.bytes.items,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("error") == null);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
    try std.testing.expectEqualStrings(
        "AI_GATEWAY_API_KEY authentication failed · HTTP 401\n",
        parsed.value.object.get("output").?.string,
    );
    const session_id = parsed.value.object.get("session_id").?.string;
    try std.testing.expect(session_id.len > 0);

    var store = try session_store.Store.initFromHome(alloc, home, "/tmp/fx-test");
    defer store.deinit(alloc);
    var loaded = try store.loadReadOnly(alloc, session_id);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.history.len);
}

test "fx ask JSON records permission-denied tool calls as error status" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(alloc, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup), root);
    defer ctx.deinit();
    ctx.output_mode = .json;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try recordToolCallRejected(@ptrCast(&ctx), arena, .{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf secret\"}",
    }, "{\"error\":{\"type\":\"tool_permission_denied\"}}", "{\"kind\":\"foreground\"}");

    try std.testing.expectEqual(@as(usize, 1), ctx.tool_call_records.items.len);
    try std.testing.expectEqualStrings("terminal", ctx.tool_call_records.items[0].name);
    try std.testing.expectEqualStrings("error", ctx.tool_call_records.items[0].status);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"foreground\"}",
        ctx.tool_call_records.items[0].command_result_json.?,
    );
}

test "fx ask JSON permission-denied capture is best effort under allocation failure" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var ctx = AskContext.init(
        failing.allocator(),
        testConfig(),
        .{
            .context_registry = test_no_context_registry,
            .tool_set = builtin_tools.advertisement_set,
            .load_mcp_runtime = testNoMcpRuntime,
        },
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .json;

    try recordToolCallRejected(@ptrCast(&ctx), std.testing.allocator, .{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf secret\"}",
    }, "{\"error\":{\"type\":\"tool_permission_denied\"}}", null);

    try std.testing.expectEqual(@as(usize, 0), ctx.tool_call_records.items.len);
}

test "fx ask JSON captures parallel tool results without corrupting records" {
    const alloc = std.heap.c_allocator;
    const thread_count = 16;
    const calls_per_thread = 256;
    const expected_count = thread_count * calls_per_thread;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(root);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(std.testing.allocator);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(std.testing.allocator);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(
            &stdout_capture,
            &stderr_capture,
            testPresentKeyStartup,
        ),
        root,
    );
    defer ctx.deinit();
    ctx.output_mode = .json;
    try ctx.tool_call_records.ensureTotalCapacity(alloc, expected_count);

    const CaptureWorker = struct {
        ctx: *AskContext,
        ready: *std.atomic.Value(usize),
        start: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (!self.start.load(.seq_cst)) {
                std.atomic.spinLoopHint();
            }

            for (0..calls_per_thread) |_| {
                var arena_state = std.heap.ArenaAllocator.init(alloc);
                const arena = arena_state.allocator();
                _ = executeToolCallAuthorized(@ptrCast(self.ctx), .{
                    .call_allocator = arena,
                    .result_allocator = arena,
                    .call = .{
                        .id = "parallel-capture",
                        .name = "list_files",
                        .arguments_json = "{}",
                    },
                    .authority = .ordinary,
                    .session_grants = &.{},
                    .advertised_dynamic_tool_names = &.{},
                    .max_tool_result_bytes = 4096,
                }) catch {
                    self.failed.store(true, .seq_cst);
                    arena_state.deinit();
                    return;
                };
                arena_state.deinit();
            }
        }
    };

    var ready = std.atomic.Value(usize).init(0);
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, CaptureWorker.run, .{CaptureWorker{
            .ctx = &ctx,
            .ready = &ready,
            .start = &start,
            .failed = &failed,
        }});
    }
    while (ready.load(.seq_cst) != thread_count) {
        std.atomic.spinLoopHint();
    }
    start.store(true, .seq_cst);
    for (threads) |thread| thread.join();

    try std.testing.expect(!failed.load(.seq_cst));
    try std.testing.expectEqual(expected_count, ctx.tool_call_records.items.len);
    for (ctx.tool_call_records.items) |record| {
        try std.testing.expectEqualStrings("list_files", record.name);
        try std.testing.expectEqualStrings("success", record.status);
    }
}

fn checkAskJsonCaptureAllocationFailures(alloc: Allocator) !void {
    var ctx = AskContext.init(alloc, testConfig(), .{
        .context_registry = test_no_context_registry,
        .tool_set = builtin_tools.advertisement_set,
        .load_mcp_runtime = testNoMcpRuntime,
    }, "/tmp/workspace");
    defer ctx.deinit();
    ctx.output_mode = .json;
    try ctx.assistant_output.appendSlice(alloc, "assistant");

    try appendToolCallRecord(
        &ctx,
        .{
            .id = "capture",
            .name = "ask_user_question",
            .arguments_json = "{\"questions\":[{\"question\":\"Continue?\"}]}",
        },
        "success",
        .{
            .model_output = "contents",
            .command_result_json = "{\"ok\":true}",
        },
    );

    const result = try takePromptRunResult(&ctx, alloc);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("assistant", result.assistant_output);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings(
        "ask_user_question",
        result.tool_calls[0].name,
    );
    try std.testing.expectEqualStrings("success", result.tool_calls[0].status);
    try std.testing.expectEqualStrings(
        "{\"ok\":true}",
        result.tool_calls[0].command_result_json.?,
    );
    try std.testing.expectEqualStrings(
        "Continue?",
        result.tool_calls[0].ask_question_text.?,
    );
}

test "fx ask JSON capture cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAskJsonCaptureAllocationFailures,
        .{},
    );
}

test "fx ask JSON records ask_user_question text for matching assertions" {
    const alloc = std.testing.allocator;
    const records = try alloc.alloc(ToolCallRecord, 1);
    records[0] = .{
        .name = try alloc.dupe(u8, "ask_user_question"),
        .status = try alloc.dupe(u8, "success"),
        .ask_question_text = try alloc.dupe(u8, "What is your GitHub handle?"),
    };
    const result = PromptRunResult{
        .exit_code = 0,
        .assistant_output = try alloc.dupe(u8, ""),
        .tool_calls = records,
    };
    defer result.deinit(alloc);

    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();
    const tool_call = parsed.value.object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("ask_user_question", tool_call.get("name").?.string);
    try std.testing.expectEqualStrings("What is your GitHub handle?", tool_call.get("question").?.string);
}

test "fx ask JSON clips ask_user_question text at a UTF-8 boundary" {
    const alloc = std.testing.allocator;
    var question_bytes: [257]u8 = undefined;
    @memset(question_bytes[0..255], 'a');
    question_bytes[255] = 0xc3;
    question_bytes[256] = 0xa9;
    const arguments_json = try std.fmt.allocPrint(
        alloc,
        "{{\"questions\":[{{\"question\":\"{s}\"}}]}}",
        .{question_bytes[0..]},
    );
    defer alloc.free(arguments_json);

    var ctx = AskContext.init(alloc, testConfig(), .{
        .context_registry = test_no_context_registry,
        .tool_set = builtin_tools.advertisement_set,
        .load_mcp_runtime = testNoMcpRuntime,
    }, "/tmp/workspace");
    defer ctx.deinit();
    ctx.output_mode = .json;
    try appendToolCallRecord(
        &ctx,
        .{
            .id = "question",
            .name = "ask_user_question",
            .arguments_json = arguments_json,
        },
        "success",
        null,
    );

    const result = try takePromptRunResult(&ctx, alloc);
    defer result.deinit(alloc);
    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();

    const question = parsed.value.object.get("tool_calls").?.array.items[0].object.get("question").?;
    try std.testing.expect(question == .string);
    if (question != .string) return error.TestUnexpectedResult;
    try std.testing.expect(std.unicode.utf8ValidateSlice(question.string));
    try std.testing.expectEqual(@as(usize, 255), question.string.len);
}

test "json run with missing API key prints diagnostic then final object" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const exit_code = try runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testMissingKeyStartup));

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("fx ask: " ++ credentials.missing_credential_message ++ "\n", stderr_capture.bytes.items);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"exit_code\":1,\"model\":\"\",\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"error\":\"MissingCredentials\"}\n",
        stdout_capture.bytes.items,
    );
}

test "recovery continuation checks local checkpoint before credentials" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const test_home = try TestAskHome.install(alloc, home);
    defer test_home.deinit();

    const session_id = "completed-session";
    var store = try session_store.Store.initFromHome(alloc, home, "/tmp/fx-test");
    defer store.deinit(alloc);
    var state = try testAskDurableState(alloc, "/tmp/fx-test", session_id);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    writable.deinit(alloc);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testMissingKeyStartup,
    );
    deps.initialize_session_stores = initializeSessionStoresDefault;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--resume-id", session_id, "--continue-recovery" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        stdout_capture.bytes.items,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "NoPendingRecovery",
        parsed.value.object.get("error").?.string,
    );
}

test "json run with session setup failure still emits final object" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.initialize_session_stores = testFailSessionStores;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--resume-id", "corrupt-session", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "\"exit_code\":1") != null);
    try std.testing.expect(std.mem.find(u8, stdout_capture.bytes.items, "\"error\":\"InvalidSessionFormat\"") != null);
}

test "missing API key returns before project context gathering" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    test_gather_project_context_calls = 0;
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testMissingKeyStartup);
    deps.context_registry = test_count_context_registry;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqual(@as(usize, 0), test_gather_project_context_calls);
}

test "fx ask emits one discovery warning when catalog truncation and a skill read report it" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    var deps = testPromptRunDeps(
        &stdout_capture,
        &stderr_capture,
        testPresentKeyTruncatedSkillCatalogStartup,
    );
    deps.load_skills = testLoadTruncatedSkillsWithDiagnostic;
    deps.process_queued_prompt = testProcessQueuedPromptRepeatsSkillDiagnostic;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, stderr_capture.bytes.items, "skill discovery warning:"),
    );
    try std.testing.expect(std.mem.find(u8, stderr_capture.bytes.items, "[context] skill catalog omitted 1 entries") != null);
}

test "fx ask carries resolved auto mode and initial registry context into the queued prompt" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    TestContextRegistryFixture.reset(test_registry_static_context, 1);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.context_registry = test_cli_context_registry;
    deps.process_queued_prompt = TestContextRegistryFixture.process;

    const exit_code = try runWithDeps(alloc, &.{ "--auto", "hello" }, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.gather_calls);
    try std.testing.expectEqual(
        PermissionMode.auto,
        TestContextRegistryFixture.transient_permission_mode orelse return error.TestExpectedEqual,
    );
}

test "default fx ask passes canonical image paths as initial context targets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "target.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
    }
    const image_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target.png");
    defer alloc.free(image_path);
    const image_path_z = try alloc.dupeZ(u8, image_path);
    defer alloc.free(image_path_z);

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    TestContextRegistryFixture.reset(test_registry_static_context, 1);
    TestContextRegistryFixture.expected_target_paths = &.{image_path};
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
    deps.context_registry = test_cli_context_registry;
    deps.process_queued_prompt = TestContextRegistryFixture.process;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--image", image_path_z, "describe" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.gather_calls);
    try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.process_calls);
    try std.testing.expect(TestContextRegistryFixture.targets_match);
}

test "default fx ask omits disabled registry context without gathering" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    TestContextRegistryFixture.reset(null, 0);
    var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyNoContextStartup);
    deps.context_registry = test_cli_context_registry;
    deps.process_queued_prompt = TestContextRegistryFixture.process;

    const exit_code = try runWithDeps(alloc, &.{"hello"}, testConfig(), deps);

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), TestContextRegistryFixture.gather_calls);
}

test "default fx ask preserves project context gathering error mappings" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const cases = [_]struct {
        err: context_contract.ProviderError,
        json: ?[]const u8,
    }{
        .{ .err = error.OutOfMemory, .json = null },
        .{ .err = error.NoSpaceLeft, .json = "{\"output\":\"\",\"exit_code\":1,\"model\":\"\",\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"error\":\"NoSpaceLeft\"}\n" },
        .{ .err = error.WriteFailed, .json = "{\"output\":\"\",\"exit_code\":1,\"model\":\"\",\"session_id\":\"\",\"steps\":0,\"tool_calls\":[],\"error\":\"WriteFailed\"}\n" },
    };

    for (cases) |case| {
        TestContextRegistryFixture.reset(null, 1);
        TestContextRegistryFixture.gather_error = case.err;
        var deps = testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup);
        deps.context_registry = test_cli_context_registry;
        deps.process_queued_prompt = TestContextRegistryFixture.process;

        try std.testing.expectError(case.err, runWithDeps(alloc, &.{"hello"}, testConfig(), deps));
        try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.gather_calls);
        try std.testing.expectEqual(@as(usize, 0), TestContextRegistryFixture.process_calls);
        try std.testing.expectEqual(@as(usize, 0), stdout_capture.bytes.items.len);
        try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);

        TestContextRegistryFixture.reset(null, 1);
        TestContextRegistryFixture.gather_error = case.err;
        if (case.json) |expected_json| {
            const exit_code = try runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), deps);
            try std.testing.expectEqual(@as(u8, 1), exit_code);
            try std.testing.expectEqualStrings(expected_json, stdout_capture.bytes.items);
        } else {
            try std.testing.expectError(
                case.err,
                runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), deps),
            );
            try std.testing.expectEqual(@as(usize, 0), stdout_capture.bytes.items.len);
        }
        try std.testing.expectEqual(@as(usize, 1), TestContextRegistryFixture.gather_calls);
        try std.testing.expectEqual(@as(usize, 0), TestContextRegistryFixture.process_calls);
        try std.testing.expectEqual(@as(usize, 0), stderr_capture.bytes.items.len);
        stdout_capture.bytes.clearRetainingCapacity();
        stderr_capture.bytes.clearRetainingCapacity();
    }
}

test "quiet suppresses streaming while quiet json captures final output" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);

    const quiet_exit = try runWithDeps(alloc, &.{ "--quiet", "hello" }, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup));
    try std.testing.expectEqual(@as(u8, 0), quiet_exit);
    try std.testing.expectEqualStrings("", stdout_capture.bytes.items);

    stdout_capture.bytes.clearRetainingCapacity();
    stderr_capture.bytes.clearRetainingCapacity();

    const json_exit = try runWithDeps(alloc, &.{ "--quiet", "--json", "hello" }, testConfig(), testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup));
    try std.testing.expectEqual(@as(u8, 0), json_exit);
    try std.testing.expect(std.mem.startsWith(u8, stdout_capture.bytes.items, "{\"output\":\"assistant text\",\"exit_code\":0,\"model\":\"model\",\"session_id\":\""));
    try std.testing.expect(std.mem.endsWith(u8, stdout_capture.bytes.items, "\",\"steps\":0,\"tool_calls\":[]}\n"));
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "fx ask JSON recovery keeps stdout structured and reports progress on stderr" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    const deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptRecoveryLifecycle,
    );

    const exit_code = try runWithDeps(alloc, &.{ "--json", "hello" }, testConfig(), deps);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("assistant text", parsed.value.object.get("output").?.string);
    try std.testing.expect(parsed.value.object.get("recovery") == null);
    try std.testing.expectEqualStrings(
        "[notice] ⚠ Network interrupted · waiting for connection · attempt 1/10\n",
        stderr_capture.bytes.items,
    );
}

test "fx ask JSON preserves partial output on prompt failure" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptPartialThenReadFailed,
    );
    deps.stdout_is_tty = TestTty.no;

    const exit_code = try runWithDeps(
        alloc,
        &.{ "--json", "--no-save", "hello" },
        testConfig(),
        deps,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, stdout_capture.bytes.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("partial résumé", parsed.value.object.get("output").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("exit_code").?.integer);
    try std.testing.expectEqualStrings("ReadFailed", parsed.value.object.get("error").?.string);
    try std.testing.expectEqualStrings("model", parsed.value.object.get("model").?.string);
    try std.testing.expectEqualStrings("", parsed.value.object.get("session_id").?.string);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("tool_calls").?.array.items.len);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "fx ask raw output still propagates prompt failure" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var deps = testPromptRunDepsWithProcess(
        &stdout_capture,
        &stderr_capture,
        testProcessQueuedPromptPartialThenReadFailed,
    );
    deps.stdout_is_tty = TestTty.no;

    try std.testing.expectError(
        error.ReadFailed,
        runWithDeps(alloc, &.{ "--no-save", "hello" }, testConfig(), deps),
    );
    try std.testing.expectEqualStrings("partial résumé", stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
}

test "CLI tagged stream routes source output rendering and diagnostics by mode" {
    const alloc = std.testing.allocator;
    const source_spans = [_][]const u8{
        "# Heading\n",
        "\n**bold** [docs](https://example.com)\n",
    };
    const source_output = "# Heading\n\n**bold** [docs](https://example.com)\n";
    const rendered_span = "\x1b[1mbold\x1b[22m\n";

    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .raw;

    const deps = agentRuntimeDeps(&ctx);
    try deps.push_text(deps.ctx, .{ .assistant_rendered = rendered_span });
    for (source_spans) |span| try deps.push_text(deps.ctx, .{ .assistant_source = span });

    try std.testing.expectEqualStrings(source_output, stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("", stderr_capture.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ctx.assistant_output.items.len);

    try deps.push_tool_lifecycle(deps.ctx, .{
        .authoritative_started = .{
            .id = .{ .turn_id = 1, .call_id = "read_1" },
            .reconciles_provisional_call_id = null,
            .tool_name = "read_file",
            .activity_kind = .read,
        },
    });
    try std.testing.expectEqual(@as(usize, 1), ctx.step_count);
    try deps.push_tool_lifecycle(deps.ctx, .{
        .progress = .{
            .id = .{ .turn_id = 1, .call_id = "read_1" },
            .text = "Reading src/main.zig",
        },
    });
    try std.testing.expectEqualStrings("Reading src/main.zig\n", stderr_capture.bytes.items);
    try deps.push_text(deps.ctx, .{ .assistant_source = "after **tool**\n" });
    try deps.push_text(deps.ctx, .{ .operational = "diagnostic\n" });

    try std.testing.expectEqualStrings(
        source_output ++ "\nafter **tool**\n",
        stdout_capture.bytes.items,
    );
    try std.testing.expectEqualStrings(
        "Reading src/main.zig\ndiagnostic\n",
        stderr_capture.bytes.items,
    );
    try std.testing.expectEqual(@as(usize, 1), ctx.step_count);
    try std.testing.expectEqual(@as(usize, 0), ctx.assistant_output.items.len);

    var json_stdout_capture: TestCapture = .{};
    defer json_stdout_capture.deinit(alloc);
    var json_stderr_capture: TestCapture = .{};
    defer json_stderr_capture.deinit(alloc);
    var json_ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&json_stdout_capture, &json_stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer json_ctx.deinit();
    json_ctx.output_mode = .json;

    const json_deps = agentRuntimeDeps(&json_ctx);
    try json_deps.push_text(json_deps.ctx, .{ .assistant_rendered = rendered_span });
    for (source_spans) |span| try json_deps.push_text(json_deps.ctx, .{ .assistant_source = span });
    try json_deps.push_text(json_deps.ctx, .{ .operational = "diagnostic\n" });

    try std.testing.expectEqualStrings(source_output, json_ctx.assistant_output.items);
    try std.testing.expectEqualStrings("", json_stdout_capture.bytes.items);
    try std.testing.expectEqualStrings("diagnostic\n", json_stderr_capture.bytes.items);

    const result = try takePromptRunResult(&json_ctx, alloc);
    defer result.deinit(alloc);
    const rendered = try renderFinalJsonResult(alloc, result);
    defer alloc.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, rendered, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(source_output, parsed.value.object.get("output").?.string);
}

test "CLI command output completion terminates only an open display line" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .json;

    try onCommandOutputChunk(&ctx, null, .stdout, "no-final");
    try pushCommandOutputComplete(&ctx, null);
    try std.testing.expectEqualStrings("no-final\n", stderr_capture.bytes.items);

    try onCommandOutputChunk(&ctx, null, .stdout, "with-final\n");
    try pushCommandOutputComplete(&ctx, null);
    try pushCommandOutputComplete(&ctx, null);
    try std.testing.expectEqualStrings(
        "no-final\nwith-final\n",
        stderr_capture.bytes.items,
    );
}

test "CLI nonterminal progress preserves distinct deferred labels without duplicates" {
    const alloc = std.testing.allocator;
    var stdout_capture: TestCapture = .{};
    defer stdout_capture.deinit(alloc);
    var stderr_capture: TestCapture = .{};
    defer stderr_capture.deinit(alloc);
    var ctx = AskContext.init(
        alloc,
        testConfig(),
        testPromptRunDeps(&stdout_capture, &stderr_capture, testPresentKeyStartup),
        "/tmp/workspace",
    );
    defer ctx.deinit();
    ctx.output_mode = .raw;

    const deps = agentRuntimeDeps(&ctx);
    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 1, .call_id = "deferred_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 1, .call_id = "deferred_write" },
        .text = "Writing file",
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .terminal = .{
        .id = .{ .turn_id = 1, .call_id = "deferred_write" },
        .outcome = .{ .kind = .deferred, .summary = "Context updated: Writing file" },
    } });
    try std.testing.expectEqualStrings("Writing file\n", stderr_capture.bytes.items);

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 2, .call_id = "retry_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 2, .call_id = "retry_write" },
        .text = "Writing file",
    } });
    try std.testing.expectEqualStrings("Writing file\n", stderr_capture.bytes.items);
    try deps.push_tool_lifecycle(deps.ctx, .{ .terminal = .{
        .id = .{ .turn_id = 2, .call_id = "retry_write" },
        .outcome = .{ .kind = .deferred, .summary = "Context updated: Writing file" },
    } });

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 3, .call_id = "final_retry_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 3, .call_id = "final_retry_write" },
        .text = "Writing file",
    } });
    try std.testing.expectEqualStrings("Writing file\n", stderr_capture.bytes.items);

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 4, .call_id = "resolved_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 4, .call_id = "resolved_write" },
        .text = "Writing build/pkg/proof.txt",
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\n",
        stderr_capture.bytes.items,
    );

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 5, .call_id = "invalid_fetch" },
        .reconciles_provisional_call_id = null,
        .tool_name = "web_fetch",
        .activity_kind = .read,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 5, .call_id = "invalid_fetch" },
        .text = "Fetching",
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\n",
        stderr_capture.bytes.items,
    );

    try deps.push_tool_lifecycle(deps.ctx, .{ .provisional = .{
        .id = .{ .turn_id = 6, .call_id = "streamed_read" },
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 6, .call_id = "streamed_read" },
        .text = "Reading streamed input",
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\nReading streamed input\n",
        stderr_capture.bytes.items,
    );

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 7, .call_id = "legacy_deferred_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 7, .call_id = "legacy_deferred_write" },
        .text = "Writing legacy file",
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .terminal = .{
        .id = .{ .turn_id = 7, .call_id = "legacy_deferred_write" },
        .outcome = .{ .kind = .denied, .summary = "Not executed: Writing legacy file" },
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\nReading streamed input\nWriting legacy file\n",
        stderr_capture.bytes.items,
    );

    try deps.push_tool_lifecycle(deps.ctx, .{ .authoritative_started = .{
        .id = .{ .turn_id = 8, .call_id = "legacy_retry_write" },
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    try deps.push_tool_lifecycle(deps.ctx, .{ .progress = .{
        .id = .{ .turn_id = 8, .call_id = "legacy_retry_write" },
        .text = "Writing legacy file",
    } });
    try std.testing.expectEqualStrings(
        "Writing file\nWriting build/pkg/proof.txt\nReading streamed input\nWriting legacy file\n",
        stderr_capture.bytes.items,
    );
}

test "CLI output mode selection preserves machine output precedence" {
    try std.testing.expectEqual(OutputMode.json, selectOutputMode(true, true, true, true));
    try std.testing.expectEqual(OutputMode.quiet, selectOutputMode(true, false, true, false));
    try std.testing.expectEqual(OutputMode.raw, selectOutputMode(false, false, false, true));
    try std.testing.expectEqual(OutputMode.terminal, selectOutputMode(false, false, true, false));
    try std.testing.expectEqual(OutputMode.terminal_no_color, selectOutputMode(false, false, true, true));
}

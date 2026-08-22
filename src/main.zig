const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const io_mod = @import("core/shared/io.zig");

pub const version = "0.0.5";

const app_lifecycle = @import("core/app/app_lifecycle.zig");
const provider_runtime = @import("core/app/provider_runtime.zig");
const auth_runtime = @import("core/auth/auth_runtime.zig");
const api_key_validator = @import("core/auth/api_key_validator.zig");
const oauth_transport = @import("core/auth/oauth_transport.zig");
const js_host_auth = @import("core/auth/js_host_auth.zig");
const credentials = @import("core/auth/credentials.zig");
const secret = @import("core/auth/secret.zig");
const model_cache_runtime = @import("core/app/model_cache_runtime.zig");
const app_auth_runtime = @import("core/app/app_auth_runtime.zig");
const app_host_config_runtime = @import("core/app/app_host_config_runtime.zig");
const app_entry_runtime = @import("core/app/app_entry_runtime.zig");
const acp_runner = @import("core/cli/acp_runner.zig");
const acp_server = @import("acp/server.zig");
const acp_turn_runner = @import("core/acp_client/turn_runner.zig");
const app_input_runtime = @import("core/app/app_input_runtime.zig");
const core_input_runtime = @import("core/input/runtime.zig");
const input_queue_runtime = @import("core/app/input_queue_runtime.zig");
const app_bootstrap_runtime = @import("core/app/app_bootstrap_runtime.zig");
const app_notification_runtime = @import("core/app/app_notification_runtime.zig");
const app_permission_runtime = @import("core/app/app_permission_runtime.zig");
const app_process_runtime = @import("core/app/app_process_runtime.zig");
const prompt_history_runtime = @import("core/app/prompt_history_runtime.zig");
const app_agent_runtime = @import("core/app/app_agent_runtime.zig");
const app_runtime_setup = @import("core/app/app_runtime_setup.zig");
const app_render_runtime = @import("core/app/app_render_runtime.zig");
const app_session_runtime = @import("core/app/app_session_runtime.zig");
const app_upgrade_runtime = @import("core/app/app_upgrade_runtime.zig");
const app_worker_runtime = @import("core/app/app_worker_runtime.zig");
const app_workspace_runtime = @import("core/app/app_workspace_runtime.zig");
const app_callbacks = @import("core/app/app_callbacks.zig");
const app_commands = @import("core/app/app_commands.zig");
const change_tracker_mod = @import("core/workspace/change_tracker.zig");
const context_contract = @import("core/workspace/context_contract.zig");
const statusline_identity = @import("core/workspace/statusline_identity.zig");
const collections = @import("core/shared/collections.zig");
const agent_steps = @import("core/config/agent_steps.zig");
const config_runtime = @import("core/config/config_runtime.zig");
const model_provider = @import("core/config/model_provider.zig");
const js_host_prompt_history = @import("core/session/js_host_prompt_history.zig");
const model_capabilities = @import("core/config/model_capabilities.zig");
const prompt_policy = @import("core/config/prompt_policy.zig");
const builtin_commands = @import("builtins/commands.zig");
const command_specs = @import("core/slash_commands/command_specs.zig");
const builtin_context = @import("builtins/context.zig");
const builtin_gateway = @import("builtins/gateway.zig");
const builtin_providers = @import("builtins/providers.zig");
const openai_codex_models = @import("gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("gateway/openai_codex_permission_reviewer.zig");
const xai_grok_models = @import("gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("gateway/xai_grok_permission_reviewer.zig");
const gateway_provider = @import("core/gateway/gateway_provider.zig");
const model_catalog = @import("core/gateway/model_catalog.zig");
const generation_usage_provider = @import("core/session/generation_usage_provider.zig");
const agent_stream_provider = @import("core/agent/stream_provider.zig");
const builtin_hooks = @import("builtins/hooks.zig");
const builtin_mcp = @import("builtins/mcp.zig");
const builtin_modes = @import("builtins/modes.zig");
const builtin_skills = @import("builtins/skills.zig");
const host = @import("core/hosts/host.zig");
const host_runtime_profile = @import("core/hosts/runtime_profile.zig");
const js_host_url_opener = @import("core/hosts/js_host_url_opener.zig");
const js_host_workspace = @import("core/hosts/js_host_workspace.zig");
const host_target = @import("core/hosts/target.zig");
const native_host = @import("core/hosts/native.zig");
const debug_trace = @import("core/shared/debug_trace.zig");
const display_width = @import("core/shared/display_width.zig");
const file_index_mod = @import("core/workspace/file_index.zig");
const mcp_command_provider = @import("core/mcp/command_provider.zig");
const mcp_runtime_mod = @import("core/mcp/mcp_runtime.zig");
const mcp_model_catalog = @import("core/mcp/model_catalog.zig");
const mcp_access_policy = @import("core/mcp/access_policy.zig");
const app_mcp_runtime = @import("core/app/app_mcp_runtime.zig");
const skill_commands = @import("core/skills/skill_commands.zig");
const skill_runtime = @import("core/skills/skill_runtime.zig");
const cli_surface = @import("core/cli/cli_surface.zig");
const hooks = @import("core/hooks/hooks.zig");
const github_publish = @import("core/github/github_publish.zig");
const subagent_domain = @import("core/subagent/domain.zig");
const subagent_execution = @import("core/subagent/execution.zig");
const subagent_agent_adapter = @import("core/subagent/agent_adapter.zig");
const types = @import("core/shared/types.zig");
const image_attachments = @import("core/images/image_attachments.zig");
const permissions = @import("core/permissions/permissions.zig");
const command_runner = @import("core/execution/command_runner.zig");
const command_admission = @import("core/permissions/command_admission.zig");
const permission_auto_classifier = @import("core/permissions/auto_classifier.zig");
const auto_classifier_context = @import("core/permissions/auto_classifier_context.zig");
const agent_runtime = @import("core/agent/agent_runtime.zig");
const assistant_presentation = @import("core/agent/assistant_presentation.zig");
const auto_upgrade = @import("core/upgrade/auto_upgrade.zig");
const update_target = @import("core/upgrade/update_target.zig");

const compiled_update_channel = update_target.Channel.parse(build_options.update_channel) orelse
    @compileError("invalid compiled update channel");
const background_runtime = @import("core/background/background_runtime.zig");
const background_process_provider = @import(
    "core/execution/background_process_provider.zig",
);
const background_process = @import("tools/shell/background_process.zig");
const process_supervisor = @import("core/background/process_supervisor.zig");
const terminal_client_runtime = @import("core/terminal/client.zig");
const terminal_direct_runtime = @import("core/terminal/direct_runtime.zig");
const app_terminal_runtime = @import("core/app/app_terminal_runtime.zig");
const app_terminal_takeover_runtime = @import("core/app/app_terminal_takeover_runtime.zig");
const terminal_host = @import("core/terminal/host.zig");
const terminal_native_session = @import("core/terminal/native_session.zig");
const terminal_tmux_session = @import("core/terminal/tmux_session.zig");
const session_runtime = @import("core/session/session.zig");
const session_codec = @import("core/session/session_codec.zig");
const session_child_store = @import("core/session/session_child_store.zig");
const session_log = @import("core/session/session_log.zig");
const builtin_tools = @import("builtins/tools.zig");
const browser_workspace_tools = @import("builtins/browser_workspace_tools.zig");
const tool_admission = @import("core/tooling/tool_admission.zig");
const tool_advertisement = @import("core/tooling/tool_advertisement.zig");
const command_output_content = @import("core/tooling/command_output_content.zig");
const tool_dispatch = @import("core/tooling/tool_dispatch.zig");
const tool_set_contract = @import("core/tooling/tool_set.zig");
const tool_mcp_runtime = @import("core/tooling/tool_mcp_runtime.zig");
const tool_runtime = @import("core/tooling/tool_runtime.zig");
const web_fetch_runtime = @import("core/tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("core/tooling/web_search_runtime.zig");
const worker_runtime = @import("core/agent/worker_runtime.zig");
const question_prompt = @import("core/agent/question_prompt.zig");
const gateway_client = @import("gateway/client.zig");
const js_host_stream_provider = @import("gateway/js_host_stream_provider.zig");
const js_host_model_catalog = @import("gateway/js_host_model_catalog.zig");
const url_opener = @import("core/hosts/url_opener.zig");
const event_loop = @import("ui/event_loop.zig");
const wasm_terminal = if (host_target.is_wasm) @import("ui/terminal/wasm_terminal.zig") else struct {};
const footer_runtime = @import("ui/footer/runtime.zig");
const question_ui = @import("ui/footer/question_ui.zig");
const ui_input = @import("ui/input/runtime.zig");
const input_action = @import("core/input/input_action.zig");
const paste_blocks = @import("core/input/pasted_blocks.zig");
const paste_framing = @import("core/input/paste_framing.zig");
const registered_entities = @import("core/input/registered_entities.zig");
const entity_spans = @import("core/shared/entity_spans.zig");
const ui_render = @import("ui/render.zig");
const shell_runtime = @import("ui/shell_runtime.zig");
const ui_terminal = @import("ui/terminal/terminal.zig");
const cursor_probe = @import("ui/terminal/cursor_probe.zig");
const ui_subagents = @import("ui/subagent/controller.zig");
const transcript_runtime = @import("ui/transcript/runtime.zig");
const resume_projection = @import("ui/transcript/resume_projection.zig");
const assistant_pacer = @import("ui/assistant/pacer.zig");
const approval_prompt = @import("core/permissions/approval_prompt.zig");

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const StreamState = types.StreamState;
const ToolCall = types.ToolCall;
const ChatMessage = types.ChatMessage;
const PermissionMode = types.PermissionMode;
const ReasoningEffort = types.ReasoningEffort;
const ToolPermissionDecision = types.ToolPermissionDecision;
const PermissionGrant = types.PermissionGrant;
const PermissionEngine = permissions.PermissionEngine;
const QueuedPrompt = worker_runtime.QueuedPrompt;
const WorkerRuntime = worker_runtime.WorkerRuntime;
const SessionRuntime = session_runtime.SessionRuntime;
const PromptHistoryRuntime = prompt_history_runtime.PromptHistoryRuntime;
const BackgroundRuntime = background_runtime.BackgroundRuntime;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const ApprovalPrompt = approval_prompt.ApprovalPrompt;
const ApprovalScreenState = footer_runtime.ApprovalScreenState;
const QuestionPrompt = question_prompt.QuestionPrompt;
const InputRuntime = core_input_runtime.Runtime;
const TerminalInputRuntime = ui_input.Runtime;
const TerminalState = shell_runtime.TerminalState;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const ResumeProjection = resume_projection.ResumeProjection;
const RawEnviron = io_mod.RawEnviron;

const RuntimeContextSnapshot = background_runtime.RuntimeContextSnapshot;

const footer_rows: u16 = 4;
const active_poll_timeout_ms: i32 = 8;
const idle_wasm_poll_timeout_ms: i32 = 16;
const resize_debounce_ms: i64 = 100;
const max_transcript_bytes: usize = 256 * 1024;
const default_max_agent_steps: usize = agent_steps.default_max_agent_steps;
const native_gateway_provider = builtin_gateway.provider;
const max_history_turns: usize = 8;
const max_list_entries: usize = 100;
const max_read_file_bytes: usize = 50 * 1024;
const max_read_file_lines: usize = 400;
const max_read_file_line_len: usize = 2000;
const max_command_output_bytes: usize = 64 * 1024;
const input_escape_timeout_ms: i64 = 30;
const max_prompt_history: usize = 100;

const ignored_list_entries = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    ".next",
    "dist",
    "build",
    "coverage",
};

fn dupeUniqueSkillBindingsFromTokens(
    alloc: Allocator,
    skill_tokens: []const registered_entities.SkillTokenSpan,
) ![]worker_runtime.SkillBinding {
    if (skill_tokens.len == 0) return &.{};

    var bindings: std.ArrayList(worker_runtime.SkillBinding) = .empty;
    errdefer {
        for (bindings.items) |binding| {
            alloc.free(binding.name);
            alloc.free(binding.path);
        }
        bindings.deinit(alloc);
    }

    for (skill_tokens) |token| {
        if (token.name.len == 0 or token.path.len == 0) continue;
        if (skillBindingPathSeen(bindings.items, token.path)) continue;

        const name_copy = try alloc.dupe(u8, token.name);
        var path_copy: []u8 = &.{};
        var appended = false;
        errdefer if (!appended) {
            alloc.free(name_copy);
            if (path_copy.len > 0) alloc.free(path_copy);
        };

        path_copy = try alloc.dupe(u8, token.path);
        try bindings.append(alloc, .{
            .name = name_copy,
            .path = path_copy,
        });
        appended = true;
    }

    if (bindings.items.len == 0) {
        bindings.deinit(alloc);
        return &.{};
    }
    return try bindings.toOwnedSlice(alloc);
}

fn skillBindingPathSeen(bindings: []const worker_runtime.SkillBinding, path: []const u8) bool {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.path, path)) return true;
    }
    return false;
}

fn dupeSkillDisplaySpansFromTokens(
    alloc: Allocator,
    skill_tokens: []const registered_entities.SkillTokenSpan,
) ![]worker_runtime.SkillDisplaySpan {
    if (skill_tokens.len == 0) return &.{};

    var spans: std.ArrayList(worker_runtime.SkillDisplaySpan) = .empty;
    errdefer {
        for (spans.items) |span| {
            alloc.free(span.name);
            alloc.free(span.path);
        }
        spans.deinit(alloc);
    }

    for (skill_tokens) |token| {
        if (token.name.len == 0 or token.path.len == 0) continue;

        const name_copy = try alloc.dupe(u8, token.name);
        var path_copy: []u8 = &.{};
        var appended = false;
        errdefer if (!appended) {
            alloc.free(name_copy);
            if (path_copy.len > 0) alloc.free(path_copy);
        };

        path_copy = try alloc.dupe(u8, token.path);
        try spans.append(alloc, .{
            .raw_start = token.raw_start,
            .raw_end = token.raw_end,
            .name = name_copy,
            .path = path_copy,
            .display_source = token.display_source,
            .owns_trailing_separator = token.owns_trailing_separator,
        });
        appended = true;
    }

    if (spans.items.len == 0) {
        spans.deinit(alloc);
        return &.{};
    }
    return try spans.toOwnedSlice(alloc);
}

fn promptCardSkillTokensFromDisplaySpans(
    alloc: Allocator,
    skill_display_spans: []const worker_runtime.SkillDisplaySpan,
) ![]registered_entities.SkillTokenSpan {
    if (skill_display_spans.len == 0) return &.{};
    const tokens = try alloc.alloc(registered_entities.SkillTokenSpan, skill_display_spans.len);
    errdefer alloc.free(tokens);
    for (skill_display_spans, 0..) |span, i| {
        tokens[i] = .{
            .raw_start = span.raw_start,
            .raw_end = span.raw_end,
            .name = span.name,
            .path = span.path,
            .display_source = span.display_source,
            .owns_trailing_separator = span.owns_trailing_separator,
        };
    }
    return tokens;
}

test "skill submit snapshot keeps display spans exact while agent bindings dedupe" {
    const alloc = std.testing.allocator;
    const tokens = [_]registered_entities.SkillTokenSpan{
        .{
            .raw_start = "raw $review then ".len,
            .raw_end = "raw $review then $review".len,
            .name = "review",
            .path = "/tmp/.codex/skills/review",
        },
        .{
            .raw_start = "raw $review then $review and ".len,
            .raw_end = "raw $review then $review and $review".len,
            .name = "review",
            .path = "/tmp/.codex/skills/review",
        },
    };

    const bindings = try dupeUniqueSkillBindingsFromTokens(alloc, &tokens);
    defer worker_runtime.freeSkillBindings(alloc, bindings);
    const display_spans = try dupeSkillDisplaySpansFromTokens(alloc, &tokens);
    defer worker_runtime.freeSkillDisplaySpans(alloc, display_spans);

    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqualStrings("review", bindings[0].name);
    try std.testing.expectEqual(@as(usize, 2), display_spans.len);
    try std.testing.expectEqual(tokens[0].raw_start, display_spans[0].raw_start);
    try std.testing.expectEqual(tokens[1].raw_start, display_spans[1].raw_start);
}

var resize_interlock = shell_runtime.ResizeApprovalInterlock{};
const default_context_registry = context_contract.Registry{ .default_provider = builtin_context.provider };
const WorkspaceHostRuntime = if (host_target.is_wasm) js_host_workspace.Runtime else struct {};
const wasm_skill_root_policy: @import("core/skills/skill_contract.zig").RootPolicy = .{
    .managed_root_source = null,
};
fn currentBuild() update_target.CurrentBuild {
    return .{
        .channel = compiled_update_channel,
        .version = version,
        .revision = build_options.git_commit,
    };
}

const App = struct {
    pub const app_version = version;
    pub const host_profile = if (host_target.is_wasm) host_runtime_profile.wasm else host_runtime_profile.native;
    pub const input_limits = paste_framing.default_input_limits;
    pub const build_update_channel = compiled_update_channel;
    pub const build_revision = build_options.git_commit;
    const Self = @This();
    const AgentAppRuntime = app_agent_runtime.Runtime(Self);
    const AuthAppRuntime = app_auth_runtime.Runtime(Self);
    const HostConfigAppRuntime = app_host_config_runtime.Runtime(Self);
    const BootstrapAppRuntime = app_bootstrap_runtime.Runtime(Self);
    const InputAppRuntime = app_input_runtime.Runtime(Self);
    const NotificationAppRuntime = app_notification_runtime.Runtime(
        Self,
        builtin_hooks.notifications.provider(Self),
    );
    const HerdrAppRuntime = builtin_hooks.Runtime(Self);
    const RenderAppRuntime = app_render_runtime.Runtime(Self);
    const SessionAppRuntime = app_session_runtime.Runtime(Self);
    const UpgradeAppRuntime = app_upgrade_runtime.Runtime(Self);
    const WorkerAppRuntime = app_worker_runtime.Runtime(Self);
    const WorkspaceAppRuntime = app_workspace_runtime.Runtime(Self);

    pub fn contextRegistry(_: *const Self) context_contract.Registry {
        return default_context_registry;
    }

    pub fn workspaceHostInfo(self: *const Self) ?*const js_host_workspace.Info {
        if (comptime host_profile.js_host_workspace) return self.workspace_host.info();
        return null;
    }

    pub fn workspaceExecutor(self: *const Self) ?js_host_workspace.Executor {
        if (comptime host_profile.js_host_workspace) return self.workspace_host.executor();
        return null;
    }

    pub fn promptPolicy(_: *const Self) prompt_policy.Policy {
        return builtin_context.prompt_policy;
    }

    pub fn slashRegistry(_: *const Self) command_specs.SlashRegistry {
        return builtin_commands.slash_registry;
    }

    pub fn mcpCommandProvider(_: *const Self) mcp_command_provider.Provider {
        return builtin_mcp.command_provider;
    }

    pub fn skillsCommandProvider(_: *const Self) skill_commands.Provider {
        return builtin_skills.command_provider;
    }

    pub fn urlOpener(_: *const Self) host.UrlOpener {
        return if (comptime host_profile.url_opening)
            url_opener.native_opener
        else if (comptime host_profile.js_host_url_open)
            js_host_url_opener.opener
        else
            host.unavailable_url_opener;
    }

    pub fn creditsProvider(_: *const Self) gateway_provider.CreditsProvider {
        return builtin_gateway.credits_provider;
    }

    pub fn agentStreamProvider(self: *const Self) agent_stream_provider.Provider {
        return self.subagentProviderRoutes()
            .select(self.provider_selection.selection().provider)
            .agent_stream_provider;
    }

    pub fn fetchProviderCatalog(
        self: *Self,
        provider: model_provider.ProviderId,
        access: credentials.CatalogAccess,
    ) !model_catalog.ProviderResult {
        return builtin_providers.modelCatalog(provider).fetch(self.alloc, .{
            .access = access,
            .endpoint = builtin_gateway.models_path,
            .cancel_flag = &self.worker.worker_cancel_requested,
            .view = .picker,
        });
    }

    pub fn cooperativeTransportPulse(self: *Self) !void {
        if (comptime !host_target.is_wasm) return;
        if (try event_loop.pump_ready_input(
            self.terminal,
            &self.should_exit,
            RenderAppRuntime.eventLoopCallbacks(self),
        )) |exit_cause| {
            if (exit_cause == .input_closed) self.should_exit = true;
            return;
        }
        try WorkerAppRuntime.tick(
            self,
            app_callbacks.Bindings(App).onTaskCompletion,
            app_callbacks.Bindings(App).workerEventHandlers(self),
        );
        try self.flushRequestedFrame();
    }

    pub fn secretStore(self: *const Self) host.SecretStore {
        return self.auth.secret_store;
    }

    pub fn clipboard(_: *const Self) host.Clipboard {
        return if (comptime host_profile.clipboard) native_host.clipboard else host.unavailable_clipboard;
    }

    pub fn terminalTitle(self: *const Self) host.TerminalTitle {
        return ui_render.terminalTitleFor(&self.shell.stdout_file);
    }

    alloc: Allocator,
    terminal: TerminalState = .{},

    auth: auth_runtime.Runtime = auth_runtime.Runtime.init(
        if (host_target.is_wasm) api_key_validator.unavailable_provider else builtin_gateway.api_key_validator,
        if (host_profile.js_host_auth)
            js_host_auth.oauth_provider
        else if (host_profile.native_auth)
            builtin_gateway.oauth_transport_provider
        else
            oauth_transport.unavailable_provider,
        if (host_target.is_wasm) host.unavailable_secret_store else native_host.secret_store,
    ),
    provider_selection: provider_runtime.Runtime = provider_runtime.Runtime.init(std.heap.c_allocator),
    model_cache: model_cache_runtime.Runtime = model_cache_runtime.Runtime.init(std.heap.c_allocator, builtin_gateway.models_path),
    workspace_root: []u8 = &.{},
    workspace_identity: statusline_identity.Runtime = .{},
    workspace_host: WorkspaceHostRuntime = .{},
    workspace: app_workspace_runtime.State = .{},
    permission_engine: PermissionEngine = .{},
    permission_state: app_permission_runtime.State = .{},
    agent_step_limit: usize = default_max_agent_steps,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{
        .provider = if (host_profile.web_search) builtin_gateway.default_web_search_provider else null,
    }),
    web_search_models_path: []const u8 = builtin_gateway.models_path,
    lifecycle_runtime: hooks.Runtime = hooks.Runtime.init(std.heap.c_allocator),
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    notifications: builtin_hooks.notifications.State = .{},
    herdr: builtin_hooks.Client = .{},

    session: SessionRuntime = SessionRuntime.init(
        max_history_turns,
        if (host_profile.generation_usage)
            builtin_gateway.generation_usage_provider
        else
            generation_usage_provider.unavailable_provider,
    ),
    session_persistence: app_session_runtime.Persistence = .{},
    prompt_history: PromptHistoryRuntime = .{},
    requested_resume: ?cli_surface.ResumeTarget = null,
    approval_prompt: ApprovalPrompt = .{},
    approval_screen: ApprovalScreenState = .{},
    question_prompt: QuestionPrompt = .{},

    should_exit: bool = false,
    input_runtime: InputRuntime = .{},
    terminal_input_runtime: TerminalInputRuntime = .{},
    queued_prompt_review: input_queue_runtime.State = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    next_image_id: usize = 1,
    shell: TranscriptRuntime = .{},
    pacer: assistant_pacer.AssistantPacer = .{},

    worker_thread: ?std.Thread = null,
    worker: WorkerRuntime = .{},
    background: BackgroundRuntime = .{},
    terminal_client: terminal_client_runtime.Runtime = .{},
    terminal_direct: terminal_direct_runtime.Runtime = .{},
    terminal_takeover: app_terminal_takeover_runtime.Controller = .{},
    upgrader: auto_upgrade.AutoUpgrade = .{},
    subagents: ui_subagents.Controller = .{},
    change_tracker: change_tracker_mod.ChangeTracker = .{},
    mcp: app_mcp_runtime.State = .{},
    acp_turn: ?*acp_turn_runner.ActiveTurn = null,
    /// Keeps the selected ACP agent's process and session alive across turns.
    acp_session_store: acp_turn_runner.SessionStore = .{},
    skills: skill_runtime.Runtime = .{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    file_index: file_index_mod.FileIndex = .{},
    context_enabled: bool = true,
    context_limits: config_runtime.context_limits.Values = .{},
    fast_mode: bool = false,
    auto_upgrade_enabled: bool = true,
    effort: ReasoningEffort = .auto,
    diff_entries: std.ArrayList(@import("core/output/diff.zig").DiffEntry) = .empty,
    next_diff_id: u32 = 1,

    statusline_context: bool = false,
    statusline_session: bool = false,
    /// Resolved display title for the active session. App owns these bytes;
    /// empty means no title has been derived or restored yet.
    session_title: std.ArrayList(u8) = .empty,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,

    stream: StreamState = .{},
    metrics: Metrics = .{},
    fn loadNoMcpRuntime(
        _: Allocator,
        _: @import("core/mcp/elicitation.zig").Capabilities,
    ) !?*mcp_runtime_mod.McpRuntime {
        return null;
    }

    pub fn init(alloc: Allocator, launch: *cli_surface.InteractiveLaunch) !Self {
        var app = Self{
            .alloc = alloc,
            .subagents = ui_subagents.Controller.init(),
            .lifecycle_runtime = hooks.Runtime.init(alloc),
            .background = BackgroundRuntime.init(if (comptime host_target.is_wasm)
                background_process_provider.unavailable_provider
            else
                background_process.provider),
            .terminal_client = terminal_client_runtime.Runtime.init(if (comptime host_target.is_wasm)
                background_process_provider.unavailable_provider
            else
                background_process.provider),
        };
        if (comptime host_profile.js_host_workspace) {
            app.workspace_host = js_host_workspace.Runtime.init(alloc) catch |err| blk: {
                if (err != error.WorkspaceUnavailable) {
                    debug_trace.logf("workspace", "js host workspace unavailable err={s}", .{@errorName(err)});
                }
                break :blk .{};
            };
        }
        if (comptime host_profile.js_host_prompt_history) {
            if (js_host_prompt_history.available()) {
                _ = app.prompt_history.initializeWithProvider(
                    app.prompt_history.enabled,
                    js_host_prompt_history.provider,
                );
            }
        }
        app.shell.max_transcript_bytes = max_transcript_bytes;
        if (launch.requested_resume) |target| {
            app.requested_resume = target;
            launch.requested_resume = null;
        }
        errdefer if (app.requested_resume) |*target| target.deinit(alloc);
        try BootstrapAppRuntime.bootstrap(
            &app,
            footer_rows,
            builtin_gateway.default_model,
            default_max_agent_steps,
            handle_sigwinch,
            launch.record_requested,
            .{
                .load_mcp_runtime = if (comptime host_target.is_wasm) loadNoMcpRuntime else builtin_mcp.loadRuntime,
                .skill_root_policy = if (comptime host_target.is_wasm) wasm_skill_root_policy else builtin_skills.root_policy,
                .terminal_title = app.terminalTitle(),
            },
        );
        errdefer app.deinit();
        try WorkspaceAppRuntime.applyLaunch(
            &app,
            launch.modifiers.additional_directories,
            launch.modifiers.saved_directories_suppressed,
        );
        app.context_limits.applyCommandLine(launch.modifiers.context_limit_overrides);
        if (comptime host_profile.durable_sessions or host_profile.js_host_sessions) {
            if (app.requested_resume != null) {
                if (launch.upgrade_relaunch) {
                    try SessionAppRuntime.resumeRequestedSessionAfterUpgrade(
                        &app,
                        app_version,
                    );
                } else {
                    try SessionAppRuntime.resumeRequestedSession(&app);
                }
                SessionAppRuntime.syncTerminalTitle(&app);
            }
        }
        if (comptime host_profile.durable_sessions) {
            SessionAppRuntime.primeSessionPicker(&app);
        }
        const env_disabled = if (io_mod.getenv("FX_AUTO_UPGRADE")) |val|
            std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false")
        else
            false;
        if (env_disabled or !auto_upgrade.shouldEnableForCurrentExecutable()) {
            app.auto_upgrade_enabled = false;
        }
        if (comptime !host_profile.auto_upgrade) app.auto_upgrade_enabled = false;
        try HostConfigAppRuntime.restore(&app, builtin_modes.registry);
        SessionAppRuntime.syncTerminalTitle(&app);
        return app;
    }

    pub fn persistAcceptedModel(self: *App, model: []const u8) !void {
        HostConfigAppRuntime.persistModel(self, model);
    }

    pub fn persistAcceptedPermissionMode(self: *App, mode: PermissionMode) !void {
        HostConfigAppRuntime.persistPermissionMode(self, mode);
    }

    pub fn configureNotifications(self: *App) !void {
        // Register herdr hooks before NotificationAppRuntime.configure freezes
        // the lifecycle runtime (its call to freeze() is the sole freeze site).
        try HerdrAppRuntime.configure(self, SessionAppRuntime.activeSessionId(self));
        try NotificationAppRuntime.configure(self);
    }

    pub fn rebindAfterInit(self: *App) void {
        SessionAppRuntime.rebindSubagentHost(self);
    }

    pub fn setNotificationPreferences(
        self: *App,
        turn_end: bool,
        attention_required: bool,
        max: bool,
    ) void {
        NotificationAppRuntime.setPreferences(self, .{
            .turn_end = turn_end,
            .attention_required = attention_required,
            .max = max,
        });
    }

    pub fn notificationPreferences(self: *const App) app_notification_runtime.Preferences {
        return NotificationAppRuntime.preferences(self);
    }

    pub fn soundMaxEnabled(self: *const App) bool {
        return NotificationAppRuntime.maxEnabled(self);
    }

    pub fn queueNotification(
        self: *App,
        notification: app_notification_runtime.Notification,
    ) void {
        NotificationAppRuntime.queue(self, notification);
    }

    pub fn notificationPresentationFinished(self: *App) void {
        NotificationAppRuntime.presentationFinished(self);
    }

    pub fn flushNotifications(self: *App) void {
        NotificationAppRuntime.flush(self);
    }

    pub fn playStartupSound(self: *App) void {
        NotificationAppRuntime.playCue(self, .bloom);
    }

    pub fn playCancelSound(self: *App) void {
        NotificationAppRuntime.playCue(self, .press);
    }

    pub fn playInteractionSound(self: *App) void {
        NotificationAppRuntime.playCue(self, .click);
    }

    pub fn playInputClearedSound(self: *App) void {
        NotificationAppRuntime.playMaxCue(self, .release);
    }

    pub fn playSlashMenuSound(self: *App) void {
        NotificationAppRuntime.playMaxCue(self, .toggle);
    }

    pub fn dispatchAttentionRequired(
        self: *App,
        turn_id: u64,
        kind: hooks.AttentionKind,
    ) void {
        NotificationAppRuntime.dispatchAttentionRequired(self, turn_id, kind);
    }

    /// Must be called after init() returns so the AutoUpgrade thread
    /// captures a pointer to the final App location (not a temporary).
    pub fn startAutoUpgrade(self: *App) void {
        if (self.auto_upgrade_enabled) {
            self.upgrader.start(self.alloc, currentBuild());
        }
    }

    pub fn applyReadyUpgradeShortcut(self: *App) !void {
        try UpgradeAppRuntime.applyReadyUpgrade(self);
    }

    pub fn prepareResumeHandoffForUpgrade(self: *App) !void {
        try SessionAppRuntime.prepareResumeHandoff(self);
    }

    pub fn requestUpgradeRelaunch(
        self: *App,
        executable_path: []const u8,
    ) !void {
        try self.upgrader.requestRelaunch(executable_path);
    }

    pub fn requestResumeHandoffForUpgrade(self: *App) void {
        SessionAppRuntime.requestUpgradeResumeHandoff(self);
    }

    pub fn takeUpgradeRelaunchRequest(
        self: *App,
    ) ?auto_upgrade.RelaunchRequest {
        return self.upgrader.takeRelaunchRequest();
    }

    pub fn deinit(self: *App) void {
        _ = self.deinitImpl(false);
    }

    /// Returns an owned handoff only after all interactive state is torn down.
    pub fn deinitWithResumeHandoff(self: *App) ?app_session_runtime.ResumeHandoff {
        return self.deinitImpl(true);
    }

    pub fn resumeHandoffColumns(self: *const App) u16 {
        return self.shell.layout.cols;
    }

    pub fn formatResumeHandoff(
        buffer: []u8,
        session_id: []const u8,
        terminal_cols: u16,
    ) ![]const u8 {
        return ui_render.formatResumeHandoff(buffer, session_id, terminal_cols);
    }

    fn deinitImpl(self: *App, capture_resume_handoff: bool) ?app_session_runtime.ResumeHandoff {
        // Client.deinit releases the herdr pane (clear agent + label) when enabled.
        self.herdr.deinit();
        self.stopStream();
        if (self.acp_turn) |turn| {
            turn.requestCancel();
            turn.deinit();
            self.acp_turn = null;
        }
        self.acp_session_store.deinit();

        self.worker.requestShutdown();
        self.background.requestStop();
        self.upgrader.stop();
        self.file_index.requestStop();

        self.terminal_takeover.shutdown(App, self);
        self.releaseTerminal();
        if (self.worker_thread) |thread| thread.join();
        self.terminal_takeover.deinit(self.alloc);
        const direct_deinit_disposition = if (capture_resume_handoff)
            self.terminal_direct.deinitSettled(self.alloc)
        else blk: {
            self.terminal_direct.deinitAbnormal(self.alloc, "runtime_failure");
            break :blk terminal_direct_runtime.DeinitDisposition.abnormal;
        };
        self.terminal_client.deinit();
        self.model_cache.deinit();
        const resume_handoff = if (capture_resume_handoff and
            direct_deinit_disposition == .settled)
            SessionAppRuntime.finalizePersistenceWithResumeHandoff(self)
        else blk: {
            SessionAppRuntime.finalizePersistence(self);
            break :blk null;
        };
        self.background.deinit(std.heap.c_allocator);
        self.worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.subagents.deinit(self.alloc);
        self.queued_prompt_review.deinit(self.alloc);
        self.prompt_history.deinit(self.alloc);
        self.clearPendingImages();
        self.pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.pacer.deinit(self.alloc);
        self.provider_selection.deinit();
        self.session_title.deinit(self.alloc);
        SessionAppRuntime.deinitPersistence(self);
        if (self.requested_resume) |*target| {
            target.deinit(self.alloc);
            self.requested_resume = null;
        }
        self.session.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        self.approval_prompt.deinit(self.alloc);
        self.question_prompt.deinit(self.alloc);

        self.change_tracker.deinit(std.heap.c_allocator);
        for (self.diff_entries.items) |*entry| entry.deinit(std.heap.c_allocator);
        self.diff_entries.deinit(std.heap.c_allocator);
        self.mcp.deinit(self.alloc);
        self.skills.deinit(std.heap.c_allocator);
        self.context_snapshot.deinit(self.alloc);
        self.file_index.deinit(std.heap.c_allocator);
        self.lifecycle_runtime.deinit();

        self.auth.deinit(self.alloc);
        WorkspaceAppRuntime.deinit(self);
        self.workspace_identity.deinit(self.alloc);
        if (self.workspace_root.len > 0) self.alloc.free(self.workspace_root);
        return resume_handoff;
    }

    pub fn releaseTerminal(self: *App) void {
        if (!self.terminal.raw_enabled and !self.terminal.signal_handler_installed) return;
        app_lifecycle.shutdownInteractiveShell(
            &self.terminal,
            &self.shell,
            &self.metrics,
            self.terminalTitle(),
        );
    }

    pub fn runExternalInteractive(self: *App, argv: []const []const u8) !void {
        try self.flushBeforeBlockingExternalWork();

        self.terminal.disableRawMode();
        var raw_restored = false;
        defer if (!raw_restored) {
            self.terminal.enableRawMode() catch {};
        };

        const io = io_mod.getIo();
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch return error.ExternalInteractiveFailed;
        const term = child.wait(io) catch return error.ExternalInteractiveFailed;
        try std.Io.File.stdout().writeStreamingAll(io, "\n");

        try self.terminal.captureOriginalTermios();
        try self.terminal.enableRawMode();
        raw_restored = true;
        self.shell.layout = self.terminal.queryLayout(footer_rows) catch self.shell.layout;
        try self.shell.requestTerminalReset(&self.metrics);
        self.shell.render_requests.request(.first_frame);

        switch (term) {
            .exited => |code| if (code != 0) return error.ExternalInteractiveFailed,
            else => return error.ExternalInteractiveFailed,
        }
    }

    pub fn flushBeforeBlockingExternalWork(self: *App) !void {
        try self.flushRequestedFrame();
    }

    pub fn suspendToJobControl(self: *App) !void {
        try self.flushBeforeBlockingExternalWork();
        try SessionAppRuntime.suspendToJobControl(self, footer_rows);
    }

    pub fn ensurePromptCredential(self: *App) !bool {
        return AuthAppRuntime.admitPromptCredential(self);
    }

    pub fn openSetupHub(self: *App) !void {
        try AuthAppRuntime.openSetupHub(self);
    }

    pub fn runLoginCommand(self: *App) !void {
        try AuthAppRuntime.runLoginCommand(self);
    }

    pub fn runLogoutCommand(self: *App, target: []const u8) !void {
        try AuthAppRuntime.runLogoutCommand(self, target);
    }

    pub fn applyAuthPickerChoice(self: *App, choice: auth_runtime.Choice) !void {
        try AuthAppRuntime.applyPickerChoice(self, choice);
    }

    pub fn selectCredentialSource(self: *App, source: credentials.Source) !bool {
        return AuthAppRuntime.selectCredentialSource(self, source);
    }

    pub fn run(self: *App) !void {
        const callbacks = RenderAppRuntime.eventLoopCallbacks(self);
        while (true) {
            const exit_cause = try event_loop.run(
                self.terminal,
                &self.should_exit,
                active_poll_timeout_ms,
                callbacks,
            );
            switch (exit_cause) {
                .requested_exit => {},
                .input_closed => {
                    self.terminal_direct.deinitAbnormal(self.alloc, "input_closed");
                    return error.TerminalInputClosed;
                },
            }
            switch (app_terminal_runtime.Runtime(App).prepareGracefulExit(self)) {
                .ready => return,
                .deferred => {
                    self.should_exit = false;
                    debug_trace.logf(
                        "terminal",
                        "interactive exit resumed after direct graceful-exit deferral",
                        .{},
                    );
                },
            }
        }
    }

    pub fn loopPollTimeoutMs(ctx: *anyopaque, default_timeout_ms: i32) i32 {
        const self: *const App = @ptrCast(@alignCast(ctx));
        if (comptime !host_target.is_wasm) return default_timeout_ms;
        return if (self.pacer.hasPending()) default_timeout_ms else idle_wasm_poll_timeout_ms;
    }

    fn processNextCooperativePrompt(self: *App) !void {
        if (comptime !host_target.is_wasm) return;
        try app_process_runtime.Runtime(App).processNextCooperativePrompt(
            self,
            app_callbacks.Bindings(App).onTaskCompletion,
            app_callbacks.Bindings(App).workerEventHandlers(self),
            flushRequestedFrame,
        );
        try SessionAppRuntime.settlePendingLiveSessionTransition(self);
    }

    fn flushRequestedFrame(self: *App) !void {
        try RenderAppRuntime.flushRequestedFrame(self);
    }

    pub fn handleCommand(self: *App, cmd: []const u8) !void {
        try app_commands.Handlers(App).route(self, cmd);
    }

    pub fn clearPendingImages(self: *App) void {
        InputAppRuntime.clearPendingImages(self);
    }

    pub fn releasePendingImages(self: *App) void {
        InputAppRuntime.releasePendingImages(self);
    }

    pub fn nextImageId(self: *App) usize {
        return image_attachments.allocateImageId(&self.next_image_id);
    }

    pub fn peekNextImageId(self: *const App) usize {
        return self.next_image_id;
    }

    pub fn captureImageAttachment(self: *App, attachment: *types.ImageAttachment) !void {
        try SessionAppRuntime.captureImageAttachment(self, attachment);
    }

    pub fn enqueuePrompt(self: *App, prompt: []const u8) !bool {
        return self.enqueuePromptWithSkillBindings(prompt, &.{});
    }

    pub fn enqueuePromptWithSkillBindings(self: *App, prompt: []const u8, skill_tokens: []const registered_entities.SkillTokenSpan) !bool {
        return self.enqueuePromptWithOptionalReview(
            prompt,
            skill_tokens,
            null,
        );
    }

    pub fn enqueuePromptWithReviewDraft(
        self: *App,
        prompt: []const u8,
        skill_tokens: []const registered_entities.SkillTokenSpan,
        review_input: []const u8,
        review_pasted_blocks: []const paste_blocks.PastedBlock,
        review_image_tokens: []const entity_spans.ImageTokenSpan,
        review_skill_tokens: []const registered_entities.SkillTokenSpan,
    ) !bool {
        const review_skill_spans = try dupeSkillDisplaySpansFromTokens(
            self.alloc,
            review_skill_tokens,
        );
        defer worker_runtime.freeSkillDisplaySpans(
            self.alloc,
            review_skill_spans,
        );
        return self.enqueuePromptWithOptionalReview(
            prompt,
            skill_tokens,
            .{
                .input = @constCast(review_input),
                .pasted_blocks = @constCast(review_pasted_blocks),
                .image_tokens = @constCast(review_image_tokens),
                .skill_display_spans = review_skill_spans,
            },
        );
    }

    fn enqueuePromptWithOptionalReview(
        self: *App,
        prompt: []const u8,
        skill_tokens: []const registered_entities.SkillTokenSpan,
        review_draft: ?worker_runtime.QueueReviewDraft,
    ) !bool {
        const context_targets = if (self.context_enabled)
            try context_contract.applicableTargetsForImages(self.alloc, self.pending_images.items)
        else
            &.{};
        defer if (context_targets.len > 0) self.alloc.free(context_targets);

        try AgentAppRuntime.refreshProjectContext(self, context_targets);
        self.session.setConversationLanguageFromUserMessage(prompt);

        debug_trace.logf(
            "prompt",
            "enqueue bytes={d} stream_active={s} queued_before={d} preview=\"{s}\"",
            .{
                prompt.len,
                if (self.stream.active) "true" else "false",
                self.worker.queuedPromptCount(),
                debug_trace.preview(prompt, 120),
            },
        );
        if (!try self.snapshotAndQueuePromptWithSkillBindings(
            prompt,
            skill_tokens,
            review_draft,
        )) return false;
        WorkerAppRuntime.syncState(
            self,
            app_callbacks.Bindings(App).worker_tool_lifecycle_presenter(self),
        );
        return true;
    }

    pub fn writeUserPromptCard(self: *App, user: types.UserTurn) !void {
        try self.writeUserPromptCardWithSpacing(user, self.session.historyLen() > 0);
    }

    pub fn writeUserPromptCardWithSkillBindings(
        self: *App,
        user: types.UserTurn,
        skill_bindings: []const worker_runtime.SkillBinding,
        skill_display_spans: []const worker_runtime.SkillDisplaySpan,
    ) !void {
        _ = skill_bindings;
        const skill_tokens = try promptCardSkillTokensFromDisplaySpans(self.alloc, skill_display_spans);
        defer if (skill_tokens.len > 0) self.alloc.free(skill_tokens);
        try self.writeUserPromptCardWithSpacingAndSkillTokens(user, self.session.historyLen() > 0, skill_tokens);
    }

    pub fn writeUserPromptCardWithSpacing(self: *App, user: types.UserTurn, has_prior_turns: bool) !void {
        try self.writeUserPromptCardWithSpacingAndSkillTokens(user, has_prior_turns, &.{});
    }

    fn writeUserPromptCardWithSpacingAndSkillTokens(
        self: *App,
        user: types.UserTurn,
        has_prior_turns: bool,
        skill_tokens: []const registered_entities.SkillTokenSpan,
    ) !void {
        _ = try self.shell.writeUserPromptCard(
            self.alloc,
            &self.metrics,
            user,
            has_prior_turns,
            skill_tokens,
        );
    }

    pub fn stopStream(self: *App) void {
        self.stream = .{};
        self.shell.resetCommandOutputDisplay(self.alloc, "stream stopped");
        self.shell.render_requests.request(.footer);
    }

    pub fn clearSession(self: *App) !void {
        try SessionAppRuntime.clearSession(self);
    }

    pub fn newSession(self: *App) !void {
        try SessionAppRuntime.newSession(self);
    }

    pub fn resetSession(self: *App) !void {
        try SessionAppRuntime.resetSession(self);
    }

    pub fn prepareLiveSessionResume(
        self: *App,
        log_options: session_log.Options,
    ) !void {
        try SessionAppRuntime.prepareLiveSessionResume(self, log_options);
    }

    pub fn finishLiveSessionResume(self: *App) !void {
        try SessionAppRuntime.finishLiveSessionResume(self);
    }

    pub fn startResumedSessionReconciliation(self: *App) void {
        SessionAppRuntime.startResumedSessionReconciliation(self);
    }

    pub fn resumeSelectedSession(self: *App) !bool {
        return SessionAppRuntime.resumeSelectedSession(self);
    }

    pub fn loadMoreSessionPicker(self: *App) !bool {
        return SessionAppRuntime.loadMoreSessionPicker(self);
    }

    pub fn beginResumeProjection(self: *App) !ResumeProjection {
        return ResumeProjection.init(
            self.alloc,
            &self.shell,
            io_mod.milliTimestamp(),
            self.next_diff_id,
        );
    }

    pub fn installResumeProjection(
        self: *App,
        projection: *ResumeProjection,
    ) !void {
        const c_alloc = std.heap.c_allocator;
        try self.diff_entries.ensureUnusedCapacity(
            c_alloc,
            projection.pending_diffs.items.len,
        );
        for (projection.pending_diffs.items) |entry| {
            self.diff_entries.appendAssumeCapacity(entry);
        }
        projection.pending_diffs.clearRetainingCapacity();
        self.next_diff_id = projection.next_diff_id;
        projection.install(&self.shell);
    }

    pub fn historicalToolActivityKind(
        self: *App,
        call: types.ToolCall,
    ) types.ToolActivityKind {
        return tool_dispatch.toolActivityKindForCall(self.alloc, self.toolRegistry(), call);
    }

    pub fn commitStartupResumeReplayAnchor(self: *App) !void {
        try self.flushRequestedFrame();
    }

    pub fn persistResumeViewAfterFrame(self: *App) void {
        SessionAppRuntime.persistResumeViewAfterFrame(self);
    }

    pub fn flushDirectTerminalShutdownOutcome(self: *App) !void {
        try RenderAppRuntime.flushRequestedFrame(@as(*Self, self));
    }

    pub fn snapshotAndQueuePromptWithSkillBindings(
        self: *App,
        prompt: []const u8,
        skill_tokens: []const registered_entities.SkillTokenSpan,
        review_draft: ?worker_runtime.QueueReviewDraft,
    ) !bool {
        return self.snapshotAndQueuePrompt(
            prompt,
            skill_tokens,
            review_draft,
            null,
        );
    }

    pub fn continuePausedRecovery(self: *App) !bool {
        return SessionAppRuntime.continuePausedRecovery(self);
    }

    pub fn queueRecoveryCheckpoint(
        self: *App,
        checkpoint: *const session_codec.RecoveryCheckpoint,
    ) !bool {
        if (!try self.snapshotAndQueuePrompt(
            checkpoint.user.text,
            &.{},
            null,
            checkpoint,
        )) return false;
        WorkerAppRuntime.syncState(
            self,
            app_callbacks.Bindings(App).worker_tool_lifecycle_presenter(self),
        );
        return true;
    }

    fn snapshotAndQueuePrompt(
        self: *App,
        prompt: []const u8,
        skill_tokens: []const registered_entities.SkillTokenSpan,
        review_draft: ?worker_runtime.QueueReviewDraft,
        recovery_checkpoint: ?*const session_codec.RecoveryCheckpoint,
    ) !bool {
        try self.reloadSkills();

        const prompt_copy = try std.heap.c_allocator.dupe(u8, prompt);
        errdefer std.heap.c_allocator.free(prompt_copy);

        const model_copy = try std.heap.c_allocator.dupe(u8, self.provider_selection.selection().model);
        errdefer std.heap.c_allocator.free(model_copy);

        const gateway_credential = self.auth.gatewayCredential() orelse return error.MissingApiKey;
        const api_key_copy = try std.heap.c_allocator.dupe(u8, gateway_credential.api_key);
        errdefer secret.zeroAndFree(std.heap.c_allocator, api_key_copy);

        const gateway_team_copy = if (gateway_credential.gateway_team) |team|
            try std.heap.c_allocator.dupe(u8, team)
        else
            null;
        errdefer if (gateway_team_copy) |team| std.heap.c_allocator.free(team);
        const account_id_copy = if (self.auth.accountId()) |account_id|
            try std.heap.c_allocator.dupe(u8, account_id)
        else
            null;
        errdefer if (account_id_copy) |account_id| std.heap.c_allocator.free(account_id);

        const authorized_image_catalog = try self.session.snapshotImageCatalog(
            std.heap.c_allocator,
            if (recovery_checkpoint) |checkpoint|
                checkpoint.user.images
            else
                self.pending_images.items,
        );
        errdefer types.freeImageAttachmentSlice(std.heap.c_allocator, authorized_image_catalog);

        const history_copy = try self.session.snapshotContextHistory(std.heap.c_allocator);
        errdefer types.freeHistoryTurnSlice(std.heap.c_allocator, history_copy);
        const root_user_intent_context = try auto_classifier_context.buildCanonicalRootUserContext(
            std.heap.c_allocator,
            prompt_copy,
            self.session.history.items,
        );
        errdefer std.heap.c_allocator.free(root_user_intent_context);

        const images_copy = try types.dupeImageAttachmentSlice(
            std.heap.c_allocator,
            if (recovery_checkpoint) |checkpoint|
                checkpoint.user.images
            else
                self.pending_images.items,
        );
        errdefer types.freeImageAttachmentSlice(std.heap.c_allocator, images_copy);

        var recovery_checkpoint_copy = if (recovery_checkpoint) |checkpoint|
            try checkpoint.dupe(std.heap.c_allocator)
        else
            null;
        errdefer if (recovery_checkpoint_copy) |*checkpoint|
            checkpoint.deinit(std.heap.c_allocator);

        const grants_copy = try types.dupePermissionGrantSlice(std.heap.c_allocator, self.permission_engine.grants.items);
        errdefer types.freePermissionGrantSlice(std.heap.c_allocator, grants_copy);

        var context_snapshot_copy = if (self.context_enabled)
            try self.context_snapshot.dupe(std.heap.c_allocator)
        else
            context_contract.GatheredContextSnapshot{};
        errdefer context_snapshot_copy.deinit(std.heap.c_allocator);

        const skill_bindings = try dupeUniqueSkillBindingsFromTokens(std.heap.c_allocator, skill_tokens);
        errdefer worker_runtime.freeSkillBindings(std.heap.c_allocator, skill_bindings);

        const skill_display_spans = try dupeSkillDisplaySpansFromTokens(std.heap.c_allocator, skill_tokens);
        errdefer worker_runtime.freeSkillDisplaySpans(std.heap.c_allocator, skill_display_spans);

        const review_draft_copy = if (review_draft) |review|
            try worker_runtime.dupeQueueReviewDraft(
                std.heap.c_allocator,
                review,
            )
        else
            null;
        errdefer if (review_draft_copy) |review|
            worker_runtime.freeQueueReviewDraft(
                std.heap.c_allocator,
                review,
            );

        try self.worker.enqueuePrompt(std.heap.c_allocator, .{
            .turn_id = if (recovery_checkpoint) |checkpoint| checkpoint.turn_id else 0,
            .prompt = prompt_copy,
            .images = images_copy,
            .authorized_image_catalog = authorized_image_catalog,
            .model = model_copy,
            .provider = self.provider_selection.selection().provider,
            .api_key = api_key_copy,
            .gateway_team = gateway_team_copy,
            .credential_source = gateway_credential.source,
            .account_id = account_id_copy,
            .permission_mode = self.permission_engine.mode,
            .history = history_copy,
            .root_user_intent_context = root_user_intent_context,
            .grants = grants_copy,
            .skill_bindings = skill_bindings,
            .skill_display_spans = skill_display_spans,
            .review_draft = review_draft_copy,
            .context_snapshot = context_snapshot_copy,
            .recovery_checkpoint = recovery_checkpoint_copy,
            .recovery_source_already_presented = recovery_checkpoint != null,
        });
        HerdrAppRuntime.reportWorking(self);
        return true;
    }

    pub fn installInitialMcpRuntime(self: *App, runtime: ?*mcp_runtime_mod.McpRuntime) void {
        self.mcp.installInitial(runtime);
    }

    pub fn acquireMcpRuntime(self: *App) ?app_mcp_runtime.Lease {
        return self.mcp.acquire();
    }

    pub fn snapshotMcpModelCatalog(
        self: *App,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
        include_ask_deferred: bool,
    ) !mcp_model_catalog.Snapshot {
        return self.mcp.snapshotModelCatalog(
            alloc,
            permission_rules,
            include_ask_deferred,
        );
    }

    pub fn waitForRequiredMcp(
        self: *App,
        alloc: Allocator,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !?[]u8 {
        return self.mcp.waitForRequired(
            alloc,
            cancel_flag,
            @intCast(@max(io_mod.milliTimestamp(), 0)),
        );
    }

    pub fn beginMcpReload(self: *App) !void {
        return self.mcp.beginReload(
            self.alloc,
            .{ .form = true, .url = true },
            if (comptime host_target.is_wasm) loadNoMcpRuntime else builtin_mcp.loadRuntime,
            self.toolRegistry(),
            @intCast(@max(io_mod.milliTimestamp(), 0)),
        );
    }

    pub fn takeMcpReloadCompletion(self: *App) !?app_mcp_runtime.ReloadCompletion {
        return self.mcp.takeReloadCompletion();
    }

    pub fn startMcpDiscovery(self: *App) void {
        self.mcp.startDiscovery(self.toolRegistry());
    }

    fn effectiveToolSet(self: *const App) tool_set_contract.ToolSet {
        if (comptime host_profile.tools) {
            return builtin_tools.advertisement_set;
        }
        return browser_workspace_tools.selectToolSet(
            false,
            self.workspaceHostInfo() != null,
        );
    }

    pub fn toolRegistry(self: *const App) tool_dispatch.Registry {
        return self.effectiveToolSet().registry;
    }

    pub fn toolAdvertisementSet(self: *const App) tool_set_contract.ToolSet {
        return self.effectiveToolSet();
    }

    pub fn hasMcpTool(self: *App, name: []const u8, access: tool_mcp_runtime.Access) bool {
        return self.mcp.hasTool(name, access);
    }

    pub fn validateMcpTool(
        self: *App,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.ValidationResult {
        return self.mcp.validateTool(arena, name, arguments_json, access);
    }

    pub fn callMcpTool(
        self: *App,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        return self.mcp.callTool(arena, name, arguments_json, max_tool_result_bytes, options);
    }

    pub fn searchMcpTools(self: *App, arena: Allocator, query: []const u8, limit: usize, permission_rules: types.PermissionRuleSet, access: tool_mcp_runtime.Access) !tool_mcp_runtime.SearchResult {
        return self.mcp.searchTools(arena, query, limit, permission_rules, self.context_limits, access);
    }

    pub fn mcpToolSchemaJson(self: *App, arena: Allocator, name: []const u8, permission_rules: types.PermissionRuleSet, access: tool_mcp_runtime.Access) !?tool_mcp_runtime.ToolSchemaResult {
        return self.mcp.toolSchema(arena, name, permission_rules, self.context_limits, access);
    }

    pub fn listMcpServersAndTools(self: *App, alloc: Allocator) ![]u8 {
        return self.mcp.renderHealth(alloc);
    }

    pub fn summarizeMcpServers(self: *App, alloc: Allocator) ![]u8 {
        return self.mcp.renderHealthSummary(alloc);
    }

    pub fn snapshotMcpToolNames(self: *App, alloc: Allocator) ![][]u8 {
        return self.mcp.snapshotToolNames(alloc, self.permission_engine.rules);
    }

    pub fn snapshotMcpAccessView(
        self: *App,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
        permission_rules: types.PermissionRuleSet,
        features_visible: bool,
    ) !?mcp_access_policy.View {
        return self.mcp.snapshotAccessView(
            alloc,
            owner_id,
            parent_id,
            permission_rules,
            features_visible,
        );
    }

    pub fn snapshotGatewayToolProjection(
        self: *App,
        alloc: Allocator,
        permission_mode: types.PermissionMode,
    ) !tool_advertisement.EffectiveToolProjection {
        self.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
        defer self.permission_state.authority_mutex.unlock(io_mod.getIo());
        return self.snapshotGatewayToolProjectionForRules(
            alloc,
            permission_mode,
            self.permission_engine.rules,
        );
    }

    pub fn snapshotSubagentGatewayToolProjection(
        self: *App,
        alloc: Allocator,
        permission_mode: types.PermissionMode,
        permission_rules: types.PermissionRuleSet,
    ) !tool_advertisement.EffectiveToolProjection {
        return self.snapshotGatewayToolProjectionForRules(
            alloc,
            permission_mode,
            permission_rules,
        );
    }

    fn snapshotGatewayToolProjectionForRules(
        self: *App,
        alloc: Allocator,
        permission_mode: types.PermissionMode,
        permission_rules: types.PermissionRuleSet,
    ) !tool_advertisement.EffectiveToolProjection {
        return app_mcp_runtime.buildGatewayToolProjection(&self.mcp, alloc, self.toolAdvertisementSet(), .{
            .permission_mode = permission_mode,
            .permission_rules = permission_rules,
            .subagent_available = self.session_persistence.subagent_host != null,
        });
    }

    pub fn subagentToolContextForAdmission(
        self: *App,
        admission: subagent_domain.AdmissionSnapshot,
    ) tool_runtime.Context {
        return AgentAppRuntime.toolContextForSubagent(self, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl(), admission);
    }

    pub fn runSubagentChild(
        raw: ?*anyopaque,
        turn: *subagent_execution.TurnContext,
        message: subagent_domain.QueuedMessage,
        admission: subagent_domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) subagent_execution.ServiceError!subagent_execution.RunOutcome {
        return AgentAppRuntime.runSubagentChild(raw, turn, message, admission, cancel);
    }

    pub fn reloadSkills(self: *App) !void {
        const loaded = try app_runtime_setup.loadSkills(std.heap.c_allocator, self.workspace_root, builtin_skills.root_policy);
        skill_runtime.traceDiagnostics("interactive_reload", loaded.diagnostics);
        self.skills.replaceLoaded(std.heap.c_allocator, loaded.dir, loaded.skills, loaded.diagnostics);
    }

    pub fn allowToolForSession(self: *App, tool_name: []const u8, target_path: []const u8) !void {
        self.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
        defer self.permission_state.authority_mutex.unlock(io_mod.getIo());
        try self.permission_engine.allow(self.alloc, tool_name, target_path);
    }

    pub fn permissionReviewerProvider(self: *const App) ?permission_auto_classifier.Provider {
        return self.subagentProviderRoutes()
            .select(self.provider_selection.selection().provider)
            .permission_reviewer_provider;
    }

    pub fn subagentProviderRoutes(_: *const App) subagent_agent_adapter.ProviderRoutes {
        return .{
            .gateway = .{
                .agent_stream_provider = if (comptime host_target.is_wasm)
                    js_host_stream_provider.provider()
                else
                    builtin_providers.agentStream(.gateway),
                .permission_reviewer_provider = if (comptime host_profile.tools)
                    builtin_gateway.permission_reviewer.provider
                else
                    null,
            },
            .codex = .{
                .agent_stream_provider = if (comptime host_target.is_wasm)
                    agent_stream_provider.unavailable_provider
                else
                    builtin_providers.agentStream(.codex),
                .permission_reviewer_provider = if (comptime host_profile.tools and !host_target.is_wasm)
                    openai_codex_permission_reviewer.provider
                else
                    null,
            },
            .grok = .{
                .agent_stream_provider = if (comptime host_target.is_wasm)
                    agent_stream_provider.unavailable_provider
                else
                    builtin_providers.agentStream(.grok),
                .permission_reviewer_provider = if (comptime host_profile.tools and !host_target.is_wasm)
                    xai_grok_permission_reviewer.provider
                else
                    null,
            },
        };
    }

    pub fn describeToolAction(self: *App, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return AgentAppRuntime.describeToolAction(self, arena, call, display_target, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn resolveToolActionDisplayTarget(self: *App, arena: Allocator, call: ToolCall) !?[]const u8 {
        return AgentAppRuntime.resolveToolActionDisplayTarget(self, arena, call, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn describeToolActionWithAdvertised(self: *App, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return self.describeToolAction(arena, call, display_target, advertised_dynamic_tool_names);
    }

    pub fn describeToolActionCompleted(self: *App, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return AgentAppRuntime.describeToolActionCompleted(self, arena, call, display_target, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn describeToolActionCompletedWithAdvertised(self: *App, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return self.describeToolActionCompleted(arena, call, display_target, advertised_dynamic_tool_names);
    }

    pub fn describeToolActionDenied(self: *App, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return AgentAppRuntime.describeToolActionDenied(self, arena, call, display_target, label, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn describeToolActionDeniedWithAdvertised(self: *App, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return self.describeToolActionDenied(arena, call, display_target, label, advertised_dynamic_tool_names);
    }

    pub fn requestToolPermissionSync(self: *App, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return AgentAppRuntime.requestToolPermissionSync(self, arena, call, review_turn, permission_mode, local_grants, live_authority, revalidation, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn requestToolPermissionSyncWithAdvertised(self: *App, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return self.requestToolPermissionSync(arena, call, review_turn, permission_mode, local_grants, live_authority, revalidation, advertised_dynamic_tool_names);
    }

    pub fn requestPreparedFileMutationPermissionSyncWithAdvertised(self: *App, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return AgentAppRuntime.requestPreparedFileMutationPermissionSync(self, arena, call, prepared, review_turn, permission_mode, local_grants, live_authority, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn validateToolCall(self: *App, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
        return AgentAppRuntime.validateToolCall(self, arena, call, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn checkToolAvailability(self: *App, arena: Allocator, call: ToolCall) !?[]const u8 {
        return AgentAppRuntime.checkToolAvailability(self, arena, call, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn permissionTargetForCall(self: *App, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return AgentAppRuntime.permissionTargetForCall(self, arena, call, advertised_dynamic_tool_names, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn permissionTargetForCallWithAdvertised(self: *App, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return self.permissionTargetForCall(arena, call, advertised_dynamic_tool_names);
    }

    pub fn preparePermissionStateAction(
        self: *App,
        arena: Allocator,
        call: ToolCall,
    ) !tool_admission.PreparedPermissionStateAction {
        const ctx = AgentAppRuntime.toolContext(
            self,
            &ignored_list_entries,
            max_list_entries,
            max_read_file_bytes,
            max_read_file_lines,
            max_read_file_line_len,
            max_command_output_bytes,
            builtin_gateway.retry_count,
            builtin_gateway.defaultChatUrl(),
        );
        return tool_admission.preparePermissionStateAction(
            ctx.admissionInput(),
            arena,
            call,
        );
    }

    pub fn writeSubagentSnapshot(self: *App) !void {
        try RenderAppRuntime.toggleSubagentView(self);
    }

    pub fn drainAcpTurn(self: *App) !void {
        try app_commands.Handlers(App).drainAcpTurn(self);
    }

    pub fn requestAcpCancel(self: *App) void {
        app_commands.Handlers(App).requestAcpCancel(self);
    }

    pub fn refreshSubagentManagerProjection(self: *App) !void {
        if (comptime !host_profile.subagents) return;
        try RenderAppRuntime.refreshSubagentManager(self, false);
    }

    pub fn refreshSubagentManagerProjectionNow(self: *App) !void {
        if (comptime !host_profile.subagents) return;
        try RenderAppRuntime.refreshSubagentManagerAfterSessionInstall(self);
    }

    pub fn acknowledgeSubagentManagerSelection(self: *App) !void {
        try RenderAppRuntime.acknowledgeSubagentManagerSelection(self);
    }

    pub fn acknowledgeVisibleSubagentChildBeforeClose(self: *App) void {
        RenderAppRuntime.acknowledgeVisibleSubagentChildBeforeClose(self);
    }

    pub fn fetchModelIds(self: *App) !std.ArrayList([]u8) {
        return AgentAppRuntime.fetchModelIds(
            self,
            if (comptime host_target.is_wasm)
                js_host_model_catalog.provider
            else
                builtin_providers.modelCatalog(self.provider_selection.selection().provider),
            builtin_gateway.models_path,
        );
    }

    pub fn startModelCacheWarmup(self: *App) void {
        if (comptime host_profile.cooperative_agent) {
            if (self.auth.credentialNeedsRefresh()) {
                debug_trace.logf("auth", "model_cache_warmup_deferred reason=credential_refresh_required", .{});
                return;
            }
            self.model_cache.loadCooperative(
                js_host_model_catalog.provider,
                self.auth.modelCatalogAccess(),
            );
        } else {
            self.model_cache.startWarmup(
                builtin_providers.modelCatalog(self.provider_selection.selection().provider),
                self.auth.modelCatalogAccess(),
            );
        }
    }

    pub fn ensureModelCache(self: *App) void {
        self.startModelCacheWarmup();
    }

    pub fn isModelCacheLoading(self: *App) bool {
        return self.model_cache.isLoading();
    }

    pub fn isModelCacheFailed(self: *App) bool {
        return self.model_cache.isFailed();
    }

    pub fn snapshotCachedModelIds(self: *App, alloc: Allocator) !?std.ArrayList([]u8) {
        return self.model_cache.snapshotCachedModelIds(alloc);
    }

    pub fn resolvedModelCapabilities(self: *App, model: []const u8) model_capabilities.Capabilities {
        if (std.mem.startsWith(u8, model, "acp/")) {
            return app_commands.Handlers(App).acpModelCapabilities(self, model);
        }
        return model_capabilities.resolveCapabilities(model, self.model_cache.metadataForModel(model));
    }

    pub fn resolveModelCapabilitiesForRequest(self: *App, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
        return self.model_cache.resolveForRequest(model, &self.worker.worker_cancel_requested);
    }

    /// Must be called after init() returns so the loader thread captures
    /// a pointer to the final App location (not a temporary). Same hazard
    /// as `startAutoUpgrade` above.
    pub fn startFileIndex(self: *App) void {
        WorkspaceAppRuntime.startFileIndex(self);
    }

    pub fn fileCompletions(
        self: *App,
        query: []const u8,
        out: []file_index_mod.SearchResult,
        match_spans: []file_index_mod.MatchSpan,
        path_storage: []u8,
    ) app_workspace_runtime.FileCompletionError!usize {
        return WorkspaceAppRuntime.fileCompletions(self, query, out, match_spans, path_storage);
    }

    pub fn fileCompletionsDependOnIndex(self: *const App, query: []const u8) bool {
        return WorkspaceAppRuntime.fileCompletionsDependOnIndex(self, query);
    }

    pub fn isFileIndexLoading(self: *App) bool {
        return self.file_index.currentState() == .loading;
    }

    pub fn isFileIndexFailed(self: *App) bool {
        return self.file_index.currentState() == .failed;
    }

    pub fn refreshFileIndex(self: *App) void {
        if (comptime !host_profile.file_index) return;
        WorkspaceAppRuntime.refreshFileIndex(self);
    }

    pub fn workspaceAccess(self: *App) *app_workspace_runtime.Access {
        return WorkspaceAppRuntime.access(self);
    }

    pub fn workspaceAccessScope(self: *const App) app_workspace_runtime.AccessScope {
        return WorkspaceAppRuntime.scope(self);
    }

    pub fn adoptWorkspaceAccess(self: *App, access: app_workspace_runtime.Access) void {
        WorkspaceAppRuntime.adopt(self, access);
    }

    pub fn installWorkspaceAccess(self: *App, access: *app_workspace_runtime.Access) bool {
        return WorkspaceAppRuntime.install(self, access);
    }

    pub fn refreshWorkspaceAccess(self: *App) app_workspace_runtime.Error!bool {
        return WorkspaceAppRuntime.refreshAvailability(self);
    }

    pub fn isCurrentFileCompletion(
        self: *App,
        query: []const u8,
        path: []const u8,
        kind: file_index_mod.CandidateKind,
    ) bool {
        return WorkspaceAppRuntime.isCurrentFileCompletion(self, query, path, kind);
    }

    pub fn modelCompletions(self: *App, query: []const u8, out: [][]const u8) usize {
        self.ensureModelCache();
        app_commands.Handlers(App).refreshAcpModelEntries(self);
        return self.model_cache.modelCompletions(query, out);
    }

    pub fn catalogModelCompletion(self: *App, model: []const u8) ?[]const u8 {
        self.ensureModelCache();
        return self.model_cache.catalogModelCompletion(model);
    }

    pub fn pushText(self: *App, text: []const u8) !void {
        try self.worker.pushEvent(std.heap.c_allocator, .{ .assistant_presentation = .{
            .text = @constCast(text),
        } });
        if (comptime host_profile.cooperative_agent) {
            try WorkerAppRuntime.tick(self, app_callbacks.Bindings(App).onTaskCompletion, app_callbacks.Bindings(App).workerEventHandlers(self));
            try self.flushRequestedFrame();
        }
    }

    pub fn processQueuedPrompt(self: *App, job: QueuedPrompt) !void {
        AgentAppRuntime.processQueuedPrompt(
            self,
            job,
            builtin_gateway.retry_count,
            builtin_gateway.defaultChatUrl(),
        ) catch |err| {
            if (err == error.TurnFinalizationDeliveryFailed) return;
            return err;
        };
    }

    pub fn executeToolCall(self: *App, request: agent_runtime.ToolExecutionRequest) !ToolExecutionResult {
        if (comptime !host_profile.tools) {
            if (comptime !host_profile.js_host_workspace) {
                return agent_runtime.unavailableHostToolResult(request.result_allocator);
            }
            if (self.workspaceHostInfo() == null) {
                return agent_runtime.unavailableHostToolResult(request.result_allocator);
            }
        }
        return AgentAppRuntime.executeToolCall(self, request, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn executeToolCallWithAdvertised(self: *App, request: agent_runtime.ToolExecutionRequest) !ToolExecutionResult {
        return self.executeToolCall(request);
    }

    pub fn formatToolExecutionErrorForAgent(self: *App, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        _ = self;
        return app_process_runtime.Runtime(App).formatToolExecutionError(arena, tool_name, err);
    }

    pub fn appendRuntimeContextMessage(self: *App, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        try AgentAppRuntime.appendTransientRuntimeContextMessage(self, arena, messages, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    pub fn appendStaticContextMessage(self: *App, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        try AgentAppRuntime.appendStaticContextMessage(self, arena, messages, &ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, builtin_gateway.retry_count, builtin_gateway.defaultChatUrl());
    }

    fn runtimeContextSnapshot(self: *App, alloc: Allocator) !RuntimeContextSnapshot {
        return self.background.snapshot(alloc);
    }

    pub fn writeTranscript(self: *App, text: []const u8, record: bool) !void {
        try self.shell.writeTranscript(self.alloc, &self.metrics, text, record);
    }

    pub fn writeTranscriptClassified(self: *App, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        try self.shell.writeTranscriptClassified(self.alloc, &self.metrics, text, record, class);
    }

    pub fn writeCompletedToolStatus(
        self: *App,
        kind: types.ToolOutcomeKind,
        text: []const u8,
        record: bool,
    ) !void {
        try self.shell.writeCompletedToolStatus(self.alloc, &self.metrics, kind, text, record);
    }

    pub fn writeCompletedToolStatusReturningEntryId(
        self: *App,
        kind: types.ToolOutcomeKind,
        text: []const u8,
        record: bool,
    ) !u32 {
        return self.shell.writeCompletedToolStatusReturningEntryId(
            self.alloc,
            &self.metrics,
            kind,
            text,
            record,
        );
    }

    pub fn attachHistoricalToolDetail(
        self: *App,
        entry_id: u32,
        call: types.ToolCall,
        result: types.PersistedToolResult,
    ) !void {
        const activity_kind = tool_dispatch.toolActivityKindForCall(self.alloc, self.toolRegistry(), call);
        try self.shell.attachHistoricalToolDetail(self.alloc, entry_id, call, activity_kind, result);
    }

    pub fn attachHistoricalToolDetailWithLifecycle(
        self: *App,
        entry_id: u32,
        call: types.ToolCall,
        result: types.PersistedToolResult,
        lifecycle_id: types.ToolLifecycleId,
    ) !void {
        const activity_kind = tool_dispatch.toolActivityKindForCall(self.alloc, self.toolRegistry(), call);
        try self.shell.attachHistoricalToolDetailWithLifecycle(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
            lifecycle_id,
        );
    }

    pub fn attachHistoricalToolDetailAfterCommandOutput(
        self: *App,
        entry_id: u32,
        call: types.ToolCall,
        result: types.PersistedToolResult,
    ) !void {
        const activity_kind = tool_dispatch.toolActivityKindForCall(self.alloc, self.toolRegistry(), call);
        try self.shell.attachHistoricalToolDetailAfterCommandOutput(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
        );
    }

    pub fn writeHistoricalQuestionResolution(
        self: *App,
        answers: []const types.QuestionAnswer,
    ) !u32 {
        const text = try question_ui.composeResolvedQuestionAnswers(
            self.alloc,
            answers,
            self.shell.layout.cols,
        );
        defer self.alloc.free(text);
        return self.appendReplaceableTranscriptLine(text);
    }

    pub fn prepareHistoricalQuestionResolution(
        self: *App,
        answers: []const types.QuestionAnswer,
    ) ![]u8 {
        return question_ui.composeResolvedQuestionAnswers(
            self.alloc,
            answers,
            self.shell.layout.cols,
        );
    }

    pub fn attachHistoricalToolCallWithoutResult(
        self: *App,
        entry_id: u32,
        call: types.ToolCall,
    ) !void {
        try self.shell.attachHistoricalToolCallWithoutResult(self.alloc, entry_id, call);
    }

    pub fn attachHistoricalCommandOutput(self: *App, entry_id: u32) void {
        self.shell.attachHistoricalCommandOutput(self.alloc, entry_id);
    }

    pub fn attachHistoricalCancelledCommandDetail(
        self: *App,
        entry_id: u32,
        call: types.ToolCall,
        command_artifact_handle: ?[]const u8,
        replayed_output: bool,
    ) !void {
        try self.shell.attachHistoricalCancelledCommandDetail(
            self.alloc,
            entry_id,
            call,
            command_artifact_handle,
            replayed_output,
        );
    }

    pub fn appendReplaceableTranscriptLine(self: *App, text: []const u8) !u32 {
        return self.shell.appendReplaceableTranscriptLine(self.alloc, &self.metrics, text);
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *App, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        return self.shell.appendReplaceableTranscriptLineClassified(self.alloc, &self.metrics, text, class);
    }

    pub fn appendReplaceableTranscriptLineSilent(self: *App, text: []const u8) !u32 {
        return self.shell.appendReplaceableTranscriptLineSilent(self.alloc, text);
    }

    pub fn appendReplaceableTranscriptLineSilentClassified(self: *App, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        return self.shell.appendReplaceableTranscriptLineSilentClassified(self.alloc, text, class);
    }

    pub fn replaceTrailingTranscriptLine(self: *App, text: []const u8) !bool {
        return self.shell.replaceTrailingTranscriptLine(self.alloc, &self.metrics, text);
    }

    pub fn replaceTrailingTranscriptLineSilent(self: *App, text: []const u8) !bool {
        return self.shell.replaceTrailingTranscriptLineSilent(self.alloc, text);
    }

    pub fn writeDomainNotice(self: *App, notice: types.SemanticNotice, record: bool) !void {
        try self.shell.writeNotice(self.alloc, &self.metrics, notice, record);
    }

    pub fn submitDirectTerminal(self: *App, command: []const u8) !void {
        try app_terminal_runtime.Runtime(App).submitDirect(self, command);
    }

    pub fn requestTerminalOpen(
        self: *App,
        session_id: []const u8,
    ) app_terminal_runtime.OpenRequestResult {
        return app_terminal_runtime.Runtime(App).requestOpen(self, session_id);
    }

    pub fn appendDomainNotice(self: *App, notice: types.SemanticNotice) !u32 {
        return self.shell.appendSemanticNotice(self.alloc, notice);
    }

    pub fn appendReplaceableDomainNotice(self: *App, notice: types.SemanticNotice) !u32 {
        return self.shell.appendReplaceableSemanticNotice(self.alloc, notice);
    }

    pub fn replaceDomainNotice(self: *App, entry_id: u32, notice: types.SemanticNotice) !bool {
        return self.shell.replaceSemanticNotice(self.alloc, entry_id, notice);
    }

    pub fn writeCommandOutputChunk(self: *App, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        try self.shell.writeCommandOutputChunk(self.alloc, &self.metrics, RenderAppRuntime.shellStyles(), stream, text, record);
    }

    pub fn writeCommandOutputChunkForLifecycle(
        self: *App,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_output_content.Stream,
        text: []const u8,
        record: bool,
    ) !void {
        try self.shell.writeCommandOutputChunkForLifecycle(
            self.alloc,
            &self.metrics,
            RenderAppRuntime.shellStyles(),
            lifecycle_id,
            stream,
            text,
            record,
        );
    }

    pub fn flushCommandOutputSummary(self: *App, record: bool) !void {
        try self.shell.flushCommandOutputSummary(self.alloc, &self.metrics, RenderAppRuntime.shellStyles(), record);
    }

    pub fn flushCommandOutputSummaryForLifecycle(self: *App, lifecycle_id: ?types.ToolLifecycleId, record: bool) !void {
        try self.shell.flushCommandOutputSummaryForLifecycle(
            self.alloc,
            &self.metrics,
            RenderAppRuntime.shellStyles(),
            lifecycle_id,
            record,
        );
    }

    pub fn preparePersistedFileDiff(
        self: *App,
        presentation: types.CommittedFilePresentation,
    ) !agent_runtime.DiffEntryPayload {
        _ = self;
        const diff_mod = @import("core/output/diff.zig");
        return diff_mod.formatPersistedFileChangePayload(
            std.heap.c_allocator,
            presentation,
            .{
                .added_fg = ui_render.diff_added_style,
                .removed_fg = ui_render.diff_removed_style,
                .context_fg = ui_render.dim_style,
                .added_marker_fg = ui_render.diff_added_marker_style,
                .removed_marker_fg = ui_render.diff_removed_marker_style,
                .reset = ui_render.reset_style,
            },
        );
    }

    pub fn registerAndEmitDiffBlock(self: *App, payload: agent_runtime.DiffEntryPayload) !void {
        const diff_mod = @import("core/output/diff.zig");
        const c_alloc = std.heap.c_allocator;

        const id = self.next_diff_id;
        var appended = false;
        errdefer if (!appended) diff_mod.freeDiffEntryPayload(c_alloc, payload);

        try self.diff_entries.append(c_alloc, .{
            .id = id,
            .full = payload.full,
        });
        appended = true;
        self.next_diff_id += 1;

        defer c_alloc.free(payload.preview);
        const wrapped = try diff_mod.wrapWithMarkers(c_alloc, id, payload.preview);
        defer c_alloc.free(wrapped);
        try self.writeTranscriptClassified(wrapped, true, .diff_block);
    }

    pub fn fullTranscriptDiffResolver(self: *App) @import("ui/full_transcript_screen.zig").FullDiffResolver {
        return .{
            .context = self,
            .full_for_marker = fullDiffForMarker,
            .has_full_for_lifecycle = hasFullDiffForLifecycle,
        };
    }

    fn fullDiffForMarker(ctx: *anyopaque, id: u32) ?[]const u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        for (self.diff_entries.items) |entry| {
            if (entry.id != id) continue;
            const full = entry.full orelse return null;
            return full.content;
        }
        return null;
    }

    fn hasFullDiffForLifecycle(
        ctx: *anyopaque,
        lifecycle_id: types.ToolLifecycleId,
    ) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        for (self.diff_entries.items) |entry| {
            const full = entry.full orelse continue;
            if (full.lifecycle_id.turn_id != lifecycle_id.turn_id) continue;
            if (std.mem.eql(u8, full.lifecycle_id.call_id, lifecycle_id.call_id)) return true;
        }
        return false;
    }

    pub fn fullTranscriptSidecarCapability(self: *App) ?*session_child_store.SessionChildCapability {
        return SessionAppRuntime.childCapability(self);
    }

    pub fn pacerEmit(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ctx));
        _ = try self.shell.streamAssistantChunk(self.alloc, &self.metrics, text);
    }

    pub fn appendAssistantTable(self: *App, table: assistant_presentation.TablePayload) !void {
        _ = try self.shell.appendAssistantTableOwned(self.alloc, table);
    }

    pub fn appendAssistantCodeBlock(self: *App, block: assistant_presentation.CodeBlockPayload) !void {
        _ = try self.shell.appendAssistantCodeBlockOwned(self.alloc, block);
    }

    pub fn appendAssistantThematicRule(self: *App) !void {
        _ = try self.shell.appendAssistantThematicRule(self.alloc);
    }

    pub fn appendHistoryTurn(self: *App, turn: types.HistoryTurn) !void {
        try SessionAppRuntime.appendHistoryTurn(self, turn);
    }

    pub fn persistRuntimePreferences(
        self: *App,
        patch: app_session_runtime.SessionPreferencePatch,
    ) app_session_runtime.PreferenceCommitResult {
        return SessionAppRuntime.commitRuntimePreferences(self, patch);
    }

    pub fn appendFinishedPrompt(self: *App, finished: types.FinishedPrompt) !void {
        try SessionAppRuntime.appendFinishedPrompt(self, finished);
        if (finished.summary) |summary| {
            _ = try self.shell.appendTurnSummaryEntry(self.alloc, summary);
        }
    }

    pub fn pacerFinish(ctx: *anyopaque, finished: types.FinishedPrompt) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ctx));
        try self.appendFinishedPrompt(finished);
        self.notificationPresentationFinished();
    }

    pub fn pacerCallbacks(self: *App) assistant_pacer.TickCallbacks {
        return .{
            .emit_ctx = self,
            .emit_fn = App.pacerEmit,
            .finish_ctx = self,
            .finish_fn = App.pacerFinish,
        };
    }

    fn nativeClearProbeEligible(self: *const App, byte: u8) bool {
        if (byte < 32 or byte == 127) return false;
        if (io_mod.getenv("TMUX") != null) return false;
        if (self.terminal_input_runtime.native_clear_probe.disabled() or
            self.terminal_input_runtime.native_clear_probe.active() or
            self.input_runtime.paste.active() or
            self.terminal_input_runtime.hasPendingTerminalAction() or
            self.question_prompt.isActive() or
            self.approval_prompt.isActive() or
            self.auth.apiKeyEntryActive() or
            self.subagents.isViewActive() or
            !self.shell.has_committed_frame or
            !self.shell.footer_viewport.has_frame or
            self.shell.footer_viewport.cursor.row == 0 or
            self.shell.layout.cols < cursor_probe.confirmation_tag_column or
            !shell_runtime.resizeLifecycleIdle(&self.shell) or
            resize_interlock.resizePending() or
            !self.terminal_input_runtime.terminal_cursor_probe.canBegin())
        {
            return false;
        }
        return true;
    }

    pub fn prepareApiKeyInputBoundary(self: *App) void {
        if (self.terminal_input_runtime.native_clear_probe.active()) {
            const discarded = self.terminal_input_runtime.native_clear_probe.settle().len;
            self.terminal_input_runtime.native_clear_probe.clearSettledInput();
            debug_trace.logf(
                "auth",
                "api key stage discarded native-clear probe input bytes={d}",
                .{discarded},
            );
        }

        self.terminal_input_runtime.terminal_cursor_probe.cancel();
        var discarded: usize = 0;
        while (self.terminal_input_runtime.terminal_cursor_probe.takeDeferredByte()) |byte| {
            _ = byte;
            std.debug.assert(self.terminal_input_runtime.terminal_cursor_probe.consumeDeferredInputDispatch());
            discarded += 1;
        }
        if (discarded > 0) {
            debug_trace.logf(
                "auth",
                "api key stage discarded cursor-probe input bytes={d}",
                .{discarded},
            );
        }
    }

    fn replayNativeClearProbeInput(self: *App) !void {
        const retained = self.terminal_input_runtime.native_clear_probe.settle();
        defer self.terminal_input_runtime.native_clear_probe.clearSettledInput();
        for (retained) |retained_byte| {
            try self.handleTerminalInputByte(retained_byte);
            if (self.should_exit) return;
        }
    }

    fn handleTerminalInputByte(self: *App, byte: u8) !void {
        const context = try InputAppRuntime.prepareTerminalDecode(self) orelse return;
        const ingress = self.terminal_input_runtime.decodeTerminalByte(
            byte,
            context,
        );
        try self.routeTerminalInputIngress(ingress);
    }

    fn routeTerminalInputIngress(
        self: *App,
        initial_ingress: input_action.TerminalInputIngress,
    ) !void {
        var ingress = initial_ingress;
        while (true) {
            const replay_byte = try InputAppRuntime.handleTerminalInputIngressWithLimits(
                self,
                ingress,
                input_limits,
                max_prompt_history,
            );
            const replay = replay_byte orelse return;
            const context = try InputAppRuntime.prepareTerminalDecode(self) orelse return;
            ingress = self.terminal_input_runtime.decodeTerminalByte(replay, context);
        }
    }

    fn finishNativeClearProbe(self: *App, reset_visual_epoch: bool) !void {
        if (reset_visual_epoch) {
            _ = try RenderAppRuntime.resetVisualEpoch(self, .native_clear_probe);
        }
        try self.replayNativeClearProbeInput();
    }

    fn retainDeferredNativeClearProbeInput(self: *App) !bool {
        while (self.terminal_input_runtime.terminal_cursor_probe.takeDeferredByte()) |deferred| {
            if (!self.terminal_input_runtime.native_clear_probe.canRetainBytes(1)) {
                std.debug.assert(self.terminal_input_runtime.terminal_cursor_probe.consumeDeferredInputDispatch());
                try self.finishNativeClearProbe(false);
                try self.handleTerminalInputByte(deferred);
                while (self.terminal_input_runtime.terminal_cursor_probe.takeDeferredByte()) |remaining| {
                    std.debug.assert(self.terminal_input_runtime.terminal_cursor_probe.consumeDeferredInputDispatch());
                    try self.handleTerminalInputByte(remaining);
                    if (self.should_exit) break;
                }
                return false;
            }
            try self.terminal_input_runtime.native_clear_probe.retainBytes(self.alloc, &.{deferred});
            std.debug.assert(self.terminal_input_runtime.terminal_cursor_probe.consumeDeferredInputDispatch());
        }
        return true;
    }

    fn beginNativeClearProbe(self: *App, byte: u8) !bool {
        if (!self.nativeClearProbeEligible(byte)) return false;

        const expected_row = self.shell.footer_viewport.cursor.row;
        try self.terminal_input_runtime.native_clear_probe.begin(self.alloc, expected_row, byte);
        self.terminal_input_runtime.terminal_cursor_probe.begin(
            .ansi_tagged,
            io_mod.milliTimestamp() + cursor_probe.response_idle_timeout_ms,
        ) catch {
            try self.replayNativeClearProbeInput();
            return true;
        };
        self.terminal.requestResizeCursorPosition(.ansi_tagged) catch |err| {
            self.terminal_input_runtime.terminal_cursor_probe.cancel();
            self.terminal_input_runtime.native_clear_probe.disable(false);
            debug_trace.logf("native_clear", "native_clear_probe_write_failed err={s}", .{@errorName(err)});
            try self.replayNativeClearProbeInput();
            return true;
        };
        debug_trace.logf(
            "native_clear",
            "native_clear_probe requested expected_row={d}",
            .{expected_row},
        );
        return true;
    }

    fn handleNativeClearProbeInput(self: *App, byte: u8) !void {
        self.terminal_input_runtime.terminal_cursor_probe.noteInputActivity(io_mod.milliTimestamp());
        switch (self.terminal_input_runtime.terminal_cursor_probe.feed(byte)) {
            .pending => {},
            .position => |position| {
                const expected_row = self.terminal_input_runtime.native_clear_probe.expectedRow();
                const reset_visual_epoch = position.row != expected_row;
                debug_trace.logf(
                    "native_clear",
                    "native_clear_probe {s} expected_row={d} observed_row={d}",
                    .{ if (reset_visual_epoch) "mismatch" else "match", expected_row, position.row },
                );
                try self.finishNativeClearProbe(reset_visual_epoch);
            },
            .late_response => {
                debug_trace.logf("native_clear", "native_clear_probe_late_response_discarded", .{});
            },
            .forward => |forwarded| {
                if (self.terminal_input_runtime.native_clear_probe.canRetainBytes(forwarded.slice().len)) {
                    try self.terminal_input_runtime.native_clear_probe.retainBytes(self.alloc, forwarded.slice());
                    return;
                }

                _ = self.terminal_input_runtime.terminal_cursor_probe.expire(io_mod.milliTimestamp());
                self.terminal_input_runtime.native_clear_probe.disable(true);
                debug_trace.logf("native_clear", "native_clear_probe_overflow", .{});
                if (try self.retainDeferredNativeClearProbeInput()) {
                    try self.finishNativeClearProbe(false);
                }
                for (forwarded.slice()) |forwarded_byte| {
                    try self.handleTerminalInputByte(forwarded_byte);
                    if (self.should_exit) return;
                }
            },
        }
    }

    fn collectNativeClearProbeFacts(self: *App) !void {
        switch (self.terminal_input_runtime.terminal_cursor_probe.poll(io_mod.milliTimestamp())) {
            .none => {},
            .probe_timed_out => {
                self.terminal_input_runtime.native_clear_probe.disable(true);
                debug_trace.logf("native_clear", "native_clear_probe_timeout", .{});
                if (!try self.retainDeferredNativeClearProbeInput()) {
                    debug_trace.logf("native_clear", "native_clear_probe_overflow", .{});
                    return;
                }
                try self.finishNativeClearProbe(false);
            },
            .late_window_expired => {
                self.terminal_input_runtime.native_clear_probe.finishLateResponse();
                debug_trace.logf("native_clear", "native_clear_probe_late_window_expired", .{});
            },
        }
    }

    fn collectThemeFacts(self: *App) !void {
        const now_ms = io_mod.milliTimestamp();
        self.terminal_input_runtime.terminal_theme_monitor.poll(now_ms);

        // FX_THEME forces colors via detectTheme; keep owning protocol bytes
        // (monitor started) but never query or apply live theme updates.
        if (ui_render.explicitThemeOverride() != null) {
            _ = self.terminal_input_runtime.terminal_theme_monitor.takeSettledUpdate();
            return;
        }

        if (self.terminal_input_runtime.terminal_theme_monitor.takeSettledUpdate()) |update| {
            debug_trace.logf("theme", "theme_update_settled light={s} rgb={s}", .{
                if (update.light) "true" else "false",
                if (update.rgb == null) "fallback" else "terminal",
            });
            try RenderAppRuntime.applyThemeUpdate(self, update.light, update.rgb);
        }
        if (InputAppRuntime.terminalPasteActive(self) or
            self.terminal_input_runtime.native_clear_probe.active() or
            self.terminal_input_runtime.native_clear_probe.awaitingLateResponse())
        {
            return;
        }
        if (self.terminal_input_runtime.terminal_theme_monitor.takeQueryRequest(now_ms)) |request| {
            debug_trace.logf("theme", "theme_query_requested kind={s}", .{@tagName(request)});
            const query_result = switch (request) {
                .response_fence => self.terminal.requestThemeResponseFence(),
                .background => self.terminal.requestThemeBackground(),
            };
            query_result catch |err| {
                self.terminal_input_runtime.terminal_theme_monitor.failQuery(now_ms);
                debug_trace.logf("theme", "theme_query_failed kind={s} err={s}", .{
                    @tagName(request),
                    @errorName(err),
                });
            };
        }
    }

    pub fn loopCollectFacts(ctx: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (!try WorkerAppRuntime.authorizeInteractiveAdmission(self)) return;

        if (!self.terminal_takeover.blocksFxSurface(&self.terminal)) {
            try self.collectThemeFacts();
        } else {
            self.terminal_input_runtime.terminal_theme_monitor.poll(io_mod.milliTimestamp());
        }

        if (comptime !host_target.is_wasm) {
            UpgradeAppRuntime.collectUpgradeFacts(self);
        }
        app_permission_runtime.Runtime(App).tick(
            self,
            app_permission_runtime.monotonicMillis(),
        );

        if (comptime !host_target.is_wasm) {
            if (self.file_index.joinThreadIfDone(std.heap.c_allocator)) {
                self.shell.render_requests.request(.footer);
            }
        }
        if (try self.model_cache.pollLoadTransition()) {
            RenderAppRuntime.requestActiveSurfaceFrame(self, .footer);
        }
        try app_commands.Handlers(App).collectMcpReloadFacts(self);
        if (comptime host_profile.native_auth or host_profile.js_host_auth) {
            try AuthAppRuntime.collectSignInFacts(self);
        }
        if (comptime host_profile.native_auth) {
            try AuthAppRuntime.collectApiKeySaveFacts(self);
            try app_terminal_runtime.Runtime(App).collectFacts(self);
        }
        try self.processNextCooperativePrompt();

        const cols_before_resize = self.shell.layout.cols;
        if (self.terminal_takeover.blocksFxSurface(&self.terminal)) {
            self.shell.layout = self.terminal.queryLayout(footer_rows) catch
                self.shell.layout;
        } else if (self.terminal_input_runtime.native_clear_probe.active() or
            self.terminal_input_runtime.native_clear_probe.awaitingLateResponse())
        {
            try self.collectNativeClearProbeFacts();
        } else {
            shell_runtime.collectResizeFacts(
                self.terminal,
                &self.shell,
                &self.metrics,
                &self.terminal_input_runtime.terminal_cursor_probe,
                &resize_interlock,
                footer_rows,
                resize_debounce_ms,
                !InputAppRuntime.terminalPasteActive(self) and !self.auth.apiKeyEntryActive(),
            ) catch |err| {
                if (err != error.TerminalTooSmall and err != error.UnableToReadTerminalSize) {
                    return err;
                }
            };
        }
        try self.terminal_takeover.collect(App, self);

        // Terminal width changed with the modal open, so the footer
        // panel needs to re-wrap labels and descriptions.
        if (self.question_prompt.isActive() and cols_before_resize != self.shell.layout.cols) {
            self.shell.render_requests.request(.modal);
        }
        if (cols_before_resize != self.shell.layout.cols) {
            self.input_runtime.vertical_navigation.reset();
        }

        if (comptime !host_target.is_wasm) {
            try SessionAppRuntime.pollSessionPicker(self);
        }
        if (!self.terminal_takeover.blocksFxSurface(&self.terminal)) {
            const input_now_ms = io_mod.milliTimestamp();
            InputAppRuntime.expireTerminalInputGestures(self, input_now_ms);
            const terminal_input = self.terminal_input_runtime.flushTerminalAction(
                input_now_ms,
                input_escape_timeout_ms,
                InputAppRuntime.terminalPasteActive(self),
            );
            try self.routeTerminalInputIngress(terminal_input);
        }
        try WorkerAppRuntime.tick(self, app_callbacks.Bindings(App).onTaskCompletion, app_callbacks.Bindings(App).workerEventHandlers(self));
        const now_ns = io_mod.nanoTimestamp();
        if (!self.approval_prompt.isActive() and !self.question_prompt.isActive() and !self.auth.apiKeyEntryActive()) {
            try self.pacer.tick(self.alloc, now_ns, self.pacerCallbacks());
        } else {
            self.pacer.pause(now_ns);
        }
    }

    pub fn loopCommitFrame(ctx: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (!try WorkerAppRuntime.authorizeInteractiveAdmission(self)) return;
        if (try self.terminal_takeover.commit(App, self)) return;
        if (self.terminal_input_runtime.native_clear_probe.active()) return;
        _ = self.admitPendingResizeSignal("post_input");
        try self.flushRequestedFrame();
    }

    pub fn admitPendingApprovalResize(self: *App) bool {
        return self.admitPendingResizeSignal("approval_input");
    }

    pub fn claimApprovalAffirmative(_: *App) bool {
        return resize_interlock.claimAffirmative();
    }

    pub fn releaseApprovalAffirmative(_: *App) void {
        resize_interlock.releaseAffirmative();
    }

    fn admitPendingResizeSignal(self: *App, source: []const u8) bool {
        return shell_runtime.admitResizeSignal(
            &self.shell,
            &resize_interlock,
            io_mod.milliTimestamp(),
            resize_debounce_ms,
            source,
        );
    }

    fn handleCursorDeferredInputByte(self: *App, byte: u8) !void {
        if (self.terminal_input_runtime.native_clear_probe.active()) {
            if (self.terminal_input_runtime.native_clear_probe.canRetainBytes(1)) {
                try self.terminal_input_runtime.native_clear_probe.retainBytes(self.alloc, &.{byte});
                return;
            }

            _ = self.terminal_input_runtime.terminal_cursor_probe.expire(io_mod.milliTimestamp());
            self.terminal_input_runtime.native_clear_probe.disable(true);
            debug_trace.logf("native_clear", "native_clear_probe_overflow", .{});
            try self.finishNativeClearProbe(false);
        }
        try self.handleTerminalInputByte(byte);
    }

    fn routeActivePasteTransportByte(self: *App, byte: u8) !bool {
        return InputAppRuntime.routeActivePasteIngressByteWithLimits(
            self,
            byte,
            input_limits,
            max_prompt_history,
        );
    }

    fn handleAfterThemeMonitorByte(self: *App, byte: u8) !void {
        if (try self.routeActivePasteTransportByte(byte)) return;
        if (try self.terminal_takeover.handleByte(App, self, byte)) return;
        if (!self.terminal_input_runtime.terminal_cursor_probe.interceptsInput()) {
            if (try self.beginNativeClearProbe(byte)) return;
            try self.handleTerminalInputByte(byte);
            return;
        }

        if (self.terminal_input_runtime.native_clear_probe.active()) {
            try self.handleNativeClearProbeInput(byte);
            return;
        }

        self.terminal_input_runtime.terminal_cursor_probe.noteInputActivity(io_mod.milliTimestamp());
        switch (self.terminal_input_runtime.terminal_cursor_probe.feed(byte)) {
            .pending => {},
            .position => |position| {
                shell_runtime.completeResizeCursorProbe(&self.shell, position);
            },
            .late_response => {
                if (self.terminal_input_runtime.native_clear_probe.awaitingLateResponse()) {
                    self.terminal_input_runtime.native_clear_probe.finishLateResponse();
                    debug_trace.logf("native_clear", "native_clear_probe_late_response_discarded", .{});
                } else {
                    debug_trace.logf("resize", "cursor_measure_late_response_discarded", .{});
                }
            },
            .forward => |forwarded| {
                for (forwarded.slice()) |forwarded_byte| {
                    try self.handleTerminalInputByte(forwarded_byte);
                    if (self.should_exit) return;
                }
            },
        }
    }

    fn handleThemeMonitorByte(self: *App, byte: u8) !void {
        switch (self.terminal_input_runtime.terminal_theme_monitor.feed(
            byte,
            io_mod.milliTimestamp(),
        )) {
            .pending, .consumed => {},
            .forward => |forwarded| {
                for (forwarded.slice()) |forwarded_byte| {
                    try self.handleAfterThemeMonitorByte(forwarded_byte);
                    if (self.should_exit) return;
                }
            },
        }
    }

    pub fn loopHandleByte(ctx: *anyopaque, byte: u8) !void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (!try WorkerAppRuntime.authorizeInteractiveAdmission(self)) return;
        const deferred_source = self.terminal_input_runtime.consumeDeferredTerminalInputDispatch();

        if (deferred_source) |source| {
            switch (source) {
                .cursor_probe => {
                    if (try self.routeActivePasteTransportByte(byte)) return;
                    if (!try self.terminal_takeover.handleByte(App, self, byte)) {
                        try self.handleCursorDeferredInputByte(byte);
                    }
                },
                .theme_monitor => try self.handleAfterThemeMonitorByte(byte),
            }
            return;
        }

        switch (ui_input.terminalInputOwner(
            &self.terminal_input_runtime.terminal_theme_monitor,
            InputAppRuntime.terminalPasteActive(self),
            true,
        )) {
            .theme_monitor => {
                try self.handleThemeMonitorByte(byte);
                return;
            },
            .paste => {
                const routed = try self.routeActivePasteTransportByte(byte);
                std.debug.assert(routed);
                return;
            },
            .takeover, .fx_input => {},
        }

        if (try self.terminal_takeover.handleByte(App, self, byte)) return;
        if (self.terminal_input_runtime.terminal_theme_monitor.enabled) {
            try self.handleThemeMonitorByte(byte);
            return;
        }
        try self.handleAfterThemeMonitorByte(byte);
    }

    pub fn loopSettleInputDeliveryEpoch(ctx: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (!InputAppRuntime.terminalPasteActive(self)) return;
        try InputAppRuntime.settleTerminalPasteDeliveryEpochWithLimits(
            self,
            input_limits,
        );
    }

    pub fn loopNextCollectedByte(ctx: *anyopaque) ?u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.terminal_takeover.blocksFxSurface(&self.terminal)) {
            return self.terminal_input_runtime.takeDeferredThemeMonitorByte();
        }
        return self.terminal_input_runtime.takeDeferredTerminalInputByte();
    }
};

comptime {
    if (!builtin.is_test and !host_target.is_wasm) {
        @export(&main, .{ .name = "main" });
    }
}

pub fn runWasmTerminal(init: std.process.Init) !void {
    if (comptime !host_target.is_wasm or build_options.wasm_surface != .term) {
        @compileError("runWasmTerminal requires -Dwasm-surface=term");
    }
    io_mod.setIo(init.io);
    io_mod.setEnvironMap(init.environ_map);
    const alloc = std.heap.c_allocator;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args.deinit();
    _ = args.skip();
    var cli_args: std.ArrayList([:0]const u8) = .empty;
    defer cli_args.deinit(alloc);
    while (args.next()) |arg| try cli_args.append(alloc, arg);

    const parsed = try cli_surface.parseInteractiveLaunch(
        alloc,
        cli_args.items,
        builtin_commands.top_level_registry,
    );
    var launch = switch (parsed) {
        .interactive => |value| value,
        .noninteractive => |value| {
            var noninteractive = value;
            defer noninteractive.deinit(alloc);
            return error.WasmTerminalInteractiveLaunchRequired;
        },
    };
    defer launch.deinit(alloc);
    const outcome = try app_entry_runtime.runInteractiveCooperative(App, alloc, &launch);
    switch (outcome) {
        .returned => {},
        .exit => |code| if (code != 0) return error.WasmTerminalExited,
    }
}

pub fn main(c_argc: c_int, c_argv: [*][*:0]c_char, c_envp: [*:null]?[*:0]c_char) callconv(.c) c_int {
    mainC(c_argc, c_argv, c_envp) catch return 1;
    return 0;
}

fn mainC(c_argc: c_int, c_argv: [*][*:0]c_char, c_envp: [*:null]?[*:0]c_char) !void {
    const raw_args = rawArgs(c_argc, c_argv);
    const raw_env: RawEnviron = @ptrCast(c_envp);

    if (comptime terminal_host.isSupported()) {
        if (terminal_tmux_session.isCaptureModeRaw(raw_args)) {
            io_mod.setRawEnviron(raw_env);
            const process_args = argsFromRaw(raw_args);
            var threaded = std.Io.Threaded.init(processAllocator(), .{
                .argv0 = .init(process_args),
                .environ = .{ .block = environBlockFromRaw(raw_env) },
            });
            defer threaded.deinit();
            io_mod.setIo(threaded.io());
            try terminal_tmux_session.runCapture(raw_args);
            return;
        }
        if (terminal_tmux_session.isLauncherModeRaw(raw_args)) {
            io_mod.setRawEnviron(raw_env);
            const process_args = argsFromRaw(raw_args);
            var threaded = std.Io.Threaded.init(processAllocator(), .{
                .argv0 = .init(process_args),
                .environ = .{ .block = environBlockFromRaw(raw_env) },
            });
            defer threaded.deinit();
            io_mod.setIo(threaded.io());
            try terminal_tmux_session.runLauncher(
                processAllocator(),
                background_process.provider,
                raw_args,
            );
            return;
        }
        if (terminal_native_session.isControlModeRaw(raw_args)) {
            io_mod.setRawEnviron(raw_env);
            const process_args = argsFromRaw(raw_args);
            var threaded = std.Io.Threaded.init(processAllocator(), .{
                .argv0 = .init(process_args),
                .environ = .{ .block = environBlockFromRaw(raw_env) },
            });
            defer threaded.deinit();
            io_mod.setIo(threaded.io());
            try terminal_native_session.runControlMarker(raw_args);
            return;
        }
        if (terminal_native_session.isLauncherModeRaw(raw_args)) {
            io_mod.setRawEnviron(raw_env);
            const process_args = argsFromRaw(raw_args);
            var threaded = std.Io.Threaded.init(processAllocator(), .{
                .argv0 = .init(process_args),
                .environ = .{ .block = environBlockFromRaw(raw_env) },
            });
            defer threaded.deinit();
            io_mod.setIo(threaded.io());
            try terminal_native_session.runLauncher(processAllocator());
            return;
        }
        if (terminal_host.isInternalModeRaw(raw_args)) {
            io_mod.setRawEnviron(raw_env);
            const process_args = argsFromRaw(raw_args);
            var threaded = std.Io.Threaded.init(processAllocator(), .{
                .argv0 = .init(process_args),
                .environ = .{ .block = environBlockFromRaw(raw_env) },
            });
            defer threaded.deinit();
            io_mod.setIo(threaded.io());
            defer debug_trace.shutdown();
            debug_trace.configureFromEnv(processAllocator(), ".");
            try terminal_host.run(
                processAllocator(),
                try terminal_host.Config.fromEnvironment(
                    background_process.provider,
                ),
            );
            return;
        }
    }

    if (shouldRunBenchmarkNoArgRaw(raw_args, raw_env)) {
        switch (cli_surface.parse(builtin_commands.top_level_registry, &.{})) {
            .interactive => exitFast(0),
            else => exitFast(1),
        }
    }

    var cli_arg_buf: [64][:0]const u8 = undefined;
    const cli_args = if (raw_args.len <= 1) &.{} else try cliArgsFromRaw(raw_args, &cli_arg_buf);
    if (command_runner.isForegroundSessionInvocation(cli_args)) {
        io_mod.setRawEnviron(raw_env);
        const process_args = argsFromRaw(raw_args);
        var threaded = std.Io.Threaded.init(processAllocator(), .{
            .argv0 = .init(process_args),
            .environ = .{ .block = environBlockFromRaw(raw_env) },
        });
        defer threaded.deinit();
        io_mod.setIo(threaded.io());
        try command_runner.runForegroundSessionBootstrap(cli_args);
        return;
    }
    _ = cli_surface.recordRequested(cli_args) catch {
        try writeStderrFast(cli_surface.record_modifier_usage);
        exitFast(1);
    };
    if (cli_args.len > 0 and isTopLevelHelp(cli_args)) {
        try writeTopLevelHelpFast(raw_env);
        exitFast(0);
    }
    try runNonBenchmark(raw_args, raw_env, cli_args);
}

fn writeTopLevelHelpFast(raw_env: RawEnviron) !void {
    const columns = topLevelHelpColumns(raw_env);
    const style = topLevelHelpStyle(raw_env);
    var buffer: [builtin_commands.top_level_help_fast_buffer_bytes]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const text = try command_specs.renderTopLevelHelpWithStyle(
        fixed.allocator(),
        builtin_commands.top_level_registry,
        columns,
        version,
        style,
    );
    try writeStdoutFast(text);
}

fn runNonBenchmark(raw_args: []const [*:0]const u8, raw_env: RawEnviron, cli_args: []const [:0]const u8) !void {
    io_mod.setRawEnviron(raw_env);

    const alloc = processAllocator();
    const cfg = if (cli_args.len == 0)
        emptyEntryConfig()
    else if (needsFullEntryConfig(cli_args))
        fullEntryConfig()
    else
        localEntryConfig();

    var early_threaded: ?std.Io.Threaded = null;
    defer if (early_threaded) |*threaded| threaded.deinit();
    if (needsEarlyThreadedIo(cli_args)) {
        const env_block = environBlockFromRaw(raw_env);
        const process_args = argsFromRaw(raw_args);
        early_threaded = std.Io.Threaded.init(alloc, .{
            .argv0 = .init(process_args),
            .environ = .{ .block = env_block },
        });
        if (early_threaded) |*threaded| io_mod.setIo(threaded.io());
    }

    const before = try app_entry_runtime.runBeforeInteractive(alloc, cli_args, cfg);
    switch (before) {
        .interactive => |launch| {
            const env_block = environBlockFromRaw(raw_env);
            const process_args = argsFromRaw(raw_args);
            var threaded = std.Io.Threaded.init(alloc, .{
                .argv0 = .init(process_args),
                .environ = .{ .block = env_block },
            });
            defer threaded.deinit();
            io_mod.setIo(threaded.io());

            var owned_launch = launch;
            defer owned_launch.deinit(alloc);
            defer debug_trace.shutdown();

            const outcome = try app_entry_runtime.runInteractive(App, alloc, &owned_launch);
            switch (outcome) {
                .returned => return,
                .exit => |code| std.process.exit(code),
            }
        },
        .returned => exitFast(0),
        .exit => |code| exitFast(code),
    }
}

fn rawArgs(c_argc: c_int, c_argv: [*][*:0]c_char) []const [*:0]const u8 {
    const argc: usize = @intCast(c_argc);
    const argv: [*][*:0]const u8 = @ptrCast(c_argv);
    return argv[0..argc];
}

fn argsFromRaw(raw_args: []const [*:0]const u8) std.process.Args {
    return .{ .vector = raw_args };
}

fn environBlockFromRaw(raw_env: RawEnviron) std.process.Environ.Block {
    var count: usize = 0;
    while (raw_env[count] != null) : (count += 1) {}
    return .{ .slice = raw_env[0..count :null] };
}

fn shouldRunBenchmarkNoArgRaw(raw_args: []const [*:0]const u8, raw_env: RawEnviron) bool {
    return raw_args.len <= 1 and benchmarkEnvPresent(raw_env);
}

fn benchmarkEnvPresent(raw_env: RawEnviron) bool {
    if (comptime builtin.link_libc) {
        if (std.c.getenv("FX_BENCH") != null) return true;
    }
    return rawEnvHas(raw_env, "FX_BENCH");
}

fn rawEnvHas(raw_env: RawEnviron, comptime key: []const u8) bool {
    return rawEnvValue(raw_env, key) != null;
}

fn rawEnvValue(raw_env: RawEnviron, comptime key: []const u8) ?[]const u8 {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (raw_env[i]) |entry_z| : (i += 1) {
        const entry = std.mem.sliceTo(entry_z, 0);
        if (entry.len <= key.len or entry[key.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..key.len], key)) return entry[key.len + 1 ..];
    }
    return null;
}

fn topLevelHelpColumns(raw_env: RawEnviron) usize {
    if (stdoutTerminalColumns()) |columns| return columns;
    if (rawEnvValue(raw_env, "COLUMNS")) |value| {
        if (parseColumnCount(value)) |columns| return columns;
    }
    if (comptime builtin.link_libc) {
        if (std.c.getenv("COLUMNS")) |value_z| {
            if (parseColumnCount(std.mem.sliceTo(value_z, 0))) |columns| return columns;
        }
    }
    return command_specs.top_level_help_default_width;
}

fn topLevelHelpStyle(raw_env: RawEnviron) command_specs.HelpStyle {
    const no_color = rawEnvHas(raw_env, "NO_COLOR");
    const dumb_terminal = if (rawEnvValue(raw_env, "TERM")) |term| std.mem.eql(u8, term, "dumb") else false;
    return topLevelHelpStyleForValues(stdoutIsTerminal(), no_color, dumb_terminal);
}

fn topLevelHelpStyleForValues(is_terminal: bool, no_color: bool, dumb_terminal: bool) command_specs.HelpStyle {
    return if (is_terminal and !no_color and !dumb_terminal) .ansi else .plain;
}

fn stdoutIsTerminal() bool {
    if (comptime builtin.os.tag == .windows or !builtin.link_libc) return false;
    return std.c.isatty(std.posix.STDOUT_FILENO) != 0;
}

fn stdoutTerminalColumns() ?usize {
    if (comptime builtin.os.tag == .windows or !builtin.link_libc) return null;

    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const req: c_int = @intCast(std.c.T.IOCGWINSZ);
    const rc = std.c.ioctl(std.posix.STDOUT_FILENO, req, &ws);
    if (rc == -1 or ws.col == 0) return null;
    return @intCast(ws.col);
}

fn parseColumnCount(value: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    const columns = std.fmt.parseUnsigned(usize, trimmed, 10) catch return null;
    return if (columns == 0) null else columns;
}

fn cliArgsFromRaw(raw_args: []const [*:0]const u8, stack_buf: [][:0]const u8) ![]const [:0]const u8 {
    @setRuntimeSafety(false);
    if (comptime hasPosixArgVector()) {
        if (raw_args.len <= 1) return &.{};
        const cli_len = raw_args.len - 1;
        if (cli_len <= stack_buf.len) {
            for (raw_args[1..], 0..) |arg, i| {
                stack_buf[i] = std.mem.sliceTo(arg, 0);
            }
            return stack_buf[0..cli_len];
        }
    }

    const args = try argsFromRaw(raw_args).toSlice(processAllocator());
    return if (args.len > 0) args[1..] else args[0..0];
}

fn isTopLevelHelp(args: []const [:0]const u8) bool {
    if (args.len == 0) return false;
    return command_specs.matchesTopLevel(builtin_commands.top_level_registry, args[0], .help);
}

fn processAllocator() Allocator {
    if (comptime builtin.link_libc) return std.heap.c_allocator;
    return std.heap.page_allocator;
}

fn writeStdoutFast(text: []const u8) !void {
    @setRuntimeSafety(false);
    if (comptime builtin.os.tag != .windows) {
        var remaining = text;
        while (remaining.len > 0) {
            const written = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
            if (written <= 0) return error.WriteFailed;
            remaining = remaining[@intCast(written)..];
        }
        return;
    }
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeStderrFast(text: []const u8) !void {
    @setRuntimeSafety(false);
    if (comptime builtin.os.tag != .windows) {
        var remaining = text;
        while (remaining.len > 0) {
            const written = std.c.write(std.posix.STDERR_FILENO, remaining.ptr, remaining.len);
            if (written <= 0) return error.WriteFailed;
            remaining = remaining[@intCast(written)..];
        }
        return;
    }
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

fn exitFast(code: u8) noreturn {
    if (comptime builtin.link_libc and builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        std.c._exit(@intCast(code));
    }
    std.process.exit(code);
}

fn hasPosixArgVector() bool {
    return switch (builtin.os.tag) {
        .windows, .freestanding, .other => false,
        .wasi => builtin.link_libc,
        else => true,
    };
}

fn needsFullEntryConfig(args: []const [:0]const u8) bool {
    const command = cli_surface.commandAfterGlobalLaunchArgs(args) orelse return false;
    return std.mem.eql(u8, command, "ask") or
        std.mem.eql(u8, command, "acp") or
        std.mem.eql(u8, command, "pr") or
        std.mem.eql(u8, command, "issue");
}

fn needsEarlyThreadedIo(args: []const [:0]const u8) bool {
    if (needsFullEntryConfig(args)) return true;
    const command = cli_surface.commandAfterGlobalLaunchArgs(args) orelse return false;
    return std.mem.eql(u8, command, "login") or
        std.mem.eql(u8, command, "logout") or
        std.mem.eql(u8, command, "teams") or
        std.mem.eql(u8, command, "provider") or
        std.mem.eql(u8, command, "setup") or
        std.mem.eql(u8, command, "upgrade") or
        // Resolve a stored credential, which reads the platform key store out of process.
        std.mem.eql(u8, command, "status") or
        std.mem.eql(u8, command, "doctor") or
        std.mem.eql(u8, command, "models") or
        std.mem.eql(u8, command, "credits");
}

test "auth and upgrade commands use early threaded io without full entry config" {
    const args = &.{@as([:0]const u8, "upgrade")};
    try std.testing.expect(!needsFullEntryConfig(args));
    try std.testing.expect(needsEarlyThreadedIo(args));
    try std.testing.expect(needsEarlyThreadedIo(&.{@as([:0]const u8, "login")}));
    try std.testing.expect(needsEarlyThreadedIo(&.{@as([:0]const u8, "logout")}));
    try std.testing.expect(needsEarlyThreadedIo(&.{@as([:0]const u8, "teams")}));
    try std.testing.expect(needsEarlyThreadedIo(&.{@as([:0]const u8, "provider")}));
    try std.testing.expect(needsEarlyThreadedIo(&.{@as([:0]const u8, "setup")}));
}

test "credential-reading commands use early threaded io without full entry config" {
    for ([_][:0]const u8{ "status", "doctor", "models", "credits" }) |command| {
        const args = &.{command};
        try std.testing.expect(!needsFullEntryConfig(args));
        try std.testing.expect(needsEarlyThreadedIo(args));
    }
}

test "early threaded io is resolved after global launch args" {
    try std.testing.expect(needsEarlyThreadedIo(&.{
        @as([:0]const u8, "--add-dir"),
        @as([:0]const u8, "/tmp/shared"),
        @as([:0]const u8, "status"),
    }));
    try std.testing.expect(needsEarlyThreadedIo(&.{
        @as([:0]const u8, "--no-additional-dirs"),
        @as([:0]const u8, "login"),
    }));
}

test "full entry config commands also use early threaded io" {
    try std.testing.expect(needsEarlyThreadedIo(&.{@as([:0]const u8, "ask")}));
    try std.testing.expect(needsEarlyThreadedIo(&.{@as([:0]const u8, "acp")}));
    try std.testing.expect(needsEarlyThreadedIo(&.{@as([:0]const u8, "pr")}));
    try std.testing.expect(needsEarlyThreadedIo(&.{@as([:0]const u8, "issue")}));
    try std.testing.expect(needsEarlyThreadedIo(&.{
        @as([:0]const u8, "--add-dir"),
        @as([:0]const u8, "/tmp/shared"),
        @as([:0]const u8, "ask"),
    }));
    try std.testing.expect(needsEarlyThreadedIo(&.{
        @as([:0]const u8, "--context-limit=project_bytes=2048"),
        @as([:0]const u8, "--no-additional-dirs"),
        @as([:0]const u8, "acp"),
    }));
}

test "lightweight local commands do not request early threaded io" {
    try std.testing.expect(!needsEarlyThreadedIo(&.{}));
    for ([_][:0]const u8{ "help", "sessions", "tasks", "permissions" }) |command| {
        try std.testing.expect(!needsEarlyThreadedIo(&.{command}));
    }
}

test "footer runtime compatibility facade exports composeFooterFrame" {
    _ = footer_runtime.composeFooterFrame;
}

test "interactive app keeps notification handlers registered for live preference changes" {
    var app = App{ .alloc = std.testing.allocator };
    defer app.lifecycle_runtime.deinit();

    try app.configureNotifications();

    try std.testing.expect(app.lifecycle_view.hasPostTurnEnd());
    try std.testing.expect(app.lifecycle_view.hasAttentionRequired());

    app.setNotificationPreferences(true, true, true);
    const preferences = app.notificationPreferences();
    try std.testing.expect(preferences.turn_end);
    try std.testing.expect(preferences.attention_required);
    try std.testing.expect(preferences.max);
    try std.testing.expect(app.soundMaxEnabled());
    try std.testing.expect(!@hasField(App, "notification_player"));
}

test "native app preserves the built-in tool set without workspace metadata" {
    var app = App{ .alloc = std.testing.allocator };
    try std.testing.expect(app.workspaceHostInfo() == null);

    const registry = app.toolRegistry();
    try std.testing.expect(registry.tools.ptr == builtin_tools.registry.tools.ptr);
    try std.testing.expectEqual(builtin_tools.registry.tools.len, registry.tools.len);

    const advertised = app.toolAdvertisementSet();
    try std.testing.expect(advertised.order.ptr == builtin_tools.advertisement_set.order.ptr);
    try std.testing.expectEqual(builtin_tools.advertisement_set.order.len, advertised.order.len);
}

fn fullEntryConfig() app_entry_runtime.Config {
    return .{
        .version = version,
        .revision = build_options.git_commit,
        .build_channel = compiled_update_channel,
        .command_catalog = builtin_commands.top_level_registry,
        .default_model = builtin_gateway.default_model,
        .default_agent_step_limit = default_max_agent_steps,
        .models_path = builtin_gateway.models_path,
        .gateway_retry_count = builtin_gateway.retry_count,
        .gateway_chat_url = builtin_gateway.default_chat_url,
        .gateway_provider = native_gateway_provider,
        .codex_agent_stream = builtin_providers.agentStream(.codex),
        .codex_cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .codex_model_catalog = openai_codex_models.model_catalog_provider,
        .grok_agent_stream = builtin_providers.agentStream(.grok),
        .grok_cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .grok_model_catalog = xai_grok_models.model_catalog_provider,
        .background_process_provider = background_process.provider,
        .url_opener = url_opener.native_opener,
        .secret_store = native_host.secret_store,
        .prompt_policy = builtin_context.prompt_policy,
        .skill_root_policy = builtin_skills.root_policy,
        .ignored_list_entries = &ignored_list_entries,
        .max_list_entries = max_list_entries,
        .max_read_file_bytes = max_read_file_bytes,
        .max_read_file_lines = max_read_file_lines,
        .max_read_file_line_len = max_read_file_line_len,
        .max_command_output_bytes = max_command_output_bytes,
        .max_tool_result_bytes = @import("core/tooling/tool_result_limits.zig").default_max_tool_result_bytes,
        .max_history_turns = max_history_turns,
        .context_registry = default_context_registry,
        .mode_registry = builtin_modes.registry,
        .tool_set = builtin_tools.advertisement_set,
        .inspect_mcp_profile_config = builtin_mcp.inspectProfileConfig,
        .load_mcp_runtime = builtin_mcp.loadRuntime,
        .acp_runner = .{ .run_fn = runAcpServer },
        .permission_reviewer_provider = builtin_gateway.permission_reviewer.provider,
        .codex_permission_reviewer_provider = openai_codex_permission_reviewer.provider,
        .grok_permission_reviewer_provider = xai_grok_permission_reviewer.provider,
    };
}

fn localEntryConfig() app_entry_runtime.Config {
    return .{
        .version = version,
        .revision = build_options.git_commit,
        .build_channel = compiled_update_channel,
        .command_catalog = builtin_commands.top_level_registry,
        .default_model = builtin_gateway.default_model,
        .default_agent_step_limit = default_max_agent_steps,
        .models_path = builtin_gateway.models_path,
        .gateway_retry_count = builtin_gateway.retry_count,
        .gateway_chat_url = builtin_gateway.default_chat_url,
        .gateway_provider = native_gateway_provider,
        .codex_agent_stream = builtin_providers.agentStream(.codex),
        .codex_cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .codex_model_catalog = openai_codex_models.model_catalog_provider,
        .grok_agent_stream = builtin_providers.agentStream(.grok),
        .grok_cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .grok_model_catalog = xai_grok_models.model_catalog_provider,
        .background_process_provider = background_process.provider,
        .url_opener = url_opener.native_opener,
        .secret_store = native_host.secret_store,
        .prompt_policy = .{ .system_prompt = "" },
        .skill_root_policy = builtin_skills.root_policy,
        .ignored_list_entries = &.{},
        .max_list_entries = 0,
        .max_read_file_bytes = 0,
        .max_read_file_lines = 0,
        .max_read_file_line_len = 0,
        .max_command_output_bytes = 0,
        .max_tool_result_bytes = 0,
        .max_history_turns = 0,
        .context_registry = default_context_registry,
        .mode_registry = builtin_modes.registry,
        .tool_set = builtin_tools.advertisement_set,
        .inspect_mcp_profile_config = builtin_mcp.inspectProfileConfig,
        .load_mcp_runtime = builtin_mcp.loadRuntime,
        .acp_runner = .{ .run_fn = runAcpServer },
    };
}

fn emptyEntryConfig() app_entry_runtime.Config {
    return .{
        .version = version,
        .revision = build_options.git_commit,
        .build_channel = compiled_update_channel,
        .command_catalog = builtin_commands.top_level_registry,
        .default_model = "",
        .default_agent_step_limit = 0,
        .models_path = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .gateway_provider = native_gateway_provider,
        .codex_agent_stream = builtin_providers.agentStream(.codex),
        .codex_cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .codex_model_catalog = openai_codex_models.model_catalog_provider,
        .grok_agent_stream = builtin_providers.agentStream(.grok),
        .grok_cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .grok_model_catalog = xai_grok_models.model_catalog_provider,
        .background_process_provider = background_process.provider,
        .url_opener = url_opener.native_opener,
        .secret_store = native_host.secret_store,
        .prompt_policy = .{ .system_prompt = "" },
        .skill_root_policy = builtin_skills.root_policy,
        .ignored_list_entries = &.{},
        .max_list_entries = 0,
        .max_read_file_bytes = 0,
        .max_read_file_lines = 0,
        .max_read_file_line_len = 0,
        .max_command_output_bytes = 0,
        .max_tool_result_bytes = 0,
        .max_history_turns = 0,
        .context_registry = default_context_registry,
        .mode_registry = builtin_modes.registry,
        .tool_set = builtin_tools.advertisement_set,
        .inspect_mcp_profile_config = builtin_mcp.inspectProfileConfig,
        .load_mcp_runtime = builtin_mcp.loadRuntime,
        .acp_runner = .{ .run_fn = runAcpServer },
    };
}

fn runAcpServer(_: ?*anyopaque, alloc: Allocator, cfg: acp_runner.Config) anyerror!void {
    return acp_server.run(alloc, cfg);
}

fn handleSigWinchNative(_: std.posix.SIG) callconv(.c) void {
    resize_interlock.noteResizeSignal();
}

fn handleSigWinchWeb() callconv(.c) void {
    resize_interlock.noteResizeSignal();
}

const handle_sigwinch: app_lifecycle.ResizeHandler = if (host_target.is_wasm)
    handleSigWinchWeb
else
    handleSigWinchNative;

test "interactive startup does not begin with synthetic resize pending" {
    try std.testing.expect(!resize_interlock.resizePending());
}

test "session reset traces and clears active paste state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "session-reset-paste.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var sink = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var app = App{
        .alloc = alloc,
        .shell = .{
            .stdout_file = sink,
            .layout = .{
                .rows = 24,
                .cols = 80,
                .content_bottom = 21,
                .divider_top_row = 22,
                .input_row = 23,
                .divider_bottom_row = 24,
                .hint_row = 22,
            },
        },
    };
    defer app.deinit();
    try app.shell.enableShadowVt(alloc);
    app.input_runtime.paste.owner = .decision_prompt;
    app.input_runtime.paste.decision_bytes = 4;
    try app.input_runtime.edit_state.input.appendSlice(alloc, "normal input");

    try app.clearSession();

    try std.testing.expectEqual(paste_framing.Owner.none, app.input_runtime.paste.owner);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.paste.decision_bytes);
    try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
    debug_trace.shutdown();

    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "decision prompt paste dropped bytes=4 reason=session_reset"));
}

test "raw benchmark preflight matches no-arg FX_BENCH presence" {
    const no_args = [_][*:0]const u8{"fx"};
    const help_args = [_][*:0]const u8{ "fx", "help" };
    const bench_env = [_:null]?[*:0]const u8{"FX_BENCH=1"};
    const empty_env = [_:null]?[*:0]const u8{};

    try std.testing.expect(shouldRunBenchmarkNoArgRaw(no_args[0..], @ptrCast(&bench_env)));
    try std.testing.expect(!shouldRunBenchmarkNoArgRaw(help_args[0..], @ptrCast(&bench_env)));
    try std.testing.expect(!shouldRunBenchmarkNoArgRaw(no_args[0..], @ptrCast(&empty_env)));
}

test "terminal help styling respects terminal capability and color opt-outs" {
    try std.testing.expectEqual(command_specs.HelpStyle.ansi, topLevelHelpStyleForValues(true, false, false));
    try std.testing.expectEqual(command_specs.HelpStyle.plain, topLevelHelpStyleForValues(false, false, false));
    try std.testing.expectEqual(command_specs.HelpStyle.plain, topLevelHelpStyleForValues(true, true, false));
    try std.testing.expectEqual(command_specs.HelpStyle.plain, topLevelHelpStyleForValues(true, false, true));
}

test "follow up prompt card top margin is renderer-owned" {
    var sink = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var app = App{
        .alloc = std.testing.allocator,
        .shell = .{
            .stdout_file = sink,
            .layout = .{
                .rows = 24,
                .cols = 80,
                .content_bottom = 21,
                .divider_top_row = 22,
                .input_row = 23,
                .divider_bottom_row = 24,
                .hint_row = 22,
            },
        },
    };
    defer {
        app.shell.deinit(std.testing.allocator);
        app.session.deinit(std.testing.allocator);
    }

    try app.session.appendAssistantHistoryTurn(std.testing.allocator, "hi", "hello");
    try app.writeTranscript("hello\n", true);
    try app.writeUserPromptCard(.{ .text = @constCast("follow up") });

    try std.testing.expect(std.mem.find(u8, app.shell.transcript.items, "hello\n\n") == null);

    const rendered = try transcript_runtime.renderEntriesToBytes(std.testing.allocator, app.shell.entries.items, app.shell.layout.cols, .{});
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.find(u8, rendered, "hello\n\n") != null);
}

test "follow up prompt card does not over-pad when assistant ends with blank row" {
    var sink = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var app = App{
        .alloc = std.testing.allocator,
        .shell = .{
            .stdout_file = sink,
            .layout = .{
                .rows = 24,
                .cols = 80,
                .content_bottom = 21,
                .divider_top_row = 22,
                .input_row = 23,
                .divider_bottom_row = 24,
                .hint_row = 22,
            },
        },
    };
    defer {
        app.shell.deinit(std.testing.allocator);
        app.session.deinit(std.testing.allocator);
    }

    try app.session.appendAssistantHistoryTurn(std.testing.allocator, "hi", "hello");
    try app.writeTranscript("hello\n\n", true);
    try app.writeUserPromptCard(.{ .text = @constCast("follow up") });

    try std.testing.expect(std.mem.find(u8, app.shell.transcript.items, "hello\n\n\n") == null);
    try std.testing.expect(std.mem.find(u8, app.shell.transcript.items, "hello\n\n") != null);
}

test "diff block writes are classified" {
    const alloc = std.testing.allocator;
    const c_alloc = std.heap.c_allocator;
    const diff_mod = @import("core/output/diff.zig");

    var sink = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var app = App{
        .alloc = alloc,
        .shell = .{
            .stdout_file = sink,
            .layout = .{
                .rows = 24,
                .cols = 80,
                .content_bottom = 21,
                .divider_top_row = 22,
                .input_row = 23,
                .divider_bottom_row = 24,
                .hint_row = 22,
            },
        },
    };
    defer {
        for (app.diff_entries.items) |*entry| entry.deinit(c_alloc);
        app.diff_entries.deinit(c_alloc);
        app.shell.deinit(alloc);
        app.session.deinit(alloc);
    }

    const payload = agent_runtime.DiffEntryPayload{
        .preview = try c_alloc.dupe(u8, "diff preview"),
    };
    errdefer diff_mod.freeDiffEntryPayload(c_alloc, payload);

    try app.registerAndEmitDiffBlock(payload);

    try std.testing.expect(app.shell.entries.items.len > 0);
    try std.testing.expectEqual(
        transcript_runtime.RawEntryClass.diff_block,
        app.shell.entries.items[app.shell.entries.items.len - 1].raw_bytes.class,
    );
}

test "prompt card wraps image badges in OSC 8 hyperlinks" {
    var sink = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var app = App{
        .alloc = std.testing.allocator,
        .shell = .{
            .stdout_file = sink,
            .layout = .{
                .rows = 24,
                .cols = 80,
                .content_bottom = 21,
                .divider_top_row = 22,
                .input_row = 23,
                .divider_bottom_row = 24,
                .hint_row = 22,
            },
        },
    };
    defer {
        app.shell.deinit(std.testing.allocator);
        app.session.deinit(std.testing.allocator);
    }

    var images = [_]types.ImageAttachment{
        .{ .id = 1, .path = @constCast("/tmp/a.png"), .media_type = @constCast("image/png") },
    };
    try app.writeUserPromptCard(.{ .text = @constCast("[Image #1]"), .images = &images });

    try std.testing.expect(std.mem.find(u8, app.shell.transcript.items, "\x1b]8;;file:///tmp/a.png\x1b\\[Image 1]\x1b]8;;\x1b\\") != null);
    const reconstructed = try transcript_runtime.renderEntriesToBytes(std.testing.allocator, app.shell.entries.items, app.shell.layout.cols, .{});
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expect(std.mem.find(u8, reconstructed, "\x1b]8;;file:///tmp/a.png\x1b\\[Image 1]\x1b]8;;\x1b\\") != null);
}

test "/version command writes version to transcript" {
    var sink = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var app = App{
        .alloc = std.testing.allocator,
        .shell = .{
            .stdout_file = sink,
            .layout = .{
                .rows = 24,
                .cols = 80,
                .content_bottom = 21,
                .divider_top_row = 22,
                .input_row = 23,
                .divider_bottom_row = 24,
                .hint_row = 22,
            },
        },
    };
    defer app.shell.deinit(std.testing.allocator);

    try app.handleCommand("/version");

    try std.testing.expectEqual(@as(usize, 1), app.shell.entries.items.len);
    try std.testing.expect(app.shell.entries.items[0] == .semantic_notice);
    const notice = app.shell.entries.items[0].semantic_notice;
    try std.testing.expectEqualStrings("version", notice.topic);
    try std.testing.expectEqual(types.NoticeTone.neutral, notice.tone);
    try std.testing.expect(std.mem.find(u8, notice.body, version) != null);
}

test "background process registry ignores stale watcher urls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(tmp_root);
    const old_log = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "old.log" });
    defer std.testing.allocator.free(old_log);
    const new_log = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "new.log" });
    defer std.testing.allocator.free(new_log);
    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), old_log, .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    {
        var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), new_log, .{ .truncate = true });
        file.close(io_mod.getIo());
    }
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
    const token = try process_supervisor.ProcessInstanceToken.parse(
        "linux:00112233445566778899aabbccddeeff:12345",
    );

    var app = App{ .alloc = std.testing.allocator };
    app.background.process_provider =
        background_process_provider.process_supervisor_test_provider;
    defer {
        app.worker.deinit(std.heap.c_allocator);
        app.background.deinit(std.heap.c_allocator);
    }

    const old_id = try app.background.registerBackground(std.heap.c_allocator, .{
        .pid = "12345",
        .process_token = token,
        .command = "npm run dev",
        .cwd = "/tmp/a",
        .log_path = old_log,
        .expect_url = true,
    });
    const new_id = try app.background.registerBackground(std.heap.c_allocator, .{
        .pid = "12345",
        .process_token = token,
        .command = "npm run dev",
        .cwd = "/tmp/b",
        .log_path = new_log,
        .expect_url = true,
    });

    _ = app.background.publishServerUrl(std.heap.c_allocator, old_id, try std.heap.c_allocator.dupe(u8, "http://localhost:3000"));

    var snapshot = try app.runtimeContextSnapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(new_id, snapshot.process_id.?);
    try std.testing.expect(snapshot.server_url == null);

    const resolved = app.background.publishServerUrl(std.heap.c_allocator, new_id, try std.heap.c_allocator.dupe(u8, "http://localhost:4000")) orelse return error.TestExpectedEqual;
    std.heap.c_allocator.free(resolved);

    snapshot.deinit(std.testing.allocator);
    snapshot = try app.runtimeContextSnapshot(std.testing.allocator);
    try std.testing.expectEqualStrings("http://localhost:4000", snapshot.server_url.?);
}

test "normalize assistant text removes markdown emphasis and leading blank lines" {
    const normalized = try agent_runtime.normalizeAssistantTextForDisplay(std.testing.allocator, "\n\n**Hola** `mundo`");
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("Hola mundo", normalized);
}

test "semantic code block preserves indentation on wrapped continuation rows" {
    const alloc = std.testing.allocator;
    var entries: std.ArrayList(transcript_runtime.TranscriptEntry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }

    const block = assistant_presentation.CodeBlockPayload{
        .language = try alloc.dupe(u8, "text"),
        .code = try alloc.dupe(u8, "  abcdefghijkl\n"),
    };
    try entries.append(alloc, .{ .assistant_code_block = .{ .id = 1, .block = block } });

    const wide = try transcript_runtime.renderEntriesToBytes(alloc, entries.items, 80, .{});
    defer alloc.free(wide);
    try std.testing.expect(std.mem.find(u8, wide, "text") != null);
    try std.testing.expect(std.mem.find(u8, wide, "┌") != null);
    try std.testing.expect(std.mem.find(u8, wide, "└") != null);
    try std.testing.expect(std.mem.find(u8, wide, "  abcdefghijkl") != null);

    const narrow = try transcript_runtime.renderEntriesToBytes(alloc, entries.items, 12, .{});
    defer alloc.free(narrow);
    try std.testing.expect(std.mem.find(u8, narrow, "\n  │   efgh │\n") != null);
    var lines = std.mem.splitScalar(u8, narrow, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 12);
    }

    const tiny = try transcript_runtime.renderEntriesToBytes(alloc, entries.items, 1, .{});
    defer alloc.free(tiny);
    try std.testing.expect(std.mem.find(u8, tiny, "┌") == null);
    lines = std.mem.splitScalar(u8, tiny, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 1);
    }

    var wide_rune_entries: std.ArrayList(transcript_runtime.TranscriptEntry) = .empty;
    defer {
        for (wide_rune_entries.items) |*entry| entry.deinit(alloc);
        wide_rune_entries.deinit(alloc);
    }
    const wide_rune_block = assistant_presentation.CodeBlockPayload{
        .language = try alloc.dupe(u8, "text"),
        .code = try alloc.dupe(u8, " a\xf0\x9f\x98\x80\n"),
    };
    try wide_rune_entries.append(alloc, .{ .assistant_code_block = .{ .id = 2, .block = wide_rune_block } });

    const boxed_wide_rune = try transcript_runtime.renderEntriesToBytes(alloc, wide_rune_entries.items, 6, .{});
    defer alloc.free(boxed_wide_rune);
    lines = std.mem.splitScalar(u8, boxed_wide_rune, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 6);
    }

    const unboxed_wide_rune = try transcript_runtime.renderEntriesToBytes(alloc, wide_rune_entries.items, 2, .{});
    defer alloc.free(unboxed_wide_rune);
    lines = std.mem.splitScalar(u8, unboxed_wide_rune, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 2);
    }
}

test {
    _ = @import("napi_fetch_state.zig");
    _ = @import("core/config/model_provider.zig");
    _ = provider_runtime;
    _ = @import("acp/prompt.zig");
    _ = @import("core/output/activity_status.zig");
    _ = @import("core/agent/agent_runtime.zig");
    _ = @import("core/agent/execution_memory.zig");
    _ = @import("core/agent/runtime/assistant_stream.zig");
    _ = @import("core/agent/runtime/execution_memory.zig");
    _ = @import("core/agent/runtime/tool_admission.zig");
    _ = @import("core/agent/runtime/prompt_context.zig");
    _ = @import("core/app/app_agent_runtime.zig");
    _ = @import("core/app/app_auth_runtime.zig");
    _ = @import("core/workspace/context_contract.zig");
    _ = @import("core/workspace/workspace_access.zig");
    _ = @import("core/workspace/workspace_commands.zig");
    _ = @import("core/app/app_workspace_runtime.zig");
    _ = @import("core/app/app_bootstrap_runtime.zig");
    _ = @import("core/app/app_callbacks.zig");
    _ = @import("core/app/app_commands.zig");
    _ = @import("core/app/app_entry_runtime.zig");
    _ = @import("core/app/app_input_runtime.zig");
    _ = @import("core/app/app_lifecycle.zig");
    _ = @import("core/app/model_cache_runtime.zig");
    _ = @import("core/app/app_process_runtime.zig");
    _ = @import("core/app/app_render_runtime.zig");
    _ = @import("core/app/app_terminal_takeover_runtime.zig");
    _ = @import("core/app/app_runtime_setup.zig");
    _ = @import("core/app/app_session_runtime.zig");
    _ = @import("core/app/app_upgrade_runtime.zig");
    _ = @import("core/app/app_worker_runtime.zig");
    _ = @import("ui/event_loop.zig");
    _ = @import("ui/resize_tests.zig");
    _ = @import("ui/render_engine/assistant_wrap.zig");
    _ = @import("ui/render_engine/transcript_blocks.zig");
    _ = @import("ui/render_engine/viewport_selection.zig");
    _ = @import("ui/subagent/controller.zig");
    _ = @import("ui/subagent/runtime.zig");
    _ = @import("core/agent/assistant_presentation.zig");
    _ = @import("core/upgrade/auto_upgrade.zig");
    _ = @import("core/background/background.zig");
    _ = @import("core/background/background_commands.zig");
    _ = @import("core/background/background_runtime.zig");
    _ = @import("core/background/background_store.zig");
    _ = @import("core/cli/cli_ask.zig");
    _ = @import("core/cli/cli_replay.zig");
    _ = @import("core/cli/cli_surface.zig");
    _ = @import("core/workspace/change_tracker.zig");
    _ = @import("core/shared/collections.zig");
    _ = @import("core/slash_commands/command_router.zig");
    _ = @import("core/slash_commands/command_specs.zig");
    _ = @import("core/acp_client/agent_catalog.zig");
    _ = @import("core/acp_client/command_provider.zig");
    _ = @import("core/acp_client/config.zig");
    _ = @import("core/acp_client/runtime.zig");
    _ = @import("core/shared/profile_paths.zig");
    _ = @import("core/config/config_runtime.zig");
    _ = @import("core/config/settings_store.zig");
    _ = @import("ui/footer/appearance_menu_presentation.zig");
    _ = @import("ui/footer/compact_command_menu_presentation.zig");
    _ = @import("ui/footer/settings_menu_presentation.zig");
    _ = @import("ui/settings_screen.zig");
    _ = @import("builtins/context.zig");
    _ = @import("builtins/gateway.zig");
    _ = @import("core/shared/debug_trace.zig");
    _ = @import("core/output/diff.zig");
    _ = @import("core/shared/display_width.zig");
    _ = @import("core/cli/doctor_runtime.zig");
    _ = @import("core/auth/login_flow.zig");
    _ = @import("core/auth/chatgpt_oauth.zig");
    _ = @import("core/auth/provider_catalog.zig");
    _ = @import("gateway/openai_codex_models.zig");
    _ = @import("gateway/openai_codex.zig");
    _ = @import("gateway/openai_codex_permission_reviewer.zig");
    _ = @import("core/auth/grok_session.zig");
    _ = @import("core/auth/grok_oauth.zig");
    _ = @import("gateway/xai_grok_models.zig");
    _ = @import("gateway/xai_grok.zig");
    _ = @import("gateway/xai_grok_permission_reviewer.zig");
    _ = credentials;
    _ = @import("core/auth/oauth.zig");
    _ = @import("core/auth/oauth_session.zig");
    _ = @import("core/workspace/file_index.zig");
    _ = @import("core/gateway/gateway_json.zig");
    _ = @import("core/github/git_context.zig");
    _ = @import("core/github/github_publish.zig");
    _ = @import("core/github/github_workflows.zig");
    _ = @import("core/hosts/host.zig");
    _ = @import("core/hooks/common.zig");
    _ = @import("core/hooks/definitions.zig");
    _ = @import("core/hooks/prompt.zig");
    _ = @import("core/hooks/runtime.zig");
    _ = @import("core/images/image_attachments.zig");
    _ = @import("core/images/image_commands.zig");
    _ = @import("core/shared/io.zig");
    _ = @import("core/shared/message.zig");
    _ = @import("core/shared/token_estimate.zig");
    _ = @import("core/shell_command/command_effect.zig");
    _ = @import("core/execution/router.zig");
    _ = @import("core/permissions/direct_command.zig");
    _ = @import("core/permissions/auto_classifier.zig");
    _ = @import("core/permissions/command_admission.zig");
    _ = @import("core/mcp/mcp_runtime.zig");
    _ = @import("core/mcp/features/common.zig");
    _ = @import("core/mcp/features/resources.zig");
    _ = @import("core/mcp/features/prompts.zig");
    _ = @import("core/mcp/features/completion.zig");
    _ = @import("core/config/model_capabilities.zig");
    _ = @import("core/output/output_contracts.zig");
    _ = @import("core/workspace/pathing.zig");
    _ = @import("core/permissions/permission_gate.zig");
    _ = @import("core/permissions/permissions.zig");
    _ = @import("core/background/process_supervisor.zig");
    _ = @import("core/execution/process_tree.zig");
    _ = @import("core/config/prompt_policy.zig");
    _ = @import("core/workspace/record_tape.zig");
    _ = @import("core/session/session.zig");
    _ = @import("core/session/session_commands.zig");
    _ = @import("core/session/session_json.zig");
    _ = @import("core/session/session_store.zig");
    _ = @import("core/session/prompt_history_store.zig");
    _ = @import("core/app/prompt_history_runtime.zig");
    _ = @import("core/session/web_fetch_artifacts.zig");
    _ = @import("core/skills/skill_runtime.zig");
    _ = @import("core/subagent/domain.zig");
    _ = @import("core/subagent/tool_result.zig");
    _ = @import("core/subagent/create_store.zig");
    _ = @import("core/subagent/control_store.zig");
    _ = @import("core/subagent/resume_admission.zig");
    _ = @import("core/subagent/relationship_index.zig");
    _ = @import("core/subagent/manager.zig");
    _ = @import("core/subagent/execution.zig");
    _ = @import("core/subagent/tool_host.zig");
    _ = @import("core/subagent/communication.zig");
    _ = @import("core/subagent/communication_store.zig");
    _ = @import("core/subagent/communication_manager.zig");
    _ = @import("core/subagent/parent_delivery_projector.zig");
    _ = @import("core/subagent/ui_projection.zig");
    _ = @import("core/subagent/authority.zig");
    _ = @import("core/subagent/approval_registry.zig");
    _ = @import("core/subagent/approval_persistence.zig");
    _ = @import("core/subagent/work_events.zig");
    _ = @import("core/terminal/contracts.zig");
    _ = @import("core/terminal/monitor.zig");
    _ = @import("core/terminal/operation.zig");
    _ = @import("core/terminal/protocol.zig");
    _ = @import("core/terminal/host_policy.zig");
    _ = @import("core/terminal/shell_resolver.zig");
    _ = @import("core/terminal/native_session.zig");
    _ = @import("core/terminal/recovery.zig");
    _ = @import("core/terminal/store.zig");
    _ = @import("core/terminal/host.zig");
    _ = @import("core/terminal/tmux_session.zig");
    _ = @import("core/terminal/client.zig");
    _ = @import("core/terminal/direct_runtime.zig");
    _ = @import("core/app/app_terminal_runtime.zig");
    _ = @import("tools/terminal/terminal.zig");
    _ = @import("core/app/input_approval_runtime.zig");
    _ = @import("acp/sessions.zig");
    _ = @import("core/tasks/task_helpers.zig");
    _ = @import("core/shared/text_utils.zig");
    _ = @import("core/tooling/tool_advertisement.zig");
    _ = @import("core/tooling/tool_dispatch.zig");
    _ = @import("core/tooling/tool_set.zig");
    _ = @import("core/hosts/js_host_workspace.zig");
    _ = @import("core/tooling/tool_args.zig");
    _ = @import("core/tooling/tool_result_errors.zig");
    _ = @import("core/tooling/tool_runtime.zig");
    _ = @import("core/tooling/tool_specs.zig");
    _ = @import("builtins/commands.zig");
    _ = @import("builtins/mcp.zig");
    _ = @import("builtins/modes.zig");
    _ = @import("builtins/tools.zig");
    _ = @import("builtins/browser_workspace_tools.zig");
    _ = @import("core/tooling/model_request_budget.zig");
    _ = @import("core/tooling/web_fetch_runtime.zig");
    _ = @import("core/tooling/web_search_policy.zig");
    _ = @import("core/tooling/web_search_runtime.zig");
    _ = @import("gateway/web_search.zig");
    _ = @import("gateway/web_search_types.zig");
    _ = @import("tools/web/content.zig");
    _ = @import("tools/web/html_to_markdown.zig");
    _ = @import("tools/filesystem/read_file.zig");
    _ = @import("tools/filesystem/semantic_search.zig");
    _ = @import("tools/skills/install_skill.zig");
    _ = @import("tools/skills/skill.zig");
    _ = @import("core/upgrade/upgrade_helpers.zig");
    _ = @import("core/upgrade/upgrade_runtime.zig");
    _ = @import("core/shared/types.zig");
    _ = @import("core/input/composer_history.zig");
    _ = @import("core/input/kill_ring.zig");
    _ = @import("core/input/horizontal_navigation.zig");
    _ = @import("core/input/edit_history.zig");
    _ = @import("core/input/vertical_navigation.zig");
    _ = @import("core/app/input_selection_runtime.zig");
    _ = @import("ui/input/native_clear_probe.zig");
    _ = @import("ui/input/terminal_action_decoder.zig");
    _ = @import("ui/input/visual_layout.zig");
    _ = @import("ui/input/runtime.zig");
    _ = @import("ui/approval_screen.zig");
    _ = @import("ui/ask_presentation.zig");
    _ = @import("ui/footer/approval_ui.zig");
    _ = @import("ui/footer/surface_invalidation.zig");
    _ = @import("ui/full_transcript_screen.zig");
    _ = @import("ui/render_engine/frame_fixed_point.zig");
    _ = @import("ui/transcript/runtime.zig");
    _ = @import("ui/transcript/runtime_tests.zig");
    _ = @import("core/agent/worker_runtime.zig");
    _ = @import("gateway/client.zig");
    _ = @import("gateway/host_stream_provider.zig");
}

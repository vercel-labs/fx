const std = @import("std");
const agents = @import("../agents/agents.zig");
const profiles = @import("../profiles/profiles.zig");
const agent_runtime = @import("../agent/agent_runtime.zig");
const runtime_deps = @import("../agent/runtime/deps.zig");
const auto_classifier = @import("../permissions/auto_classifier.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const compaction_activity = @import("../output/compaction_activity.zig");
const command_admission = @import("../permissions/command_admission.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const shared_theme = @import("../shared/theme.zig");
const code_highlight = @import("../agent/presentation/code_highlight.zig");
const code_highlight_languages = @import("../agent/presentation/code_highlight_languages.zig");
const app_callbacks = @import("app_callbacks.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const host = @import("../hosts/host.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const hooks = @import("../hooks/hooks.zig");
const io_mod = @import("../shared/io.zig");
const mcp_elicitation_interaction = @import("../mcp/elicitation_interaction.zig");
const mcp_model_catalog = @import("../mcp/model_catalog.zig");
const permission_gate = @import("../permissions/permission_gate.zig");
const permissions = @import("../permissions/permissions.zig");
const prompt_policy_contract = @import("../config/prompt_policy.zig");
const model_provider = @import("../config/model_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const session_runtime = @import("../session/session.zig");
const result_store = @import("../session/result_store.zig");
const session_child_store = @import("../session/session_child_store.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_agent_adapter = @import("../subagent/agent_adapter.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_execution = @import("../subagent/execution.zig");
const subagent_authority = @import("../subagent/authority.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("../tooling/tool_args.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_projection_mod = @import("../tooling/tool_projection.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const context_contract = @import("../workspace/context_contract.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const test_builtin_gateway = if (@import("builtin").is_test)
    @import("../../builtins/gateway.zig")
else
    struct {};
const test_builtin_tools = if (@import("builtin").is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const web_fetch_runtime = @import("../tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../tooling/web_search_runtime.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const js_host_workspace = @import("../hosts/js_host_workspace.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        const ToolAuthorityView = struct {
            mode: PermissionMode,
            grants: []const PermissionGrant,
            rules: types.PermissionRuleSet,
        };

        fn appAccessScope(app: *const App) ?workspace_access.AccessScope {
            if (comptime @hasDecl(App, "workspaceAccessScope")) {
                return app.workspaceAccessScope();
            }
            return null;
        }

        fn appHostWorkspaceInfo(app: *const App) ?*const js_host_workspace.Info {
            if (comptime @hasDecl(App, "workspaceHostInfo")) {
                return app.workspaceHostInfo();
            }
            return null;
        }

        const TurnWorkspace = struct {
            root: []const u8,
            access_scope: ?workspace_access.AccessScope,
        };

        /// A host workspace owns the root that tools, turns, and project
        /// context use; otherwise the app's local workspace does.
        fn turnWorkspace(app: *const App) TurnWorkspace {
            if (appHostWorkspaceInfo(app)) |info| return .{
                .root = info.root(),
                .access_scope = workspace_access.AccessScope.primaryOnly(info.root()),
            };
            return .{ .root = app.workspace_root, .access_scope = appAccessScope(app) };
        }

        fn modelVisibleProjectContext(app: *App, agent: *AppAgent) []const u8 {
            if (comptime @hasField(App, "context_enabled")) {
                if (!app.context_enabled) return "";
            }
            if (agent.worker.active_context_snapshot) |snapshot| return snapshot.modelVisibleBytes();
            return agent.context_snapshot.modelVisibleBytes();
        }

        fn childToolContext(root_context: tool_runtime.Context) tool_runtime.Context {
            var child_context = root_context;
            child_context.tracker = null;
            return child_context;
        }

        pub fn toolContext(
            app: *App,
            agent: *AppAgent,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                agent,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                childToolAuthority(agent),
            );
        }

        /// The current run of the agent this thread works for, when it is a
        /// subagent.
        /// The tools a turn may be shown. A subagent's come from its
        /// admission's permission mode and rules, fixed when it was admitted;
        /// in its own context it has no subagent host, so `subagent` is left
        /// out. Main's come from the job's permission mode.
        fn turnToolProjection(
            app: *App,
            agent: *AppAgent,
            alloc: Allocator,
            permission_mode: types.PermissionMode,
        ) !tool_projection_mod.EffectiveToolProjection {
            if (comptime @hasDecl(App, "snapshotSubagentModelToolProjection")) {
                if (childRun(agent)) |run| return app.snapshotSubagentModelToolProjection(
                    agent,
                    alloc,
                    run.admission.permission_mode,
                    run.admission.rules,
                );
            }
            return app.snapshotModelToolProjection(agent, alloc, permission_mode);
        }

        fn admittedTool(run: *const agents.ChildRun, name: []const u8) bool {
            for (run.admission.tool_names) |tool| if (std.mem.eql(u8, tool, name)) return true;
            return false;
        }

        fn childRun(agent: *AppAgent) ?*agents.ChildRun {
            if (comptime !agents.hasAgentField(App, "child_run")) return null;
            return if (agent.child_run) |*run| run else null;
        }

        /// A subagent's tools work under its run's admission, never main's
        /// permission engine.
        fn childToolAuthority(agent: *AppAgent) ?ToolAuthorityView {
            const run = childRun(agent) orelse return null;
            return .{
                .mode = (if (comptime agents.hasAgentField(App, "permission_mode")) agent.permission_mode else null) orelse
                    run.admission.permission_mode,
                .grants = run.admission.grants,
                .rules = run.admission.rules,
            };
        }

        /// Narrows a tool context to a subagent's run: its own provider, model,
        /// and credential, web search only when its provider has it, and no
        /// subagent host, so a subagent never starts subagents. Its auto-mode
        /// reviewer runs as main's does, on the user's requests the run
        /// carries, never on main's messages to it. Hiding a tool from the model does
        /// not stop a call to it; `childLiveToolAuthority` refuses any tool
        /// outside the admission.
        fn applyChildToolContext(app: *App, ctx: *tool_runtime.Context, run: *agents.ChildRun) void {
            ctx.session_grants = run.admission.grants;
            ctx.permission_state_override = &run.admission.permission_state;
            ctx.advertised_dynamic_tool_names = run.admission.integration_names;
            ctx.mcp_access = if (run.admission.mcp_view) |*view|
                .{ .scoped = .{
                    .captured = view,
                    .admission_authority_generation = run.admission.authority_generation,
                    .live = .{ .context = run, .resolve_fn = resolveChildLiveMcpView },
                } }
            else
                .disabled;
            // A child's `subagent` calls go to its own host, which the tool
            // context already holds, as main's go to main's.
            // A child's approvals and questions go to its own worker, as
            // main's do, for main's runs and the user's alike; main's screen
            // borrows them while the child is hidden.
            ctx.interactive = false;
            ctx.ask_user_questions = true;
            ctx.provider = run.admission.provider;
            ctx.model = run.admission.model;
            if (comptime @hasDecl(App, "providerSet")) {
                const bundle = app.providerSet().select(run.admission.provider);
                ctx.provider_capabilities = bundle.capabilities;
                ctx.agent_stream_provider = bundle.agent_stream_or_unavailable();
                ctx.permission_reviewer_provider = bundle.permission_reviewer;
            }
            if (run.credential) |credential| {
                ctx.api_key = credential.token;
                ctx.gateway_team = credential.gatewayTeam();
                ctx.credential_source = credential.source;
                ctx.account_id = credential.accountId();
            }
            if (!ctx.provider_capabilities.fx_search) {
                ctx.web_search_backend = null;
                ctx.web_search_runtime_ready = false;
            }
        }

        /// A subagent turn's live tool authority: every tool call is decided
        /// against the child's admission, resolved fresh for each call.
        fn childLiveToolAuthority(run: *agents.ChildRun) runtime_deps.LiveToolAuthorityProvider {
            return .{ .context = run, .resolve_fn = resolveChildLiveToolAction };
        }

        /// The permission mode a turn on the child decides its tools with when
        /// no work of main's is in flight: a turn the user typed, or steering
        /// left over after main's run ended. Null while main's run is in
        /// flight, whose own work decides. The admission's mode already went
        /// through the child's profile, which gives the same mode again.
        fn userPermissionMode(run: *const agents.ChildRun) ?types.PermissionMode {
            return if (run.inFlight()) null else run.admission.permission_mode;
        }

        fn resolveChildLiveMcpView(raw: *anyopaque, alloc: Allocator) !tool_mcp_runtime.ResolvedLiveView {
            const run: *agents.ChildRun = @ptrCast(@alignCast(raw));
            var authority = if (userPermissionMode(run)) |mode|
                try run.authority_resolver.resolveForUser(alloc, run.child_id, mode)
            else
                try run.authority_resolver.resolve(alloc, run.child_id);
            return subagent_execution.liveMcpViewFrom(alloc, &authority);
        }

        fn resolveChildLiveToolAction(
            raw: *anyopaque,
            alloc: Allocator,
            call: ToolCall,
            workspace_root: []const u8,
            target: []const u8,
            target_kind: tool_dispatch.PermissionTargetKind,
        ) !runtime_deps.ResolvedLiveToolAuthority {
            const run: *agents.ChildRun = @ptrCast(@alignCast(raw));
            return subagent_execution.resolveLiveToolActionFor(
                run.authority_resolver,
                run.child_id,
                userPermissionMode(run),
                alloc,
                call,
                workspace_root,
                target,
                target_kind,
            );
        }

        pub fn toolContextForSubagent(
            app: *App,
            agent: *AppAgent,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            admission: subagent_domain.AdmissionSnapshot,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                agent,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                .{
                    .mode = admission.permission_mode,
                    .grants = admission.grants,
                    .rules = admission.rules,
                },
            );
        }

        fn toolContextWithAuthority(
            app: *App,
            agent: *AppAgent,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            authority: ?ToolAuthorityView,
        ) tool_runtime.Context {
            const host_workspace = appHostWorkspaceInfo(app);
            const workspace = turnWorkspace(app);
            const agent_settings = agent.worker.effectiveAgentTurnSettings();
            const permission_snapshot = if (authority) |snapshot|
                worker_runtime.PermissionSnapshot{
                    .mode = snapshot.mode,
                }
            else
                app_permission_runtime.Runtime(App).livePermissionSnapshot(app, agent);
            const permission_grants = if (authority) |snapshot|
                snapshot.grants
            else
                app_permission_runtime.Runtime(App).grantsOf(app, agent);
            const permission_rules = if (authority) |snapshot|
                snapshot.rules
            else
                app.permission_engine.rules;
            const child_capability =
                if (comptime agents.hasAgentField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(agent)
                else
                    null;
            const selected_provider = provider_runtime.providerOf(app, agent);
            const provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                app.providerSet().select(selected_provider).capabilities
            else if (selected_provider == .gateway)
                provider_set.Bundle.Capabilities{ .fx_search = true, .vision_fallback = true }
            else
                provider_set.Bundle.Capabilities{};
            var ctx: tool_runtime.Context = .{
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .ignored_list_entries = ignored_list_entries,
                .max_list_entries = max_list_entries,
                .max_read_file_bytes = max_read_file_bytes,
                .max_read_file_lines = max_read_file_lines,
                .max_read_file_line_len = max_read_file_line_len,
                .max_command_output_bytes = max_command_output_bytes,
                .max_tool_result_bytes = agent_settings.max_tool_result_bytes,
                .auto_compact_percent = agent_settings.auto_compact_percent,
                .api_key = app.auth.apiKey() orelse "",
                .agent_stream_provider = if (comptime @hasDecl(App, "agentStreamProvider"))
                    app.agentStreamProvider()
                else
                    agent_stream_provider.unavailable_provider,
                .gateway_team = app.auth.gatewayTeam(),
                .credential_source = app.auth.credentialSource(),
                .account_id = app.auth.accountId(),
                .provider = selected_provider,
                .provider_capabilities = provider_capabilities,
                .oauth_transport = app.auth.oauthTransport(),
                .secret_store = if (comptime @hasDecl(@TypeOf(app.auth), "secretStore"))
                    app.auth.secretStore()
                else
                    host.unavailable_secret_store,
                .model = provider_runtime.modelOf(app, agent),
                .reviewer_model = if (comptime @hasField(App, "review_model")) app.review_model else "",
                .gateway_retry_count = gateway_retry_count,
                .gateway_chat_url = gateway_chat_url,
                .gateway_models_path = if (comptime @hasField(App, "web_search_models_path")) app.web_search_models_path else "/v1/models",
                .agent_step_limit = app.agent_step_limit,
                .fast_mode = agent_settings.fast_mode,
                .ultrafast_mode = agent_settings.ultrafast_mode,
                .effort = agent_settings.effort,
                .provider_order = if (selected_provider == .gateway) agent_settings.provider_order else &.{},
                .provider_strict = selected_provider == .gateway and agent_settings.provider_strict,
                .first_call_tool_choice = agent_settings.first_call_tool_choice,
                .tool_registry = if (comptime @hasDecl(App, "toolRegistry")) app.toolRegistry(agent) else .{},
                .subagent_host = if (comptime agents.hasAgentField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).ownSubagentHost(agent)
                else
                    null,
                .subagent_caller_id = if (comptime agents.hasAgentField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).activeSessionId(agent)
                else
                    null,
                .permission_mode = permission_snapshot.mode,
                .permission_grants = permission_grants,
                .permission_rules = permission_rules,
                .worker = &agent.worker,
                .permission_prompter = tool_admission.workerPrompter(&agent.worker),
                .cancel_flag = &agent.worker.worker_cancel_requested,
                .session_child_capability = child_capability,
                .terminal_client = if (comptime @hasField(App, "terminal_client"))
                    &app.terminal_client
                else
                    null,
                .managed_executions = if (comptime agents.hasAgentField(App, "managed_executions"))
                    &agent.managed_executions
                else
                    null,
                .ephemeral_command_replay = if (comptime agents.hasAgentField(App, "managed_executions"))
                    agent.managed_executions.replayStore()
                else
                    null,
                .session = &agent.session,
                .session_allocator = app.alloc,
                .skills_dir = app.skills.dir,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else true,
                .context_registry = app.contextRegistry(),
                .output_chunk_ctx = @ptrCast(agent),
                .on_output_chunk = app_callbacks.Bindings(App).onCommandOutputChunk,
                .workspace_executor = if (comptime @hasDecl(App, "workspaceExecutor")) app.workspaceExecutor() else null,
                .host_sandbox_default = if (host_workspace) |info| switch (info.permission) {
                    .allow_sandboxed => .allow_sandboxed,
                    .prompt => .prompt,
                } else .none,
                .permission_reviewer_provider = if (comptime @hasDecl(App, "permissionReviewerProvider")) app.permissionReviewerProvider() else null,
                .tracker = &agent.change_tracker,
                .mcp_ctx = @ptrCast(app),
                .mcp_has_tool = if (comptime runtime_profile.allows(App, .mcp)) mcpHasTool else null,
                .mcp_validate_tool = if (comptime runtime_profile.allows(App, .mcp)) validateMcpTool else null,
                .mcp_call_tool = if (comptime runtime_profile.allows(App, .mcp)) callMcpTool else null,
                .mcp_search_tools = if (comptime runtime_profile.allows(App, .mcp)) searchMcpTools else null,
                .mcp_tool_schema = if (comptime runtime_profile.allows(App, .mcp)) mcpToolSchemaJson else null,
                .mcp_snapshot_tool = if (comptime runtime_profile.allows(App, .mcp)) mcpSnapshotTool else null,
                .mcp_progress_ctx = @ptrCast(agent),
                .on_mcp_progress = app_callbacks.Bindings(App).onMcpProgress,
                .tool_progress_ctx = @ptrCast(agent),
                .on_tool_progress = app_callbacks.Bindings(App).onToolProgress,
                .subagent_status_renderer = app_callbacks.Bindings(App).subagentStatusRenderer(agent),
                .lifecycle_view = app.lifecycle_view,
                .lifecycle_scope = lifecycleContext(app, agent).scope,
            };
            if (comptime @hasField(App, "web_fetch_runtime")) {
                ctx.web_fetch_runtime = &app.web_fetch_runtime;
                ctx.web_fetch_artifact_store = agent.session.webFetchArtifactStore();
                ctx.web_fetch_artifact_error = agent.session.webFetchArtifactError();
                ctx.web_fetch_progress_ctx = @ptrCast(agent);
                ctx.on_web_fetch_progress = app_callbacks.Bindings(App).onWebFetchProgress;
            }
            if (comptime @hasField(App, "web_search_runtime")) {
                if (provider_capabilities.fx_search) {
                    app.web_search_runtime.configure(.{
                        .api_key = app.auth.apiKey() orelse "",
                        .credential_source = app.auth.credentialSource(),
                        .gateway_team = app.auth.gatewayTeam(),
                        .worker_model = provider_runtime.modelOf(app, agent),
                        .gateway_retry_count = gateway_retry_count,
                        .gateway_chat_url = gateway_chat_url,
                    });
                    ctx.web_search_backend = app.web_search_runtime.dispatchBackend();
                }
                ctx.web_search_runtime_ready = false;
                ctx.web_search_progress_ctx = @ptrCast(agent);
                ctx.on_web_search_progress = app_callbacks.Bindings(App).onWebSearchProgress;
            }
            if (comptime runtime_profile.allows(App, .mcp) and
                @hasDecl(@TypeOf(agent.worker), "requestMcpElicitationAnswerBlocking") and
                @hasDecl(App, "urlOpener"))
            {
                ctx.mcp_input_responder = .{
                    .context = @ptrCast(agent),
                    .capabilities = .{ .form = true, .url = true },
                    .legacy_url_manual_completion = true,
                    .callback = respondToMcpInput,
                };
            }
            ctx.model_capability_resolver = app_callbacks.Bindings(App).modelCapabilityResolver(agent);
            ctx.model_override_resolver = app_callbacks.Bindings(App).modelOverrideResolver(agent);
            // An instance whose profile names its MCP servers uses only those.
            // A subagent's run replaces this with its own view below.
            if (comptime agents.hasAgentField(App, "profile") and agents.hasAgentField(App, "role")) {
                if (agent.role == .instance and profiles.setsMcpServers(&agent.profile.profile)) {
                    ctx.mcp_access = .{ .servers = .{ .context = @ptrCast(&agent.profile.profile), .allows_fn = profileAllowsMcpServer } };
                }
            }
            if (childRun(agent)) |run| applyChildToolContext(app, &ctx, run);
            return ctx;
        }

        /// Whether the instance profile at `raw` allows MCP server `server`.
        /// The profile is fixed once the instance launches, so worker threads
        /// read it as it is.
        fn profileAllowsMcpServer(raw: *const anyopaque, server: []const u8) bool {
            const profile: *const profiles.Profile = @ptrCast(@alignCast(raw));
            return profiles.allowsMcpServer(profile, server);
        }

        fn respondToMcpInput(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            origin: tool_mcp_runtime.InputOrigin,
            required: tool_mcp_runtime.InputRequired,
        ) anyerror![]const u8 {
            return mcp_elicitation_interaction.respond(alloc, origin, required, .{
                .questioner = .{ .context = raw_ctx, .ask_fn = askMcpQuestion },
                .browser = .{ .context = raw_ctx, .open_fn = openMcpUrl },
                .compact_forms = true,
                .capabilities = .{ .form = true, .url = true },
            });
        }

        fn askMcpQuestion(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            entries: []const types.QuestionBatchEntry,
            deadline_ms: i64,
            lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
        ) anyerror!?[][]u8 {
            const agent: *AppAgent = @ptrCast(@alignCast(raw_ctx));
            var watch = DeadlineWatch{
                .agent = agent,
                .deadline_ms = deadline_ms,
                .lifecycle_cancel_flag = lifecycle_cancel_flag,
            };
            const watcher = try std.Thread.spawn(.{}, DeadlineWatch.run, .{&watch});
            defer {
                watch.done.store(true, .release);
                watcher.join();
            }

            const c_alloc = std.heap.c_allocator;
            const answers = try agent.worker.requestMcpElicitationAnswerBlocking(c_alloc, entries) orelse {
                if (watch.timed_out.load(.acquire)) return error.McpInputTimedOut;
                return null;
            };
            defer freeMcpAnswers(c_alloc, answers);
            const copy = try alloc.alloc([]u8, answers.len);
            errdefer alloc.free(copy);
            var copied: usize = 0;
            errdefer for (copy[0..copied]) |answer| alloc.free(answer);
            while (copied < answers.len) : (copied += 1) {
                copy[copied] = try alloc.dupe(u8, answers[copied]);
            }
            return copy;
        }

        fn openMcpUrl(
            raw_ctx: ?*anyopaque,
            alloc: Allocator,
            url: []const u8,
        ) anyerror!bool {
            const agent: *AppAgent = @ptrCast(@alignCast(raw_ctx.?));
            return app_agents_runtime.appOf(App, agent).urlOpener().open(alloc, url);
        }

        fn freeMcpAnswers(alloc: Allocator, answers: [][]u8) void {
            for (answers) |answer| alloc.free(answer);
            alloc.free(answers);
        }

        /// Watches one agent's cancel flag while its MCP question waits. It
        /// runs on its own thread, so it holds the agent it watches.
        const DeadlineWatch = struct {
            agent: *AppAgent,
            deadline_ms: i64,
            lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
            done: std.atomic.Value(bool) = .init(false),
            timed_out: std.atomic.Value(bool) = .init(false),

            fn run(self: *DeadlineWatch) void {
                while (!self.done.load(.acquire)) {
                    const cancelled = self.agent.worker.worker_cancel_requested.load(.acquire);
                    const lifecycle_cancelled = if (self.lifecycle_cancel_flag) |flag|
                        flag.load(.acquire)
                    else
                        false;
                    const timed_out = currentAwakeMillis() >= self.deadline_ms;
                    if (cancelled or lifecycle_cancelled or timed_out) {
                        if (timed_out and !cancelled and !lifecycle_cancelled) {
                            self.timed_out.store(true, .release);
                        }
                        if (self.agent.worker.cancelPendingQuestionBatch()) return;
                    }
                    io_mod.sleep(20 * std.time.ns_per_ms);
                }
            }
        };

        fn currentAwakeMillis() i64 {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
            return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
                std.math.minInt(i64)
            else
                std.math.maxInt(i64);
        }

        fn mcpHasTool(raw_ctx: *anyopaque, name: []const u8, access: tool_mcp_runtime.Access) bool {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return app.hasMcpTool(name, access);
        }

        fn validateMcpTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.ValidationResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasDecl(App, "validateMcpTool")) {
                return app.validateMcpTool(arena, name, arguments_json, access);
            }
            return .not_available;
        }

        fn callMcpTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, max_tool_result_bytes: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return app.callMcpTool(arena, name, arguments_json, max_tool_result_bytes, options);
        }

        fn searchMcpTools(raw_ctx: *anyopaque, arena: Allocator, request: tool_mcp_runtime.SearchRequest, permission_rules: types.PermissionRuleSet, _: @import("../config/context_limits.zig").Values, access: tool_mcp_runtime.Access, cancel_flag: ?*std.atomic.Value(bool)) anyerror!tool_mcp_runtime.SearchResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasDecl(App, "searchMcpTools")) {
                return app.searchMcpTools(arena, request, permission_rules, access, cancel_flag);
            }
            return .{ .model_output = try arena.dupe(u8, "{\"tools\":[],\"count\":0}") };
        }

        fn mcpSnapshotTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, known: tool_mcp_runtime.Binding, permission_rules: types.PermissionRuleSet, limits: @import("../config/context_limits.zig").Values, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.DefinitionSnapshot {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasField(App, "mcp")) {
                return app.mcp.snapshotToolDefinition(arena, name, known, permission_rules, limits, access);
            }
            return .unavailable;
        }

        fn mcpToolSchemaJson(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, permission_rules: types.PermissionRuleSet, _: @import("../config/context_limits.zig").Values, access: tool_mcp_runtime.Access, cancel_flag: ?*std.atomic.Value(bool)) anyerror!?tool_mcp_runtime.ToolSchemaResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasDecl(App, "mcpToolSchemaJson")) {
                return app.mcpToolSchemaJson(arena, name, permission_rules, access, cancel_flag);
            }
            return null;
        }

        pub fn resolveToolActionDisplayTarget(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            const ctx = toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            return tool_presentation.resolveTerminalDisplayTarget(
                arena,
                ctx.tool_registry,
                ctx.workspace_root,
                ctx.terminal_client,
                ctx.managed_executions,
                call,
            );
        }

        pub fn releaseAgentTerminalLease(
            app: *App,
            agent: *AppAgent,
            session_id: []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            return tool_runtime.release_agent_terminal_lease(
                toolContext(
                    app,
                    agent,
                    ignored_list_entries,
                    max_list_entries,
                    max_read_file_bytes,
                    max_read_file_lines,
                    max_read_file_line_len,
                    max_command_output_bytes,
                    gateway_retry_count,
                    gateway_chat_url,
                ),
                session_id,
            );
        }

        pub fn describeToolAction(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .active, null);
        }

        pub fn describeToolActionCompleted(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .completed, null);
        }

        pub fn describeToolActionDenied(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            label: []const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .denied, label);
        }

        pub fn requestToolPermissionSync(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            review_turn: permission_auto_classifier.ReviewTurnContext,
            permission_mode: PermissionMode,
            local_grants: []const PermissionGrant,
            live_authority: ?agent_runtime.LiveToolAuthority,
            revalidation: ?agent_runtime.LivePermissionRevalidation,
            advertised_dynamic_tool_names: []const []const u8,
            mcp_review_schema_json: ?[]const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            var ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            applyCredentialLease(app, agent, &ctx, review_turn.credential, gateway_retry_count, gateway_chat_url);
            ctx.permission_review_turn = review_turn;
            ctx.mcp_review_schema_json = mcp_review_schema_json;
            const admission = ctx.admissionInputWithLiveAuthority(live_authority);
            return if (revalidation) |request| switch (request) {
                .action => |action| tool_admission.revalidateLiveActionPermissionOutcome(
                    admission,
                    arena,
                    call,
                    permission_mode,
                    local_grants,
                    action.authority,
                    action.human_approval,
                ),
            } else tool_admission.requestPermissionOutcome(
                admission,
                arena,
                call,
                permission_mode,
                local_grants,
            );
        }

        pub fn requestPreparedFileMutationPermissionSync(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            prepared: *tool_admission.PreparedFileMutationCall,
            review_turn: permission_auto_classifier.ReviewTurnContext,
            permission_mode: PermissionMode,
            local_grants: []const PermissionGrant,
            live_authority: ?agent_runtime.LiveToolAuthority,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            var ctx = tool_runtime.withAdvertisedDynamicToolNames(
                toolContext(
                    app,
                    agent,
                    ignored_list_entries,
                    max_list_entries,
                    max_read_file_bytes,
                    max_read_file_lines,
                    max_read_file_line_len,
                    max_command_output_bytes,
                    gateway_retry_count,
                    gateway_chat_url,
                ),
                advertised_dynamic_tool_names,
            );
            applyCredentialLease(app, agent, &ctx, review_turn.credential, gateway_retry_count, gateway_chat_url);
            ctx.permission_review_turn = review_turn;
            const admission = ctx.admissionInputWithLiveAuthority(live_authority);
            return tool_admission.requestPreparedFileMutationPermissionOutcome(
                admission,
                arena,
                call,
                prepared,
                permission_mode,
                local_grants,
            );
        }

        pub fn validateToolCall(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolCallValidationResult {
            return tool_runtime.validateToolCall(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        pub fn checkToolAvailability(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            return tool_runtime.checkToolAvailability(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        pub fn permissionTargetForCall(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            call: ToolCall,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return tool_admission.permissionTargetForCall(ctx.admissionInput(), arena, call);
        }

        pub fn executeToolCall(
            app: *App,
            agent: *AppAgent,
            request: agent_runtime.ToolExecutionRequest,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolExecutionResult {
            var ctx = toolContext(app, agent, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            applyCredentialLease(app, agent, &ctx, request.credential, gateway_retry_count, gateway_chat_url);
            ctx.root_user_intent_context = request.root_user_intent_context;
            ctx.root_user_messages = request.root_user_messages;
            ctx.root_user_evidence_complete = request.root_user_evidence_complete;
            ctx.session_grants = request.session_grants;
            ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
            ctx.max_tool_result_bytes = request.max_tool_result_bytes;
            return tool_runtime.executeToolCallAuthorized(ctx, request);
        }

        fn applyCredentialLease(
            app: *App,
            agent: *AppAgent,
            ctx: *tool_runtime.Context,
            credential: types.CredentialLease,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) void {
            const credential_secret = credential.secret() orelse return;
            const credential_source = credential.credentialSource();
            ctx.api_key = credential_secret;
            ctx.credential_source = credential_source;
            ctx.account_id = credential.accountId();
            ctx.gateway_team = credential.tenant();
            if (comptime @hasField(App, "web_search_runtime") and agents.hasAgentField(App, "session")) {
                if (ctx.provider_capabilities.fx_search) {
                    app.web_search_runtime.configure(.{
                        .api_key = credential_secret,
                        .credential_source = credential_source,
                        .gateway_team = credential.tenant(),
                        .worker_model = provider_runtime.modelOf(app, agent),
                        .gateway_retry_count = gateway_retry_count,
                        .gateway_chat_url = gateway_chat_url,
                    });
                    ctx.web_search_backend = app.web_search_runtime.dispatchBackend();
                }
            }
        }

        pub fn appendStaticContextMessage(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            project_context: ?[]const u8,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            try app.contextRegistry().appendDefaultStatic(.{
                .project_context = project_context orelse modelVisibleProjectContext(app, agent),
            }, arena, messages);
            var report = if (comptime @hasDecl(App, "snapshotMcpModelCatalog"))
                try app.snapshotMcpModelCatalog(arena)
            else
                mcp_model_catalog.Report{ .snapshot = try mcp_model_catalog.Snapshot.empty(arena) };
            // The request arena retains the change notice, which outlives this
            // function inside `messages`; only the snapshot names are released.
            defer report.snapshot.deinit(arena);
            const section = try mcp_model_catalog.render(arena, report.snapshot);
            if (section.text.len > 0) {
                try messages.append(arena, .{ .role = .system, .content = section.text });
            }
            if (report.change_notice) |notice| {
                try messages.append(arena, .{ .role = .system, .content = notice });
            }
            if (section.notice) |notice| try pushMcpModelCatalogNotice(app, agent, notice);
        }

        fn pushMcpModelCatalogNotice(app: *App, agent: *AppAgent, notice: []const u8) !void {
            if (comptime @hasDecl(@TypeOf(agent.session), "claimContextNotice")) {
                if (!try agent.session.claimContextNotice(std.heap.c_allocator, notice)) return;
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, notice);
            defer std.heap.c_allocator.free(body);
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, agent, .{
                .topic = "context",
                .tone = .warning,
                .body = body,
                .visibility = .full_only,
            });
        }

        pub fn appendTransientRuntimeContextMessage(
            app: *App,
            agent: *AppAgent,
            arena: Allocator,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            const permission_snapshot = app_permission_runtime.Runtime(App).livePermissionSnapshot(app, agent);
            const host_workspace = appHostWorkspaceInfo(app);
            const workspace = turnWorkspace(app);
            try app.contextRegistry().appendDefaultTransient(.{
                .workspace_root = workspace.root,
                .host_workspace = if (host_workspace) |info| .{
                    .root = info.root(),
                    .cwd = info.cwd(),
                    .home = info.home(),
                } else null,
                .access_scope = workspace.access_scope,
                .interactive = true,
                .permission_mode = permission_snapshot.mode,
                .stale_shell_handles = agent.session.has_stale_shell_handles,
            }, arena, messages);
        }

        pub fn refreshProjectContext(app: *App, agent: *AppAgent, targets: []const context_contract.ApplicableTarget) context_contract.ProviderError!void {
            agent.context_snapshot.deinit(app.alloc);
            if (!app.context_enabled) return;

            const workspace = turnWorkspace(app);
            agent.context_snapshot = app.contextRegistry().gatherDefaultSnapshot(app.alloc, .{
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .targets = targets,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            }) catch |err| {
                debug_trace.logf("context", "gather failed err={s}", .{@errorName(err)});
                return err;
            };
            if (comptime @hasDecl(App, "writeDomainNotice")) {
                for (agent.context_snapshot.notices) |notice| {
                    const should_emit = if (comptime @hasDecl(@TypeOf(agent.session), "claimContextNotice"))
                        try agent.session.claimContextNotice(app.alloc, notice)
                    else
                        true;
                    if (should_emit) {
                        const body = try types.renderContextNoticeBody(app.alloc, notice);
                        defer app.alloc.free(body);
                        app.writeDomainNotice(.{
                            .topic = "context",
                            .tone = .warning,
                            .body = body,
                            .visibility = .full_only,
                        }, true) catch return error.WriteFailed;
                    }
                }
            }
        }

        pub fn fetchModelIds(
            app: *App,
            provider: model_catalog.Provider,
            catalog_endpoint: []const u8,
        ) !std.ArrayList([]u8) {
            const result = model_catalog.fetchWithPublicFallback(provider, app.alloc, .{
                .access = app.auth.modelCatalogAccess(),
                .endpoint = catalog_endpoint,
            });
            var catalog = switch (result) {
                .loaded => |loaded| loaded.catalog,
                .failed => |failed| return failed.failure.asError(),
            };
            defer model_catalog.freeModelCatalog(app.alloc, &catalog);
            return model_catalog.projectModelIds(app.alloc, catalog.items);
        }

        pub fn processQueuedPrompt(
            app: *App,
            agent: *AppAgent,
            queued_job: worker_runtime.QueuedPrompt,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            failure_provenance: ?*?compaction_activity.ErrorProvenance,
        ) !void {
            if (failure_provenance) |out| out.* = null;
            var job = queued_job;
            var snapshot_ownership = worker_runtime.ActivePromptSnapshotOwnership.init(job.images);
            agent.worker.beginActivePromptSnapshots(&snapshot_ownership);
            defer agent.worker.endActivePromptSnapshots(&snapshot_ownership);
            agent.worker.active_context_snapshot = &job.context_snapshot;
            defer agent.worker.active_context_snapshot = null;
            defer if (comptime !@import("builtin").single_threaded) {
                if (agent.session_persistence.subagent_host) |child_host| child_host.cancelYielded();
            };
            agent.worker.setActiveAgentTurnSettings(job.agent_settings);
            defer agent.worker.clearActiveAgentTurnSettings();
            var preflight_context_notices: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
            defer preflight_context_notices.deinit();
            for (job.context_snapshot.notices) |notice| {
                try appendClaimedContextNotice(agent, &preflight_context_notices.writer, notice);
            }

            var skill_catalog = app.skills.acquireCatalog();
            defer skill_catalog.deinit();
            const explicit_bindings = try std.heap.c_allocator.alloc(skill_invocation.ExplicitBinding, job.skill_bindings.len);
            defer std.heap.c_allocator.free(explicit_bindings);
            for (job.skill_bindings, 0..) |binding, index| {
                explicit_bindings[index] = .{ .name = binding.name, .path = binding.path };
            }
            if (preflight_context_notices.written().len > 0) {
                try app_worker_runtime.Runtime(App).pushSemanticNotice(app, agent, .{
                    .topic = "context",
                    .tone = .warning,
                    .body = preflight_context_notices.written(),
                    .visibility = .full_only,
                });
            }
            var tool_projection = try turnToolProjection(app, agent, std.heap.c_allocator, job.permission_mode);
            defer tool_projection.deinit(std.heap.c_allocator);
            const session_child_capability =
                if (comptime agents.hasAgentField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(agent)
                else
                    null;

            var deps = app_callbacks.Bindings(App).agentRuntimeDeps(app, agent);
            if (comptime @hasDecl(App, "providerSet")) deps.agent_stream_provider = app.providerSet().select(job.provider).agent_stream_or_unavailable();
            deps.compaction_failure = failure_provenance;
            // Hiding a tool does not stop a call to it: a subagent's calls are
            // decided against its admission, so `subagent` and any tool or
            // integration outside it are refused.
            if (childRun(agent)) |run| deps.live_tool_authority = childLiveToolAuthority(run);
            const semantic_presentation = app_callbacks.Bindings(App).semanticPresentationSink(agent);
            var config = buildQueuedPromptConfig(
                app,
                agent,
                job,
                .{ .skills = skill_catalog.items, .diagnostics = skill_catalog.diagnostics },
                explicit_bindings,
                gateway_retry_count,
                gateway_chat_url,
                &tool_projection,
                session_child_capability,
            );
            // A subagent is shown only the built-in tools its run was admitted
            // with, the ones its live authority lets it call.
            var child_tools = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer child_tools.deinit();
            if (childRun(agent)) |run| {
                const shown: subagent_agent_adapter.Shown = .{ .admitted = .{
                    .tools = run.admission.tool_names,
                    .starts_subagents = app_session_runtime.Runtime(App).ownSubagentHost(agent) != null,
                } };
                config.advertised_tool_names = try subagent_agent_adapter.childToolNames(
                    child_tools.allocator(),
                    config.advertised_tool_names,
                    deps.tool_registry,
                    shown,
                );
                config.advertised_functions = try subagent_agent_adapter.childFunctions(
                    child_tools.allocator(),
                    config.advertised_functions,
                    deps.tool_registry,
                    shown,
                );
                // The vision fallback is offered as a tool, so a run not
                // admitted with `vision` is not offered it.
                if (!admittedTool(run, "vision")) config.provider_capabilities.vision_fallback = false;
            }
            const process_result = agent_runtime.processAgentPrompt(&agent.session.agent, &deps, semantic_presentation, lifecycleContext(app, agent), config, job);
            try process_result;
        }

        pub fn processContextCompaction(
            app: *App,
            agent: *AppAgent,
            job: worker_runtime.ContextCompactionTask,
            gateway_retry_count: usize,
            failure_provenance: ?*?compaction_activity.ErrorProvenance,
        ) anyerror!void {
            if (failure_provenance) |out| out.* = null;
            const operation_id = job.operation_id orelse agent.worker.beginCompactionActivity(.manual, job.turn_id);
            agent.worker.runCompactionActivity(operation_id, .preparation);
            // Covers early cancellation before compaction starts; acknowledged settlement wins.
            defer if (agent.worker.isCancelRequested()) {
                agent.worker.settleCompactionActivity(operation_id, .{ .outcome = .cancelled });
            };
            compactWithActivity(app, agent, job, gateway_retry_count, operation_id) catch |err| {
                agent.worker.settleCompactionActivity(operation_id, compaction_activity.failure(err, .preparation, agent.worker.isCancelRequested()));
                if (failure_provenance) |out| out.* = .{ .operation_id = operation_id, .turn_id = job.turn_id, .err = err };
                return err;
            };
        }

        fn compactWithActivity(
            app: *App,
            agent: *AppAgent,
            job: worker_runtime.ContextCompactionTask,
            gateway_retry_count: usize,
            operation_id: compaction_activity.OperationId,
        ) anyerror!void {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var deps = app_callbacks.Bindings(App).agentRuntimeDeps(app, agent);
            const provider_capabilities: provider_set.Bundle.Capabilities = if (comptime @hasDecl(App, "providerSet")) blk: {
                const bundle = app.providerSet().select(job.provider);
                deps.agent_stream_provider = bundle.agent_stream_or_unavailable();
                break :blk bundle.capabilities;
            } else .{};
            const capabilities = deps.available_model_capabilities(deps.ctx, job.model);
            const settings = agent.worker.effectiveAgentTurnSettings();
            var provider_options = model_capabilities.resolveProviderOptionsForCapabilities(capabilities, settings.effort, settings.fast_mode);
            provider_options.prompt_caching = provider_capabilities.gateway_prompt_caching;
            if (job.provider == .gateway) {
                provider_options.provider_order = settings.provider_order;
                provider_options.provider_strict = settings.provider_strict;
            }
            var summary_model: agent_runtime.CompactorCaller = .{
                .stream_provider = deps.agent_stream_provider,
                .cooperative_transport_pulse = deps.cooperative_transport_pulse,
                .provider = job.provider,
                .model = job.model,
                .api_key = job.api_key,
                .credential_source = job.credential_source,
                .account_id = job.account_id,
                .gateway_team = job.gateway_team,
                .session_id = app_session_runtime.Runtime(App).activeSessionId(agent),
                .retry_count = gateway_retry_count,
                .provider_options = provider_options,
                .max_output_tokens = model_capabilities.requestOutputTokens(capabilities),
                .capabilities_context = deps.ctx,
                .capabilities_fn = deps.available_model_capabilities,
            };
            const result = agent_runtime.compactContext(arena, &deps, .{
                .operation_id = operation_id,
                .activity_origin = .manual,
                .compactor = .{
                    .history = job.history,
                    .append_messages = session_runtime.appendHistoryChatMessages,
                    .size = agent_runtime.compactionSize(&agent.session.agent, capabilities, settings.auto_compact_percent, job.model),
                    .caller = summary_model.caller(),
                    .records = if (app_session_runtime.Runtime(App).childCapability(agent)) |capability| result_store.compactorStore(capability) else null,
                    .cancel_flag = &agent.worker.worker_cancel_requested,
                    .trace_ctx = .{ .turn_id = job.turn_id },
                },
            }) catch |err| {
                if (err == error.Cancelled and agent.worker.worker_cancel_requested.load(.seq_cst)) return;
                return @as(anyerror!void, err);
            };
            if (result == null) agent.worker.settleCompactionActivity(operation_id, .{ .outcome = .no_op });
        }

        fn lifecycleContext(app: *App, agent: *AppAgent) agent_runtime.LifecycleContext {
            if (childRun(agent)) |run| return .{
                .view = app.lifecycle_view,
                .scope = .{
                    .kind = .subagent,
                    .workspace_root = app.workspace_root,
                    .session_id = run.child_id,
                    .subagent_id = run.subagent_id,
                },
                .outcome_allocator = app.alloc,
            };
            return .{
                .view = app.lifecycle_view,
                .scope = .{
                    .kind = .interactive,
                    .workspace_root = app.workspace_root,
                    .session_id = if (comptime agents.hasAgentField(App, "session_persistence"))
                        app_session_runtime.Runtime(App).activeSessionId(agent)
                    else
                        null,
                },
                .outcome_allocator = app.alloc,
            };
        }

        /// Binds a child's run to the child's own agent, started on first use,
        /// so its turn runs on that agent's worker. Runs on the run's slot
        /// thread and waits for the main loop.
        pub fn bindSubagentWorker(
            raw: ?*anyopaque,
            turn: *subagent_execution.TurnContext,
            cancel: *std.atomic.Value(bool),
        ) subagent_execution.ServiceError!void {
            const app: *App = @ptrCast(@alignCast(raw.?));
            var post = app_agents_runtime.Post{ .turn = turn };
            app_agents_runtime.postAndWait(&app.child_mailbox, &post, cancel) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                error.Failed => error.ProviderFailed,
            };
        }

        /// Runs one child turn on the child's own agent, which runs main's
        /// code: the run is handed to the main loop, which sends the message
        /// to the agent as if typed, and this waits until its turn is saved to
        /// the child's log or ends. Runs on the run's slot thread, after
        /// `bindSubagentWorker`.
        pub fn runSubagentChild(
            raw: ?*anyopaque,
            turn: *subagent_execution.TurnContext,
            message: subagent_domain.QueuedMessage,
            admission: subagent_domain.AdmissionSnapshot,
            cancel: *std.atomic.Value(bool),
        ) subagent_execution.ServiceError!subagent_execution.RunOutcome {
            const app: *App = @ptrCast(@alignCast(raw.?));
            if (turn.hosted_worker == null) return error.ProviderFailed;
            var run = try prepareChildRun(app, turn, message, admission);
            var completion: agents.ChildRunCompletion = .{};
            run.completion = &completion;
            var post = app_agents_runtime.Post{ .turn = turn, .run = run, .message = message.content };
            defer if (post.run) |*unsent| {
                unsent.completion = null;
                unsent.turn = null;
                unsent.deinit(app.alloc);
            };
            app_agents_runtime.postAndWait(&app.child_mailbox, &post, cancel) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Cancelled => error.Cancelled,
                error.Failed => error.ProviderFailed,
            };
            return switch (app_agents_runtime.waitForCompletion(&completion, cancel, turn.workerRuntime())) {
                .completed => .completed,
                .cancelled => error.Cancelled,
                .failed => error.ProviderFailed,
            };
        }

        /// What a child's run takes from its admission alone: the admission,
        /// the system prompt with the child's profile and `overlay`, and the
        /// credential for the admission's provider when main's does not
        /// authorize it. A run's turn context, when there is one, records why
        /// a credential could not be had.
        const ChildRunBase = struct {
            admission: subagent_domain.AdmissionSnapshot,
            system_prompt: []u8,
            credential: ?credentials.Credential,
        };

        fn prepareChildRunBase(
            app: *App,
            child_id: []const u8,
            resolver: *subagent_authority.Resolver,
            overlay: []const u8,
            admission: subagent_domain.AdmissionSnapshot,
            turn: ?*subagent_execution.TurnContext,
        ) subagent_execution.ServiceError!ChildRunBase {
            const alloc = app.alloc;
            // The tool context and prompt are those of the instance at the
            // top of the child's tree, so a launched instance's subagents use
            // its provider and approvals, not the first instance's.
            const root = rootInstanceOfChild(app, child_id);
            const base_context = app.subagentToolContextForAdmission(root, admission);
            var credential: ?credentials.Credential = null;
            errdefer if (credential) |*value| value.deinit(alloc);
            if (admission.provider == .configured or
                !model_provider.authorizesCredential(admission.provider, base_context.credential_source))
            {
                credential = auth_runtime.prepareCredential(
                    alloc,
                    base_context.oauth_transport,
                    base_context.secret_store,
                    admission.provider,
                    base_context.credential_source,
                ) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    if (turn) |value| value.setFailureDiagnostic("model_credential_resolution_failed", @errorName(err));
                    return error.ProviderFailed;
                };
                if (credential == null) {
                    if (turn) |value| value.setFailureDiagnostic("model_credential_missing", admission.model);
                    return error.ProviderFailed;
                }
            }
            var prompt_arena = std.heap.ArenaAllocator.init(alloc);
            defer prompt_arena.deinit();
            const system_prompt = try alloc.dupe(u8, try subagent_agent_adapter.childSystemPrompt(
                prompt_arena.allocator(),
                subagent_agent_adapter.childProfile(resolver, child_id),
                app.promptPolicy(root).system_prompt,
                overlay,
            ));
            errdefer alloc.free(system_prompt);
            const owned_admission = admission.clone(alloc) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.AdmissionFailed,
            };
            return .{ .admission = owned_admission, .system_prompt = system_prompt, .credential = credential };
        }

        /// The instance at the top of child `child_id`'s tree, or the first
        /// instance while the child is not yet bound to the host that
        /// started it. Takes the authority lock, which guards the list.
        fn rootInstanceOfChild(app: *App, child_id: []const u8) *AppAgent {
            if (comptime !@hasField(App, "child_agents")) return &app.main_agent;
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
            for (app.child_agents.items) |child| {
                if (std.mem.eql(u8, child.id, child_id)) return child.agent.root_instance orelse &app.main_agent;
            }
            return &app.main_agent;
        }

        fn freeChildRunBase(alloc: Allocator, base: *ChildRunBase) void {
            base.admission.deinit(alloc);
            alloc.free(base.system_prompt);
            if (base.credential) |*value| value.deinit(alloc);
        }

        /// Everything a child agent's turns read from this run, prepared off
        /// the main loop: its admission, system prompt, and credential
        /// (`prepareChildRunBase`), and the root user's request for the
        /// permission reviewer.
        fn prepareChildRun(
            app: *App,
            turn: *subagent_execution.TurnContext,
            message: subagent_domain.QueuedMessage,
            admission: subagent_domain.AdmissionSnapshot,
        ) subagent_execution.ServiceError!agents.ChildRun {
            const alloc = app.alloc;
            const child_id = turn.child_id orelse return error.AdmissionFailed;
            const work_id = turn.active_work_id orelse return error.AdmissionFailed;
            const resolver = turn.live_authority orelse return error.AdmissionFailed;
            var base = try prepareChildRunBase(app, child_id, resolver, message.system_prompt_overlay, admission, turn);
            errdefer freeChildRunBase(alloc, &base);
            const owned_child_id = try alloc.dupe(u8, child_id);
            errdefer alloc.free(owned_child_id);
            const owned_work_id = try alloc.dupe(u8, work_id);
            errdefer alloc.free(owned_work_id);
            const intent = try alloc.dupe(u8, message.root_user_intent_context);
            errdefer alloc.free(intent);
            const messages = try alloc.alloc([]u8, message.root_user_messages.len);
            var copied: usize = 0;
            errdefer {
                for (messages[0..copied]) |value| alloc.free(value);
                alloc.free(messages);
            }
            for (message.root_user_messages) |value| {
                messages[copied] = try alloc.dupe(u8, value);
                copied += 1;
            }
            return .{
                .child_id = owned_child_id,
                .admission = base.admission,
                .authority_resolver = resolver,
                .system_prompt = base.system_prompt,
                .credential = base.credential,
                .root_user_intent_context = intent,
                .root_user_messages = messages,
                .root_user_evidence_complete = message.root_user_evidence_complete,
                .work_id = owned_work_id,
                .turn = turn,
            };
        }

        /// The run the turns the user starts on a subagent's own screen read:
        /// built as main's runs are, from `admission`, with the child's
        /// `instructions` as its overlay. It has no work id, since no request
        /// of main's started it. The caller owns the run.
        pub fn prepareOwnTurnRun(
            app: *App,
            child_id: []const u8,
            resolver: *subagent_authority.Resolver,
            instructions: []const u8,
            admission: subagent_domain.AdmissionSnapshot,
        ) subagent_execution.ServiceError!agents.ChildRun {
            var base = try prepareChildRunBase(app, child_id, resolver, instructions, admission, null);
            errdefer freeChildRunBase(app.alloc, &base);
            return .{
                .child_id = try app.alloc.dupe(u8, child_id),
                .admission = base.admission,
                .authority_resolver = resolver,
                .system_prompt = base.system_prompt,
                .credential = base.credential,
            };
        }

        fn appendClaimedContextNotice(agent: *AppAgent, writer: *std.Io.Writer, notice: []const u8) !void {
            const should_emit = if (comptime @hasDecl(@TypeOf(agent.session), "claimContextNotice"))
                try agent.session.claimContextNotice(std.heap.c_allocator, notice)
            else
                true;
            if (!should_emit) return;
            if (writer.buffered().len > 0 and !std.mem.endsWith(u8, writer.buffered(), "\n")) {
                try writer.writeByte('\n');
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, notice);
            defer std.heap.c_allocator.free(body);
            try writer.writeAll(body);
        }

        fn buildQueuedPromptConfig(
            app: *App,
            agent: *AppAgent,
            job: worker_runtime.QueuedPrompt,
            catalog: skill_invocation.Catalog,
            bindings: []const skill_invocation.ExplicitBinding,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            tool_projection: *const tool_projection_mod.EffectiveToolProjection,
            session_child_capability: ?*session_child_store.SessionChildCapability,
        ) agent_runtime.Config {
            const prompt_policy = app.promptPolicy(agent);
            const workspace = turnWorkspace(app);
            const child_run = childRun(agent);
            // Work the parent started runs as a subagent turn, as it does
            // without a child agent: the parent's steering is labeled as
            // its feedback, and the reviewer judges it against the root
            // user's requests.
            const parent_run: ?*agents.ChildRun = if (child_run) |run| (if (run.startedByParent()) run else null) else null;
            return .{
                .system_prompt = if (child_run) |run|
                    if (run.system_prompt.len > 0) run.system_prompt else prompt_policy.system_prompt
                else
                    prompt_policy.system_prompt,
                .model_prompt_overlay = prompt_policy.modelPromptOverlay(job.model),
                .skill_catalog = catalog,
                .skill_bindings = bindings,
                .gateway_retry_count = gateway_retry_count,
                .recovery_pause_flag = if (comptime @hasField(@TypeOf(agent.worker), "worker_recovery_pause_requested"))
                    &agent.worker.worker_recovery_pause_requested
                else
                    null,
                .gateway_chat_url = gateway_chat_url,
                .advertised_tool_names = tool_projection.advertised_names,
                .advertised_functions = tool_projection.advertised_functions,
                .provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                    app.providerSet().select(job.provider).capabilities
                else if (job.provider == .gateway)
                    .{ .fx_search = true, .vision_fallback = true }
                else
                    .{},
                .custom_tool_guidance = tool_projection.custom_guidance,
                .agent_step_limit = app.agent_step_limit,
                .max_tool_result_bytes = job.agent_settings.max_tool_result_bytes,
                .auto_compact_percent = job.agent_settings.auto_compact_percent,
                .cancel_flag = &agent.worker.worker_cancel_requested,
                .review_enabled = false,
                .fast_mode = job.agent_settings.fast_mode,
                .ultrafast_mode = job.agent_settings.ultrafast_mode,
                .effort = job.agent_settings.effort,
                .provider_order = if (job.provider == .gateway) job.agent_settings.provider_order else &.{},
                .provider_strict = job.provider == .gateway and job.agent_settings.provider_strict,
                .first_call_tool_choice = job.agent_settings.first_call_tool_choice,
                .workspace_root = workspace.root,
                .access_scope = workspace.access_scope,
                .session_child_capability = session_child_capability,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
                .origin = if (parent_run != null) .subagent else .root,
                .root_user_intent_context = if (parent_run) |run| run.root_user_intent_context else "",
                .root_user_messages = if (parent_run) |run| run.root_user_messages else &.{},
                .root_user_evidence_complete = if (parent_run) |run| run.root_user_evidence_complete else false,
                .subagent_id = if (parent_run) |run| run.subagent_id else 0,
            };
        }
    };
}

const ToolActionState = enum { active, completed, denied };

fn formatToolAction(
    ctx: tool_runtime.Context,
    arena: Allocator,
    call: ToolCall,
    display_target: ?[]const u8,
    state: ToolActionState,
    denied_label: ?[]const u8,
) ![]const u8 {
    if (std.mem.eql(u8, call.name, "web_search") or tool_presentation.isProviderSearchAlias(call.name)) {
        return formatWebSearchAction(arena, call, state, denied_label);
    }
    const spec = ctx.tool_registry.lookup(call.name) orelse {
        if (dynamicMcpActionLabel(state)) |label| {
            if (mcpToolAvailable(ctx, call.name)) {
                return formatToolActionValue(arena, label, call.name);
            }
        }
        return formatMissingSpecToolAction(arena, state, denied_label, call.name);
    };
    if (try tool_presentation.formatRunCommandActivity(arena, ctx.tool_registry, ctx.workspace_root, call)) |activity| {
        defer arena.free(activity.detail);
        const label = if (activity.compatibility_tool) |compatibility_tool|
            specLabel(compatibility_tool, state, denied_label)
        else switch (state) {
            .active => "Running",
            .completed => "Ran",
            .denied => denied_label.?,
        };
        return formatCommandActionValue(
            arena,
            label,
            activity.detail,
        );
    }
    if (std.mem.eql(u8, call.name, "write_file") or
        std.mem.eql(u8, call.name, "edit_file"))
    {
        return formatToolActionValue(
            arena,
            specLabel(spec, state, denied_label),
            display_target orelse spec.label_arg_default,
        );
    }
    if (try tool_presentation.subagentAction(arena, call, switch (state) {
        .active => .active,
        .completed => .completed,
        .denied => .{ .stopped = denied_label.? },
    })) |action| {
        defer action.deinit(arena);
        return formatToolActionValue(arena, action.label, action.detail);
    }
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    const value = display_target orelse
        call.resolved_display_target orelse
        tool_presentation.resolvedSkillName(call, presentation) orelse
        tool_dispatch.presentationLabelValue(presentation, args) orelse
        presentation.label_arg_default;
    return formatToolActionValue(arena, presentationLabel(presentation, state, denied_label), value);
}

fn formatWebSearchAction(arena: Allocator, call: ToolCall, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };
    const label = switch (state) {
        .active => "Searching",
        .completed => "Searched",
        .denied => denied_label.?,
    };
    return formatToolActionValue(arena, label, try tool_presentation.formatWebSearchActionDetail(arena, args));
}

fn formatMissingSpecToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8, name: []const u8) ![]const u8 {
    return switch (state) {
        .active => formatToolActionValue(arena, "Working", name),
        .completed => formatToolActionValue(arena, "Completed", name),
        .denied => formatToolActionValue(arena, denied_label.?, name),
    };
}

fn formatInvalidArgsToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    return switch (state) {
        .active => arena.print("● Working…\x1b[0m", .{}),
        .completed => formatToolActionValue(arena, "Completed", "tool call"),
        .denied => formatToolActionValue(arena, denied_label.?, "tool call"),
    };
}

fn formatToolActionValue(arena: Allocator, label: []const u8, value: []const u8) ![]const u8 {
    return arena.print("● {s}\x1b[0m {s}{s}\x1b[0m", .{ label, shared_theme.current().tool_stdout_style, value });
}

/// Command rows keep the muted tool-text base and add shell syntax colors for
/// quoted strings, numbers, comments, and keywords.
fn formatCommandActionValue(arena: Allocator, label: []const u8, command: []const u8) ![]const u8 {
    const theme = shared_theme.current();
    const profile = code_highlight_languages.resolve("sh") orelse
        return formatToolActionValue(arena, label, command);
    const highlighted = try code_highlight.highlight(
        arena,
        command,
        profile,
        if (theme.light) .light else .dark,
        theme.tool_stdout_style,
    );
    return arena.print("● {s}\x1b[0m {s}\x1b[0m", .{ label, highlighted });
}

fn specLabel(spec: *const tool_dispatch.Tool, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => spec.action_label,
        .completed => spec.completed_action_label,
        .denied => denied_label.?,
    };
}

fn presentationLabel(presentation: tool_dispatch.CallPresentation, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => presentation.action_label,
        .completed => presentation.completed_action_label,
        .denied => denied_label.?,
    };
}

fn dynamicMcpActionLabel(state: ToolActionState) ?[]const u8 {
    return switch (state) {
        .active => "Running MCP",
        .completed => "Ran MCP",
        .denied => null,
    };
}

fn mcpToolAvailable(ctx: tool_runtime.Context, name: []const u8) bool {
    var advertised = false;
    for (ctx.advertised_dynamic_tool_names) |advertised_name| {
        if (std.mem.eql(u8, advertised_name, name)) {
            advertised = true;
            break;
        }
    }
    if (!advertised) return false;
    const raw_ctx = ctx.mcp_ctx orelse return false;
    const has_tool = ctx.mcp_has_tool orelse return false;
    return has_tool(raw_ctx, name, ctx.mcp_access);
}

const test_ignored_list_entries = [_][]const u8{ ".git", "zig-out" };
const test_gateway_chat_url = "https://gateway.test/chat";
const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.web_search,
    test_builtin_tools.shell,
    test_builtin_tools.grep_files,
    test_builtin_tools.skill,
    test_builtin_tools.install_skill,
    test_builtin_tools.subagent,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_label_tool = tool_dispatch.Tool{
    .name = "custom_registered_tool",
    .description = "Custom registered test tool.",
    .model_schema = .{
        .name = "custom_registered_tool",
        .description = "Custom registered test tool.",
    },
    .action_label = "Custom running",
    .completed_action_label = "Custom ran",
    .label_arg_kind = .name,
    .label_arg_default = "custom fallback",
    .decode = test_builtin_tools.read_file.decode,
    .call = test_builtin_tools.read_file.call,
    .reads_only_fn = test_builtin_tools.read_file.reads_only_fn,
    .irreversible_fn = test_builtin_tools.read_file.irreversible_fn,
};
const custom_registry_tools = [_]tool_dispatch.Tool{custom_label_tool};
const custom_tool_registry = tool_dispatch.Registry{ .tools = custom_registry_tools[0..] };

fn gatherTestProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendTestStaticContext(input: context_contract.StaticContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
    const content = try alloc.print("provider static:{s}", .{input.project_context});
    try messages.append(alloc, .{ .role = .system, .content = content });
}

fn appendTestTransientContext(input: context_contract.TransientContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
    const content = try alloc.print(
        "provider transient:{s}:{s}",
        .{ input.workspace_root, @tagName(input.permission_mode) },
    );
    try messages.append(alloc, .{ .role = .system, .content = content });
}

const test_context_provider = context_contract.Provider{
    .id = "test.default_context",
    .gather_project_context_fn = gatherTestProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendTestStaticContext,
    .append_transient_fn = appendTestTransientContext,
};
const test_context_registry = context_contract.Registry{ .default_provider = test_context_provider };
const test_prompt_policy = prompt_policy_contract.Policy{
    .system_prompt = "test system prompt",
    .model_prompt_overlay_fn = struct {
        fn overlay(model: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, model, "test-model")) "test model overlay" else null;
        }
    }.overlay,
};

var refresh_gather_calls: usize = 0;
var refresh_targets_match: bool = false;
var refresh_gather_error: context_contract.ProviderError = error.WriteFailed;

fn gatherFreshProjectContext(alloc: Allocator, input: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    refresh_gather_calls += 1;
    refresh_targets_match = input.targets.len == 1 and
        input.targets[0].kind == .file and
        std.mem.eql(u8, input.targets[0].path, "/tmp/workspace/images/example.png");
    const content = try alloc.print("fresh:{s}", .{input.workspace_root});
    errdefer alloc.free(content);
    const notices = try alloc.alloc([]u8, 1);
    errdefer alloc.free(notices);
    notices[0] = try alloc.dupe(u8, "fresh context notice");
    return .{ .content = content, .notices = notices };
}

fn gatherFailingProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    refresh_gather_calls += 1;
    return refresh_gather_error;
}

fn appendNoopStaticContext(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContext(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

const fresh_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.fresh_context",
    .gather_project_context_fn = gatherFreshProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContext,
    .append_transient_fn = appendNoopTransientContext,
} };
const failing_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.failing_context",
    .gather_project_context_fn = gatherFailingProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContext,
    .append_transient_fn = appendNoopTransientContext,
} };

const RefreshContextApp = struct {
    alloc: Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    context_enabled: bool,
    main_agent: struct {
        context_snapshot: context_contract.GatheredContextSnapshot,
        session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
    },
    context_registry: context_contract.Registry,
    context_notices: std.ArrayList(u8) = .empty,
    context_notice_tone: ?types.NoticeTone = null,
    context_notice_visibility: ?types.NoticeVisibility = null,
    host_info: ?js_host_workspace.Info = null,

    fn contextRegistry(self: *const RefreshContextApp) context_contract.Registry {
        return self.context_registry;
    }

    pub fn workspaceHostInfo(self: *const RefreshContextApp) ?*const js_host_workspace.Info {
        return if (self.host_info) |*info| info else null;
    }

    fn deinit(self: *RefreshContextApp) void {
        self.agent().context_snapshot.deinit(self.alloc);
        self.context_notices.deinit(self.alloc);
        self.agent().session.deinit(self.alloc);
    }

    pub fn writeDomainNotice(self: *RefreshContextApp, notice: types.SemanticNotice, _: bool) !void {
        self.context_notice_tone = notice.tone;
        self.context_notice_visibility = notice.visibility;
        try self.context_notices.appendSlice(self.alloc, notice.body);
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn makeTestContextSnapshot(alloc: Allocator, provider_id: []const u8, content: []const u8) !context_contract.GatheredContextSnapshot {
    const owned_provider_id = try alloc.dupe(u8, provider_id);
    errdefer alloc.free(owned_provider_id);
    return .{ .contribution = .{
        .provider_id = owned_provider_id,
        .content = try alloc.dupe(u8, content),
    } };
}

fn testToolContext(app: *FakeApp) tool_runtime.Context {
    return Runtime(FakeApp).toolContext(app, app.agent(), &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
}

const ProjectionBarrier = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn wait(self: *ProjectionBarrier) void {
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    }
};

const FakeApp = struct {
    alloc: Allocator,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    workspace_root: []const u8 = "/tmp/workspace",
    auth: auth_runtime.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    selected_provider: model_provider.ProviderId = .gateway,
    permission_engine: permissions.PermissionEngine = .{},
    agent_step_limit: usize = 8,
    fast_mode: bool = true,
    main_agent: struct {
        effort: types.ReasoningEffort = types.ReasoningEffort.literal("high"),
        context_snapshot: context_contract.GatheredContextSnapshot,
        change_tracker: change_tracker.ChangeTracker = .{},
        total_input_tokens: u64 = 0,
        total_output_tokens: u64 = 0,
        total_web_search_requests: u64 = 0,
        session: session_runtime.SessionRuntime = .{ .max_history_turns = 4 },
        session_persistence: app_session_runtime.Persistence = .{},
        worker: worker_runtime.WorkerRuntime = .{},
        child_run: ?agents.ChildRun = null,
    },
    skills_dir: []const u8 = "/tmp/skills",
    permission_state: app_permission_runtime.State = .{},
    skills: skill_runtime.Runtime = .{},
    append_context_count: usize = 0,
    snapshot_tools_count: usize = 0,
    snapshot_permission_mode: ?PermissionMode = null,
    snapshot_permission_rule_pattern: ?[]const u8 = null,
    snapshot_barrier: ?*ProjectionBarrier = null,
    snapshot_tools_error: ?anyerror = null,
    snapshot_custom_guidance: []const u8 = "",
    mcp_name: []const u8 = "mcp_lookup",
    mcp_has_tool_calls: usize = 0,
    mcp_result: []const u8 = "{\"ok\":true}",
    mcp_change_notice: ?[]const u8 = null,
    diff_blocks: usize = 0,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{
        .provider = test_builtin_gateway.default_web_search_provider,
    }),
    web_search_models_path: []const u8 = "/models",
    lifecycle_runtime: hooks.Runtime,
    lifecycle_view: hooks.RuntimeView,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    context_registry: context_contract.Registry = test_context_registry,

    fn init(alloc: Allocator) !FakeApp {
        var lifecycle_runtime = hooks.Runtime.init(alloc);
        const lifecycle_view = lifecycle_runtime.freeze();
        var app = FakeApp{
            .alloc = alloc,
            .lifecycle_runtime = lifecycle_runtime,
            .lifecycle_view = lifecycle_view,
            .main_agent = .{ .context_snapshot = try makeTestContextSnapshot(alloc, "test.default_context", "project context") },
        };
        errdefer app.agent().context_snapshot.deinit(alloc);
        var credential = credentials.Credential{
            .token = try alloc.dupe(u8, "api-key"),
            .source = .ai_gateway_api_key,
        };
        defer credential.deinit(alloc);
        _ = app.auth.adoptCredential(alloc, &credential);
        errdefer app.auth.deinit(alloc);
        try app.selected_model.appendSlice(alloc, "test-model");
        return app;
    }

    pub fn toolRegistry(self: *const FakeApp, _: anytype) tool_dispatch.Registry {
        return self.tool_registry;
    }

    fn contextRegistry(self: *const FakeApp) context_contract.Registry {
        return self.context_registry;
    }

    pub fn snapshotMcpModelCatalog(
        self: *FakeApp,
        alloc: Allocator,
    ) !mcp_model_catalog.Report {
        return .{
            .snapshot = try mcp_model_catalog.Snapshot.empty(alloc),
            .change_notice = if (self.mcp_change_notice) |notice| try alloc.dupe(u8, notice) else null,
        };
    }

    fn promptPolicy(_: *const FakeApp, _: anytype) prompt_policy_contract.Policy {
        return test_prompt_policy;
    }

    pub fn agentStreamProvider(self: *const FakeApp) agent_stream_provider.Provider {
        return self.agent_stream_provider;
    }

    fn deinit(self: *FakeApp) void {
        self.auth.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        self.agent().context_snapshot.deinit(self.alloc);
        self.agent().worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.agent().session.deinit(self.alloc);
        self.agent().change_tracker.deinit(self.alloc);
        self.lifecycle_runtime.deinit();
    }

    fn hasMcpTool(self: *FakeApp, name: []const u8, _: tool_mcp_runtime.Access) bool {
        self.mcp_has_tool_calls += 1;
        return std.mem.eql(u8, name, self.mcp_name);
    }

    fn callMcpTool(self: *FakeApp, arena: Allocator, name: []const u8, arguments_json: []const u8, _: usize, _: tool_mcp_runtime.CallOptions) !?tool_mcp_runtime.CallResult {
        _ = arguments_json;
        if (!self.hasMcpTool(name, .unrestricted)) return null;
        return .{ .model_output = try arena.dupe(u8, self.mcp_result) };
    }

    fn subagentToolContextForAdmission(
        self: *FakeApp,
        _: anytype,
        admission: subagent_domain.AdmissionSnapshot,
    ) tool_runtime.Context {
        return Runtime(FakeApp).toolContextForSubagent(
            self,
            self.agent(),
            &test_ignored_list_entries,
            100,
            1024,
            40,
            120,
            2048,
            2,
            test_gateway_chat_url,
            admission,
        );
    }

    fn snapshotModelToolProjection(
        self: *FakeApp,
        _: anytype,
        alloc: Allocator,
        permission_mode: PermissionMode,
    ) !tool_projection_mod.EffectiveToolProjection {
        self.snapshot_tools_count += 1;
        self.snapshot_permission_mode = permission_mode;
        if (self.snapshot_barrier) |barrier| barrier.wait();
        self.snapshot_permission_rule_pattern = if (self.permission_engine.rules.rules.len > 0)
            self.permission_engine.rules.rules[0].pattern
        else
            null;
        if (self.snapshot_tools_error) |err| return err;
        const advertised_names = try alloc.alloc([]const u8, 0);
        errdefer alloc.free(advertised_names);
        const advertised_functions = try alloc.alloc(model_tool_schema.FunctionSchema, 0);
        errdefer alloc.free(advertised_functions);
        return .{
            .advertised_names = advertised_names,
            .advertised_functions = advertised_functions,
            .custom_guidance = try alloc.dupe(u8, self.snapshot_custom_guidance),
        };
    }

    pub fn snapshotSubagentModelToolProjection(
        self: *FakeApp,
        _: anytype,
        alloc: Allocator,
        permission_mode: PermissionMode,
        permission_rules: types.PermissionRuleSet,
    ) !tool_projection_mod.EffectiveToolProjection {
        self.snapshot_tools_count += 1;
        self.snapshot_permission_mode = permission_mode;
        if (self.snapshot_barrier) |barrier| barrier.wait();
        self.snapshot_permission_rule_pattern = if (permission_rules.rules.len > 0)
            permission_rules.rules[0].pattern
        else
            null;
        if (self.snapshot_tools_error) |err| return err;
        const advertised_names = try alloc.alloc([]const u8, 0);
        errdefer alloc.free(advertised_names);
        const advertised_functions = try alloc.alloc(model_tool_schema.FunctionSchema, 0);
        errdefer alloc.free(advertised_functions);
        return .{
            .advertised_names = advertised_names,
            .advertised_functions = advertised_functions,
            .custom_guidance = try alloc.dupe(u8, self.snapshot_custom_guidance),
        };
    }

    pub fn appendRuntimeContextMessage(self: *FakeApp, _: anytype, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        self.append_context_count += 1;
        try Runtime(FakeApp).appendTransientRuntimeContextMessage(self, self.agent(), arena, messages, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestToolPermissionSync(self: *FakeApp, arena: Allocator, call: ToolCall, permission_mode: PermissionMode, local_grants: []const PermissionGrant) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestToolPermissionSync(self, self.agent(), arena, call, "", permission_mode, local_grants, null, null, &.{}, null, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestToolPermissionSyncWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8, mcp_review_schema_json: ?[]const u8) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestToolPermissionSync(self, self.agent(), arena, call, review_turn, permission_mode, local_grants, live_authority, revalidation, advertised_dynamic_tool_names, mcp_review_schema_json, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestPreparedFileMutationPermissionSyncWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestPreparedFileMutationPermissionSync(self, self.agent(), arena, call, prepared, review_turn, permission_mode, local_grants, live_authority, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn validateToolCall(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
        return Runtime(FakeApp).validateToolCall(self, self.agent(), arena, call, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn checkToolAvailability(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall) !?[]const u8 {
        return Runtime(FakeApp).checkToolAvailability(self, self.agent(), arena, call, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolAction(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).describeToolAction(self, self.agent(), arena, call, null, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolAction(self, self.agent(), arena, call, display_target, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionCompleted(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).describeToolActionCompleted(self, self.agent(), arena, call, null, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionCompletedWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionCompleted(self, self.agent(), arena, call, display_target, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionDenied(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, label: []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionDenied(self, self.agent(), arena, call, null, label, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionDeniedWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionDenied(self, self.agent(), arena, call, display_target, label, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn permissionTargetForCall(self: *FakeApp, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).permissionTargetForCall(self, self.agent(), arena, call, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn permissionTargetForCallWithAdvertised(self: *FakeApp, _: anytype, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).permissionTargetForCall(self, self.agent(), arena, call, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn executeToolCall(self: *FakeApp, _: anytype, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
        return Runtime(FakeApp).executeToolCall(self, self.agent(), request, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn executeToolCallWithAdvertised(self: *FakeApp, _: anytype, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
        return self.executeToolCall(&self.main_agent, request);
    }

    pub fn registerAndEmitDiffBlock(self: *FakeApp, payload: agent_runtime.DiffEntryPayload) !void {
        _ = payload;
        self.diff_blocks += 1;
    }

    pub fn formatToolExecutionErrorForAgent(self: *FakeApp, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        _ = self;
        return arena.print("Tool {s} failed: {s}", .{ tool_name, @errorName(err) });
    }

    pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
        return &self.main_agent;
    }
};

fn testAgentStreamProvider(stream_fn: agent_stream_provider.StreamFn) agent_stream_provider.Provider {
    var provider = test_builtin_gateway.agent_stream_provider;
    provider.stream_fn = stream_fn;
    return provider;
}

const TestCatalogProvider = struct {
    saw_expected_input: bool = false,

    fn appendEntry(
        alloc: Allocator,
        catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
        id_text: []const u8,
    ) !void {
        const id = try alloc.dupe(u8, id_text);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{ .id = id, .model_type = model_type });
    }

    fn fetch(
        raw_context: ?*anyopaque,
        alloc: Allocator,
        input: model_catalog.FetchInput,
    ) Allocator.Error!model_catalog.ProviderResult {
        const self: *TestCatalogProvider = @ptrCast(@alignCast(raw_context.?));
        self.saw_expected_input =
            std.mem.eql(u8, input.access.authorizationCredential() orelse "", "api-key") and
            input.access.teamContext() == null and
            input.access.credentialSource() == .ai_gateway_api_key and
            std.mem.eql(u8, input.endpoint, "/catalog") and
            input.cancel_flag == null and
            input.view == .full;

        var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
        errdefer model_catalog.freeModelCatalog(alloc, &catalog);
        try appendEntry(alloc, &catalog, "provider/first");
        try appendEntry(alloc, &catalog, "provider/second");
        return .{ .catalog = catalog };
    }
};

test "app model id loading uses the injected catalog provider" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();
    var test_provider = TestCatalogProvider{};

    var ids = try Runtime(FakeApp).fetchModelIds(
        &app,
        .{
            .context = @ptrCast(&test_provider),
            .fetch_fn = TestCatalogProvider.fetch,
        },
        "/catalog",
    );
    defer {
        for (ids.items) |id| alloc.free(id);
        ids.deinit(alloc);
    }

    try std.testing.expect(test_provider.saw_expected_input);
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);
    try std.testing.expectEqualStrings("provider/first", ids.items[0]);
    try std.testing.expectEqualStrings("provider/second", ids.items[1]);
}

test "app agent runtime builds tool context from app state and MCP callbacks" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();

    app.permission_engine.mode = .auto;
    app.agent().worker.agent_turn_settings = .{
        .max_tool_result_bytes = 4096,
        .first_call_tool_choice = .none,
        .fast_mode = true,
        .effort = types.ReasoningEffort.literal("high"),
    };
    try app.permission_engine.allow(alloc, "run_command", "/tmp/workspace::zig build");

    const ctx = testToolContext(&app);
    try std.testing.expectEqualStrings("/tmp/workspace", ctx.workspace_root);
    try std.testing.expectEqualStrings("api-key", ctx.api_key);
    try std.testing.expectEqualStrings("test-model", ctx.model);
    try std.testing.expect(ctx.tool_registry.lookup("web_search") != null);
    try std.testing.expectEqual(PermissionMode.auto, ctx.permission_mode);
    try std.testing.expectEqual(@as(usize, 1), ctx.permission_grants.len);
    try std.testing.expect(ctx.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), ctx.effort);
    try std.testing.expect(!ctx.web_search_runtime_ready);
    try std.testing.expect(ctx.web_search_backend != null);
    try std.testing.expect(ctx.web_fetch_runtime.? == &app.web_fetch_runtime);
    try std.testing.expect(ctx.web_fetch_progress_ctx != null);
    try std.testing.expect(ctx.on_web_fetch_progress != null);
    try std.testing.expectEqualStrings("test-model", app.web_search_runtime.worker_model);
    try std.testing.expectEqual(ctx.gateway_retry_count, app.web_search_runtime.gateway_retry_count);
    try std.testing.expectEqualStrings(ctx.gateway_chat_url, app.web_search_runtime.gateway_chat_url);
    try std.testing.expectEqualStrings("/models", ctx.gateway_models_path);
    try std.testing.expectEqual(@as(usize, 4096), ctx.max_tool_result_bytes);
    try std.testing.expectEqual(types.ToolChoice.none, ctx.first_call_tool_choice);
    try std.testing.expect(ctx.cancel_flag.? == &app.agent().worker.worker_cancel_requested);
    try std.testing.expectEqual(&app.agent().worker, ctx.worker);
    try std.testing.expect(!@hasField(tool_runtime.Context, "background"));
    try std.testing.expect(ctx.subagent_host == null);
    try std.testing.expect(ctx.subagent_caller_id == null);
    try std.testing.expectEqual(&app.agent().session, ctx.session);
    try std.testing.expectEqual(&app.agent().change_tracker, ctx.tracker.?);
    const child_ctx = Runtime(FakeApp).childToolContext(ctx);
    try std.testing.expect(child_ctx.tracker == null);
    try std.testing.expect(ctx.mcp_has_tool.?(ctx.mcp_ctx.?, "mcp_lookup", .unrestricted));

    const result = try ctx.mcp_call_tool.?(
        ctx.mcp_ctx.?,
        alloc,
        "mcp_lookup",
        "{}",
        ctx.max_tool_result_bytes,
        .{},
    );
    defer alloc.free(result.?.model_output);
    try std.testing.expectEqualStrings("{\"ok\":true}", result.?.model_output);
}

test "interactive app prepared file mutation callback applies app permission policy" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var app = try FakeApp.init(alloc);
    defer app.deinit();
    app.workspace_root = workspace;
    const mutation_tools = [_]tool_dispatch.Tool{test_builtin_tools.write_file};
    app.tool_registry = .{ .tools = &mutation_tools };
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("blocked.txt"),
        .action = .deny,
    }};
    app.permission_engine.rules = .{ .rules = &rules };
    defer app.permission_engine.rules = .{};

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call: ToolCall = .{
        .id = "prepared-app-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"blocked.txt\",\"content\":\"blocked\"}",
    };
    var prepared = switch (try tool_admission.prepareFileMutationCall(arena, call, .{
        .tool_registry = app.toolRegistry(app.agent()),
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .not_file_mutation => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);

    const deps = app_callbacks.Bindings(FakeApp).agentRuntimeDeps(&app, (&app).agent());
    const callback = deps.request_prepared_file_mutation_permission orelse
        return error.TestExpectedPreparedFileMutationCallback;
    const review_calls = [_]ToolCall{call};
    const review_root_messages = [_][]const u8{"do not bypass policy"};
    const review_turn: permission_auto_classifier.ReviewTurnContext = .{
        .model = "openai/gpt-5",
        .pending_assistant = .{ .role = .assistant, .tool_calls = &review_calls },
        .target_call_id = call.id,
        .origin = .root,
        .trusted_root_context = review_root_messages[0],
    };
    const outcome = try callback(
        deps.ctx,
        arena,
        call,
        &prepared,
        review_turn,
        .ask,
        &.{},
        null,
        &.{},
    );

    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, outcome.decision);
    try std.testing.expect(outcome.execution_authority == null);
}

test "app prompt projection configures web search then blocks native execution" {
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
    var app = try FakeApp.init(alloc);
    defer app.deinit();
    var provider_state = ProviderState{};
    var provider = app.web_search_runtime.provider orelse return error.TestExpectedEqual;
    provider.context = @ptrCast(&provider_state);
    provider.execute_fn = FailingWebSearchProvider.execute;
    app.web_search_runtime = web_search_runtime.Runtime.init(.{
        .provider = provider,
    });

    app.web_search_runtime.configure(.{
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
    try Runtime(FakeApp).appendStaticContextMessage(&app, (&app).agent(), arena, null, &messages, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    try app.appendRuntimeContextMessage(app.agent(), arena, &messages);

    try std.testing.expectEqualStrings("stale-key", app.web_search_runtime.api_key);

    const validation = try app.validateToolCall(app.agent(), arena, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"x\"}",
    });
    try std.testing.expectEqualStrings("web_search field \"query\" must contain at least two characters", validation.failure);
    try std.testing.expectEqualStrings(app.auth.apiKey().?, app.web_search_runtime.api_key);
    try std.testing.expectEqualStrings(app.selected_model.items, app.web_search_runtime.worker_model);
    try std.testing.expectEqual(@as(usize, 2), app.web_search_runtime.gateway_retry_count);
    try std.testing.expectEqualStrings(test_gateway_chat_url, app.web_search_runtime.gateway_chat_url);

    const execution = try app.executeToolCall(app.agent(), .{
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
        .max_tool_result_bytes = 2048,
    });
    try std.testing.expectEqualStrings(app.auth.apiKey().?, app.web_search_runtime.api_key);
    try std.testing.expectEqualStrings(app.selected_model.items, app.web_search_runtime.worker_model);
    try std.testing.expectEqual(@as(usize, 2), app.web_search_runtime.gateway_retry_count);
    try std.testing.expectEqualStrings(test_gateway_chat_url, app.web_search_runtime.gateway_chat_url);
    try std.testing.expectEqual(.failure, execution.status);
    try std.testing.expectEqual(@as(usize, 0), provider_state.calls);
}

test "app ChatGPT route removes Gateway-backed auxiliary capabilities" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();
    var credential = credentials.Credential{
        .token = try alloc.dupe(u8, "chatgpt-secret"),
        .source = .chatgpt_subscription,
    };
    defer credential.deinit(alloc);
    _ = app.auth.adoptCredential(alloc, &credential);
    app.selected_provider = .codex;

    const ctx = Runtime(FakeApp).toolContext(
        &app,
        (&app).agent(),
        &test_ignored_list_entries,
        100,
        1024,
        40,
        120,
        2048,
        2,
        test_gateway_chat_url,
    );
    try std.testing.expect(ctx.web_search_backend == null);
    try std.testing.expect(ctx.permission_reviewer_provider == null);
}

test "app agent runtime tool context combines active settings with live permission mode" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();

    app.fast_mode = false;
    app.agent().effort = types.ReasoningEffort.literal("low");
    app.agent().worker.agent_turn_settings = .{
        .max_tool_result_bytes = 1024,
        .first_call_tool_choice = .auto,
        .fast_mode = false,
        .effort = types.ReasoningEffort.literal("low"),
    };
    app.agent().worker.setActiveAgentTurnSettings(.{
        .max_tool_result_bytes = 8192,
        .first_call_tool_choice = .none,
        .fast_mode = true,
        .effort = types.ReasoningEffort.literal("high"),
    });
    defer app.agent().worker.clearActiveAgentTurnSettings();
    app.permission_engine.mode = .auto;

    const ctx = testToolContext(&app);

    try std.testing.expectEqual(@as(usize, 8192), ctx.max_tool_result_bytes);
    try std.testing.expectEqual(types.ToolChoice.none, ctx.first_call_tool_choice);
    try std.testing.expect(ctx.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), ctx.effort);
    try std.testing.expectEqual(PermissionMode.auto, ctx.permission_mode);
}

test "app agent runtime formats active completed denied and MCP tool actions" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var app = try FakeApp.init(alloc);
    defer app.deinit();

    const run_call: ToolCall = .{
        .id = "1",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"zig build\"}",
    };

    const active = try app.describeToolAction(app.agent(), arena, run_call);
    try std.testing.expect(std.mem.find(u8, active, "● ") != null);
    try std.testing.expect(std.mem.find(u8, active, "•") == null);
    try std.testing.expect(std.mem.find(u8, active, "⏺") == null);
    try std.testing.expect(std.mem.find(u8, active, "▸") == null);
    try std.testing.expect(std.mem.find(u8, active, "Running") != null);
    try std.testing.expect(std.mem.find(u8, active, "\x1b[38;5;252mzig\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, active, " build") != null);

    const completed = try app.describeToolActionCompleted(app.agent(), arena, run_call);
    try std.testing.expect(std.mem.find(u8, completed, "● ") != null);
    try std.testing.expect(std.mem.find(u8, completed, "•") == null);
    try std.testing.expect(std.mem.find(u8, completed, "⏺") == null);
    try std.testing.expect(std.mem.find(u8, completed, "▸") == null);
    try std.testing.expect(std.mem.find(u8, completed, "Ran") != null);
    try std.testing.expect(std.mem.find(u8, completed, "\x1b[38;5;252mzig\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, completed, " build") != null);

    const denied = try app.describeToolActionDenied(app.agent(), arena, run_call, "Denied");
    try std.testing.expect(std.mem.find(u8, denied, "Denied") != null);
    try std.testing.expect(std.mem.find(u8, denied, "\x1b[38;5;252mzig\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, denied, " build") != null);

    const malformed_registered: ToolCall = .{
        .id = "malformed_registered",
        .name = "grep_files",
        .arguments_json = "{",
    };
    const malformed_completed = try app.describeToolActionCompleted(app.agent(), arena, malformed_registered);
    try std.testing.expectEqualStrings(
        "● Completed\x1b[0m \x1b[38;5;245mtool call\x1b[0m",
        malformed_completed,
    );
    const malformed_denied = try app.describeToolActionDenied(app.agent(), arena, malformed_registered, "Denied");
    try std.testing.expectEqualStrings(
        "● Denied\x1b[0m \x1b[38;5;245mtool call\x1b[0m",
        malformed_denied,
    );

    const malformed_unknown: ToolCall = .{
        .id = "malformed_unknown",
        .name = "mcp_unknown",
        .arguments_json = "{",
    };
    const malformed_unknown_completed = try app.describeToolActionCompleted(app.agent(), arena, malformed_unknown);
    try std.testing.expect(std.mem.find(u8, malformed_unknown_completed, "mcp_unknown") != null);

    const historical_memory: ToolCall = .{
        .id = "historical_memory",
        .name = "memory",
        .arguments_json = "{\"action\":\"list\"}",
    };
    const historical_memory_completed = try app.describeToolActionCompleted(app.agent(), arena, historical_memory);
    try std.testing.expect(std.mem.find(u8, historical_memory_completed, "memory") != null);

    const mcp_call: ToolCall = .{ .id = "mcp", .name = "mcp_lookup", .arguments_json = "{}" };
    const mcp_action = try app.describeToolActionCompleted(app.agent(), arena, mcp_call);
    try std.testing.expect(std.mem.find(u8, mcp_action, "Completed") != null);
    try std.testing.expect(std.mem.find(u8, mcp_action, "MCP") == null);
    try std.testing.expect(std.mem.find(u8, mcp_action, "mcp_lookup") != null);

    const advertised = [_][]const u8{"mcp_lookup"};
    const advertised_mcp_active = try Runtime(FakeApp).describeToolAction(&app, (&app).agent(), arena, mcp_call, null, &advertised, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    try std.testing.expectEqualStrings(
        "● Running MCP\x1b[0m \x1b[38;5;245mmcp_lookup\x1b[0m",
        advertised_mcp_active,
    );
    const advertised_mcp_action = try Runtime(FakeApp).describeToolActionCompleted(&app, (&app).agent(), arena, mcp_call, null, &advertised, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    try std.testing.expectEqualStrings(
        "● Ran MCP\x1b[0m \x1b[38;5;245mmcp_lookup\x1b[0m",
        advertised_mcp_action,
    );
    app.mcp_has_tool_calls = 0;
    const advertised_mcp_denied = try Runtime(FakeApp).describeToolActionDenied(&app, (&app).agent(), arena, mcp_call, null, "Denied", &advertised, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    try std.testing.expectEqualStrings(
        "● Denied\x1b[0m \x1b[38;5;245mmcp_lookup\x1b[0m",
        advertised_mcp_denied,
    );
    try std.testing.expectEqual(@as(usize, 0), app.mcp_has_tool_calls);

    app.mcp_name = "mcp_other";
    app.mcp_has_tool_calls = 0;
    const unavailable_mcp_action = try Runtime(FakeApp).describeToolActionCompleted(&app, (&app).agent(), arena, mcp_call, null, &advertised, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    try std.testing.expect(std.mem.find(u8, unavailable_mcp_action, "MCP") == null);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_has_tool_calls);

    app.mcp_has_tool_calls = 0;
    const builtin_advertised = [_][]const u8{"shell"};
    _ = try Runtime(FakeApp).describeToolActionCompleted(&app, (&app).agent(), arena, run_call, null, &builtin_advertised, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    try std.testing.expectEqual(@as(usize, 0), app.mcp_has_tool_calls);
}

test "app agent runtime formats registered tool labels from context registry" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var app = try FakeApp.init(alloc);
    defer app.deinit();
    app.tool_registry = custom_tool_registry;

    const call: ToolCall = .{
        .id = "custom",
        .name = "custom_registered_tool",
        .arguments_json = "{\"name\":\"registry value\"}",
    };
    const active = try app.describeToolAction(app.agent(), arena, call);
    try std.testing.expect(std.mem.find(u8, active, "Custom running") != null);
    try std.testing.expect(std.mem.find(u8, active, "registry value") != null);

    const completed = try app.describeToolActionCompleted(app.agent(), arena, call);
    try std.testing.expect(std.mem.find(u8, completed, "Custom ran") != null);
    try std.testing.expect(std.mem.find(u8, completed, "registry value") != null);
}

test "app agent runtime bounds a large multiline run command activity" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var app = try FakeApp.init(alloc);
    defer app.deinit();

    const arguments_json = "{\"action\":\"run\",\"command\":\"" ++ text_utils.repeat("x\\n", 20_000) ++ "\"}";
    const label = try app.describeToolAction(app.agent(), arena, .{
        .id = "large_command",
        .name = "shell",
        .arguments_json = arguments_json,
    });

    try std.testing.expect(label.len <= 180);
    try std.testing.expect(std.mem.findScalar(u8, label, '\n') == null);
    try std.testing.expect(std.mem.find(u8, label, "...") != null);
}

test "native web_search labels preserve bounded query and domain filters" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var app = try FakeApp.init(alloc);
    defer app.deinit();

    const call: ToolCall = .{
        .id = "web_search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current Zig release\",\"allowed_domains\":[\"ziglang.org\",\"github.com\"]}",
    };
    const active = try app.describeToolAction(app.agent(), arena, call);
    try std.testing.expect(std.mem.find(u8, active, "Searching") != null);
    try std.testing.expect(std.mem.find(u8, active, "current Zig release") != null);
    try std.testing.expect(std.mem.find(u8, active, "allowed: ziglang.org, github.com") != null);

    const completed = try app.describeToolActionCompleted(app.agent(), arena, call);
    try std.testing.expect(std.mem.find(u8, completed, "Searched") != null);
    try std.testing.expect(std.mem.find(u8, completed, "current Zig release") != null);
}

test "provider search labels use search wording and generic fallback" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var app = try FakeApp.init(alloc);
    defer app.deinit();

    const call: ToolCall = .{
        .id = "provider_search",
        .name = "parallel_search",
        .arguments_json = "{}",
        .provenance = .provider_executed,
    };
    const active = try app.describeToolAction(app.agent(), arena, call);
    try std.testing.expect(std.mem.find(u8, active, "Searching") != null);
    try std.testing.expect(std.mem.find(u8, active, "web") != null);

    const completed = try app.describeToolActionCompleted(app.agent(), arena, call);
    try std.testing.expect(std.mem.find(u8, completed, "Searched") != null);
    try std.testing.expect(std.mem.find(u8, completed, "web") != null);
}

test "tool labels preserve skill name value" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var app = try FakeApp.init(alloc);
    defer app.deinit();

    const selected: @import("../skills/skill_contract.zig").PreparedSkill = .{ .skill = .{
        .name = "selected-workflow",
        .description = "",
        .path = "/skills/different-directory",
        .source = .workspace_fx,
    } };
    const selected_call: ToolCall = .{
        .id = "selected",
        .name = "skill",
        .arguments_json = "{\"location\":\"skill:0000000000000001:0/different-directory\"}",
        .resolved_skill = &selected,
    };
    const selected_active = try app.describeToolAction(app.agent(), arena, selected_call);
    try std.testing.expect(std.mem.find(u8, selected_active, "selected-workflow") != null);
    const selected_completed = try app.describeToolActionCompleted(app.agent(), arena, selected_call);
    try std.testing.expect(std.mem.find(u8, selected_completed, "selected-workflow") != null);

    var selected_resource = selected_call;
    selected_resource.arguments_json = "{\"location\":\"/skills/different-directory\",\"resource\":\"references/rules.md\"}";
    const selected_resource_completed = try app.describeToolActionCompleted(app.agent(), arena, selected_resource);
    try std.testing.expect(std.mem.find(u8, selected_resource_completed, "Read skill resource") != null);
    try std.testing.expect(std.mem.find(u8, selected_resource_completed, "references/rules.md") != null);

    const skill_call: ToolCall = .{
        .id = "skill",
        .name = "skill",
        .arguments_json = "{\"name\":\"workflow\"}",
    };
    const active = try app.describeToolAction(app.agent(), arena, skill_call);
    try std.testing.expect(std.mem.find(u8, active, "Loading skill") != null);
    try std.testing.expect(std.mem.find(u8, active, "workflow") != null);

    const completed = try app.describeToolActionCompleted(app.agent(), arena, skill_call);
    try std.testing.expect(std.mem.find(u8, completed, "Loaded skill") != null);
    try std.testing.expect(std.mem.find(u8, completed, "workflow") != null);

    const resource_call: ToolCall = .{
        .id = "skill_resource",
        .name = "skill",
        .arguments_json = "{\"name\":\"workflow\",\"resource\":\"references/contract-design.md\"}",
    };
    const resource_active = try app.describeToolAction(app.agent(), arena, resource_call);
    try std.testing.expect(std.mem.find(u8, resource_active, "Reading skill resource") != null);
    try std.testing.expect(std.mem.find(u8, resource_active, "references/contract-design.md") != null);
    try std.testing.expect(std.mem.find(u8, resource_active, "Loading skill workflow") == null);

    const resource_completed = try app.describeToolActionCompleted(app.agent(), arena, resource_call);
    try std.testing.expect(std.mem.find(u8, resource_completed, "Read skill resource") != null);
    try std.testing.expect(std.mem.find(u8, resource_completed, "references/contract-design.md") != null);
    try std.testing.expect(std.mem.find(u8, resource_completed, "Loaded skill workflow") == null);

    const install_call: ToolCall = .{
        .id = "install_skill",
        .name = "install_skill",
        .arguments_json = "{\"source\":\"vercel-labs/agent-skills\",\"skill\":\"workflow\"}",
    };
    const install_active = try app.describeToolAction(app.agent(), arena, install_call);
    try std.testing.expect(std.mem.find(u8, install_active, "Installing skill") != null);
    try std.testing.expect(std.mem.find(u8, install_active, "vercel-labs/agent-skills") != null);

    const install_completed = try app.describeToolActionCompleted(app.agent(), arena, install_call);
    try std.testing.expect(std.mem.find(u8, install_completed, "Installed skill") != null);
    try std.testing.expect(std.mem.find(u8, install_completed, "vercel-labs/agent-skills") != null);
}

test "subagent labels show named request and reply" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var app = try FakeApp.init(alloc);
    defer app.deinit();

    const subagent_call: ToolCall = .{
        .id = "subagent",
        .name = "subagent",
        .arguments_json = "{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"Check replay\"}}",
    };

    const active = try app.describeToolAction(app.agent(), arena, subagent_call);
    try std.testing.expectEqualStrings("● reviewer working\x1b[0m \x1b[38;5;245m· Check replay\x1b[0m", active);

    const completed = try app.describeToolActionCompleted(app.agent(), arena, subagent_call);
    try std.testing.expectEqualStrings("● reviewer replied\x1b[0m \x1b[38;5;245m· Check replay\x1b[0m", completed);
}

test "app agent runtime refreshes enabled project context through registry" {
    const alloc = std.testing.allocator;
    refresh_gather_calls = 0;
    refresh_targets_match = false;
    var app = RefreshContextApp{
        .alloc = alloc,
        .context_enabled = true,
        .context_registry = fresh_context_registry,
        .main_agent = .{ .context_snapshot = try makeTestContextSnapshot(alloc, "test.stale_context", "stale context") },
    };
    defer app.deinit();

    const targets = [_]context_contract.ApplicableTarget{.{
        .path = "/tmp/workspace/images/example.png",
        .kind = .file,
    }};
    try Runtime(RefreshContextApp).refreshProjectContext(&app, (&app).agent(), &targets);

    try std.testing.expectEqual(@as(usize, 1), refresh_gather_calls);
    try std.testing.expect(refresh_targets_match);
    const contribution = app.agent().context_snapshot.contribution orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("test.fresh_context", contribution.provider_id);
    try std.testing.expectEqualStrings("fresh:/tmp/workspace", contribution.content);
    try std.testing.expectEqualStrings("fresh context notice", app.context_notices.items);
    try std.testing.expectEqual(types.NoticeTone.warning, app.context_notice_tone.?);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, app.context_notice_visibility.?);
}

const TestHostWorkspace = struct {
    pub fn workspaceAvailable() i32 {
        return 1;
    }

    pub fn workspaceInfo(out_ptr: [*]u8, out_cap: usize) i32 {
        const json = "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"allow-sandboxed\"}";
        if (json.len > out_cap) return -3;
        @memcpy(out_ptr[0..json.len], json);
        return json.len;
    }
};

test "app agent runtime turn workspace prefers the host workspace root" {
    const alloc = std.testing.allocator;
    var app = RefreshContextApp{
        .alloc = alloc,
        .workspace_root = "/",
        .context_enabled = true,
        .context_registry = fresh_context_registry,
        .main_agent = .{ .context_snapshot = .{} },
    };
    defer app.deinit();

    const local = Runtime(RefreshContextApp).turnWorkspace(&app);
    try std.testing.expectEqualStrings("/", local.root);
    try std.testing.expect(local.access_scope == null);

    app.host_info = try js_host_workspace.Adapter(TestHostWorkspace).loadInfo(alloc);
    const hosted = Runtime(RefreshContextApp).turnWorkspace(&app);
    try std.testing.expectEqualStrings("/workspace", hosted.root);
    const scope = hosted.access_scope orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/workspace", scope.primary_directory);
    try std.testing.expectEqual(@as(usize, 0), scope.additional_directories.len);
}

test "app agent runtime gathers project context from the host workspace root" {
    const alloc = std.testing.allocator;
    refresh_gather_calls = 0;
    var app = RefreshContextApp{
        .alloc = alloc,
        .workspace_root = "/",
        .context_enabled = true,
        .context_registry = fresh_context_registry,
        .host_info = try js_host_workspace.Adapter(TestHostWorkspace).loadInfo(alloc),
        .main_agent = .{ .context_snapshot = .{} },
    };
    defer app.deinit();

    try Runtime(RefreshContextApp).refreshProjectContext(&app, (&app).agent(), &.{});

    try std.testing.expectEqual(@as(usize, 1), refresh_gather_calls);
    const contribution = app.agent().context_snapshot.contribution orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("fresh:/workspace", contribution.content);
}

test "app agent runtime clears disabled project context without gathering" {
    const alloc = std.testing.allocator;
    refresh_gather_calls = 0;
    var app = RefreshContextApp{
        .alloc = alloc,
        .context_enabled = false,
        .context_registry = fresh_context_registry,
        .main_agent = .{ .context_snapshot = try makeTestContextSnapshot(alloc, "test.stale_context", "stale context") },
    };
    defer app.deinit();

    try Runtime(RefreshContextApp).refreshProjectContext(&app, (&app).agent(), &.{});

    try std.testing.expectEqual(@as(usize, 0), refresh_gather_calls);
    try std.testing.expect(app.agent().context_snapshot.contribution == null);
}

test "app agent runtime propagates project context gathering failures" {
    const alloc = std.testing.allocator;
    const errors = [_]context_contract.ProviderError{
        error.OutOfMemory,
        error.NoSpaceLeft,
        error.WriteFailed,
    };
    for (errors) |expected_error| {
        refresh_gather_calls = 0;
        refresh_gather_error = expected_error;
        var app = RefreshContextApp{
            .alloc = alloc,
            .context_enabled = true,
            .context_registry = failing_context_registry,
            .main_agent = .{ .context_snapshot = try makeTestContextSnapshot(alloc, "test.stale_context", "stale context") },
        };
        defer app.deinit();

        try std.testing.expectError(
            expected_error,
            Runtime(RefreshContextApp).refreshProjectContext(&app, (&app).agent(), &.{}),
        );

        try std.testing.expectEqual(@as(usize, 1), refresh_gather_calls);
        try std.testing.expect(app.agent().context_snapshot.contribution == null);
    }
}

test "app agent runtime appends static and transient context through configured registry" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(arena);
    app.permission_engine.mode = .auto;

    try Runtime(FakeApp).appendStaticContextMessage(&app, (&app).agent(), arena, null, &messages, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    try Runtime(FakeApp).appendTransientRuntimeContextMessage(&app, (&app).agent(), arena, &messages, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);

    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expectEqual(types.ChatRole.system, messages.items[0].role);
    try std.testing.expectEqualStrings("provider static:project context", messages.items[0].content.?);
    try std.testing.expect(std.mem.find(u8, messages.items[1].content.?, "<mcp_servers>") != null);
    try std.testing.expectEqualStrings("provider transient:/tmp/workspace:auto", messages.items[2].content.?);
}

test "app agent runtime prefers active queued project context snapshot" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();
    var queued_snapshot = try makeTestContextSnapshot(alloc, "test.queued_context", "queued project context");
    defer queued_snapshot.deinit(alloc);
    app.agent().worker.active_context_snapshot = &queued_snapshot;
    defer app.agent().worker.active_context_snapshot = null;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(arena);

    try Runtime(FakeApp).appendStaticContextMessage(&app, (&app).agent(), arena, null, &messages, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("provider static:queued project context", messages.items[0].content.?);
    try std.testing.expect(std.mem.find(u8, messages.items[1].content.?, "<mcp_servers>") != null);
    const tool_context = testToolContext(&app);
    try std.testing.expectEqualStrings("test.default_context", tool_context.context_registry.defaultProvider().id);
}

test "app agent runtime shows MCP availability changes to the model" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();
    app.mcp_change_notice = "MCP server availability changed since earlier in this session:\n  linear: authentication_required -> ready (74 tools)\n";

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(arena);

    try Runtime(FakeApp).appendStaticContextMessage(&app, (&app).agent(), arena, null, &messages, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);

    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
    try std.testing.expect(std.mem.find(u8, messages.items[1].content.?, "<mcp_servers>") != null);
    try std.testing.expectEqual(types.ChatRole.system, messages.items[2].role);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?, "linear: authentication_required -> ready (74 tools)") != null);
}

fn makeQueuedPrompt(alloc: Allocator) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, "draft an issue"),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "api-key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    };
}

test "manual compaction worker call commits a checkpoint without a continuation" {
    const Gateway = struct {
        request_count: usize = 0,
        saw_no_tools: bool = false,
        observed_model: ?[]const u8 = null,

        fn stream(
            raw: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.ModelRequest,
        ) !agent_stream_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.request_count += 1;
            self.observed_model = request.model;
            self.saw_no_tools = request.tools.advertised_names.len == 0 and
                request.tools.advertised_functions.len == 0 and
                request.tools.additional_functions.len == 0 and
                request.tools.selected_dynamic.len == 0 and
                request.tool_choice == .none;
            try request.admission.admit();
            request.delivery.markPossiblySent();
            const response = "Continue after manual compaction with the user's constraints intact.";
            request.events.emit(.{ .content_delta = response });
            return .{ .completed = .{ .completion = .{
                .content = response,
                .finish_reason = .stop,
            } } };
        }
    };

    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();
    var gateway = Gateway{};
    var provider = testAgentStreamProvider(Gateway.stream);
    provider.context = &gateway;
    app.agent_stream_provider = provider;

    var job = worker_runtime.ContextCompactionTask{
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "api-key"),
        .credential_source = .ai_gateway_api_key,
        .history = try alloc.alloc(types.HistoryTurn, 2),
    };
    defer worker_runtime.freeContextCompactionTask(alloc, job);
    // A tool call leaves work to summarize, so the model is asked.
    const calls = [_]types.ToolCall{.{ .id = "read-1", .name = "read_file", .arguments_json = "{\"path\":\"notes.md\"}" }};
    const results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("read-1"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("notes"),
        .output_bytes = 5,
        .stored_output_bytes = 5,
    }};
    const steps = [_]types.ToolExecutionStep{.{ .tool_calls = @constCast(&calls), .tool_results = @constCast(&results) }};
    job.history[0] = try types.dupeHistoryTurn(alloc, .{ .assistant = .{
        .user = .{ .text = @constCast("exact user request") },
        .assistant = @constCast("exact completed response\n" ++ text_utils.repeat("evidence ", 1_000)),
        .execution = .{ .tool_steps = @constCast(&steps) },
    } });
    job.history[1] = try types.dupeHistoryTurn(alloc, .{ .assistant = .{
        .user = .{ .text = @constCast("second user request") },
        .assistant = @constCast("second response"),
    } });
    for (job.history) |turn| try app.agent().session.appendHistoryEntry(alloc, turn);

    const Worker = struct {
        returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failure: ?anyerror = null,

        fn run(self: *@This(), target: *FakeApp, task: worker_runtime.ContextCompactionTask) void {
            Runtime(FakeApp).processContextCompaction(target, target.agent(), task, 1, null) catch |err| {
                self.failure = err;
            };
            self.returned.store(true, .release);
        }

        fn commit(raw: *anyopaque, event: worker_runtime.ContextCompaction) !void {
            const target: *FakeApp = @ptrCast(@alignCast(raw));
            try app_session_runtime.Runtime(FakeApp).commitContextCompaction(target, target.agent(), event.summary, event.active_prefix, event.retained_from);
        }
    };
    var worker: Worker = .{};
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &worker, &app, job });
    var joined = false;
    defer if (!joined) {
        app.agent().worker.requestShutdown();
        thread.join();
    };
    var events: std.ArrayList(worker_runtime.WorkerEvent) = .empty;
    defer events.deinit(std.heap.c_allocator);
    defer for (events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
    const deadline = io_mod.milliTimestamp() + 5_000;
    while (events.items.len == 0) {
        var batch = app.agent().worker.takeEvents();
        defer batch.deinit(std.heap.c_allocator);
        try events.appendSlice(std.heap.c_allocator, batch.items);
        if (io_mod.milliTimestamp() >= deadline) return error.TestExpectedCompactionEvent;
        if (events.items.len == 0) io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(events.items[0] == .context_compaction);
    try std.testing.expect(!worker.returned.load(.acquire));
    const pending_activity = app.agent().worker.compactionActivitySnapshot();
    try std.testing.expectEqual(compaction_activity.Stage.publication, pending_activity.operation.?.phase.running);
    try std.testing.expectEqual(@as(usize, 2), app.agent().session.historyLen());
    app.agent().worker.resolveContextCompaction(std.heap.c_allocator, events.items[0].context_compaction, &app, Worker.commit);
    thread.join();
    joined = true;
    if (worker.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), app.agent().session.historyLen());
    var tail_events = app.agent().worker.takeEvents();
    defer tail_events.deinit(std.heap.c_allocator);
    try events.appendSlice(std.heap.c_allocator, tail_events.items);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_count);
    try std.testing.expect(gateway.saw_no_tools);
    try std.testing.expectEqualStrings("test-model", gateway.observed_model.?);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .context_compaction);
    try std.testing.expect(events.items[0].context_compaction.active_prefix == null);

    const completed_activity = app.agent().worker.compactionActivitySnapshot();
    try std.testing.expectEqual(pending_activity.operation.?.id, completed_activity.operation.?.id);
    try std.testing.expectEqual(compaction_activity.Outcome.succeeded, completed_activity.operation.?.phase.terminal.outcome);
    try std.testing.expect(completed_activity.revision > pending_activity.revision);
    app.agent().worker.finishProcessing();
    try std.testing.expectEqualDeep(completed_activity, app.agent().worker.compactionActivitySnapshot());

    // The oldest turn is compacted: its user message is kept word for word,
    // and the newest turn stays unchanged after the checkpoint.
    const checkpoint = events.items[0].context_compaction.summary;
    try std.testing.expectEqual(@as(usize, 1), checkpoint.removed_turn_count);
    const model_text = (try session_runtime.formatCompactedContinuationMessage(alloc, checkpoint.summary));
    defer alloc.free(model_text);
    try std.testing.expect(std.mem.find(u8, model_text, "User 1:\nexact user request\n") != null);
    try std.testing.expect(std.mem.find(u8, model_text, "Continue after manual compaction") != null);
    try std.testing.expect(std.mem.find(u8, model_text, "second user request") == null);
}

test "app agent runtime processes a cancelled queued prompt" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();

    app.agent().worker.worker_cancel_requested.store(true, .seq_cst);

    const job = try makeQueuedPrompt(alloc);
    defer worker_runtime.freeQueuedPrompt(alloc, job);

    try Runtime(FakeApp).processQueuedPrompt(&app, (&app).agent(), job, 1, test_gateway_chat_url, null);

    try std.testing.expectEqual(@as(usize, 0), app.append_context_count);
    try std.testing.expectEqual(@as(usize, 1), app.snapshot_tools_count);

    var events = app.agent().worker.takeEvents();
    defer events.deinit(std.heap.c_allocator);
    defer for (events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expect(events.items[0] == .tool_lifecycle);
    try std.testing.expect(events.items[0].tool_lifecycle.turn_finished.turn_id != 0);
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.interrupted,
        events.items[0].tool_lifecycle.turn_finished.outcome,
    );
    try std.testing.expect(events.items[1] == .finish_prompt);
    try std.testing.expect(events.items[1].finish_prompt.turn == .interrupted);
}

test "app direct ask delivers semantic presentation through the runtime sink" {
    const Gateway = struct {
        fn stream(
            _: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.ModelRequest,
        ) !agent_stream_provider.Result {
            try request.admission.admit();
            request.events.emit(.{ .content_delta = "Before table.\n" ++
                "| Name | Count |\n" ++
                "|------|------:|\n" ++
                "| api | 7 |\n" ++
                "After table.\n\n" ++
                "```zig\n" ++
                "const ready = true;\n" ++
                "```\n\n" ++
                "---\n" });
            return .{ .completed = .{ .completion = .{ .content = "", .finish_reason = .stop } } };
        }
    };

    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();
    const job = try makeQueuedPrompt(alloc);
    defer worker_runtime.freeQueuedPrompt(alloc, job);

    app.agent_stream_provider = testAgentStreamProvider(Gateway.stream);

    try Runtime(FakeApp).processQueuedPrompt(&app, (&app).agent(), job, 1, test_gateway_chat_url, null);

    var events = app.agent().worker.takeEvents();
    defer events.deinit(std.heap.c_allocator);
    defer for (events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);

    var table_count: usize = 0;
    var code_count: usize = 0;
    var rule_count: usize = 0;
    const SemanticEvent = enum { table, code_block, thematic_rule };
    var semantic_events: [3]SemanticEvent = undefined;
    var semantic_event_count: usize = 0;
    for (events.items) |event| switch (event) {
        .assistant_presentation => |presentation| switch (presentation) {
            .table => |table| {
                table_count += 1;
                semantic_events[semantic_event_count] = .table;
                semantic_event_count += 1;
                try std.testing.expectEqualStrings("api", table.rows[1].cells[0]);
            },
            .code_block => |block| {
                code_count += 1;
                semantic_events[semantic_event_count] = .code_block;
                semantic_event_count += 1;
                try std.testing.expectEqualStrings("zig", block.language);
                try std.testing.expectEqualStrings("const ready = true;\n", block.code);
            },
            .thematic_rule => {
                rule_count += 1;
                semantic_events[semantic_event_count] = .thematic_rule;
                semantic_event_count += 1;
            },
            .text => {},
        },
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 1), table_count);
    try std.testing.expectEqual(@as(usize, 1), code_count);
    try std.testing.expectEqual(@as(usize, 1), rule_count);
    try std.testing.expectEqualSlices(
        SemanticEvent,
        &.{ .table, .code_block, .thematic_rule },
        semantic_events[0..semantic_event_count],
    );
}

test "app agent runtime clears active turn settings when queued prompt setup fails" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();

    app.fast_mode = false;
    app.agent().effort = types.ReasoningEffort.literal("low");
    app.agent().worker.agent_turn_settings = .{
        .fast_mode = false,
        .effort = types.ReasoningEffort.literal("low"),
    };
    app.snapshot_tools_error = error.TestExpectedEqual;

    var job = try makeQueuedPrompt(alloc);
    defer worker_runtime.freeQueuedPrompt(alloc, job);
    job.agent_settings = .{
        .fast_mode = true,
        .effort = types.ReasoningEffort.literal("high"),
    };
    job.permission_mode = .yolo;

    try std.testing.expectError(error.TestExpectedEqual, Runtime(FakeApp).processQueuedPrompt(&app, (&app).agent(), job, 1, test_gateway_chat_url, null));
    try std.testing.expectEqual(
        @as(?PermissionMode, .yolo),
        app.snapshot_permission_mode,
    );

    const effective = app.agent().worker.effectiveAgentTurnSettings();
    try std.testing.expect(!effective.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("low"), effective.effort);
}

test "a subagent turn's tool projection uses its immutable admission permission rules" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();

    var live_rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("live-rule"),
        .action = .deny,
    }};
    app.permission_engine.rules = .{ .rules = &live_rules };
    defer app.permission_engine.rules = .{};

    var admission_rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("admitted-rule"),
        .action = .allow,
    }};
    const admission = try subagent_domain.captureAdmission(alloc, .{
        .parent_id = "parent",
        .source_id = "parent",
        .model = "test-model",
        .effort = .auto,
        .permission_mode = .auto,
        .rules = .{ .rules = &admission_rules },
    });
    app.main_agent.child_run = .{
        .child_id = try alloc.dupe(u8, "child"),
        .admission = admission,
        .authority_resolver = undefined,
    };
    defer {
        app.main_agent.child_run.?.deinit(alloc);
        app.main_agent.child_run = null;
    }

    var replacement_rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("replacement-rule"),
        .action = .ask,
    }};
    var barrier = ProjectionBarrier{};
    app.snapshot_barrier = &barrier;
    app.snapshot_tools_error = error.TestExpectedEqual;
    const Project = struct {
        app: *FakeApp,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            // The job's own mode is main's; a subagent's turn ignores it.
            var projection = Runtime(FakeApp).turnToolProjection(self.app, (self.app).agent(), std.testing.allocator, .yolo) catch |err| {
                self.err = err;
                return;
            };
            projection.deinit(std.testing.allocator);
        }
    };
    var project = Project{ .app = &app };
    const projection_thread = try std.Thread.spawn(.{}, Project.run, .{&project});
    var joined = false;
    defer if (!joined) {
        barrier.release.store(true, .release);
        projection_thread.join();
    };
    const observation_deadline = io_mod.milliTimestamp() + 5_000;
    while (!barrier.entered.load(.acquire) and
        !project.done.load(.acquire) and
        io_mod.milliTimestamp() < observation_deadline)
    {
        io_mod.sleep(std.time.ns_per_ms);
    }
    if (!barrier.entered.load(.acquire)) {
        barrier.release.store(true, .release);
        projection_thread.join();
        joined = true;
        return error.TestProjectionNotEntered;
    }
    app.permission_engine.rules = .{ .rules = &replacement_rules };
    barrier.release.store(true, .release);
    projection_thread.join();
    joined = true;

    try std.testing.expectEqual(error.TestExpectedEqual, project.err.?);
    try std.testing.expectEqualStrings(
        "admitted-rule",
        app.snapshot_permission_rule_pattern orelse return error.TestExpectedEqual,
    );
}

test "subagent tool context uses immutable admission authority" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();

    var live_rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("live-rule"),
        .action = .deny,
    }};
    app.permission_engine.rules = .{ .rules = &live_rules };
    defer app.permission_engine.rules = .{};

    var admission_rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("admitted-rule"),
        .action = .allow,
    }};
    const admission_grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("run_command"),
        .target_path = @constCast("/tmp/workspace::zig build"),
    }};
    var admission = try subagent_domain.captureAdmission(alloc, .{
        .parent_id = "parent",
        .source_id = "parent",
        .model = "test-model",
        .effort = .auto,
        .permission_mode = .auto,
        .rules = .{ .rules = &admission_rules },
        .grants = &admission_grants,
    });
    defer admission.deinit(alloc);

    const ctx = app.subagentToolContextForAdmission(app.agent(), admission);
    try std.testing.expectEqual(PermissionMode.auto, ctx.permission_mode);
    try std.testing.expectEqual(@as(usize, 1), ctx.permission_rules.rules.len);
    try std.testing.expectEqualStrings(
        "admitted-rule",
        ctx.permission_rules.rules[0].pattern,
    );
    try std.testing.expectEqual(@as(usize, 1), ctx.permission_grants.len);
    try std.testing.expectEqualStrings(
        "run_command",
        ctx.permission_grants[0].tool_name,
    );
}

test "app agent runtime settles queued snapshot ownership when prompt admission fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "queued-snapshot.bin", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nqueued");
    }
    const snapshot_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "queued-snapshot.bin");
    defer alloc.free(snapshot_path);

    var app = try FakeApp.init(alloc);
    defer app.deinit();
    app.snapshot_tools_error = error.TestExpectedEqual;
    defer app.agent().session_persistence.deinit(alloc);

    var job = try makeQueuedPrompt(alloc);
    defer worker_runtime.freeQueuedPrompt(alloc, job);
    job.images = try types.dupeImageAttachmentSlice(alloc, &.{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = snapshot_path,
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }});

    try std.testing.expectError(
        error.TestExpectedEqual,
        Runtime(FakeApp).processQueuedPrompt(&app, (&app).agent(), job, 1, test_gateway_chat_url, null),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, snapshot_path, .{}),
    );
}

test "app agent runtime discards every snapshot in a failed multi-image preflight" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var first = try tmp.dir.createFile(std.testing.io, "first.bin", .{});
        defer first.close(std.testing.io);
        try first.writeStreamingAll(std.testing.io, "first");
    }
    {
        var second = try tmp.dir.createFile(std.testing.io, "second.bin", .{});
        defer second.close(std.testing.io);
        try second.writeStreamingAll(std.testing.io, "second");
    }
    const first_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "first.bin");
    defer alloc.free(first_path);
    const second_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "second.bin");
    defer alloc.free(second_path);

    var app = try FakeApp.init(alloc);
    defer app.deinit();
    app.snapshot_tools_error = error.TestExpectedEqual;
    var job = try makeQueuedPrompt(alloc);
    defer worker_runtime.freeQueuedPrompt(alloc, job);
    job.images = try types.dupeImageAttachmentSlice(alloc, &.{
        .{
            .id = 1,
            .path = @constCast("/tmp/first.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = first_path,
            .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        },
        .{
            .id = 2,
            .path = @constCast("/tmp/second.png"),
            .media_type = @constCast("image/png"),
            .snapshot_path = second_path,
            .snapshot_sha256 = @constCast("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        },
    });

    try std.testing.expectError(
        error.TestExpectedEqual,
        Runtime(FakeApp).processQueuedPrompt(&app, (&app).agent(), job, 1, test_gateway_chat_url, null),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, first_path, .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, second_path, .{}),
    );
}

test "app agent runtime queued prompt config uses captured job settings over stale live app state" {
    const alloc = std.testing.allocator;
    var app = try FakeApp.init(alloc);
    defer app.deinit();

    app.fast_mode = false;
    app.agent().effort = types.ReasoningEffort.literal("low");
    app.agent().worker.agent_turn_settings = .{
        .max_tool_result_bytes = 1024,
        .first_call_tool_choice = .auto,
        .fast_mode = false,
        .effort = types.ReasoningEffort.literal("low"),
    };

    var job = try makeQueuedPrompt(alloc);
    defer worker_runtime.freeQueuedPrompt(alloc, job);
    job.agent_settings = .{
        .max_tool_result_bytes = 8192,
        .first_call_tool_choice = .none,
        .fast_mode = true,
        .effort = types.ReasoningEffort.literal("high"),
    };
    const custom_guidance = try alloc.dupe(u8, "app custom tool guidance");
    var tool_projection = tool_projection_mod.EffectiveToolProjection{
        .advertised_names = try alloc.alloc([]const u8, 0),
        .advertised_functions = try alloc.alloc(model_tool_schema.FunctionSchema, 0),
        .custom_guidance = custom_guidance,
    };
    defer tool_projection.deinit(alloc);
    const config = Runtime(FakeApp).buildQueuedPromptConfig(&app, (&app).agent(), job, .{ .skills = &.{} }, &.{}, 1, test_gateway_chat_url, &tool_projection, null);

    try std.testing.expect(config.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), config.effort);
    try std.testing.expectEqual(@as(usize, 8192), config.max_tool_result_bytes);
    try std.testing.expectEqual(types.ToolChoice.none, config.first_call_tool_choice);
    try std.testing.expectEqualSlices([]const u8, tool_projection.advertised_names, config.advertised_tool_names);
    try std.testing.expectEqualSlices(model_tool_schema.FunctionSchema, tool_projection.advertised_functions, config.advertised_functions);
    try std.testing.expectEqualStrings(tool_projection.custom_guidance, config.custom_tool_guidance);
    try std.testing.expectEqualStrings(test_prompt_policy.system_prompt, config.system_prompt);
    try std.testing.expectEqualStrings("test model overlay", config.model_prompt_overlay.?);
    try std.testing.expect(!app.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("low"), app.agent().effort);
}

test "app agent runtime highlights shell command rows over the tool text base" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var app = try FakeApp.init(alloc);
    defer app.deinit();

    const run_call: ToolCall = .{
        .id = "1",
        .name = "shell",
        .arguments_json = "{\"action\":\"run\",\"command\":\"printf 'hello world' | wc -c\"}",
    };
    const completed = try app.describeToolActionCompleted(app.agent(), arena, run_call);

    // The label and untokenized command text keep the muted tool-text base,
    // while the command verb and quoted string pick up syntax palette colors
    // and return to the base after their closes.
    try std.testing.expect(std.mem.startsWith(u8, completed, "● Ran\x1b[0m \x1b[38;5;245m"));
    try std.testing.expect(std.mem.find(
        u8,
        completed,
        "\x1b[38;5;252mprintf\x1b[39m\x1b[38;5;245m",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        completed,
        "\x1b[38;5;250m'hello world'\x1b[39m\x1b[38;5;245m",
    ) != null);
    try std.testing.expect(std.mem.endsWith(u8, completed, "\x1b[0m"));
    // The pipe and the command after it take the keyword color, the flag the
    // number color; plain bytes are intact beneath the styling.
    try std.testing.expect(std.mem.find(u8, completed, "\x1b[38;5;252m|\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, completed, "\x1b[38;5;252mwc\x1b[39m") != null);
    try std.testing.expect(std.mem.find(u8, completed, "\x1b[38;5;250m-c\x1b[39m") != null);
}

const std = @import("std");
const app_lifecycle = @import("app_lifecycle.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_input_runtime = @import("app_input_runtime.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const app_runtime_setup = @import("app_runtime_setup.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const host = @import("../hosts/host.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const record_tape = @import("../workspace/record_tape.zig");
const statusline_identity = @import("../workspace/statusline_identity.zig");
const shared_io = @import("../shared/io.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const permissions = @import("../permissions/permissions.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const update_target = @import("../upgrade/update_target.zig");
const core_input_runtime = @import("../input/runtime.zig");
const ui_render = @import("../../ui/render.zig");
const ui_input = @import("../../ui/input/runtime.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const Allocator = std.mem.Allocator;

pub const CapabilityProviders = struct {
    load_mcp_runtime: mcp_runtime.LoadRuntimeFn,
    skill_root_policy: skill_contract.RootPolicy,
    terminal_title: host.TerminalTitle,
};

fn BootstrapDeps(comptime App: type) type {
    return struct {
        const BootstrapInteractiveAppFn = *const fn (app_lifecycle.BootstrapConfig) anyerror!app_lifecycle.StartupState;
        const ConfigureSessionPreferencesFn = *const fn (
            *App,
            model_provider.ProviderId,
            []const u8,
            config_runtime.ModelSource,
            []const u8,
            types.ReasoningEffort,
            bool,
        ) anyerror!void;
        const InitializePersistenceFn = *const fn (*App, bool) anyerror!void;
        const StageRequestedResumeViewFn = *const fn (*App) app_session_runtime.ResumeViewStage;
        const PublishStagedResumeViewFn = *const fn (*App, u32) anyerror!void;
        const LoadSkillsFn = *const fn (
            Allocator,
            []const u8,
            skill_contract.RootPolicy,
        ) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills;
        const WelcomeMessageFn = *const fn (Allocator) anyerror![]u8;
        const BeginFreshPersistedSessionFn = *const fn (*App) anyerror!void;
        const EnableSessionStoresFn = *const fn (*App) void;
        bootstrap_interactive_app: BootstrapInteractiveAppFn,
        configure_session_preferences: ConfigureSessionPreferencesFn,
        initialize_persistence: InitializePersistenceFn,
        stage_requested_resume_view: StageRequestedResumeViewFn,
        publish_staged_resume_view: PublishStagedResumeViewFn,
        load_mcp_runtime: mcp_runtime.LoadRuntimeFn,
        load_skills: LoadSkillsFn,
        skill_root_policy: skill_contract.RootPolicy,
        welcome_message: WelcomeMessageFn,
        begin_fresh_persisted_session: BeginFreshPersistedSessionFn,
        enable_session_stores: EnableSessionStoresFn,
        terminal_title: host.TerminalTitle,
    };
}

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn bootstrap(
            app: *App,
            footer_rows: u16,
            default_model: []const u8,
            default_agent_step_limit: usize,
            resize_handler: app_lifecycle.ResizeHandler,
            record_requested: bool,
            capability_providers: CapabilityProviders,
        ) !void {
            try bootstrapWithDeps(
                app,
                footer_rows,
                default_model,
                default_agent_step_limit,
                resize_handler,
                record_requested,
                defaultDeps(capability_providers),
            );
        }

        fn defaultDeps(capability_providers: CapabilityProviders) BootstrapDeps(App) {
            return .{
                .bootstrap_interactive_app = bootstrapInteractiveAppDefault,
                .configure_session_preferences = configureSessionPreferencesDefault,
                .initialize_persistence = initializePersistenceDefault,
                .stage_requested_resume_view = stageRequestedResumeViewDefault,
                .publish_staged_resume_view = publishStagedResumeViewDefault,
                .load_mcp_runtime = capability_providers.load_mcp_runtime,
                .load_skills = app_runtime_setup.loadSkills,
                .skill_root_policy = capability_providers.skill_root_policy,
                .welcome_message = welcomeMessageDefault,
                .begin_fresh_persisted_session = beginFreshPersistedSessionDefault,
                .enable_session_stores = enableSessionStoresDefault,
                .terminal_title = capability_providers.terminal_title,
            };
        }

        fn bootstrapInteractiveAppDefault(cfg: app_lifecycle.BootstrapConfig) !app_lifecycle.StartupState {
            return app_lifecycle.bootstrapInteractiveApp(cfg);
        }

        fn initializePersistenceDefault(
            app: *App,
            required: bool,
        ) !void {
            try app_session_runtime.Runtime(App).initializePersistence(
                app,
                required,
            );
        }

        fn stageRequestedResumeViewDefault(app: *App) app_session_runtime.ResumeViewStage {
            return app_session_runtime.Runtime(App).stageRequestedResumeView(app);
        }

        fn publishStagedResumeViewDefault(app: *App, entry_id: u32) !void {
            try app_session_runtime.Runtime(App).publishStagedResumeView(app, entry_id);
        }

        fn configureSessionPreferencesDefault(
            app: *App,
            provider: model_provider.ProviderId,
            configured_model: []const u8,
            model_source: config_runtime.ModelSource,
            selected_model: []const u8,
            effort: types.ReasoningEffort,
            fast_mode: bool,
        ) !void {
            try app_session_runtime.Runtime(App).configureStartupPreferences(
                app,
                provider,
                configured_model,
                model_source,
                selected_model,
                effort,
                fast_mode,
            );
        }

        fn welcomeMessageDefault(alloc: Allocator) ![]u8 {
            return ui_render.welcomeMessage(alloc);
        }

        fn beginFreshPersistedSessionDefault(app: *App) !void {
            try app_session_runtime.Runtime(App).beginFreshPersistedSession(app);
        }

        fn enableSessionStoresDefault(app: *App) void {
            app_session_runtime.Runtime(App).enableSessionStores(app);
        }

        // Neutral one-line summary inline; the full detail stays behind Ctrl+O.
        fn writeCollapsedStartupNotice(app: *App, topic: []const u8, summary_lead: []const u8, detail: []const u8) !void {
            const summary = try std.fmt.allocPrint(app.alloc, "{s} (ctrl o to view)", .{summary_lead});
            defer app.alloc.free(summary);
            try app.writeDomainNotice(.{ .topic = topic, .tone = .neutral, .body = summary }, true);
            try app.writeDomainNotice(.{ .topic = topic, .tone = .neutral, .body = detail, .visibility = .full_only }, true);
        }

        fn bootstrapWithDeps(
            app: *App,
            footer_rows: u16,
            default_model: []const u8,
            default_agent_step_limit: usize,
            resize_handler: app_lifecycle.ResizeHandler,
            record_requested: bool,
            deps: BootstrapDeps(App),
        ) !void {
            errdefer app.deinit();

            var startup = try deps.bootstrap_interactive_app(.{
                .alloc = app.alloc,
                .terminal = &app.terminal,
                .shell = &app.shell,
                .metrics = &app.metrics,
                .terminal_title = deps.terminal_title,
                .footer_rows = footer_rows,
                .startup_min_body_rows = ui_render.welcome_message_reserved_rows,
                .default_model = default_model,
                .default_agent_step_limit = default_agent_step_limit,
                .secret_store = if (comptime @hasDecl(App, "secretStore"))
                    app.secretStore()
                else
                    host.unavailable_secret_store,
                .resize_handler = resize_handler,
                .fx_version = App.app_version,
                .record_requested = record_requested,
            });
            defer startup.deinit(app.alloc);

            app.workspace_root = startup.takeWorkspaceRoot();
            if (comptime @hasDecl(App, "adoptWorkspaceAccess")) {
                app.adoptWorkspaceAccess(startup.takeWorkspaceAccess());
            }
            if (startup.takeCredential()) |credential_value| {
                var credential = credential_value;
                defer credential.deinit(app.alloc);
                _ = app.auth.adoptCredential(app.alloc, &credential);
            }
            app.auth.recordStartupStatus(
                startup.stored_key_status,
                startup.credential_onboarding_skipped,
            );
            if (comptime @hasDecl(@TypeOf(app.auth), "refreshChatGptSourceInventory")) {
                app.auth.refreshChatGptSourceInventory(app.alloc) catch |err| {
                    debug_trace.logf("auth", "startup ChatGPT inventory refresh failed err={s}", .{@errorName(err)});
                };
                if (comptime @hasDecl(@TypeOf(app.auth), "refreshClaudeSourceInventory")) {
                    app.auth.refreshClaudeSourceInventory(app.alloc) catch |err| {
                        debug_trace.logf("auth", "startup Claude inventory refresh failed err={s}", .{@errorName(err)});
                    };
                }
            } else {
                app.auth.refreshSourceInventory(app.alloc) catch |err| {
                    debug_trace.logf("auth", "startup source inventory refresh failed err={s}", .{@errorName(err)});
                };
            }
            const startup_auth_view = app.auth.view();
            if (startup_auth_view.active_source == null and !startup_auth_view.onboarding_skipped) {
                app.auth.openOnboardingPicker(app.alloc);
            }
            if (comptime @hasField(App, "terminal_input_runtime") and @hasField(App, "terminal")) {
                // Own theme protocol bytes even under FX_THEME; probing stays gated.
                app.terminal_input_runtime.terminal_theme_monitor.start();
                if (startup.theme_monitor_enabled) {
                    app.terminal.enableThemeNotifications() catch |err| {
                        debug_trace.logf("theme", "theme_notification_enable_failed err={s}", .{@errorName(err)});
                    };
                    app.terminal.requestThemeColorScheme() catch |err| {
                        debug_trace.logf("theme", "theme_color_scheme_query_failed err={s}", .{@errorName(err)});
                    };
                }
            }
            var prompt_history_unavailable = false;
            if (comptime @hasField(App, "prompt_history")) {
                prompt_history_unavailable =
                    (try app.prompt_history.initialize(
                        app.alloc,
                        shared_io.getenv("HOME"),
                        startup.prompt_history_enabled,
                        startup.prompt_history_store_allowed,
                    )) == .unavailable;
            }
            if (comptime @hasField(App, "session") and
                @hasDecl(@TypeOf(app.session), "initializeProfileUsage"))
            {
                _ = try app.session.initializeProfileUsage(
                    app.alloc,
                    shared_io.getenv("HOME"),
                );
            }

            var selected_model = startup.takeSelectedModel();
            defer if (selected_model.len > 0) app.alloc.free(selected_model);
            if (comptime @hasField(App, "provider_selection")) {
                app.provider_selection.adoptOwned(startup.provider, &selected_model);
            } else {
                try provider_runtime.replaceModel(app, selected_model);
            }
            const active_model = provider_runtime.model(app);
            try deps.configure_session_preferences(
                app,
                startup.provider,
                startup.configured_model,
                startup.model_source,
                active_model,
                startup.effort,
                startup.fast_mode,
            );
            app.permission_engine.mode = startup.permission_mode;
            app.permission_engine.replaceRules(app.alloc, startup.takePermissionRules());
            app.agent_step_limit = startup.agent_step_limit;
            app.worker.agent_turn_settings.max_tool_result_bytes = startup.max_tool_result_bytes;
            if (comptime @hasField(App, "context_limits")) app.context_limits = startup.context_limits;
            app.worker.agent_turn_settings.first_call_tool_choice = startup.first_call_tool_choice;
            app.worker.agent_turn_settings.fast_mode = startup.fast_mode;
            app.worker.agent_turn_settings.effort = startup.effort;
            app.context_enabled = startup.context_enabled;
            app.fast_mode = startup.fast_mode;
            app.input_runtime.slash_menu_categories = startup.slash_menu_categories;
            app.auto_upgrade_enabled = startup.auto_upgrade;
            app.upgrader.configure_channel(startup.update_channel);
            app.effort = startup.effort;
            app.shell.setCommandOutputRenderPolicy(
                app_render_runtime.Runtime(App).shellStyles(),
            );
            app.permission_state.yolo_acknowledged = startup.yolo_acknowledged;
            app_permission_runtime.Runtime(App).initializeYoloWarning(app);
            app.statusline_context = startup.statusline_context;
            app.statusline_session = startup.statusline_session;
            if (comptime @hasField(App, "workspace_identity")) {
                app.workspace_identity.enabled = startup.statusline_workspace;
            }
            if (comptime @hasDecl(App, "setNotificationPreferences")) {
                app.setNotificationPreferences(
                    startup.notification_turn_end,
                    startup.notification_attention_required,
                    startup.notification_max,
                );
            }
            try deps.initialize_persistence(
                app,
                app.requested_resume != null,
            );
            const staged_resume_view = if (app.requested_resume != null)
                deps.stage_requested_resume_view(app)
            else
                app_session_runtime.ResumeViewStage.none;
            const profile_mcp = try deps.load_mcp_runtime(app.alloc, .{ .form = true, .url = true });
            if (comptime @hasDecl(App, "installInitialMcpRuntime")) {
                app.installInitialMcpRuntime(profile_mcp);
            } else {
                app.mcp_runtime = profile_mcp;
            }

            const loaded = try deps.load_skills(
                std.heap.c_allocator,
                app.workspace_root,
                deps.skill_root_policy,
            );
            skill_runtime.traceDiagnostics("interactive_startup", loaded.diagnostics);
            app.skills.replaceLoaded(std.heap.c_allocator, loaded.dir, loaded.skills, loaded.diagnostics);

            if (app.requested_resume == null) {
                const welcome_message = try deps.welcome_message(app.alloc);
                defer app.alloc.free(welcome_message);
                var welcome_preview_buf: [96]u8 = undefined;
                const welcome_preview = debug_trace.terminalPreview(welcome_preview_buf[0..], welcome_message);
                debug_trace.logf(
                    "paint",
                    "welcome_write bytes={d} reserved_rows={d} has_version={s} has_help={s} has_feedback={s} preview=\"{s}\"",
                    .{
                        welcome_message.len,
                        ui_render.welcome_message_reserved_rows,
                        if (std.mem.find(u8, welcome_message, " v") != null) "true" else "false",
                        if (std.mem.find(u8, welcome_message, "Run /help") != null) "true" else "false",
                        if (std.mem.find(u8, welcome_message, "Feedback?") != null) "true" else "false",
                        welcome_preview,
                    },
                );
                try app.writeTranscriptClassified(welcome_message, true, .welcome);
            }
            if (app.skills.diagnostics.len > 0) {
                var notice_writer: std.Io.Writer.Allocating = .init(app.alloc);
                defer notice_writer.deinit();
                skill_runtime.writeDiagnosticSummary(app.alloc, &notice_writer.writer, app.skills.diagnostics) catch return error.OutOfMemory;
                const skills_body = notice_writer.toOwnedSlice() catch return error.OutOfMemory;
                defer app.alloc.free(skills_body);
                if (comptime @hasField(App, "session") and @hasDecl(@TypeOf(app.session), "claimContextNotice")) {
                    _ = try app.session.claimContextNotice(app.alloc, skills_body);
                }

                const skills_summary = try std.fmt.allocPrint(app.alloc, "{d} discovery issue{s}; some skills may be missing", .{
                    app.skills.diagnostics.len,
                    if (app.skills.diagnostics.len == 1) "" else "s",
                });
                defer app.alloc.free(skills_summary);
                try writeCollapsedStartupNotice(app, "skills", skills_summary, skills_body);
            }
            if (comptime @hasField(App, "auth")) {
                const auth_view = app.auth.view();
                if (auth_view.active_source == null and auth_view.stored_key_status == .unavailable) {
                    debug_trace.logf("keychain", "interactive read skipped", .{});
                    try app.writeDomainNotice(.{
                        .topic = "keychain",
                        .tone = .warning,
                        .body = "fx could not access " ++ credentials.stored_key_backend_label ++ ". Continuing without an API key.",
                    }, true);
                }
            }
            var recording = try record_tape.captureStatus(app.alloc);
            defer recording.deinit(app.alloc);
            if (recording == .active) {
                const recording_body = try std.fmt.allocPrint(
                    app.alloc,
                    "visual terminal capture: {s}\nvisible terminal content, including typed prompt text, is recorded",
                    .{recording.active},
                );
                defer app.alloc.free(recording_body);
                try app.writeDomainNotice(.{
                    .topic = "recording",
                    .tone = .warning,
                    .body = recording_body,
                }, true);
            }
            {
                var detail_writer: std.Io.Writer.Allocating = .init(app.alloc);
                defer detail_writer.deinit();
                var reported: usize = 0;
                for (startup.config_diagnostics) |diagnostic| {
                    if (!diagnostic.reportAtStartup()) continue;
                    if (reported > 0) try detail_writer.writer.writeByte('\n');
                    try detail_writer.writer.print(
                        "{s}: {s}",
                        .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
                    );
                    try config_runtime.writeDiagnosticMetadata(&detail_writer.writer, diagnostic);
                    reported += 1;
                }
                if (reported > 0) {
                    const summary = try std.fmt.allocPrint(app.alloc, "{d} configuration issue{s}", .{
                        reported,
                        if (reported == 1) "" else "s",
                    });
                    defer app.alloc.free(summary);
                    try writeCollapsedStartupNotice(app, "config", summary, detail_writer.written());
                }
            }
            if (comptime @hasField(App, "prompt_history")) {
                if (prompt_history_unavailable) {
                    try app.writeDomainNotice(.{
                        .topic = "history",
                        .tone = .warning,
                        .body = "durable prompt history unavailable",
                    }, true);
                } else {
                    app_input_runtime.Runtime(App).loadAndInstallPromptHistory(
                        app,
                    ) catch |err| {
                        app.prompt_history.writes_available = false;
                        debug_trace.logf(
                            "prompt_history",
                            "startup load failed err={s}",
                            .{@errorName(err)},
                        );
                        const history_body = try std.fmt.allocPrint(
                            app.alloc,
                            "failed to load durable prompt history ({s})",
                            .{@errorName(err)},
                        );
                        defer app.alloc.free(history_body);
                        try app.writeDomainNotice(.{
                            .topic = "history",
                            .tone = .warning,
                            .body = history_body,
                        }, true);
                    };
                }
            }

            if (app.requested_resume == null) {
                try deps.begin_fresh_persisted_session(app);
                deps.enable_session_stores(app);
                app_session_runtime.Runtime(App).syncTerminalTitleWith(app, deps.terminal_title);
            }

            switch (staged_resume_view) {
                .none => {},
                .ready => |entry_id| try deps.publish_staged_resume_view(app, entry_id),
            }
            app.shell.render_requests.request(.first_frame);
        }
    };
}

const TestCapture = struct {
    alloc: Allocator,
    bootstrap_calls: usize = 0,
    footer_rows: u16 = 0,
    default_model: []const u8 = "",
    default_agent_step_limit: usize = 0,
    fx_version: []const u8 = "",
    configured_model: [64]u8 = undefined,
    configured_model_len: usize = 0,
    configured_model_source: config_runtime.ModelSource = .compiled_default,
    runtime_model: [64]u8 = undefined,
    runtime_model_len: usize = 0,
    configured_effort: types.ReasoningEffort = .auto,
    configured_fast_mode: bool = false,
    initialize_required: bool = false,
    load_skills_workspace: []const u8 = "",
    load_skills_workspace_root_count: usize = 0,
    load_skills_global_root_count: usize = 0,
    transcript_recorded: bool = false,
    begin_calls: usize = 0,
    enable_calls: usize = 0,
    title: [64]u8 = undefined,
    title_len: usize = 0,
    bootstrap_error: ?anyerror = null,
    bootstrap_init_backing_before_error: bool = false,
    load_skills_error: ?app_runtime_setup.LoadSkillsError = null,
    emit_skill_diagnostic: bool = false,
    emit_config_diagnostics: bool = false,
    startup_with_credential: bool = true,
    onboarding_skipped: bool = true,
    early_notice_palette_initialized: bool = false,
    events: [16][]const u8 = undefined,
    event_count: usize = 0,

    fn init(alloc: Allocator) TestCapture {
        return .{ .alloc = alloc };
    }

    fn titleText(self: *const TestCapture) []const u8 {
        return self.title[0..self.title_len];
    }

    fn configuredModel(self: *const TestCapture) []const u8 {
        return self.configured_model[0..self.configured_model_len];
    }

    fn runtimeModel(self: *const TestCapture) []const u8 {
        return self.runtime_model[0..self.runtime_model_len];
    }

    fn recordEvent(self: *TestCapture, event: []const u8) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    fn eventSlice(self: *const TestCapture) []const []const u8 {
        return self.events[0..self.event_count];
    }
};

var active_capture: ?*TestCapture = null;

const test_workspace_skill_roots = [_]skill_contract.RootSpec{
    .{ .source = .workspace_shared, .path = "skills" },
};

const test_global_skill_roots = [_]skill_contract.RootSpec{
    .{ .source = .global_codex, .path = ".codex/skills" },
};

const TestApp = struct {
    pub const app_version = "0.2.10-test";

    alloc: Allocator,
    terminal: shell_runtime.TerminalState = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    metrics: types.Metrics = .{},
    workspace_root: []u8 = &.{},
    auth: auth_runtime.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    permission_engine: permissions.PermissionEngine = .{},
    agent_step_limit: usize = 0,
    worker: worker_runtime.WorkerRuntime = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: ui_input.Runtime = .{},
    context_enabled: bool = true,
    fast_mode: bool = false,
    auto_upgrade_enabled: bool = true,
    upgrader: auto_upgrade.AutoUpgrade = .{},
    effort: types.ReasoningEffort = .auto,
    permission_state: app_permission_runtime.State = .{},
    statusline_context: bool = false,
    statusline_session: bool = false,
    workspace_identity: statusline_identity.Runtime = .{},
    requested_resume: ?u8 = null,
    mcp_runtime: ?*mcp_runtime.McpRuntime = null,
    skills: skill_runtime.Runtime = .{},
    transcript: std.ArrayList(u8) = .empty,
    transcript_recorded: bool = false,
    begin_fresh_called: bool = false,
    deinit_calls: usize = 0,

    fn init(alloc: Allocator) TestApp {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *TestApp) void {
        self.deinit_calls += 1;
        if (self.workspace_root.len > 0) {
            self.alloc.free(self.workspace_root);
            self.workspace_root = &.{};
        }
        self.auth.deinit(self.alloc);
        self.workspace_identity.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        if (self.mcp_runtime) |runtime| {
            runtime.deinit();
            self.alloc.destroy(runtime);
            self.mcp_runtime = null;
        }
        self.skills.deinit(std.heap.c_allocator);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
    }

    fn writeTranscript(self: *TestApp, text: []const u8, record: bool) !void {
        self.transcript_recorded = record;
        try self.transcript.appendSlice(self.alloc, text);
        active_capture.?.recordEvent("welcome");
    }

    fn writeTranscriptClassified(self: *TestApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        _ = class;
        try self.writeTranscript(text, record);
    }

    fn writeDomainNotice(self: *TestApp, semantic_notice: types.SemanticNotice, record: bool) !void {
        const styles = self.shell.retainedTranscriptStyles();
        active_capture.?.early_notice_palette_initialized =
            styles.notice_information_style.len > 0 and
            styles.system_notice_text_style.len > 0 and
            styles.reset_style.len > 0;
        const notice = if (semantic_notice.topic.len > 0)
            try std.fmt.allocPrint(self.alloc, "● {c}{s}: {s}{s}\n", .{
                std.ascii.toUpper(semantic_notice.topic[0]),
                semantic_notice.topic[1..],
                semantic_notice.body,
                if (semantic_notice.visibility == .full_only) " [full-only]" else "",
            })
        else
            try std.fmt.allocPrint(self.alloc, "● {s}{s}\n", .{
                semantic_notice.body,
                if (semantic_notice.visibility == .full_only) " [full-only]" else "",
            });
        defer self.alloc.free(notice);
        try self.writeTranscriptClassified(notice, record, .subagent_status);
    }
};

fn testDeps() BootstrapDeps(TestApp) {
    return .{
        .bootstrap_interactive_app = bootstrapInteractiveAppForTest,
        .configure_session_preferences = configureSessionPreferencesForTest,
        .initialize_persistence = initializePersistenceForTest,
        .stage_requested_resume_view = stageRequestedResumeViewForTest,
        .publish_staged_resume_view = publishStagedResumeViewForTest,
        .load_mcp_runtime = loadMcpRuntimeForTest,
        .load_skills = loadSkillsForTest,
        .skill_root_policy = .{
            .workspace_roots = &test_workspace_skill_roots,
            .managed_root_source = .global_fx,
            .global_roots = &test_global_skill_roots,
        },
        .welcome_message = welcomeMessageForTest,
        .begin_fresh_persisted_session = beginFreshPersistedSessionForTest,
        .enable_session_stores = enableSessionStoresForTest,
        .terminal_title = .{
            .set_fn = setTerminalTitleLabelForTest,
            .clear_fn = clearTerminalTitleForTest,
        },
    };
}

fn bootstrapInteractiveAppForTest(cfg: app_lifecycle.BootstrapConfig) !app_lifecycle.StartupState {
    const capture = active_capture.?;
    capture.bootstrap_calls += 1;
    capture.footer_rows = cfg.footer_rows;
    capture.default_model = cfg.default_model;
    capture.default_agent_step_limit = cfg.default_agent_step_limit;
    capture.fx_version = cfg.fx_version;
    try std.testing.expect(cfg.terminal == &active_app_for_pointer_check.?.terminal);
    active_app_for_pointer_check.?.shell.layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    if (capture.bootstrap_error) |err| {
        if (capture.bootstrap_init_backing_before_error) {
            try cfg.shell.initBacking(cfg.alloc);
        }
        return err;
    }
    return makeStartupState(capture.alloc);
}

var active_app_for_pointer_check: ?*TestApp = null;

fn makeStartupState(alloc: Allocator) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{ .agent_step_limit = 19 };
    state.max_tool_result_bytes = 131072;
    state.first_call_tool_choice = .none;
    state.workspace_root = try alloc.dupe(u8, "/workspace");
    errdefer alloc.free(state.workspace_root);
    if (active_capture.?.startup_with_credential) {
        const credential_token = try alloc.dupe(u8, "api-key");
        errdefer alloc.free(credential_token);
        const credential_team = try alloc.dupe(u8, "team_123");
        errdefer alloc.free(credential_team);
        state.credential = .{
            .token = credential_token,
            .source = .ai_gateway_api_key,
            .team_id = credential_team,
        };
    }
    state.stored_key_status = .not_found;
    state.credential_onboarding_skipped = active_capture.?.onboarding_skipped;
    state.selected_model = try alloc.dupe(u8, "model-x");
    errdefer alloc.free(state.selected_model);
    state.configured_model = try alloc.dupe(u8, "configured-model");
    errdefer alloc.free(state.configured_model);
    state.model_source = .process_override;
    state.permission_mode = .auto;
    state.context_enabled = false;
    state.fast_mode = true;
    state.auto_upgrade = false;
    state.update_channel = .dev;
    state.effort = types.ReasoningEffort.literal("high");
    state.statusline_workspace = true;
    if (active_capture.?.emit_config_diagnostics) {
        const diagnostics = try alloc.alloc(config_runtime.ConfigDiagnostic, 2);
        errdefer alloc.free(diagnostics);
        diagnostics[0] = .{ .layer = .user, .cause = .malformed_settings };
        diagnostics[1] = .{ .layer = .project, .cause = .settings_too_large };
        state.config_diagnostics = diagnostics;
    }
    return state;
}

fn initializePersistenceForTest(
    app: *TestApp,
    required: bool,
) !void {
    _ = app;
    active_capture.?.initialize_required = required;
}

fn stageRequestedResumeViewForTest(_: *TestApp) app_session_runtime.ResumeViewStage {
    active_capture.?.recordEvent("resume_view_stage");
    return .{ .ready = 1 };
}

fn publishStagedResumeViewForTest(_: *TestApp, entry_id: u32) !void {
    try std.testing.expectEqual(@as(u32, 1), entry_id);
    active_capture.?.recordEvent("resume_view_publish");
}

fn loadMcpRuntimeForTest(_: Allocator, _: @import("../mcp/elicitation.zig").Capabilities) !?*mcp_runtime.McpRuntime {
    active_capture.?.recordEvent("load_mcp");
    return null;
}

fn loadSkillsForTest(
    alloc: Allocator,
    workspace_root: []const u8,
    root_policy: skill_contract.RootPolicy,
) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills {
    active_capture.?.recordEvent("load_skills");
    active_capture.?.load_skills_workspace = workspace_root;
    active_capture.?.load_skills_workspace_root_count = root_policy.workspace_roots.len;
    active_capture.?.load_skills_global_root_count = root_policy.global_roots.len;
    if (active_capture.?.load_skills_error) |err| return err;

    const dir = try alloc.dupe(u8, "/skills");
    errdefer alloc.free(dir);
    if (!active_capture.?.emit_skill_diagnostic) {
        return .{ .dir = dir, .skills = &.{} };
    }

    const diagnostics = try alloc.alloc(skill_runtime.SkillDiagnostic, 1);
    errdefer alloc.free(diagnostics);
    diagnostics[0] = .{
        .path = try alloc.dupe(u8, "/skills/hostile\npath/body-sentinel"),
        .source = .global_fx,
        .scope = .candidate,
        .cause = .{ .invalid_metadata = .missing_name },
    };
    return .{ .dir = dir, .skills = &.{}, .diagnostics = diagnostics };
}

fn welcomeMessageForTest(alloc: Allocator) ![]u8 {
    return alloc.dupe(u8, "welcome\n");
}

fn configureSessionPreferencesForTest(
    _: *TestApp,
    _: model_provider.ProviderId,
    configured_model: []const u8,
    model_source: config_runtime.ModelSource,
    selected_model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,
) !void {
    const capture = active_capture.?;
    capture.configured_model_len = @min(
        configured_model.len,
        capture.configured_model.len,
    );
    @memcpy(
        capture.configured_model[0..capture.configured_model_len],
        configured_model[0..capture.configured_model_len],
    );
    capture.configured_model_source = model_source;
    capture.runtime_model_len = @min(
        selected_model.len,
        capture.runtime_model.len,
    );
    @memcpy(
        capture.runtime_model[0..capture.runtime_model_len],
        selected_model[0..capture.runtime_model_len],
    );
    capture.configured_effort = effort;
    capture.configured_fast_mode = fast_mode;
}

fn beginFreshPersistedSessionForTest(app: *TestApp) !void {
    active_capture.?.begin_calls += 1;
    active_capture.?.recordEvent("begin_fresh");
    app.begin_fresh_called = true;
}

fn enableSessionStoresForTest(_: *TestApp) void {
    const capture = active_capture.?;
    capture.enable_calls += 1;
    capture.recordEvent("enable_stores");
}

fn setTerminalTitleLabelForTest(_: ?*anyopaque, label: []const u8) void {
    const capture = active_capture.?;
    capture.title_len = @min(label.len, capture.title.len);
    @memcpy(capture.title[0..capture.title_len], label[0..capture.title_len]);
    capture.recordEvent("title");
}

fn clearTerminalTitleForTest(_: ?*anyopaque) void {
    const capture = active_capture.?;
    capture.title_len = 0;
    capture.recordEvent("title_clear");
}

fn runBootstrapForTest(app: *TestApp, capture: *TestCapture) !void {
    active_capture = capture;
    active_app_for_pointer_check = app;
    defer {
        active_capture = null;
        active_app_for_pointer_check = null;
    }

    try Runtime(TestApp).bootstrapWithDeps(
        app,
        4,
        "default-model",
        24,
        resizeHandlerForTest,
        false,
        testDeps(),
    );
}

fn tracePathForTest(alloc: Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    const io_mod = @import("../shared/io.zig");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn readTraceForTest(alloc: Allocator, path: []const u8) ![]u8 {
    const io_mod = @import("../shared/io.zig");
    debug_trace.shutdown();
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 8192);
}

fn resizeHandlerForTest(_: std.posix.SIG) callconv(.c) void {}

test "app_bootstrap_runtime transfers startup state and starts a fresh session" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(alloc);
    var app = TestApp.init(alloc);
    defer app.deinit();

    try runBootstrapForTest(&app, &capture);

    try std.testing.expectEqual(@as(usize, 1), capture.bootstrap_calls);
    try std.testing.expectEqual(@as(u16, 4), capture.footer_rows);
    try std.testing.expectEqualStrings("default-model", capture.default_model);
    try std.testing.expectEqual(@as(usize, 24), capture.default_agent_step_limit);
    try std.testing.expectEqualStrings(TestApp.app_version, capture.fx_version);
    try std.testing.expectEqualStrings(
        "configured-model",
        capture.configuredModel(),
    );
    try std.testing.expectEqual(
        config_runtime.ModelSource.process_override,
        capture.configured_model_source,
    );
    try std.testing.expectEqualStrings("model-x", capture.runtimeModel());
    try std.testing.expectEqual(
        types.ReasoningEffort.literal("high"),
        capture.configured_effort,
    );
    try std.testing.expect(capture.configured_fast_mode);
    try std.testing.expectEqual(
        update_target.Channel.dev,
        app.upgrader.channel(),
    );
    try std.testing.expect(!capture.initialize_required);
    try std.testing.expectEqualStrings("/workspace", capture.load_skills_workspace);
    try std.testing.expectEqual(@as(usize, 1), capture.load_skills_workspace_root_count);
    try std.testing.expectEqual(@as(usize, 1), capture.load_skills_global_root_count);
    const events = capture.eventSlice();
    try std.testing.expectEqual(@as(usize, 6), events.len);
    try std.testing.expectEqualStrings("load_mcp", events[0]);
    try std.testing.expectEqualStrings("load_skills", events[1]);
    try std.testing.expectEqualStrings("welcome", events[2]);
    try std.testing.expectEqualStrings("begin_fresh", events[3]);
    try std.testing.expectEqualStrings("enable_stores", events[4]);
    try std.testing.expectEqualStrings("title", events[5]);
    try std.testing.expectEqual(@as(usize, 1), capture.begin_calls);
    try std.testing.expectEqual(@as(usize, 1), capture.enable_calls);
    try std.testing.expectEqualStrings("workspace · model-x", capture.titleText());

    try std.testing.expectEqualStrings("/workspace", app.workspace_root);
    try std.testing.expectEqualStrings("api-key", app.auth.apiKey().?);
    try std.testing.expectEqual(types.CredentialSource.ai_gateway_api_key, app.auth.credentialSource().?);
    try std.testing.expectEqualStrings("team_123", app.auth.gatewayTeam().?);
    const auth_view = app.auth.view();
    try std.testing.expectEqual(credentials.StoredKeyReadStatus.not_found, auth_view.stored_key_status);
    try std.testing.expect(auth_view.onboarding_skipped);
    try std.testing.expectEqualStrings("model-x", app.selected_model.items);
    try std.testing.expectEqual(types.PermissionMode.auto, app.permission_engine.mode);
    try std.testing.expectEqual(@as(usize, 19), app.agent_step_limit);
    try std.testing.expectEqual(@as(usize, 131072), app.worker.agent_turn_settings.max_tool_result_bytes);
    try std.testing.expectEqual(types.ToolChoice.none, app.worker.agent_turn_settings.first_call_tool_choice);
    try std.testing.expect(app.worker.agent_turn_settings.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), app.worker.agent_turn_settings.effort);
    try std.testing.expect(!app.context_enabled);
    try std.testing.expect(app.fast_mode);
    try std.testing.expect(!app.auto_upgrade_enabled);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), app.effort);
    try std.testing.expect(app.workspace_identity.enabled);
    try std.testing.expectEqualStrings("/skills", app.skills.dir);
    try std.testing.expectEqualStrings("welcome\n", app.transcript.items);
    try std.testing.expect(app.transcript_recorded);
    try std.testing.expect(app.shell.render_requests.hasReason(.first_frame));
    try std.testing.expect(app.begin_fresh_called);
}

test "app_bootstrap_runtime opens onboarding before first frame without a credential" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(alloc);
    capture.startup_with_credential = false;
    capture.onboarding_skipped = false;
    var app = TestApp.init(alloc);
    defer app.deinit();

    try runBootstrapForTest(&app, &capture);

    const picker = app.auth.pickerView();
    try std.testing.expect(picker.active);
    try std.testing.expect(picker.include_skip);
    try std.testing.expectEqual(auth_runtime.PickerStage.root, picker.stage);
    try std.testing.expect(app.shell.render_requests.hasReason(.first_frame));
}

test "app_bootstrap_runtime stages requested sessions with the first frame pending" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(alloc);
    var app = TestApp.init(alloc);
    app.requested_resume = 1;
    defer app.deinit();

    try runBootstrapForTest(&app, &capture);

    try std.testing.expect(capture.initialize_required);
    try std.testing.expectEqual(@as(usize, 0), capture.begin_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.enable_calls);
    try std.testing.expectEqualStrings("", capture.titleText());
    try std.testing.expect(app.shell.render_requests.hasReason(.first_frame));
    try std.testing.expectEqual(@as(?u8, 1), app.requested_resume);
    try std.testing.expect(!app.begin_fresh_called);
    try std.testing.expectEqualStrings("", app.transcript.items);
    try std.testing.expect(!app.transcript_recorded);
    const events = capture.eventSlice();
    try std.testing.expectEqualStrings("resume_view_stage", events[0]);
    try std.testing.expectEqualStrings("load_mcp", events[1]);
    try std.testing.expectEqualStrings("load_skills", events[2]);
    try std.testing.expectEqualStrings("resume_view_publish", events[3]);
}

test "app_bootstrap_runtime publishes a staged resume view after startup notices" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(alloc);
    capture.emit_skill_diagnostic = true;
    var app = TestApp.init(alloc);
    app.requested_resume = 1;
    defer app.deinit();

    try runBootstrapForTest(&app, &capture);

    try std.testing.expectEqualSlices(
        []const u8,
        &.{
            "resume_view_stage",
            "load_mcp",
            "load_skills",
            "welcome",
            "welcome",
            "resume_view_publish",
        },
        capture.eventSlice(),
    );
}

test "app_bootstrap_runtime deinitializes app after bootstrap dependency failure" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(alloc);
    capture.bootstrap_error = error.LayoutFailed;
    capture.bootstrap_init_backing_before_error = true;
    var app = TestApp.init(alloc);

    try std.testing.expectError(error.LayoutFailed, runBootstrapForTest(&app, &capture));
    try std.testing.expectEqual(@as(usize, 1), app.deinit_calls);
}

test "app_bootstrap_runtime propagates skill discovery allocation failure" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(alloc);
    capture.load_skills_error = error.OutOfMemory;
    var app = TestApp.init(alloc);

    try std.testing.expectError(error.OutOfMemory, runBootstrapForTest(&app, &capture));
    try std.testing.expectEqual(@as(usize, 1), app.deinit_calls);
}

test "app_bootstrap_runtime reports a bounded skill discovery warning" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(alloc);
    capture.emit_skill_diagnostic = true;
    var app = TestApp.init(alloc);
    defer app.deinit();

    try runBootstrapForTest(&app, &capture);

    try std.testing.expectEqual(@as(usize, 1), app.skills.diagnostics.len);
    try std.testing.expect(capture.early_notice_palette_initialized);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "● Skills: 1 discovery issue; some skills may be missing (ctrl o to view)\n") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "● Skills: skill discovery warning:") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "hostile&#x0a;path/body-sentinel") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "metadata is invalid (missing_name)") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, " [full-only]\n") != null);
}

test "app_bootstrap_runtime collapses config diagnostics into one neutral summary" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(alloc);
    capture.emit_config_diagnostics = true;
    var app = TestApp.init(alloc);
    defer app.deinit();

    try runBootstrapForTest(&app, &capture);

    try std.testing.expect(std.mem.find(u8, app.transcript.items, "● Config: 2 configuration issues (ctrl o to view)\n") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "user: malformed_settings\nproject: settings_too_large [full-only]\n") != null);
}

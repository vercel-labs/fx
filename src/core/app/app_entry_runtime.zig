const std = @import("std");
const builtin = @import("builtin");
const app_process_runtime = @import("app_process_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const acp_runner = @import("../cli/acp_runner.zig");
const cli_surface = @import("../cli/cli_surface.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const context_contract = @import("../workspace/context_contract.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const update_target = @import("../upgrade/update_target.zig");
const test_builtin_gateway = if (builtin.is_test)
    @import("../../builtins/gateway.zig")
else
    struct {};
const test_builtin_commands = if (builtin.is_test)
    @import("../../builtins/commands.zig")
else
    struct {};

const Allocator = std.mem.Allocator;

pub const Config = struct {
    version: []const u8 = "",
    revision: []const u8 = "",
    build_channel: update_target.Channel = .stable,
    command_catalog: command_specs.TopLevelRegistry,
    default_model: []const u8,
    default_agent_step_limit: usize,
    models_path: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_provider: gateway_provider.Provider,
    codex_agent_stream: ?agent_stream_provider.Provider = null,
    codex_cli_model_catalog: ?gateway_provider.CliModelCatalogProvider = null,
    codex_model_catalog: ?model_catalog.Provider = null,
    grok_agent_stream: ?agent_stream_provider.Provider = null,
    grok_cli_model_catalog: ?gateway_provider.CliModelCatalogProvider = null,
    grok_model_catalog: ?model_catalog.Provider = null,
    claude_agent_stream: ?agent_stream_provider.Provider = null,
    claude_cli_model_catalog: ?gateway_provider.CliModelCatalogProvider = null,
    claude_model_catalog: ?model_catalog.Provider = null,
    background_process_provider: background_process_provider.Provider =
        background_process_provider.unavailable_provider,
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
    load_mcp_runtime: mcp_runtime.LoadRuntimeFn,
    acp_runner: acp_runner.Runner,
    permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    codex_permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    grok_permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
    claude_permission_reviewer_provider: ?permission_auto_classifier.Provider = null,
};

pub fn run(comptime App: type, alloc: Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const outcome = try runWithDeps(App, alloc, args, cfg, .{});
    switch (outcome) {
        .returned => return,
        .exit => |code| std.process.exit(code),
    }
}

pub const RunOutcome = union(enum) {
    returned,
    exit: u8,
};

pub const BeforeInteractiveResult = union(enum) {
    interactive: cli_surface.InteractiveLaunch,
    returned,
    exit: u8,
};

const RunIfRequestedFn = *const fn (?*anyopaque, Allocator, []const [:0]const u8, cli_surface.Config) anyerror!cli_surface.RunResult;
const GetenvFn = *const fn (?*anyopaque, []const u8) ?[]const u8;
const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const FormatUnexpectedErrorFn = *const fn ([]u8, anyerror) anyerror![]const u8;
const StartWorkerThreadFn = *const fn (?*anyopaque, *anyopaque) anyerror!void;
const ReplaceProcessFn = *const fn (
    ?*anyopaque,
    std.Io,
    std.process.ReplaceOptions,
) std.process.ReplaceError;
const RunDeps = struct {
    cli_ctx: ?*anyopaque = null,
    run_if_requested: RunIfRequestedFn = if (host_target.is_wasm)
        unavailableCliDispatch
    else
        runIfRequestedDefault,
    env_ctx: ?*anyopaque = null,
    getenv: GetenvFn = getenvDefault,
    stderr_ctx: ?*anyopaque = null,
    write_stderr: WriteFn = writeRealStderr,
    stdout_ctx: ?*anyopaque = null,
    write_stdout: WriteFn = writeRealStdout,
    format_unexpected_error: FormatUnexpectedErrorFn = formatUnexpectedError,
    worker_ctx: ?*anyopaque = null,
    start_worker_thread: ?StartWorkerThreadFn = null,
    replace_ctx: ?*anyopaque = null,
    replace_process: ReplaceProcessFn = replaceProcessDefault,
};

fn runWithDeps(comptime App: type, alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !RunOutcome {
    var launch: cli_surface.InteractiveLaunch = .{};
    defer launch.deinit(alloc);

    const before = try runBeforeInteractiveWithDeps(alloc, args, cfg, deps);
    switch (before) {
        .interactive => |value| launch = value,
        .returned => return .returned,
        .exit => |code| return .{ .exit = code },
    }

    return runInteractiveWithDeps(App, false, alloc, &launch, deps);
}

pub fn runBeforeInteractive(alloc: Allocator, args: []const [:0]const u8, cfg: Config) !BeforeInteractiveResult {
    _ = cli_surface.recordRequested(args) catch {
        writeStderr(.{}, cli_surface.record_modifier_usage);
        return .{ .exit = 1 };
    };
    const run_result = cli_surface.runIfRequested(alloc, args, cliSurfaceConfig(cfg)) catch |err| switch (err) {
        error.UnknownCliCommand => return .{ .exit = 1 },
        else => {
            tryWriteErrorMessage(.{}, err);
            return .{ .exit = 1 };
        },
    };

    return beforeInteractiveResultFromRunResult(alloc, run_result, benchEnabled());
}

pub fn runNoConfigBeforeInteractive(
    alloc: Allocator,
    args: []const [:0]const u8,
    version: []const u8,
    command_catalog: command_specs.TopLevelRegistry,
) !?RunOutcome {
    return if (try cli_surface.runNoConfigIfRequested(alloc, args, version, command_catalog)) .returned else null;
}

fn runBeforeInteractiveWithDeps(alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !BeforeInteractiveResult {
    _ = cli_surface.recordRequested(args) catch {
        writeStderr(deps, cli_surface.record_modifier_usage);
        return .{ .exit = 1 };
    };
    const run_result = deps.run_if_requested(deps.cli_ctx, alloc, args, cliSurfaceConfig(cfg)) catch |err| switch (err) {
        error.UnknownCliCommand => return .{ .exit = 1 },
        else => {
            tryWriteErrorMessage(deps, err);
            return .{ .exit = 1 };
        },
    };

    return beforeInteractiveResultFromRunResult(alloc, run_result, deps.getenv(deps.env_ctx, "FX_BENCH") != null);
}

fn beforeInteractiveResultFromRunResult(alloc: Allocator, run_result: cli_surface.RunResult, bench: bool) BeforeInteractiveResult {
    switch (run_result) {
        .interactive => |launch| {
            if (bench) {
                var mutable_launch = launch;
                mutable_launch.deinit(alloc);
                return .returned;
            }
            return .{ .interactive = launch };
        },
        .handled_success => return .returned,
        .handled_failure => return .{ .exit = 1 },
        .handled_exit => |code| return if (code == 0) .returned else .{ .exit = code },
    }
}

fn benchEnabled() bool {
    if (comptime builtin.link_libc) {
        return std.c.getenv("FX_BENCH") != null;
    }
    return io_mod.getenv("FX_BENCH") != null;
}

pub fn runInteractive(comptime App: type, alloc: Allocator, launch: *cli_surface.InteractiveLaunch) !RunOutcome {
    return runInteractiveWithDeps(App, false, alloc, launch, .{});
}

/// Runs the interactive product without native CLI dispatch, process replacement,
/// or a worker thread. Single-threaded hosts must arrange cooperative prompt work.
pub fn runInteractiveCooperative(comptime App: type, alloc: Allocator, launch: *cli_surface.InteractiveLaunch) !RunOutcome {
    return runInteractiveWithDeps(App, true, alloc, launch, .{});
}

fn unavailableCliDispatch(_: ?*anyopaque, _: Allocator, _: []const [:0]const u8, _: cli_surface.Config) anyerror!cli_surface.RunResult {
    return error.UnknownCliCommand;
}

fn runInteractiveWithDeps(comptime App: type, comptime cooperative: bool, alloc: Allocator, launch: *cli_surface.InteractiveLaunch, deps: RunDeps) !RunOutcome {
    const resume_requested = launch.requested_resume != null;
    var app = App.init(alloc, launch) catch |err| {
        switch (err) {
            error.NotATerminal => {
                writeStderr(deps, "fx requires an interactive terminal (TTY).\n");
                return .{ .exit = 1 };
            },
            error.TerminalTooSmall => {
                writeStderr(deps, "fx needs at least 5 terminal rows.\n");
                return .returned;
            },
            error.RecordingStartFailed => {
                writeStderr(deps, "fx: unable to start terminal recording.\n");
                return .{ .exit = 1 };
            },
            error.NoSavedSessions => {
                writeStderr(deps, "fx: no saved sessions for this workspace.\n");
                return .{ .exit = 1 };
            },
            error.SessionNotFound => {
                writeStderr(deps, "fx: saved session not found.\n");
                return .{ .exit = 1 };
            },
            error.SessionBusy => {
                writeStderr(deps, "fx: another Fx process may be using this session (running or suspended); check other terminals or run jobs, then use fg or quit that process\n");
                return .{ .exit = 1 };
            },
            error.SessionLockUnsupported => {
                writeStderr(deps, "fx: the filesystem cannot provide the required session lock\n");
                return .{ .exit = 1 };
            },
            error.SessionAuthorityBoundaryUnavailable,
            error.SessionCommitBoundaryUnavailable,
            => {
                writeStderr(deps, "fx: this session is being updated; wait a moment and retry\n");
                return .{ .exit = 1 };
            },
            error.OneOffSessionNotResumable => {
                writeStderr(deps, "fx: one-off child sessions cannot accept additional prompts; create a persistent child to continue the conversation\n");
                return .{ .exit = 1 };
            },
            error.InvalidSessionFormat => {
                writeStderr(deps, "fx: saved session is unreadable. Run `fx doctor`; if it is recoverable, use `fx session recover <id>`.\n");
                return .{ .exit = 1 };
            },
            error.UnsupportedSessionSchema => {
                writeStderr(deps, "fx: saved session uses an unsupported version and cannot be resumed by this fx build.\n");
                return .{ .exit = 1 };
            },
            else => {
                reportUnexpectedInteractiveError(deps, err);
                return err;
            },
        }
    };
    if (comptime !cooperative) {
        if (@hasDecl(App, "startMcpDiscovery")) app.startMcpDiscovery();
        if (@hasDecl(App, "rebindAfterInit")) app.rebindAfterInit();
    }
    var app_needs_deinit = true;
    defer if (app_needs_deinit) app.deinit();
    if (comptime !cooperative and @hasField(App, "session") and
        @hasDecl(@TypeOf(app.session), "attachProfileUsagePublisher"))
    {
        app.session.attachProfileUsagePublisher(app.alloc);
    }
    if (comptime !cooperative) {
        if (resume_requested) app.startResumedSessionReconciliation();
        if (@hasDecl(App, "configureNotifications")) try app.configureNotifications();
        if (@hasDecl(App, "playStartupSound")) app.playStartupSound();
        if (@hasDecl(App, "startAutoUpgrade")) app.startAutoUpgrade();
        if (@hasDecl(App, "startFileIndex")) app.startFileIndex();
        startWorkerThread(App, &app, deps) catch |err| {
            app.releaseTerminal();
            reportUnexpectedInteractiveError(deps, err);
            return err;
        };
        app.startModelCacheWarmup();
    }

    app.run() catch |err| {
        app.releaseTerminal();
        if (err == error.TerminalInputClosed) return .returned;
        reportUnexpectedInteractiveError(deps, err);
        return err;
    };
    const relaunch_request: ?auto_upgrade.RelaunchRequest = if (comptime cooperative)
        null
    else if (comptime @hasDecl(App, "takeUpgradeRelaunchRequest"))
        app.takeUpgradeRelaunchRequest()
    else
        null;
    const resume_handoff_columns: u16 = if (comptime cooperative)
        0
    else if (comptime @hasDecl(App, "resumeHandoffColumns"))
        app.resumeHandoffColumns()
    else
        0;
    app_needs_deinit = false;
    const handoff_value = if (comptime cooperative) blk: {
        app.deinit();
        break :blk null;
    } else app.deinitWithResumeHandoff();
    if (relaunch_request) |request| {
        if (handoff_value) |value| {
            var handoff = value;
            defer handoff.deinit(alloc);
            var argv = [_][]const u8{
                request.executablePath(),
                "resume",
                handoff.session_id,
                cli_surface.upgrade_relaunch_arg,
            };
            const replace_err = deps.replace_process(
                deps.replace_ctx,
                io_mod.getIo(),
                .{ .argv = &argv },
            );
            writeUpgradeRelaunchFailure(deps, replace_err, handoff.session_id);
        } else {
            writeStderr(
                deps,
                "fx: upgrade installed, but no validated resume handoff was available. Your conversation remains on disk; run `fx doctor`.\n",
            );
        }
        return .{ .exit = 1 };
    }
    if (handoff_value) |value| {
        var handoff = value;
        defer handoff.deinit(alloc);
        var message_buffer: [512]u8 = undefined;
        const message = (if (comptime @hasDecl(App, "formatResumeHandoff"))
            App.formatResumeHandoff(
                &message_buffer,
                handoff.session_id,
                resume_handoff_columns,
            )
        else
            formatResumeHandoff(&message_buffer, handoff.session_id)) catch return .returned;
        deps.write_stdout(deps.stdout_ctx, message) catch {};
    }
    return .returned;
}

fn replaceProcessDefault(
    _: ?*anyopaque,
    zio: std.Io,
    options: std.process.ReplaceOptions,
) std.process.ReplaceError {
    return std.process.replace(zio, options);
}

fn writeUpgradeRelaunchFailure(
    deps: RunDeps,
    err: std.process.ReplaceError,
    session_id: []const u8,
) void {
    var buffer: [768]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "fx: upgrade installed, but relaunch failed: {s}\nContinue session with: fx --resume {s}\n",
        .{ @errorName(err), session_id },
    ) catch "fx: upgrade installed, but relaunch failed; run `fx doctor`.\n";
    writeStderr(deps, message);
}

fn cliSurfaceConfig(cfg: Config) cli_surface.Config {
    return .{
        .version = cfg.version,
        .revision = cfg.revision,
        .build_channel = cfg.build_channel,
        .command_catalog = cfg.command_catalog,
        .default_model = cfg.default_model,
        .default_agent_step_limit = cfg.default_agent_step_limit,
        .models_path = cfg.models_path,
        .gateway_retry_count = cfg.gateway_retry_count,
        .gateway_chat_url = cfg.gateway_chat_url,
        .gateway_provider = cfg.gateway_provider,
        .codex_agent_stream = cfg.codex_agent_stream,
        .codex_cli_model_catalog = cfg.codex_cli_model_catalog,
        .codex_model_catalog = cfg.codex_model_catalog,
        .grok_agent_stream = cfg.grok_agent_stream,
        .grok_cli_model_catalog = cfg.grok_cli_model_catalog,
        .grok_model_catalog = cfg.grok_model_catalog,
        .claude_agent_stream = cfg.claude_agent_stream,
        .claude_cli_model_catalog = cfg.claude_cli_model_catalog,
        .claude_model_catalog = cfg.claude_model_catalog,
        .background_process_provider = cfg.background_process_provider,
        .url_opener = cfg.url_opener,
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
        .context_registry = cfg.context_registry,
        .mode_registry = cfg.mode_registry,
        .tool_set = cfg.tool_set,
        .inspect_mcp_profile_config = cfg.inspect_mcp_profile_config,
        .load_mcp_runtime = cfg.load_mcp_runtime,
        .acp_runner = cfg.acp_runner,
        .permission_reviewer_provider = cfg.permission_reviewer_provider,
        .codex_permission_reviewer_provider = cfg.codex_permission_reviewer_provider,
        .grok_permission_reviewer_provider = cfg.grok_permission_reviewer_provider,
        .claude_permission_reviewer_provider = cfg.claude_permission_reviewer_provider,
    };
}

fn startWorkerThread(comptime App: type, app: *App, deps: RunDeps) !void {
    if (!@hasField(App, "worker_thread")) {
        const start = deps.start_worker_thread orelse return error.MissingWorkerThreadDependency;
        return start(deps.worker_ctx, @ptrCast(app));
    }
    if (deps.start_worker_thread) |start| {
        return start(deps.worker_ctx, @ptrCast(app));
    }
    try app_process_runtime.Runtime(App).startWorkerThread(app);
}

fn runIfRequestedDefault(_: ?*anyopaque, alloc: Allocator, args: []const [:0]const u8, cfg: cli_surface.Config) !cli_surface.RunResult {
    return cli_surface.runIfRequested(alloc, args, cfg);
}

fn getenvDefault(_: ?*anyopaque, key: []const u8) ?[]const u8 {
    return io_mod.getenv(key);
}

fn writeRealStderr(_: ?*anyopaque, text: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

fn writeRealStdout(_: ?*anyopaque, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn formatResumeHandoff(buffer: []u8, session_id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "Continue session with: fx --resume {s}\n",
        .{session_id},
    );
}

fn formatUnexpectedError(buffer: []u8, err: anyerror) ![]const u8 {
    return std.fmt.bufPrint(buffer, "fx: {s}\n", .{@errorName(err)});
}

fn reportUnexpectedInteractiveError(deps: RunDeps, err: anyerror) void {
    var buffer: [256]u8 = undefined;
    const message = deps.format_unexpected_error(&buffer, err) catch return;
    deps.write_stderr(deps.stderr_ctx, message) catch {};
}

fn writeStderr(deps: RunDeps, text: []const u8) void {
    deps.write_stderr(deps.stderr_ctx, text) catch {};
}

fn tryWriteErrorMessage(deps: RunDeps, err: anyerror) void {
    writeStderr(deps, "fx: ");
    writeStderr(deps, @errorName(err));
    writeStderr(deps, "\n");
}

fn gatherNoopContextForTest(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopStaticContextForTest(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(@import("../shared/types.zig").ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContextForTest(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(@import("../shared/types.zig").ChatMessage)) context_contract.ProviderError!void {}

const test_entry_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.entry_context",
    .gather_project_context_fn = gatherNoopContextForTest,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContextForTest,
    .append_transient_fn = appendNoopTransientContextForTest,
} };

fn noMcpRuntimeForTest(_: Allocator, _: @import("../mcp/elicitation.zig").Capabilities) !?*mcp_runtime.McpRuntime {
    return null;
}

fn noMcpConfigInspectionForTest(
    _: Allocator,
) error{OutOfMemory}!mcp_contract.ProfileConfigDiagnostic {
    return .clear;
}

fn unexpectedAcpRunForTest(_: ?*anyopaque, _: Allocator, _: acp_runner.Config) anyerror!void {
    return error.TestUnexpectedAcpRun;
}

fn testConfig() Config {
    return .{
        .version = "0.2.10",
        .command_catalog = test_builtin_commands.top_level_registry,
        .default_model = "model",
        .default_agent_step_limit = 12,
        .models_path = "/models",
        .gateway_retry_count = 2,
        .gateway_chat_url = "https://gateway/chat",
        .gateway_provider = test_builtin_gateway.provider,
        .url_opener = host.unavailable_url_opener,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "system" },
        .skill_root_policy = .{ .managed_root_source = .global_fx },
        .ignored_list_entries = &.{ ".git", "zig-out" },
        .max_list_entries = 100,
        .max_read_file_bytes = 1024,
        .max_read_file_lines = 10,
        .max_read_file_line_len = 80,
        .max_command_output_bytes = 2048,
        .max_tool_result_bytes = 2048,
        .max_history_turns = 32,
        .context_registry = test_entry_context_registry,
        .mode_registry = .{ .default_mode_id = "entry" },
        .inspect_mcp_profile_config = noMcpConfigInspectionForTest,
        .load_mcp_runtime = noMcpRuntimeForTest,
        .acp_runner = .{ .run_fn = unexpectedAcpRunForTest },
        .tool_set = .{
            .registry = .{ .tools = &.{} },
            .order = &.{"entry_test_tool"},
            .read_only_tool_names = &.{},
        },
    };
}

var test_events: [16][]const u8 = undefined;
var test_event_count: usize = 0;
var test_init_event_buf: [128]u8 = undefined;
var active_capture: ?*TestCapture = null;

fn resetTestEvents() void {
    test_event_count = 0;
}

fn appendTestEvent(text: []const u8) void {
    test_events[test_event_count] = text;
    test_event_count += 1;
}

fn appendInitEvent(launch: *const cli_surface.InteractiveLaunch) void {
    if (launch.requested_resume) |target| {
        switch (target) {
            .pick => appendTestEvent("init:pick"),
            .last => appendTestEvent("init:last"),
            .id => |id| appendTestEvent(std.fmt.bufPrint(&test_init_event_buf, "init:{s}", .{id}) catch "init:<invalid>"),
        }
    } else {
        appendTestEvent("init:none");
    }
}

fn expectEvents(expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, test_event_count);
    for (expected, test_events[0..test_event_count]) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

const TestCapture = struct {
    run_result: cli_surface.RunResult,
    cli_calls: usize = 0,
    seen_config: ?cli_surface.Config = null,
    stderr: std.Io.Writer.Allocating,
    stdout: std.Io.Writer.Allocating,
    bench_value: ?[]const u8 = null,
    init_error: ?anyerror = null,
    worker_error: ?anyerror = null,
    run_error: ?anyerror = null,
    stderr_error: ?anyerror = null,
    stdout_error: ?anyerror = null,
    stderr_calls: usize = 0,
    stdout_calls: usize = 0,
    record_stderr_event: bool = false,
    record_stdout_event: bool = false,
    resume_handoff_id: ?[]const u8 = null,
    upgrade_relaunch_path: ?[]const u8 = null,
    replace_error: std.process.ReplaceError = error.InvalidExe,
    replace_calls: usize = 0,
    replace_arg_count: usize = 0,
    replace_arg_bufs: [4][128]u8 = undefined,
    replace_arg_lens: [4]usize = .{ 0, 0, 0, 0 },
    fail_unexpected_format: bool = false,

    fn init(run_result: cli_surface.RunResult) TestCapture {
        resetTestEvents();
        return .{
            .run_result = run_result,
            .stderr = .init(std.testing.allocator),
            .stdout = .init(std.testing.allocator),
        };
    }

    fn deinit(self: *TestCapture) void {
        active_capture = null;
        self.stderr.deinit();
        self.stdout.deinit();
    }

    fn deps(self: *TestCapture) RunDeps {
        active_capture = self;
        return .{
            .cli_ctx = self,
            .run_if_requested = runIfRequestedForTest,
            .env_ctx = self,
            .getenv = getenvForTest,
            .stderr_ctx = self,
            .write_stderr = writeStderrForTest,
            .stdout_ctx = self,
            .write_stdout = writeStdoutForTest,
            .format_unexpected_error = if (self.fail_unexpected_format)
                failUnexpectedErrorFormatForTest
            else
                formatUnexpectedError,
            .worker_ctx = self,
            .start_worker_thread = startWorkerThreadForTest,
            .replace_ctx = self,
            .replace_process = replaceProcessForTest,
        };
    }

    fn replaceArg(self: *const TestCapture, index: usize) []const u8 {
        return self.replace_arg_bufs[index][0..self.replace_arg_lens[index]];
    }
};

fn runIfRequestedForTest(ctx: ?*anyopaque, _: Allocator, _: []const [:0]const u8, cfg: cli_surface.Config) !cli_surface.RunResult {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    capture.cli_calls += 1;
    capture.seen_config = cfg;
    return capture.run_result;
}

fn getenvForTest(ctx: ?*anyopaque, key: []const u8) ?[]const u8 {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, key, "FX_BENCH")) return capture.bench_value;
    return null;
}

fn writeStderrForTest(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    capture.stderr_calls += 1;
    if (capture.record_stderr_event) appendTestEvent("stderr-attempt");
    if (capture.stderr_error) |err| return err;
    try capture.stderr.writer.writeAll(text);
}

fn writeStdoutForTest(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    capture.stdout_calls += 1;
    if (capture.record_stdout_event) appendTestEvent("stdout-attempt");
    if (capture.stdout_error) |err| return err;
    try capture.stdout.writer.writeAll(text);
}

fn replaceProcessForTest(
    ctx: ?*anyopaque,
    _: std.Io,
    options: std.process.ReplaceOptions,
) std.process.ReplaceError {
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    capture.replace_calls += 1;
    capture.replace_arg_count = options.argv.len;
    const count = @min(options.argv.len, capture.replace_arg_bufs.len);
    for (options.argv[0..count], 0..) |arg, index| {
        if (arg.len > capture.replace_arg_bufs[index].len) {
            return error.SystemResources;
        }
        @memcpy(capture.replace_arg_bufs[index][0..arg.len], arg);
        capture.replace_arg_lens[index] = arg.len;
    }
    return capture.replace_error;
}

fn failUnexpectedErrorFormatForTest(_: []u8, _: anyerror) ![]const u8 {
    return error.TestUnexpectedErrorFormatFailed;
}

fn startWorkerThreadForTest(ctx: ?*anyopaque, _: *anyopaque) !void {
    appendTestEvent("worker-thread");
    const capture: *TestCapture = @ptrCast(@alignCast(ctx.?));
    if (capture.worker_error) |err| return err;
}

const TestApp = struct {
    requested_resume: ?cli_surface.ResumeTarget = null,
    terminal_released: bool = false,

    fn init(_: Allocator, launch: *cli_surface.InteractiveLaunch) !TestApp {
        appendInitEvent(launch);
        if (active_capture.?.init_error) |err| return err;

        var app = TestApp{};
        if (launch.requested_resume) |target| {
            app.requested_resume = target;
            launch.requested_resume = null;
        }
        return app;
    }

    fn deinit(self: *TestApp) void {
        self.releaseTerminal();
        if (self.requested_resume) |*target| target.deinit(std.testing.allocator);
        appendTestEvent("deinit");
        self.* = undefined;
    }

    fn deinitWithResumeHandoff(self: *TestApp) ?app_session_runtime.ResumeHandoff {
        const handoff: ?app_session_runtime.ResumeHandoff = if (active_capture.?.resume_handoff_id) |id| blk: {
            const session_id = std.testing.allocator.dupe(u8, id) catch {
                self.deinit();
                return null;
            };
            break :blk .{ .session_id = session_id };
        } else null;
        self.deinit();
        return handoff;
    }

    fn takeUpgradeRelaunchRequest(_: *TestApp) ?auto_upgrade.RelaunchRequest {
        const path = active_capture.?.upgrade_relaunch_path orelse return null;
        var request = auto_upgrade.RelaunchRequest{
            .executable_path_len = path.len,
        };
        @memcpy(request.executable_path_buf[0..path.len], path);
        return request;
    }

    fn releaseTerminal(self: *TestApp) void {
        if (self.terminal_released) return;
        self.terminal_released = true;
        appendTestEvent("terminal-release");
    }

    fn startResumedSessionReconciliation(_: *TestApp) void {
        appendTestEvent("resume-reconciliation");
    }

    fn startAutoUpgrade(_: *TestApp) void {
        appendTestEvent("auto-upgrade");
    }

    fn startFileIndex(_: *TestApp) void {
        appendTestEvent("file-index");
    }

    fn startMcpDiscovery(_: *TestApp) void {
        appendTestEvent("mcp-discovery");
    }

    fn rebindAfterInit(_: *TestApp) void {
        appendTestEvent("rebind-after-init");
    }

    fn startModelCacheWarmup(_: *TestApp) void {
        appendTestEvent("model-cache");
    }

    fn run(_: *TestApp) !void {
        appendTestEvent("run");
        if (active_capture.?.run_error) |err| return err;
    }
};

test "app entry returns after handled CLI success without initializing app" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.handled_success);
    defer capture.deinit();
    const skill_roots = [_]skill_contract.RootSpec{
        .{ .source = .workspace_shared, .path = "skills" },
    };
    var cfg = testConfig();
    var url_opener_context: u8 = 0;
    var secret_store_context: u8 = 0;
    cfg.url_opener.context = &url_opener_context;
    cfg.secret_store.context = &secret_store_context;
    cfg.skill_root_policy.workspace_roots = &skill_roots;
    const outcome = try runWithDeps(TestApp, alloc, &.{@constCast("help")}, cfg, capture.deps());

    try std.testing.expectEqual(RunOutcome.returned, outcome);
    try std.testing.expectEqual(@as(usize, 1), capture.cli_calls);
    try std.testing.expectEqualStrings("0.2.10", capture.seen_config.?.version);
    try std.testing.expectEqualStrings("help", capture.seen_config.?.command_catalog.specs[0].token);
    try std.testing.expectEqualStrings("test.entry_context", capture.seen_config.?.context_registry.defaultProvider().id);
    try std.testing.expectEqualStrings("entry", capture.seen_config.?.mode_registry.default_mode_id);
    try std.testing.expectEqualStrings("entry_test_tool", capture.seen_config.?.tool_set.order[0]);
    try std.testing.expectEqualStrings("skills", capture.seen_config.?.skill_root_policy.workspace_roots[0].path);
    try std.testing.expect(capture.seen_config.?.gateway_provider.chat_url.resolve_fn == test_builtin_gateway.chat_url_provider.resolve_fn);
    try std.testing.expect(capture.seen_config.?.gateway_provider.cli_model_catalog.fetch_fn == test_builtin_gateway.cli_model_catalog_provider.fetch_fn);
    try std.testing.expect(capture.seen_config.?.gateway_provider.web_search.execute_fn == test_builtin_gateway.default_web_search_provider.execute_fn);
    try std.testing.expect(capture.seen_config.?.gateway_provider.model_catalog.fetch_fn == test_builtin_gateway.model_catalog_provider.fetch_fn);
    try std.testing.expect(
        capture.seen_config.?.background_process_provider.spawn_prepared_fn ==
            cfg.background_process_provider.spawn_prepared_fn,
    );
    try std.testing.expect(capture.seen_config.?.url_opener.context == cfg.url_opener.context);
    try std.testing.expect(capture.seen_config.?.url_opener.open_fn == cfg.url_opener.open_fn);
    try std.testing.expect(capture.seen_config.?.secret_store.context == cfg.secret_store.context);
    try std.testing.expect(capture.seen_config.?.secret_store.load_fn == cfg.secret_store.load_fn);
    try std.testing.expect(capture.seen_config.?.inspect_mcp_profile_config == noMcpConfigInspectionForTest);
    try std.testing.expect(capture.seen_config.?.load_mcp_runtime == noMcpRuntimeForTest);
    try std.testing.expectEqual(@as(usize, 0), test_event_count);
}

test "app entry exits after handled CLI failure" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.handled_failure);
    defer capture.deinit();
    const outcome = try runWithDeps(TestApp, alloc, &.{@constCast("models")}, testConfig(), capture.deps());

    try std.testing.expectEqual(@as(u8, 1), outcome.exit);
    try std.testing.expectEqual(@as(usize, 0), test_event_count);
}

test "app entry maps handled CLI exit without initializing app" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .handled_exit = 42 });
    defer capture.deinit();
    const outcome = try runWithDeps(TestApp, alloc, &.{ @constCast("replay"), @constCast("tape") }, testConfig(), capture.deps());

    try std.testing.expectEqual(@as(u8, 42), outcome.exit);
    try std.testing.expectEqual(@as(usize, 1), capture.cli_calls);
    try std.testing.expectEqual(@as(usize, 0), test_event_count);
}

test "app entry returns after handled zero exit without initializing app" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .handled_exit = 0 });
    defer capture.deinit();
    const outcome = try runWithDeps(TestApp, alloc, &.{ @constCast("replay"), @constCast("tape") }, testConfig(), capture.deps());

    try std.testing.expectEqual(RunOutcome.returned, outcome);
    try std.testing.expectEqual(@as(usize, 1), capture.cli_calls);
    try std.testing.expectEqual(@as(usize, 0), test_event_count);
}

test "app entry honors FX_BENCH before app initialization" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.bench_value = "1";
    const outcome = try runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps());

    try std.testing.expectEqual(RunOutcome.returned, outcome);
    try std.testing.expectEqual(@as(usize, 1), capture.cli_calls);
    try std.testing.expectEqual(@as(usize, 0), test_event_count);
}

test "app entry runs interactive startup callbacks in active order" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    const outcome = try runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps());

    try std.testing.expectEqual(RunOutcome.returned, outcome);
    try std.testing.expectEqual(@as(usize, 0), capture.stdout_calls);
    try expectEvents(&.{ "init:none", "mcp-discovery", "rebind-after-init", "auto-upgrade", "file-index", "worker-thread", "model-cache", "run", "terminal-release", "deinit" });
}

test "app entry writes exact resume handoff after interactive teardown" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.resume_handoff_id = "session-123";
    capture.record_stdout_event = true;

    const outcome = try runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps());

    try std.testing.expectEqual(RunOutcome.returned, outcome);
    try std.testing.expectEqualStrings(
        "Continue session with: fx --resume session-123\n",
        capture.stdout.written(),
    );
    try std.testing.expectEqual(@as(usize, 1), capture.stdout_calls);
    try std.testing.expectEqualStrings("", capture.stderr.written());
    try expectEvents(&.{
        "init:none",
        "mcp-discovery",
        "rebind-after-init",
        "auto-upgrade",
        "file-index",
        "worker-thread",
        "model-cache",
        "run",
        "terminal-release",
        "deinit",
        "stdout-attempt",
    });
}

test "app entry relaunches only after teardown with the validated handoff" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.resume_handoff_id = "session-123";
    capture.upgrade_relaunch_path = "/tmp/fx-upgraded";
    capture.record_stderr_event = true;

    const outcome = try runWithDeps(
        TestApp,
        alloc,
        &.{},
        testConfig(),
        capture.deps(),
    );

    try std.testing.expectEqual(@as(u8, 1), outcome.exit);
    try std.testing.expectEqual(@as(usize, 1), capture.replace_calls);
    try std.testing.expectEqual(@as(usize, 4), capture.replace_arg_count);
    try std.testing.expectEqualStrings("/tmp/fx-upgraded", capture.replaceArg(0));
    try std.testing.expectEqualStrings("resume", capture.replaceArg(1));
    try std.testing.expectEqualStrings("session-123", capture.replaceArg(2));
    try std.testing.expectEqualStrings("--upgrade-relaunch", capture.replaceArg(3));
    try std.testing.expect(std.mem.find(
        u8,
        capture.stderr.written(),
        "relaunch failed: InvalidExe",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        capture.stderr.written(),
        "fx --resume session-123",
    ) != null);
    try expectEvents(&.{
        "init:none",
        "mcp-discovery",
        "rebind-after-init",
        "auto-upgrade",
        "file-index",
        "worker-thread",
        "model-cache",
        "run",
        "terminal-release",
        "deinit",
        "stderr-attempt",
    });
}

test "app entry never relaunches without a validated handoff" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.upgrade_relaunch_path = "/tmp/fx-upgraded";

    const outcome = try runWithDeps(
        TestApp,
        alloc,
        &.{},
        testConfig(),
        capture.deps(),
    );

    try std.testing.expectEqual(@as(u8, 1), outcome.exit);
    try std.testing.expectEqual(@as(usize, 0), capture.replace_calls);
    try std.testing.expect(std.mem.find(
        u8,
        capture.stderr.written(),
        "no validated resume handoff",
    ) != null);
}

test "app entry ignores resume handoff stdout failures" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.resume_handoff_id = "session-123";
    capture.stdout_error = error.TestStdoutWriteFailed;

    const outcome = try runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps());

    try std.testing.expectEqual(RunOutcome.returned, outcome);
    try std.testing.expectEqual(@as(usize, 1), capture.stdout_calls);
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

fn runWithOuterCleanup(comptime App: type, alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !RunOutcome {
    defer appendTestEvent("outer-defer");
    return runWithDeps(App, alloc, args, cfg, deps);
}

test "app entry reports unexpected init errors once and preserves identity" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.init_error = error.TestInitFailed;
    capture.record_stderr_event = true;

    try std.testing.expectError(error.TestInitFailed, runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps()));
    try std.testing.expectEqualStrings("fx: TestInitFailed\n", capture.stderr.written());
    try std.testing.expectEqual(@as(usize, 1), capture.stderr_calls);
    try expectEvents(&.{ "init:none", "stderr-attempt" });
}

test "app entry releases terminal before reporting worker start errors" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.worker_error = error.TestWorkerStartFailed;
    capture.record_stderr_event = true;

    try std.testing.expectError(error.TestWorkerStartFailed, runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps()));
    try std.testing.expectEqualStrings("fx: TestWorkerStartFailed\n", capture.stderr.written());
    try std.testing.expectEqual(@as(usize, 1), capture.stderr_calls);
    try expectEvents(&.{ "init:none", "mcp-discovery", "rebind-after-init", "auto-upgrade", "file-index", "worker-thread", "terminal-release", "stderr-attempt", "deinit" });
}

test "app entry releases terminal before reporting initial context failures exactly" {
    const alloc = std.testing.allocator;
    const errors = [_]context_contract.ProviderError{
        error.OutOfMemory,
        error.NoSpaceLeft,
        error.WriteFailed,
    };

    for (errors) |expected_error| {
        var capture = TestCapture.init(.{ .interactive = .{} });
        defer capture.deinit();
        capture.run_error = expected_error;
        capture.record_stderr_event = true;

        try std.testing.expectError(
            expected_error,
            runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps()),
        );
        var expected_stderr_buf: [64]u8 = undefined;
        const expected_stderr = try std.fmt.bufPrint(
            &expected_stderr_buf,
            "fx: {s}\n",
            .{@errorName(expected_error)},
        );
        try std.testing.expectEqualStrings(expected_stderr, capture.stderr.written());
        try std.testing.expectEqual(@as(usize, 1), capture.stderr_calls);
        try expectEvents(&.{
            "init:none",
            "mcp-discovery",
            "rebind-after-init",
            "auto-upgrade",
            "file-index",
            "worker-thread",
            "model-cache",
            "run",
            "terminal-release",
            "stderr-attempt",
            "deinit",
        });
    }
}

test "app entry reports run errors before deinit and outer cleanup" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.run_error = error.TestRunFailed;
    capture.record_stderr_event = true;

    try std.testing.expectError(error.TestRunFailed, runWithOuterCleanup(TestApp, alloc, &.{}, testConfig(), capture.deps()));
    try std.testing.expectEqualStrings("fx: TestRunFailed\n", capture.stderr.written());
    try std.testing.expectEqual(@as(usize, 1), capture.stderr_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.stdout_calls);
    try expectEvents(&.{ "init:none", "mcp-discovery", "rebind-after-init", "auto-upgrade", "file-index", "worker-thread", "model-cache", "run", "terminal-release", "stderr-attempt", "deinit", "outer-defer" });
}

test "app entry treats terminal input closure as abnormal cleanup without stderr" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.run_error = error.TerminalInputClosed;
    capture.record_stderr_event = true;
    capture.resume_handoff_id = "session-123";

    const outcome = try runWithDeps(
        TestApp,
        alloc,
        &.{},
        testConfig(),
        capture.deps(),
    );

    try std.testing.expectEqual(RunOutcome.returned, outcome);
    try std.testing.expectEqualStrings("", capture.stderr.written());
    try std.testing.expectEqual(@as(usize, 0), capture.stderr_calls);
    try std.testing.expectEqual(@as(usize, 0), capture.stdout_calls);
    try expectEvents(&.{
        "init:none",
        "mcp-discovery",
        "rebind-after-init",
        "auto-upgrade",
        "file-index",
        "worker-thread",
        "model-cache",
        "run",
        "terminal-release",
        "deinit",
    });
}

test "app entry preserves run errors when fatal formatting fails" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.run_error = error.TestRunFailed;
    capture.fail_unexpected_format = true;

    try std.testing.expectError(error.TestRunFailed, runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps()));
    try std.testing.expectEqualStrings("", capture.stderr.written());
    try std.testing.expectEqual(@as(usize, 0), capture.stderr_calls);
    try expectEvents(&.{ "init:none", "mcp-discovery", "rebind-after-init", "auto-upgrade", "file-index", "worker-thread", "model-cache", "run", "terminal-release", "deinit" });
}

test "app entry preserves run errors when fatal writer fails" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.run_error = error.TestRunFailed;
    capture.stderr_error = error.TestStderrWriteFailed;
    capture.record_stderr_event = true;

    try std.testing.expectError(error.TestRunFailed, runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps()));
    try std.testing.expectEqualStrings("", capture.stderr.written());
    try std.testing.expectEqual(@as(usize, 1), capture.stderr_calls);
    try expectEvents(&.{ "init:none", "mcp-discovery", "rebind-after-init", "auto-upgrade", "file-index", "worker-thread", "model-cache", "run", "terminal-release", "stderr-attempt", "deinit" });
}

test "app entry passes requested resume into app init" {
    const alloc = std.testing.allocator;
    const id = try alloc.dupe(u8, "session-123");
    var capture = TestCapture.init(.{ .interactive = .{ .requested_resume = .{ .id = id } } });
    defer capture.deinit();
    const outcome = try runWithDeps(TestApp, alloc, &.{ @constCast("resume"), @constCast("session-123") }, testConfig(), capture.deps());

    try std.testing.expectEqual(RunOutcome.returned, outcome);
    try expectEvents(&.{ "init:session-123", "mcp-discovery", "rebind-after-init", "resume-reconciliation", "auto-upgrade", "file-index", "worker-thread", "model-cache", "run", "terminal-release", "deinit" });
}

test "app entry maps noninteractive terminal startup to exit one" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.init_error = error.NotATerminal;
    const outcome = try runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps());

    try std.testing.expectEqual(@as(u8, 1), outcome.exit);
    try std.testing.expectEqualStrings("fx requires an interactive terminal (TTY).\n", capture.stderr.written());
    try expectEvents(&.{"init:none"});
}

test "app entry maps missing saved sessions to exit one" {
    const alloc = std.testing.allocator;
    var capture = TestCapture.init(.{ .interactive = .{} });
    defer capture.deinit();
    capture.init_error = error.NoSavedSessions;
    const outcome = try runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps());

    try std.testing.expectEqual(@as(u8, 1), outcome.exit);
    try std.testing.expectEqualStrings("fx: no saved sessions for this workspace.\n", capture.stderr.written());
}

test "app entry maps unavailable session state to one expected startup failure" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        init_error: anyerror,
        message: []const u8,
    }{
        .{
            .init_error = error.SessionBusy,
            .message = "fx: another Fx process may be using this session (running or suspended); check other terminals or run jobs, then use fg or quit that process\n",
        },
        .{
            .init_error = error.SessionLockUnsupported,
            .message = "fx: the filesystem cannot provide the required session lock\n",
        },
        .{
            .init_error = error.SessionAuthorityBoundaryUnavailable,
            .message = "fx: this session is being updated; wait a moment and retry\n",
        },
        .{
            .init_error = error.SessionCommitBoundaryUnavailable,
            .message = "fx: this session is being updated; wait a moment and retry\n",
        },
        .{
            .init_error = error.OneOffSessionNotResumable,
            .message = "fx: one-off child sessions cannot accept additional prompts; create a persistent child to continue the conversation\n",
        },
    };

    for (cases) |case| {
        var capture = TestCapture.init(.{ .interactive = .{} });
        defer capture.deinit();
        capture.init_error = case.init_error;
        capture.fail_unexpected_format = true;

        const outcome = try runWithDeps(TestApp, alloc, &.{}, testConfig(), capture.deps());

        try std.testing.expectEqual(@as(u8, 1), outcome.exit);
        try std.testing.expectEqualStrings(case.message, capture.stderr.written());
        try std.testing.expectEqual(@as(usize, 1), capture.stderr_calls);
        try expectEvents(&.{"init:none"});
    }
}

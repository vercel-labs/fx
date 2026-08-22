const std = @import("std");
const background_runtime = @import("../background/background_runtime.zig");
const command_admission = @import("../permissions/command_admission.zig");
const core_permissions = @import("../permissions/permissions.zig");
const core_types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const command_environment = @import("../execution/command_environment.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const io_mod = @import("../shared/io.zig");
const message = @import("../shared/message.zig");
const mod_registry = @import("../mods/registry.zig");
const permission_gate = @import("../permissions/permission_gate.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const read_tracker_mod = @import("../workspace/read_tracker.zig");
const session_child_store = @import("../session/session_child_store.zig");
const command_runner = @import("../execution/command_runner.zig");
const subagent_tool_provider = @import("../subagent/tool_provider.zig");
const text_utils = @import("../shared/text_utils.zig");
const web_fetch_runtime = @import("web_fetch_runtime.zig");
const web_fetch_artifacts = @import("../session/web_fetch_artifacts.zig");
const gateway_schema = @import("gateway_schema.zig");
const host = @import("../hosts/host.zig");
const tool_result_errors = @import("tool_result_errors.zig");
const tool_result_limits = @import("tool_result_limits.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const web_search_contract = @import("web_search_contract.zig");
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const terminal_contracts = @import("../terminal/contracts.zig");
const tool_args = @import("tool_args.zig");

const Allocator = std.mem.Allocator;

pub const default_ignored_list_entries = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    ".next",
    "dist",
    "build",
    "coverage",
};
pub const default_max_list_entries: usize = 100;
pub const default_max_read_file_bytes: usize = 50 * 1024;
pub const default_max_read_file_lines: usize = 400;
pub const default_max_read_file_line_len: usize = 2000;

pub const web_search_unavailable_message = "web_search is unavailable: no local runtime with a configured Gateway transport policy is installed";
pub const web_fetch_unavailable_message = "web_fetch is unavailable: no local WebFetch runtime is installed";
pub const terminal_unavailable_message =
    "{\"error\":{\"tool\":\"terminal\",\"code\":\"unsupported_host\",\"retryable\":false}}";
const terminal_saved_session_required_message =
    "Durable terminal actions require a saved fx session.";
const terminal_saved_session_required_suggestion =
    "Use terminal.exec, or rerun without --no-save.";

pub const ToolCapabilities = struct {
    web_search_runtime_ready: bool = false,
    terminal: host.TerminalSupport = .unsupported,

    pub fn for_host(host_capabilities: host.Capabilities) ToolCapabilities {
        return .{ .terminal = host_capabilities.terminal };
    }

    pub fn terminalAvailable(self: ToolCapabilities) bool {
        return self.terminal.isSupported();
    }
};

pub const WebSearchProgressFn = *const fn (*anyopaque, []const u8, core_types.WebSearchProgress) void;
pub const WebFetchProgressFn = *const fn (*anyopaque, []const u8, core_types.WebFetchProgress) void;

pub const WebSearchBackendFn = *const fn (
    *anyopaque,
    DispatchContext,
    web_search_contract.Request,
) anyerror!web_search_contract.ExecutionOutput;

pub const WebSearchBackend = struct {
    ctx: *anyopaque,
    execute_fn: WebSearchBackendFn,

    pub fn execute(
        self: WebSearchBackend,
        ctx: DispatchContext,
        request: web_search_contract.Request,
    ) !web_search_contract.ExecutionOutput {
        return self.execute_fn(self.ctx, ctx, request);
    }
};

pub const VisionProviderFn = *const fn (
    ?*anyopaque,
    DispatchContext,
    ToolInput,
) DispatchError!ToolResult;

pub const VisionProvider = struct {
    ctx: ?*anyopaque = null,
    execute_fn: VisionProviderFn,

    pub fn execute(
        self: VisionProvider,
        ctx: DispatchContext,
        input: ToolInput,
    ) DispatchError!ToolResult {
        return self.execute_fn(self.ctx, ctx, input);
    }
};

pub const SelectedDynamicToolSinkFn = *const fn (
    ?*anyopaque,
    []const u8,
    []const u8,
) error{OutOfMemory}!void;

pub const ContextNoticeSinkFn = *const fn (?*anyopaque, []const u8) error{OutOfMemory}!void;

/// Erased, owned typed input decoded by a concrete tool.
pub const ToolInput = struct {
    ptr: *anyopaque,
    deinit_fn: *const fn (ptr: *anyopaque, alloc: Allocator) void,

    /// Casts the erased input back to the tool's concrete input type.
    pub fn as(self: ToolInput, comptime T: type) *T {
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Frees the concrete input through the tool-provided destructor.
    pub fn deinit(self: ToolInput, alloc: Allocator) void {
        self.deinit_fn(self.ptr, alloc);
    }
};

/// Owned success or failure text returned by a tool call.
pub const ToolResult = union(enum) {
    success: []u8,
    failure: []u8,

    /// Frees the owned result text.
    pub fn deinit(self: ToolResult, alloc: Allocator) void {
        switch (self) {
            .success => |body| alloc.free(body),
            .failure => |body| alloc.free(body),
        }
    }
};

/// Result of decoding a raw JSON argument buffer into a typed input.
pub const DecodeResult = union(enum) {
    input: ToolInput,
    failure: []u8,
};

/// Errors that stop local dispatch before a model-recoverable result is built.
pub const DispatchError = std.json.ParseError(std.json.Scanner) || error{
    OutOfMemory,
    InvalidToolArguments,
    InvalidPath,
    FileNotFound,
    HomeNotSet,
    PathOutsideWorkspace,
    WorkspaceUnavailable,
    Cancelled,
};

/// Core-owned execution backend used by the registered run_command callback.
pub const RunCommandRequest = struct {
    command: []const u8,
    resolved_cwd: []const u8,
    environment: command_environment.Environment,
};

pub const RunCommandBackendFn = *const fn (
    ?*anyopaque,
    DispatchContext,
    RunCommandRequest,
) DispatchError!ToolResult;

pub const RunCommandBackend = struct {
    ctx: ?*anyopaque = null,
    execute_fn: RunCommandBackendFn,

    pub fn execute(
        self: RunCommandBackend,
        ctx: DispatchContext,
        request: RunCommandRequest,
    ) DispatchError!ToolResult {
        return self.execute_fn(self.ctx, ctx, request);
    }
};

/// Context shared by core tool dispatch, validation, and execution.
pub const DispatchContext = struct {
    allocator: Allocator,
    permission_mode: permission_gate.PermissionMode = .ask,
    permission_decider: ?PermissionDecider = null,
    execution_authority: ?command_admission.ToolExecutionAuthority = null,
    workspace_root: []const u8 = "",
    access_scope: ?workspace_access.AccessScope = null,
    ignored_list_entries: []const []const u8 = &default_ignored_list_entries,
    max_list_entries: usize = default_max_list_entries,
    max_read_file_bytes: usize = default_max_read_file_bytes,
    max_read_file_lines: usize = default_max_read_file_lines,
    max_read_file_line_len: usize = default_max_read_file_line_len,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    skills_dir: []const u8 = "",
    context_limits: context_limits.Values = .{},
    permission_ctx: ?*const PermissionContext = null,
    read_tracker: ?*read_tracker_mod.ReadTracker = null,
    change_tracker: ?*change_tracker.ChangeTracker = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    output_chunk_lifecycle_id: ?core_types.ToolLifecycleId = null,
    output_chunk_ctx: ?*anyopaque = null,
    on_output_chunk: ?command_runner.CommandOutputCallback = null,
    background_ctx: ?*background_runtime.BackgroundRuntime = null,
    background_url_ctx: ?*anyopaque = null,
    on_background_url_ready: ?*const fn (*anyopaque, []const u8, []const u8) void = null,
    background_log_dir: ?[]const u8 = null,
    command_artifact_dir: ?[]const u8 = null,
    tool_result_dir: ?[]const u8 = null,
    session_child_capability: ?*session_child_store.SessionChildCapability = null,
    terminal_client: ?*terminal_client_runtime.Runtime = null,
    terminal_owner_session_id: ?[]const u8 = null,
    terminal_transport_role: terminal_contracts.TransportRole = .interactive,
    background_lifecycle_allocator: Allocator = std.heap.c_allocator,
    command_timeout_ms: ?usize = null,
    captured_command_host: command_environment.Host = .native,
    run_command_backend: ?RunCommandBackend = null,
    subagent_provider: ?subagent_tool_provider.Provider = null,
    vision_provider: ?VisionProvider = null,
    ask_question_ctx: ?*anyopaque = null,
    ask_question_batch: ?AskQuestionBatchFn = null,
    tool_capabilities: ToolCapabilities = .{},
    web_fetch_runtime: ?*web_fetch_runtime.Runtime = null,
    web_fetch_artifact_store: ?*web_fetch_artifacts.Store = null,
    web_fetch_artifact_error: ?anyerror = null,
    web_search_backend: ?WebSearchBackend = null,
    tool_call_id: []const u8 = "",
    tool_call_name: []const u8 = "",
    web_search_progress_ctx: ?*anyopaque = null,
    on_web_search_progress: ?WebSearchProgressFn = null,
    web_fetch_progress_ctx: ?*anyopaque = null,
    on_web_fetch_progress: ?WebFetchProgressFn = null,
    mcp_ctx: ?*anyopaque = null,
    mcp_call_tool: ?tool_mcp_runtime.CallToolFn = null,
    mcp_search_tools: ?tool_mcp_runtime.SearchToolsFn = null,
    mcp_tool_schema: ?tool_mcp_runtime.ToolSchemaFn = null,
    mcp_call_feature: ?tool_mcp_runtime.FeatureCallFn = null,
    mcp_access: tool_mcp_runtime.Access = .unrestricted,
    mcp_input_responder: ?tool_mcp_runtime.InputResponder = null,
    mcp_call_options: tool_mcp_runtime.CallOptions = .{},
    mcp_call_status_sink: ?*?tool_mcp_runtime.CallStatus = null,
    mcp_execution_error_sink: ?*?anyerror = null,
    mcp_permission_rules: core_types.PermissionRuleSet = .{},
    selected_dynamic_tool_ctx: ?*anyopaque = null,
    on_selected_dynamic_tool: ?SelectedDynamicToolSinkFn = null,
    context_notice_ctx: ?*anyopaque = null,
    on_context_notice: ?ContextNoticeSinkFn = null,
    inner_usage_sink: ?*?core_types.ToolUsage = null,
    web_search_completion_sink: ?*?core_types.WebSearchCompletion = null,
    web_fetch_completion_sink: ?*?core_types.WebFetchCompletion = null,
    tool_result_memory_sink: ?*?core_types.ToolResultMemory = null,
};

/// Function pointer used by ask_user_question to request live user answers.
pub const AskQuestionBatchFn = *const fn (
    ?*anyopaque,
    Allocator,
    []const core_types.QuestionBatchEntry,
) anyerror!?[][]u8;

/// Function pointer used to override permission decisions in tests and callers.
pub const PermissionDecider = *const fn (*const Tool, ToolInput, DispatchContext) permission_gate.Decision;

/// Rule-engine lookup function carried through dispatch for test injection.
pub const PermissionRuleLookup = *const fn (
    Allocator,
    core_types.PermissionRuleSet,
    []const u8,
    []const u8,
    []const u8,
    PermissionTargetKind,
) anyerror!core_permissions.RuleDecision;

/// Permission state shared by a noninteractive turn.
pub const PermissionContext = struct {
    rules: ?*const core_types.PermissionRuleSet = null,
    rule_lookup: PermissionRuleLookup = core_permissions.ruleDecisionFor,
};

/// Function pointer that decodes JSON arguments into a concrete input.
pub const DecodeFn = *const fn (DispatchContext, []const u8) DispatchError!DecodeResult;

/// Optional pure validation step run before the permission gate.
pub const ValidateFn = *const fn (DispatchContext, ToolInput) DispatchError!?[]u8;

/// Function pointer that executes a validated and allowed tool input.
pub const CallFn = *const fn (DispatchContext, ToolInput) DispatchError!ToolResult;

/// Optional Core adapter selected by a registered tool descriptor when the
/// ordinary decode/validate/call path needs a focused lifecycle wrapper.
pub const AuthorizedCallAdapterFn = *const fn (
    DispatchContext,
    Registry,
    message.ToolCall,
) DispatchError!DispatchResult;

/// Optional Core mapper selected by a registered tool descriptor after an
/// authorized call has produced its structured dispatch result.
pub const AuthorizedResultMapperFn = *const fn (
    Allocator,
    DispatchResult,
) Allocator.Error!DispatchResult;

pub const RunCommandCompatibility = struct {
    matches: *const fn ([]const u8) bool,
    /// Returns success or failure text owned by `ctx.allocator`.
    execute: *const fn (DispatchContext, []const u8) DispatchError!ToolResult,
};

/// Consumes a decoded tool input and transfers its owned fields into Core's
/// canonical file-mutation contract. The caller owns the returned input and
/// must not deinitialize the consumed ToolInput.
pub const TakeFileMutationInputFn = *const fn (
    ToolInput,
    Allocator,
) file_mutation_contract.FileMutationInput;

/// Function pointer classifying whether an input is read-only.
pub const ReadsOnlyFn = *const fn (ToolInput) bool;

/// Function pointer classifying whether an input is irreversible.
pub const IrreversibleFn = *const fn (ToolInput) bool;

pub const GatewayAdvertisementError = std.mem.Allocator.Error || std.Io.Writer.Error || error{
    InvalidWebSearchBackend,
    ConflictingDomainFilters,
    InvalidGatewayAdvertisement,
};

pub const WriteGatewayAdvertisementFn = *const fn (
    std.mem.Allocator,
    *std.Io.Writer,
) GatewayAdvertisementError!void;

pub const LabelArgKind = enum {
    none,
    name,
    path,
    pattern,
    url,
    command,
    description,
    source,
    old_path,
    action,
    query,
    selector,
    session_id,
};

pub const PermissionTargetKind = core_permissions.PermissionTargetKind;

pub const ExecutorKind = enum {
    list_files,
    glob_files,
    grep_files,
    read_file,
    read_tool_result,
    write_file,
    edit_file,
    delete_file,
    rename_file,
    copy_file,
    create_folder,
    file_info,
    memory,
    semantic_search,
    open_file,
    web_fetch,
    web_search,
    run_command,
    terminal,
    skill,
    install_skill,
    subagent,
    mcp_search_tools,
    mcp_select_tool,
    mcp_features,
    ask_user_question,
    vision,
};

pub const ApprovalPolicy = enum {
    standard,
    ask_only,
    auto_deny_on_ask,
};

pub const RuntimeProviderKind = enum {
    none,
    run_command,
    subagent,
    vision,
};

pub const CapturedCommandFn = *const fn (ToolInput) bool;

pub const CallPresentation = struct {
    activity_kind: core_types.ToolActivityKind,
    action_label: []const u8,
    completed_action_label: []const u8,
    label_arg_kind: LabelArgKind,
    label_arg_default: []const u8,
};

/// Optional call-aware presentation override. Returned strings must outlive the
/// parsed arguments supplied to the callback.
pub const PresentationFn = *const fn (std.json.ObjectMap) ?CallPresentation;

/// Descriptor for a core tool's model-facing metadata and runtime callbacks.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    gateway_schema: gateway_schema.FunctionSchema,
    write_gateway_advertisement_fn: ?WriteGatewayAdvertisementFn = null,
    /// Set when the provider runs the tool instead of fx dispatch. Such a tool
    /// never reaches a call-time permission check, so advertisement is its only
    /// enforcement point and requires an already-settled allow.
    provider_executed: bool = false,
    executor_kind: ExecutorKind = .list_files,
    activity_kind: core_types.ToolActivityKind = .read,
    requires_approval: bool = false,
    approval_policy: ApprovalPolicy = .standard,
    action_label: []const u8 = "Working",
    completed_action_label: []const u8 = "Completed",
    label_arg_kind: LabelArgKind = .none,
    label_arg_default: []const u8 = "",
    presentation_fn: ?PresentationFn = null,
    permission_target_kind: PermissionTargetKind = .none,
    decode: DecodeFn,
    validate: ?ValidateFn = null,
    call: CallFn,
    runtime_provider: RuntimeProviderKind = .none,
    captured_command_host: command_environment.Host = .native,
    captured_command_action: ?[]const u8 = null,
    captured_command_fn: ?CapturedCommandFn = null,
    authorized_call_adapter: ?AuthorizedCallAdapterFn = null,
    authorized_result_mapper: ?AuthorizedResultMapperFn = null,
    cancel_if_requested_after_call: bool = false,
    run_command_compatibility: ?RunCommandCompatibility = null,
    take_file_mutation_input_fn: ?TakeFileMutationInputFn = null,
    reads_only_fn: ReadsOnlyFn,
    irreversible_fn: IrreversibleFn,
};

pub const Registry = mod_registry.ToolRegistry(Tool);

pub const ProgressLabelKind = enum {
    none,
    started,
    completed,
};

/// Classifies rendered tool progress through the registered presentation labels.
pub fn classifyProgressLabel(registry: Registry, text: []const u8) ProgressLabelKind {
    for (registry.tools) |tool| {
        if (startsWithProgressLabel(text, tool.action_label)) return .started;
        if (startsWithProgressLabel(text, tool.completed_action_label)) return .completed;
    }
    return .none;
}

fn startsWithProgressLabel(text: []const u8, label: []const u8) bool {
    if (!std.mem.startsWith(u8, text, label)) return false;
    if (text.len == label.len) return true;
    return text[label.len] == ' ';
}

pub const RunCommandCompatibilityMatch = struct {
    tool: *const Tool,
    compatibility: RunCommandCompatibility,
};

pub const RunCommandCompatibilityMatchError = error{AmbiguousRunCommandCompatibility};

pub fn matchRunCommandCompatibility(
    registry: Registry,
    command: []const u8,
) RunCommandCompatibilityMatchError!?RunCommandCompatibilityMatch {
    var matched: ?RunCommandCompatibilityMatch = null;
    for (registry.tools) |*tool| {
        const compatibility = tool.run_command_compatibility orelse continue;
        if (!compatibility.matches(command)) continue;
        if (matched != null) return error.AmbiguousRunCommandCompatibility;
        matched = .{
            .tool = tool,
            .compatibility = compatibility,
        };
    }
    return matched;
}

pub fn dispatchRunCommandCompatibility(
    ctx: DispatchContext,
    registry: Registry,
    request: RunCommandRequest,
) (DispatchError || RunCommandCompatibilityMatchError)!?ToolResult {
    if (std.meta.activeTag(request.environment) != .legacy) return null;
    const matched = (try matchRunCommandCompatibility(
        registry,
        request.command,
    )) orelse return null;
    if (std.mem.indexOfAny(u8, request.command, "|;&\n") != null) return null;
    return try matched.compatibility.execute(ctx, request.command);
}

pub fn toolActivityKind(registry: Registry, tool_name: []const u8) core_types.ToolActivityKind {
    return if (registry.lookup(tool_name)) |tool| tool.activity_kind else .command;
}

pub fn staticPresentation(tool: Tool) CallPresentation {
    return .{
        .activity_kind = tool.activity_kind,
        .action_label = tool.action_label,
        .completed_action_label = tool.completed_action_label,
        .label_arg_kind = tool.label_arg_kind,
        .label_arg_default = tool.label_arg_default,
    };
}

pub fn presentationForArgs(tool: Tool, args: std.json.ObjectMap) CallPresentation {
    if (tool.presentation_fn) |resolve| {
        if (resolve(args)) |presentation| return presentation;
    }
    return staticPresentation(tool);
}

pub fn toolCallPresentation(
    alloc: Allocator,
    registry: Registry,
    call: core_types.ToolCall,
) ?CallPresentation {
    const tool = registry.lookup(call.name) orelse return null;
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const args = tool_args.parseToolArgsObject(
        scratch_state.allocator(),
        call.arguments_json,
    ) catch return staticPresentation(tool.*);
    return presentationForArgs(tool.*, args);
}

pub fn toolActivityKindForCall(
    alloc: Allocator,
    registry: Registry,
    call: core_types.ToolCall,
) core_types.ToolActivityKind {
    const presentation = toolCallPresentation(alloc, registry, call) orelse
        return .command;
    return presentation.activity_kind;
}

pub fn toolLabelValue(tool: Tool, args: std.json.ObjectMap) ?[]const u8 {
    return labelValueForKind(tool.label_arg_kind, args);
}

pub fn presentationLabelValue(presentation: CallPresentation, args: std.json.ObjectMap) ?[]const u8 {
    return labelValueForKind(presentation.label_arg_kind, args);
}

fn labelValueForKind(kind: LabelArgKind, args: std.json.ObjectMap) ?[]const u8 {
    return switch (kind) {
        .none => null,
        .name => optionalStringArg(args, "name"),
        .path => optionalStringArg(args, "path"),
        .pattern => optionalStringArg(args, "pattern"),
        .url => optionalStringArg(args, "url"),
        .command => optionalStringArg(args, "command"),
        .description => optionalStringArg(args, "description"),
        .source => optionalStringArg(args, "source"),
        .old_path => optionalStringArg(args, "old_path"),
        .action => optionalStringArg(args, "action"),
        .query => optionalStringArg(args, "query"),
        .selector => optionalStringArg(args, "selector"),
        .session_id => optionalStringArg(args, "session_id"),
    };
}

fn optionalStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = args.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

/// Side-effect-free admission result for a registered tool call.
pub const ValidationResult = union(enum) {
    not_registered,
    valid,
    failure: []u8,
};

const ValidatedToolCall = union(enum) {
    not_registered,
    failure: []u8,
    input: struct {
        tool: *const Tool,
        value: ToolInput,
    },
};

/// Decodes and validates registered input without resolving permission or executing the tool.
pub fn validateRegisteredToolCall(ctx: DispatchContext, registry: Registry, call: message.ToolCall) DispatchError!ValidationResult {
    const validated = try decodeAndValidateRegisteredToolCall(ctx, registry, call);
    return switch (validated) {
        .not_registered => .not_registered,
        .failure => |reason| .{ .failure = reason },
        .input => |input| blk: {
            input.value.deinit(ctx.allocator);
            break :blk .valid;
        },
    };
}

fn decodeAndValidateRegisteredToolCall(ctx: DispatchContext, registry: Registry, call: message.ToolCall) DispatchError!ValidatedToolCall {
    const tool = registry.lookup(call.name) orelse return .not_registered;
    return decodeAndValidateToolCall(ctx, tool, call.arguments_json);
}

fn decodeAndValidateToolCall(
    ctx: DispatchContext,
    tool: *const Tool,
    arguments_json: []const u8,
) DispatchError!ValidatedToolCall {
    const decoded = try tool.decode(ctx, arguments_json);
    return switch (decoded) {
        .failure => |reason| .{ .failure = reason },
        .input => |input| blk: {
            errdefer input.deinit(ctx.allocator);
            if (tool.validate) |validate| {
                if (try validate(ctx, input)) |reason| {
                    input.deinit(ctx.allocator);
                    break :blk .{ .failure = reason };
                }
            }
            break :blk .{ .input = .{ .tool = tool, .value = input } };
        },
    };
}

/// A registered call that passed local availability and permission admission.
pub const AdmittedToolCall = struct {
    tool: *const Tool,
    input: ToolInput,
    context: DispatchContext,
    permission_decision: permission_gate.Decision,

    pub fn deinit(self: AdmittedToolCall) void {
        var permission_decision = self.permission_decision;
        permission_decision.deinit(self.context.allocator);
        self.input.deinit(self.context.allocator);
    }
};

/// Result of generic tool lookup, validation, availability, and permission admission.
pub const AdmissionResult = union(enum) {
    not_registered,
    failure: []u8,
    admitted: AdmittedToolCall,
};

/// Admits one model-requested registered call without executing it.
pub fn admitToolCall(ctx: DispatchContext, registry: Registry, call: message.ToolCall) DispatchError!AdmissionResult {
    var call_ctx = ctx;
    const validated = try decodeAndValidateRegisteredToolCall(call_ctx, registry, call);
    switch (validated) {
        .not_registered => return .not_registered,
        .failure => |reason| return .{ .failure = reason },
        .input => |input| {
            var input_transferred = false;
            defer if (!input_transferred) input.value.deinit(call_ctx.allocator);

            if (try localToolAvailabilityFailure(call_ctx, input.tool, input.value)) |reason| {
                return .{ .failure = reason };
            }

            var decision = permission_gate.decideOrdinary(input.tool, input.value, call_ctx);
            var decision_transferred = false;
            defer if (!decision_transferred) decision.deinit(call_ctx.allocator);

            switch (decision.action) {
                .allow => {},
                .deny => {
                    traceDeniedWebSearch(.{}, call, decision.denial_reason orelse .policy_denied);
                    return .{ .failure = try deniedToolResultBody(call_ctx.allocator, input.tool.name, decision) };
                },
                .ask => {
                    traceDeniedWebSearch(.{}, call, .permission_required);
                    return .{ .failure = try tool_result_errors.toolPermissionDeniedJson(call_ctx.allocator, input.tool.name, .permission_required) };
                },
            }

            const captured_command = input.tool.executor_kind == .run_command or
                if (input.tool.captured_command_fn) |classify|
                    classify(input.value)
                else
                    false;
            if (captured_command) {
                const authority = decision.execution_authority orelse {
                    return .{ .failure = try call_ctx.allocator.dupe(u8, "captured command permission allowed without execution authority") };
                };
                call_ctx.execution_authority = switch (authority) {
                    .run_command => |command_authority| .{ .run_command = command_authority },
                    else => {
                        return .{ .failure = try call_ctx.allocator.dupe(u8, "captured command permission returned invalid execution authority") };
                    },
                };
            } else {
                if (decision.execution_authority != null) {
                    return .{ .failure = try call_ctx.allocator.dupe(u8, "non-command permission returned command execution authority") };
                }
                call_ctx.execution_authority = .ordinary;
            }

            if (core_permissions.isFilesystemMutationTool(input.tool.name)) {
                var execution_decision = permission_gate.decideOrdinary(input.tool, input.value, call_ctx);
                defer execution_decision.deinit(call_ctx.allocator);
                switch (execution_decision.action) {
                    .allow => {},
                    .deny => {
                        return .{ .failure = try deniedToolResultBody(call_ctx.allocator, input.tool.name, execution_decision) };
                    },
                    .ask => {
                        return .{ .failure = try tool_result_errors.toolPermissionDeniedJson(call_ctx.allocator, input.tool.name, .permission_required) };
                    },
                }
            }

            const admitted = AdmissionResult{ .admitted = .{
                .tool = input.tool,
                .input = input.value,
                .context = call_ctx,
                .permission_decision = decision,
            } };
            input_transferred = true;
            decision_transferred = true;
            return admitted;
        },
    }
}

/// Owned tool-result message body produced by dispatch.
pub const DispatchResult = struct {
    status: Status,
    body: []u8,
    status_detail: ?[]u8 = null,
    inner_usage: ?core_types.ToolUsage = null,
    web_search_completion: ?core_types.WebSearchCompletion = null,
    web_fetch_completion: ?core_types.WebFetchCompletion = null,
    tool_result_memory: ?core_types.ToolResultMemory = null,

    /// Tool-result status used only by tests and diagnostics.
    pub const Status = enum {
        success,
        failure,
    };

    /// Frees the owned tool-result body and optional diagnostic detail.
    pub fn deinit(self: DispatchResult, alloc: Allocator) void {
        alloc.free(self.body);
        if (self.status_detail) |detail| alloc.free(detail);
    }
};

/// Runs one model-requested tool call through lookup, validation, gate, and call.
pub fn dispatchToolCall(ctx: DispatchContext, registry: Registry, call: message.ToolCall) DispatchError!DispatchResult {
    var captured_usage: ?core_types.ToolUsage = null;
    var captured_web_search_completion: ?core_types.WebSearchCompletion = null;
    var captured_web_fetch_completion: ?core_types.WebFetchCompletion = null;
    var captured_tool_result_memory: ?core_types.ToolResultMemory = null;
    var call_ctx = ctx;
    if (call_ctx.inner_usage_sink == null) call_ctx.inner_usage_sink = &captured_usage;
    if (call_ctx.web_search_completion_sink == null) call_ctx.web_search_completion_sink = &captured_web_search_completion;
    if (call_ctx.web_fetch_completion_sink == null) call_ctx.web_fetch_completion_sink = &captured_web_fetch_completion;
    if (call_ctx.tool_result_memory_sink == null) call_ctx.tool_result_memory_sink = &captured_tool_result_memory;

    const admission = try admitToolCall(call_ctx, registry, call);
    switch (admission) {
        .not_registered => return failure(try std.fmt.allocPrint(call_ctx.allocator, "unknown tool: {s}", .{call.name})),
        .failure => |reason| return failure(reason),
        .admitted => |admitted| {
            defer admitted.deinit();

            const result = try admitted.tool.call(admitted.context, admitted.input);
            const inner_usage = if (admitted.context.inner_usage_sink) |slot| slot.* else captured_usage;
            const web_search_completion = if (admitted.context.web_search_completion_sink) |slot| slot.* else captured_web_search_completion;
            const web_fetch_completion = if (admitted.context.web_fetch_completion_sink) |slot| slot.* else captured_web_fetch_completion;
            const tool_result_memory = if (admitted.context.tool_result_memory_sink) |slot| slot.* else captured_tool_result_memory;
            return switch (result) {
                .success => |body| .{
                    .status = .success,
                    .body = body,
                    .inner_usage = inner_usage,
                    .web_search_completion = web_search_completion,
                    .web_fetch_completion = web_fetch_completion,
                    .tool_result_memory = tool_result_memory,
                },
                .failure => |body| .{
                    .status = .failure,
                    .body = body,
                    .inner_usage = inner_usage,
                    .web_search_completion = web_search_completion,
                    .web_fetch_completion = web_fetch_completion,
                    .tool_result_memory = tool_result_memory,
                },
            };
        },
    }
}

/// Runs one already-authorized registered tool call through lookup, validation, and call.
pub fn dispatchAuthorizedToolCall(ctx: DispatchContext, registry: Registry, call: message.ToolCall) DispatchError!DispatchResult {
    const tool = registry.lookup(call.name) orelse return failure(
        try std.fmt.allocPrint(ctx.allocator, "unknown tool: {s}", .{call.name}),
    );
    const result = if (tool.authorized_call_adapter) |adapter|
        try adapter(ctx, registry, call)
    else
        try dispatchAuthorizedToolCallDefault(ctx, registry, call);
    if (tool.authorized_result_mapper) |mapper| {
        return mapper(ctx.allocator, result) catch |err| {
            result.deinit(ctx.allocator);
            return err;
        };
    }
    return result;
}

/// Runs the ordinary authorized decode/validate/call path without consulting a
/// descriptor's lifecycle adapter. Focused adapters use this to wrap one call
/// without recursively selecting themselves again.
pub fn dispatchAuthorizedToolCallDefault(ctx: DispatchContext, registry: Registry, call: message.ToolCall) DispatchError!DispatchResult {
    var captured_usage: ?core_types.ToolUsage = null;
    var captured_web_search_completion: ?core_types.WebSearchCompletion = null;
    var captured_web_fetch_completion: ?core_types.WebFetchCompletion = null;
    var captured_tool_result_memory: ?core_types.ToolResultMemory = null;
    var call_ctx = ctx;
    if (call_ctx.inner_usage_sink == null) call_ctx.inner_usage_sink = &captured_usage;
    if (call_ctx.web_search_completion_sink == null) call_ctx.web_search_completion_sink = &captured_web_search_completion;
    if (call_ctx.web_fetch_completion_sink == null) call_ctx.web_fetch_completion_sink = &captured_web_fetch_completion;
    if (call_ctx.tool_result_memory_sink == null) call_ctx.tool_result_memory_sink = &captured_tool_result_memory;

    const validated = try decodeAndValidateRegisteredToolCall(call_ctx, registry, call);
    switch (validated) {
        .not_registered => return failure(try std.fmt.allocPrint(call_ctx.allocator, "unknown tool: {s}", .{call.name})),
        .failure => |reason| return failure(reason),
        .input => |input| {
            defer input.value.deinit(call_ctx.allocator);

            const result = try input.tool.call(call_ctx, input.value);
            if (input.tool.cancel_if_requested_after_call and
                call_ctx.cancel_flag != null and
                call_ctx.cancel_flag.?.load(.seq_cst))
            {
                result.deinit(call_ctx.allocator);
                return error.Cancelled;
            }
            const inner_usage = if (call_ctx.inner_usage_sink) |slot| slot.* else captured_usage;
            const web_search_completion = if (call_ctx.web_search_completion_sink) |slot| slot.* else captured_web_search_completion;
            const web_fetch_completion = if (call_ctx.web_fetch_completion_sink) |slot| slot.* else captured_web_fetch_completion;
            const tool_result_memory = if (call_ctx.tool_result_memory_sink) |slot| slot.* else captured_tool_result_memory;
            return switch (result) {
                .success => |body| .{
                    .status = .success,
                    .body = body,
                    .inner_usage = inner_usage,
                    .web_search_completion = web_search_completion,
                    .web_fetch_completion = web_fetch_completion,
                    .tool_result_memory = tool_result_memory,
                },
                .failure => |body| .{
                    .status = .failure,
                    .body = body,
                    .inner_usage = inner_usage,
                    .web_search_completion = web_search_completion,
                    .web_fetch_completion = web_fetch_completion,
                    .tool_result_memory = tool_result_memory,
                },
            };
        },
    }
}

pub fn reportInnerUsage(ctx: DispatchContext, usage: core_types.ToolUsage) void {
    const sink = ctx.inner_usage_sink orelse return;
    sink.* = usage;
}

pub fn reportWebSearchCompletion(ctx: DispatchContext, completion: core_types.WebSearchCompletion) void {
    const sink = ctx.web_search_completion_sink orelse return;
    sink.* = completion;
}

pub fn reportWebFetchCompletion(ctx: DispatchContext, completion: core_types.WebFetchCompletion) void {
    const sink = ctx.web_fetch_completion_sink orelse return;
    sink.* = completion;
}

pub fn reportToolResultMemory(ctx: DispatchContext, memory: core_types.ToolResultMemory) void {
    const sink = ctx.tool_result_memory_sink orelse return;
    sink.* = memory;
}

pub fn reportSelectedDynamicTool(
    ctx: DispatchContext,
    name: []const u8,
    schema_json: []const u8,
) error{OutOfMemory}!void {
    const sink = ctx.on_selected_dynamic_tool orelse return;
    try sink(ctx.selected_dynamic_tool_ctx, name, schema_json);
}

pub fn reportContextNotice(ctx: DispatchContext, notice: []const u8) error{OutOfMemory}!void {
    const sink = ctx.on_context_notice orelse return;
    try sink(ctx.context_notice_ctx, notice);
}

pub fn localToolAvailabilityFailure(
    ctx: DispatchContext,
    tool: *const Tool,
    input: ToolInput,
) DispatchError!?[]u8 {
    return switch (tool.executor_kind) {
        .web_search => if (ctx.tool_capabilities.web_search_runtime_ready)
            null
        else
            try ctx.allocator.dupe(u8, web_search_unavailable_message),
        .terminal => if (tool.captured_command_fn != null and tool.captured_command_fn.?(input))
            null
        else if (!ctx.tool_capabilities.terminalAvailable())
            try ctx.allocator.dupe(u8, terminal_unavailable_message)
        else if (ctx.session_child_capability != null)
            null
        else
            try tool_result_errors.toolExecutionFailureJson(ctx.allocator, .{
                .tool_name = tool.name,
                .message = terminal_saved_session_required_message,
                .suggestion = terminal_saved_session_required_suggestion,
            }),
        else => null,
    };
}

pub fn localToolAvailabilityFailureForCall(
    ctx: DispatchContext,
    registry: Registry,
    call: message.ToolCall,
) DispatchError!?[]u8 {
    const validated = try decodeAndValidateRegisteredToolCall(ctx, registry, call);
    return switch (validated) {
        .not_registered, .failure => null,
        .input => |input| blk: {
            defer input.value.deinit(ctx.allocator);
            break :blk try localToolAvailabilityFailure(ctx, input.tool, input.value);
        },
    };
}

fn failure(body: []u8) DispatchResult {
    return .{ .status = .failure, .body = body };
}

fn deniedToolResultBody(alloc: Allocator, tool_name: []const u8, decision: permission_gate.Decision) ![]u8 {
    if (decision.structured_model_output) return alloc.dupe(u8, decision.reason);
    return tool_result_errors.toolPermissionDeniedJson(alloc, tool_name, decision.denial_reason orelse .policy_denied);
}

pub fn traceDeniedWebSearch(ctx: debug_trace.TraceContext, call: message.ToolCall, reason: core_types.ToolPermissionDenialReason) void {
    if (!core_permissions.isWebSearchToolName(call.name)) return;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, arena, call.arguments_json, .{}) catch {
        debug_trace.eventf("permission", "web_search_denied", ctx, "call_id={s} tool_name={s} query=<invalid-json> reason={s}", .{ call.id, call.name, @tagName(reason) });
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const query_value = parsed.value.object.get("query") orelse return;
    if (query_value != .string) return;

    const masked = text_utils.maskSecrets(arena, query_value.string) catch "<redaction-error>";
    var preview_buf: [160]u8 = undefined;
    const query_preview = debug_trace.terminalPreview(&preview_buf, masked);
    debug_trace.eventf("permission", "web_search_denied", ctx, "call_id={s} tool_name={s} query={s} query_bytes={d} reason={s}", .{ call.id, call.name, query_preview, query_value.string.len, @tagName(reason) });
}

const MockInput = struct {
    read_only: bool = true,
    irreversible: bool = false,
};

fn mockInputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *MockInput = @ptrCast(@alignCast(ptr));
    alloc.destroy(input);
}

fn decodeMock(ctx: DispatchContext, args_json: []const u8) DispatchError!DecodeResult {
    if (std.mem.eql(u8, args_json, "invalid_args_error")) {
        return error.InvalidToolArguments;
    }

    if (std.mem.eql(u8, args_json, "decode_error")) {
        return .{ .failure = try ctx.allocator.dupe(u8, "invalid mock arguments") };
    }

    const input = try ctx.allocator.create(MockInput);
    input.* = .{
        .read_only = !std.mem.eql(u8, args_json, "deny"),
        .irreversible = std.mem.eql(u8, args_json, "irreversible"),
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = mockInputDeinit } };
}

fn validateMock(ctx: DispatchContext, input: ToolInput) DispatchError!?[]u8 {
    _ = input;
    _ = ctx;
    return null;
}

fn rejectMock(ctx: DispatchContext, input: ToolInput) DispatchError!?[]u8 {
    _ = input;
    return try ctx.allocator.dupe(u8, "validation rejected input");
}

fn callMock(ctx: DispatchContext, input: ToolInput) DispatchError!ToolResult {
    _ = input;
    return .{ .success = try ctx.allocator.dupe(u8, "mock ok") };
}

fn mockReadsOnly(input: ToolInput) bool {
    return input.as(MockInput).read_only;
}

fn mockIrreversible(input: ToolInput) bool {
    return input.as(MockInput).irreversible;
}

fn askDecision(_: *const Tool, _: ToolInput, _: DispatchContext) permission_gate.Decision {
    return .{ .action = .ask, .reason = "side effect requires confirmation" };
}

var unavailable_web_search_permission_count: usize = 0;
var unavailable_web_search_execution_count: usize = 0;

fn countWebSearchPermission(_: *const Tool, _: ToolInput, _: DispatchContext) permission_gate.Decision {
    unavailable_web_search_permission_count += 1;
    return .{ .action = .allow, .reason = "test allow" };
}

fn denyWebSearchPermission(_: *const Tool, _: ToolInput, _: DispatchContext) permission_gate.Decision {
    unavailable_web_search_permission_count += 1;
    return .{ .action = .deny, .reason = "test deny", .denial_reason = .user_denied };
}

fn countWebSearchExecution(ctx: DispatchContext, _: ToolInput) DispatchError!ToolResult {
    unavailable_web_search_execution_count += 1;
    return .{ .success = try ctx.allocator.dupe(u8, "unexpected execution") };
}

const mock_tool = Tool{
    .name = "mock_tool",
    .description = "Mock tool used by dispatch tests.",
    .gateway_schema = .{
        .name = "mock_tool",
        .description = "Mock tool used by dispatch tests.",
    },
    .decode = decodeMock,
    .validate = validateMock,
    .call = callMock,
    .reads_only_fn = mockReadsOnly,
    .irreversible_fn = mockIrreversible,
};

fn matchesCompatibilityFixture(_: []const u8) bool {
    return true;
}

fn executeCompatibilityFixture(ctx: DispatchContext, _: []const u8) DispatchError!ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, "compatibility fixture") };
}

const first_compatibility_tool = blk: {
    var tool = mock_tool;
    tool.name = "first_compatibility";
    tool.run_command_compatibility = .{
        .matches = matchesCompatibilityFixture,
        .execute = executeCompatibilityFixture,
    };
    break :blk tool;
};

const second_compatibility_tool = blk: {
    var tool = mock_tool;
    tool.name = "second_compatibility";
    tool.run_command_compatibility = .{
        .matches = matchesCompatibilityFixture,
        .execute = executeCompatibilityFixture,
    };
    break :blk tool;
};

test "run command compatibility rejects overlapping matches" {
    const registry = Registry{ .tools = &.{ first_compatibility_tool, second_compatibility_tool } };

    try std.testing.expectError(
        error.AmbiguousRunCommandCompatibility,
        matchRunCommandCompatibility(registry, "matching command"),
    );
}

test "Registry.lookup returns hit and miss" {
    const registry = Registry{ .tools = &.{mock_tool} };

    try std.testing.expect(registry.lookup("mock_tool") != null);
    try std.testing.expect(registry.lookup("missing") == null);
}

test "classifyProgressLabel preserves registered order and label boundaries" {
    const first_tool = blk: {
        var tool = mock_tool;
        tool.action_label = "Running mock";
        tool.completed_action_label = "Shared label";
        break :blk tool;
    };
    const second_tool = blk: {
        var tool = mock_tool;
        tool.name = "second_mock_tool";
        tool.action_label = "Shared label";
        tool.completed_action_label = "Ran mock";
        break :blk tool;
    };
    const registry = Registry{ .tools = &.{ first_tool, second_tool } };

    try std.testing.expectEqual(ProgressLabelKind.started, classifyProgressLabel(registry, "Running mock"));
    try std.testing.expectEqual(ProgressLabelKind.started, classifyProgressLabel(registry, "Running mock value"));
    try std.testing.expectEqual(ProgressLabelKind.completed, classifyProgressLabel(registry, "Shared label value"));
    try std.testing.expectEqual(ProgressLabelKind.completed, classifyProgressLabel(registry, "Ran mock value"));
    try std.testing.expectEqual(ProgressLabelKind.none, classifyProgressLabel(registry, "Running mockery"));
    try std.testing.expectEqual(ProgressLabelKind.none, classifyProgressLabel(registry, "Unknown tool"));
}

test "toolLabelValue reads the label field named by registered metadata" {
    const labeled_tool = Tool{
        .name = "labeled_tool",
        .description = "Labeled mock tool.",
        .gateway_schema = .{
            .name = "labeled_tool",
            .description = "Labeled mock tool.",
        },
        .label_arg_kind = .command,
        .decode = decodeMock,
        .call = callMock,
        .reads_only_fn = mockReadsOnly,
        .irreversible_fn = mockIrreversible,
    };

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"command\":\"zig build\",\"name\":\"ignored\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("zig build", toolLabelValue(labeled_tool, parsed.value.object).?);
    try std.testing.expect(toolLabelValue(mock_tool, parsed.value.object) == null);
}

test "validateRegisteredToolCall distinguishes unregistered valid and rejected calls without execution" {
    const rejecting_tool = Tool{
        .name = "rejecting_tool",
        .description = "Rejecting mock tool.",
        .gateway_schema = .{
            .name = "rejecting_tool",
            .description = "Rejecting mock tool.",
        },
        .decode = decodeMock,
        .validate = rejectMock,
        .call = callMock,
        .reads_only_fn = mockReadsOnly,
        .irreversible_fn = mockIrreversible,
    };
    const registry = Registry{ .tools = &.{ mock_tool, rejecting_tool } };

    try std.testing.expectEqual(.not_registered, try validateRegisteredToolCall(.{ .allocator = std.testing.allocator }, registry, .{
        .id = "c1",
        .name = "missing",
        .arguments_json = "{}",
    }));
    try std.testing.expectEqual(.valid, try validateRegisteredToolCall(.{ .allocator = std.testing.allocator }, registry, .{
        .id = "c2",
        .name = "mock_tool",
        .arguments_json = "{}",
    }));

    const rejected = try validateRegisteredToolCall(.{ .allocator = std.testing.allocator }, registry, .{
        .id = "c3",
        .name = "rejecting_tool",
        .arguments_json = "{}",
    });
    defer switch (rejected) {
        .failure => |reason| std.testing.allocator.free(reason),
        else => {},
    };
    try std.testing.expectEqualStrings("validation rejected input", rejected.failure);
}

test "dispatchToolCall materializes unknown tool failure" {
    const result = try dispatchToolCall(.{ .allocator = std.testing.allocator }, .{}, .{
        .id = "c1",
        .name = "missing",
        .arguments_json = "{}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("unknown tool: missing", result.body);
}

test "dispatchToolCall materializes decode failure" {
    const registry = Registry{ .tools = &.{mock_tool} };
    const result = try dispatchToolCall(.{ .allocator = std.testing.allocator }, registry, .{
        .id = "c1",
        .name = "mock_tool",
        .arguments_json = "decode_error",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("invalid mock arguments", result.body);
}

test "dispatchToolCall propagates decode errors" {
    const registry = Registry{ .tools = &.{mock_tool} };
    try std.testing.expectError(error.InvalidToolArguments, dispatchToolCall(.{ .allocator = std.testing.allocator }, registry, .{
        .id = "c1",
        .name = "mock_tool",
        .arguments_json = "invalid_args_error",
    }));
}

test "dispatchToolCall materializes validate failure" {
    const rejecting_tool = Tool{
        .name = "rejecting_tool",
        .description = "Rejecting mock tool.",
        .gateway_schema = .{
            .name = "rejecting_tool",
            .description = "Rejecting mock tool.",
        },
        .decode = decodeMock,
        .validate = rejectMock,
        .call = callMock,
        .reads_only_fn = mockReadsOnly,
        .irreversible_fn = mockIrreversible,
    };
    const registry = Registry{ .tools = &.{rejecting_tool} };
    const result = try dispatchToolCall(.{ .allocator = std.testing.allocator }, registry, .{
        .id = "c1",
        .name = "rejecting_tool",
        .arguments_json = "{}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("validation rejected input", result.body);
}

test "dispatchToolCall allows and calls read-only tool" {
    const registry = Registry{ .tools = &.{mock_tool} };
    const result = try dispatchToolCall(.{ .allocator = std.testing.allocator }, registry, .{
        .id = "c1",
        .name = "mock_tool",
        .arguments_json = "{}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("mock ok", result.body);
}

test "dispatchToolCall denies non-read-only tool through gate" {
    const registry = Registry{ .tools = &.{mock_tool} };
    const result = try dispatchToolCall(.{ .allocator = std.testing.allocator }, registry, .{
        .id = "c1",
        .name = "mock_tool",
        .arguments_json = "deny",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.failure, result.status);
    try expectPermissionDeniedBody(result.body, "mock_tool", .permission_required);
}

test "dispatchToolCall downgrades ask decision to deny result" {
    const registry = Registry{ .tools = &.{mock_tool} };
    const result = try dispatchToolCall(.{
        .allocator = std.testing.allocator,
        .permission_decider = askDecision,
    }, registry, .{
        .id = "c1",
        .name = "mock_tool",
        .arguments_json = "{}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.failure, result.status);
    try expectPermissionDeniedBody(result.body, "mock_tool", .permission_required);
}

fn checkAdmitToolCallAskFailureAllocationFailures(alloc: Allocator) !void {
    const registry = Registry{ .tools = &.{mock_tool} };
    const admission = try admitToolCall(.{
        .allocator = alloc,
        .permission_decider = askDecision,
    }, registry, .{
        .id = "c1",
        .name = "mock_tool",
        .arguments_json = "{}",
    });

    switch (admission) {
        .failure => |body| {
            defer alloc.free(body);
            try expectPermissionDeniedBody(body, "mock_tool", .permission_required);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "admitToolCall cleans decoded input across ask failure-body allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAdmitToolCallAskFailureAllocationFailures,
        .{},
    );
}

test "dispatchToolCall rejects unavailable web_search before permission or execution" {
    unavailable_web_search_permission_count = 0;
    unavailable_web_search_execution_count = 0;
    const web_search = Tool{
        .name = "web_search",
        .description = "Web search dispatch fixture.",
        .gateway_schema = .{
            .name = "web_search",
            .description = "Web search dispatch fixture.",
        },
        .executor_kind = .web_search,
        .decode = decodeMock,
        .call = countWebSearchExecution,
        .reads_only_fn = mockReadsOnly,
        .irreversible_fn = mockIrreversible,
    };
    const registry = Registry{ .tools = &.{web_search} };

    const result = try dispatchToolCall(.{
        .allocator = std.testing.allocator,
        .permission_decider = countWebSearchPermission,
    }, registry, .{
        .id = "c1",
        .name = "web_search",
        .arguments_json = "{}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings(web_search_unavailable_message, result.body);
    try std.testing.expectEqual(@as(usize, 0), unavailable_web_search_permission_count);
    try std.testing.expectEqual(@as(usize, 0), unavailable_web_search_execution_count);
}

test "dispatchToolCall traces denied web_search query without secrets or execution" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "web-search-denied-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "permission");

    unavailable_web_search_permission_count = 0;
    unavailable_web_search_execution_count = 0;
    const web_search = Tool{
        .name = "web_search",
        .description = "Web search dispatch fixture.",
        .gateway_schema = .{
            .name = "web_search",
            .description = "Web search dispatch fixture.",
        },
        .executor_kind = .web_search,
        .decode = decodeMock,
        .call = countWebSearchExecution,
        .reads_only_fn = mockReadsOnly,
        .irreversible_fn = mockIrreversible,
    };
    const registry = Registry{ .tools = &.{web_search} };

    const result = try dispatchToolCall(.{
        .allocator = alloc,
        .permission_decider = denyWebSearchPermission,
        .tool_capabilities = .{ .web_search_runtime_ready = true },
    }, registry, .{
        .id = "c1",
        .name = "web_search",
        .arguments_json = "{\"query\":\"latest AI_GATEWAY_API_KEY=secret-value news\"}",
    });
    defer result.deinit(alloc);
    debug_trace.shutdown();

    try expectPermissionDeniedBody(result.body, "web_search", .user_denied);
    try std.testing.expectEqual(@as(usize, 1), unavailable_web_search_permission_count);
    try std.testing.expectEqual(@as(usize, 0), unavailable_web_search_execution_count);

    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer file.close(std.testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &file, 8192);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=web_search_denied") != null);
    try std.testing.expect(std.mem.find(u8, trace, "tool_name=web_search") != null);
    try std.testing.expect(std.mem.find(u8, trace, "query=latest AI_GATEWAY_API_KEY=[redacted] news") != null);
    try std.testing.expect(std.mem.find(u8, trace, "secret-value") == null);
    try std.testing.expect(std.mem.find(u8, trace, "result body") == null);
}

fn expectPermissionDeniedBody(body: []const u8, tool_name: []const u8, reason: core_types.ToolPermissionDenialReason) !void {
    try std.testing.expect(tool_result_errors.isToolPermissionDeniedOutput(body));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    const error_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("tool_permission_denied", error_obj.get("type").?.string);
    try std.testing.expectEqualStrings(tool_name, error_obj.get("tool_name").?.string);
    try std.testing.expectEqualStrings(@tagName(reason), error_obj.get("reason").?.string);
    try std.testing.expect(error_obj.get("denied").?.bool);
}

test "ToolResult deinit frees owned success and failure bodies" {
    var ok = ToolResult{ .success = try std.testing.allocator.dupe(u8, "ok") };
    ok.deinit(std.testing.allocator);

    var err = ToolResult{ .failure = try std.testing.allocator.dupe(u8, "err") };
    err.deinit(std.testing.allocator);
}
test "DispatchContext command runner fields default to inactive values" {
    const ctx = DispatchContext{ .allocator = std.testing.allocator };

    try std.testing.expectEqual(permission_gate.PermissionMode.ask, ctx.permission_mode);
    try std.testing.expect(ctx.cancel_flag == null);
    try std.testing.expect(ctx.output_chunk_ctx == null);
    try std.testing.expect(ctx.on_output_chunk == null);
    try std.testing.expect(ctx.background_ctx == null);
    try std.testing.expect(ctx.background_url_ctx == null);
    try std.testing.expect(ctx.on_background_url_ready == null);
    try std.testing.expect(ctx.background_log_dir == null);
    try std.testing.expect(ctx.command_artifact_dir == null);
    try std.testing.expect(ctx.command_timeout_ms == null);
    try std.testing.expect(ctx.run_command_backend == null);
    try std.testing.expect(ctx.subagent_provider == null);
    try std.testing.expect(ctx.ask_question_ctx == null);
    try std.testing.expect(ctx.ask_question_batch == null);
    try std.testing.expect(!ctx.tool_capabilities.web_search_runtime_ready);
    try std.testing.expectEqual(host.TerminalSupport.unsupported, ctx.tool_capabilities.terminal);
}

test "terminal tool capability facts follow the host support matrix" {
    const os_tags = [_]std.Target.Os.Tag{
        .macos,
        .linux,
        .windows,
        .wasi,
        .freebsd,
        .emscripten,
    };
    for (os_tags) |os_tag| {
        const expected = host.terminalSupportForOs(os_tag);
        const capabilities = ToolCapabilities.for_host(host.nativeForOs(os_tag));
        try std.testing.expectEqual(expected, capabilities.terminal);
        try std.testing.expectEqual(
            expected.isSupported(),
            capabilities.terminalAvailable(),
        );
    }
}

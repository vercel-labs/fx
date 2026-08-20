const std = @import("std");
const types = @import("../shared/types.zig");
const context_limits = @import("../config/context_limits.zig");
const elicitation = @import("../mcp/elicitation.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const access_policy = @import("../mcp/access_policy.zig");

const Allocator = std.mem.Allocator;

pub const HasToolFn = *const fn (*anyopaque, []const u8, Access) bool;
pub const ValidateToolFn = *const fn (*anyopaque, Allocator, []const u8, []const u8, Access) anyerror!ValidationResult;
pub const CallToolFn = *const fn (*anyopaque, Allocator, []const u8, []const u8, usize, CallOptions) anyerror!?CallResult;
pub const SearchToolsFn = *const fn (*anyopaque, Allocator, []const u8, usize, types.PermissionRuleSet, context_limits.Values, Access) anyerror!SearchResult;
pub const ToolSchemaFn = *const fn (*anyopaque, Allocator, []const u8, types.PermissionRuleSet, context_limits.Values, Access) anyerror!?ToolSchemaResult;
pub const FeatureCallFn = *const fn (
    *anyopaque,
    Allocator,
    FeatureRequest,
    FeatureCallOptions,
) anyerror!FeatureResult;

pub const Progress = mcp_contract.Progress;
pub const ProgressSink = mcp_contract.ProgressSink;

pub const ResolvedLiveView = struct {
    /// Generation of the MCP-specific immutable view.
    authority_generation: u64,
    view: access_policy.View,
    /// Full child authority generation for final action precommit.
    action_authority_generation: u64 = 0,

    pub fn deinit(self: *ResolvedLiveView, alloc: Allocator) void {
        self.view.deinit(alloc);
        self.* = undefined;
    }
};

const LiveViewProvider = struct {
    context: *anyopaque,
    resolve_fn: *const fn (*anyopaque, Allocator) anyerror!ResolvedLiveView,

    pub fn resolve(self: LiveViewProvider, alloc: Allocator) !ResolvedLiveView {
        return self.resolve_fn(self.context, alloc);
    }
};

pub const Access = union(enum) {
    unrestricted,
    disabled,
    scoped: struct {
        captured: *const access_policy.View,
        admission_authority_generation: u64,
        live: LiveViewProvider,
        action_authority_generation: u64 = 0,
    },

    pub fn allowsTool(self: Access, runtime_generation: u64, name: []const u8) bool {
        return switch (self) {
            .unrestricted => true,
            .disabled => false,
            .scoped => |scope| scope.captured.runtime_generation == runtime_generation and
                scope.captured.tool(name) != null,
        };
    }

    pub fn allowsFeatureServer(self: Access, runtime_generation: u64, name: []const u8) bool {
        return switch (self) {
            .unrestricted => true,
            .disabled => false,
            .scoped => |scope| scope.captured.runtime_generation == runtime_generation and
                scope.captured.features_visible and scope.captured.server(name) != null,
        };
    }
};

pub const CallOptions = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    progress: ?ProgressSink = null,
    input_responder: ?InputResponder = null,
    continuation: ?Continuation = null,
    access: Access = .unrestricted,
};

pub const InputRequired = struct {
    input_requests_json: []const u8,
    request_state_json: ?[]const u8 = null,
    legacy_retry_without_responses: bool = false,
    legacy_url_phase: LegacyUrlPhase = .consent,
    legacy_url_completion_signal: ?*const LegacyUrlCompletionSignal = null,
};

const LegacyUrlPhase = enum {
    consent,
    await_completion,
};

pub const LegacyUrlCompletionStatus = enum(u8) {
    pending,
    completed,
    cancelled,
};

/// Borrowed wake state for one legacy URL-required interaction. The runtime
/// owns its lifetime; product adapters may observe it only during a responder
/// callback and must not retain either pointer.
pub const LegacyUrlCompletionSignal = struct {
    wake: std.atomic.Value(bool) = .init(false),
    status: std.atomic.Value(LegacyUrlCompletionStatus) = .init(.pending),
};

pub const InputOrigin = struct {
    wire: elicitation.Wire,
    server_name: []const u8,
    operation: elicitation.Operation,
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    catalog_generation: u64,
    request_generation: u64,
    auth_generation: u64,
    deadline_ms: i64,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,
};

pub const InputIdentityWitness = struct {
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    catalog_generation: u64,
    auth_generation: u64,
};

pub const InputResponder = struct {
    context: *anyopaque,
    capabilities: elicitation.Capabilities = .{},
    legacy_url_manual_completion: bool = false,
    callback: *const fn (*anyopaque, Allocator, InputOrigin, InputRequired) anyerror![]const u8,
    continuation_terminal: ?*const fn (*anyopaque, Allocator, InputOrigin, ContinuationTerminal) void = null,
};

pub const LegacyUrlCompletion = struct {
    server_name: []const u8,
    elicitation_id: []const u8,
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    auth_generation: u64,
};

pub const LegacyUrlCompletionSink = struct {
    context: *anyopaque,
    /// Accepts the unique outbound ACP elicitation id. The legacy wire id is
    /// not unique across recovered connections and cannot own cleanup.
    accept: *const fn (*anyopaque, InputOrigin, []const u8) LegacyUrlAcceptTransition,
    consume: *const fn (*anyopaque, LegacyUrlCompletion) LegacyUrlConsumeTransition,
    publish: *const fn (*anyopaque, []u8) void,
};

pub const LegacyUrlConsumeTransition = union(enum) {
    missing,
    consumed: ?[]u8,
};

pub const LegacyUrlAcceptStatus = enum {
    awaiting_completion,
    completed,
};

pub const LegacyUrlAcceptTransition = union(enum) {
    missing,
    awaiting_completion,
    completed: []u8,
};

pub const ContinuationTerminal = enum {
    completed,
    abandoned,
};

pub const Continuation = struct {
    input_responses_json: []const u8,
    request_state_json: ?[]const u8 = null,
};

pub const FeatureAction = enum {
    resource_list,
    resource_templates,
    resource_read,
    prompt_list,
    prompt_get,
    prompt_complete,
    resource_complete,
};

pub const FeatureArgument = struct {
    name: []const u8,
    value: []const u8,
};

pub const FeatureRequest = struct {
    action: FeatureAction,
    server_name: []const u8,
    identity: []const u8 = "",
    argument_name: []const u8 = "",
    value: []const u8 = "",
    arguments_json: []const u8 = "{}",
    context_arguments: []const FeatureArgument = &.{},
};

pub const FeatureCallOptions = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    input_responder: ?InputResponder = null,
    output_limit_bytes: usize,
    access: Access = .unrestricted,
};

pub const FeatureResult = struct {
    model_output: []u8,

    pub fn deinit(self: *FeatureResult, alloc: Allocator) void {
        alloc.free(self.model_output);
        self.* = undefined;
    }
};

pub const CallStatus = enum {
    success,
    tool_failure,
    protocol_failure,
    input_required,
};

pub const CallResult = struct {
    model_output: []const u8,
    status: CallStatus = .success,
    input_required: ?InputRequired = null,

    pub fn deinit(self: *CallResult, alloc: Allocator) void {
        alloc.free(self.model_output);
        self.deinitInputRequired(alloc);
        self.* = undefined;
    }

    pub fn takeModelOutput(self: *CallResult, alloc: Allocator) []const u8 {
        const model_output = self.model_output;
        self.deinitInputRequired(alloc);
        self.* = undefined;
        return model_output;
    }

    fn deinitInputRequired(self: *CallResult, alloc: Allocator) void {
        if (self.input_required) |required| {
            alloc.free(required.input_requests_json);
            if (required.request_state_json) |state| alloc.free(state);
        }
    }
};

pub const ValidationResult = union(enum) {
    valid,
    invalid: []const u8,
    not_available,
};

pub const SearchResult = struct {
    model_output: []u8,
    notice: ?[]u8 = null,

    pub fn deinit(self: *SearchResult, alloc: Allocator) void {
        alloc.free(self.model_output);
        if (self.notice) |notice| alloc.free(notice);
        self.* = undefined;
    }
};

pub const ToolSchemaResult = union(enum) {
    selected: Selected,
    rejected: Payload,

    pub const Selected = struct {
        name: []u8,
        description: []u8,
        input_schema_json: []u8,
        notice: ?[]u8 = null,
    };

    pub const Payload = struct {
        model_output: []u8,
        notice: ?[]u8 = null,
    };

    pub fn deinit(self: *ToolSchemaResult, alloc: Allocator) void {
        switch (self.*) {
            .selected => |payload| {
                alloc.free(payload.name);
                alloc.free(payload.description);
                alloc.free(payload.input_schema_json);
                if (payload.notice) |notice| alloc.free(notice);
            },
            .rejected => |payload| {
                alloc.free(payload.model_output);
                if (payload.notice) |notice| alloc.free(notice);
            },
        }
        self.* = undefined;
    }
};

pub const RuntimeCapabilities = struct {
    context: ?*anyopaque = null,
    has_tool: ?HasToolFn = null,
    validate_tool: ?ValidateToolFn = null,
    call_tool: ?CallToolFn = null,
    tool_schema: ?ToolSchemaFn = null,
    access: Access = .unrestricted,
};

pub fn validateAdvertisedDynamicTool(
    input: AvailabilityInput,
    arena: Allocator,
    name: []const u8,
    arguments_json: []const u8,
) !ValidationResult {
    if (input.is_registered_tool) return .not_available;
    const context = input.runtime.context orelse return .not_available;
    const validate_tool = input.runtime.validate_tool orelse return .not_available;
    return try validate_tool(context, arena, name, arguments_json, input.runtime.access);
}

const AvailabilityInput = struct {
    is_registered_tool: bool,
    advertised_dynamic_tool_names: []const []const u8,
    runtime: RuntimeCapabilities,
};

const CallInput = struct {
    advertised_dynamic_tool_names: []const []const u8,
    runtime: RuntimeCapabilities,
    max_tool_result_bytes: usize,
    options: CallOptions = .{},
};
pub fn isAdvertisedDynamicToolName(
    advertised_dynamic_tool_names: []const []const u8,
    name: []const u8,
) bool {
    for (advertised_dynamic_tool_names) |advertised| {
        if (std.mem.eql(u8, advertised, name)) return true;
    }
    return false;
}

pub fn isAvailableDynamicTool(input: AvailabilityInput, name: []const u8) bool {
    if (input.is_registered_tool) return false;
    if (!isAdvertisedDynamicToolName(input.advertised_dynamic_tool_names, name)) return false;
    const context = input.runtime.context orelse return false;
    const has_tool = input.runtime.has_tool orelse return false;
    return has_tool(context, name, input.runtime.access);
}

fn callAdvertisedDynamicTool(
    input: CallInput,
    arena: Allocator,
    name: []const u8,
    arguments_json: []const u8,
) !?CallResult {
    if (!isAdvertisedDynamicToolName(input.advertised_dynamic_tool_names, name)) return null;
    const context = input.runtime.context orelse return null;
    const call_tool = input.runtime.call_tool orelse return null;
    return try call_tool(
        context,
        arena,
        name,
        arguments_json,
        input.max_tool_result_bytes,
        input.options,
    );
}
pub fn notSelectedOutput(arena: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "Dynamic MCP tool not selected for this model step: {s}. Use mcp_search_tools and mcp_select_tool first; the selected tool can be called on the next model step after its schema is advertised.",
        .{name},
    );
}
test "MCP advertised dynamic tool executes only through its supplied capability" {
    var fixture = Fixture.CountingContext{};
    const advertised = [_][]const u8{"mcp_fs_read"};
    const input = CallInput{
        .advertised_dynamic_tool_names = &advertised,
        .runtime = .{
            .context = @ptrCast(&fixture),
            .call_tool = Fixture.callCounting,
        },
        .max_tool_result_bytes = 1024,
    };

    const result = (try callAdvertisedDynamicTool(
        input,
        std.testing.allocator,
        "mcp_fs_read",
        "{}",
    )).?;
    defer std.testing.allocator.free(result.model_output);

    try std.testing.expectEqualStrings("mcp ok", result.model_output);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect((try callAdvertisedDynamicTool(
        input,
        std.testing.allocator,
        "mcp_other",
        "{}",
    )) == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

const Fixture = struct {
    const CountingContext = struct {
        calls: usize = 0,
    };

    fn callCounting(raw_context: *anyopaque, arena: Allocator, _: []const u8, _: []const u8, _: usize, _: CallOptions) anyerror!?CallResult {
        const context: *CountingContext = @ptrCast(@alignCast(raw_context));
        context.calls += 1;
        return .{ .model_output = try arena.dupe(u8, "mcp ok") };
    }
};

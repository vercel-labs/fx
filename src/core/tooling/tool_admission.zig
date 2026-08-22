const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const background_runtime = @import("../background/background_runtime.zig");
const vision_contracts = @import("../agent/runtime/vision_contracts.zig");
const command_admission = @import("../permissions/command_admission.zig");
const command_environment = @import("../execution/command_environment.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const command_policy = @import("command_policy.zig");
const file_mutation = @import("file_mutation.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const diff_mod = @import("../output/diff.zig");
const pathing = @import("../workspace/pathing.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permissions = @import("../permissions/permissions.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const tool_presentation = @import("tool_presentation.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolPermissionDecision = types.ToolPermissionDecision;
const BackgroundRuntime = background_runtime.BackgroundRuntime;
const WorkerRuntime = worker_runtime.WorkerRuntime;

pub const HostSandboxDefault = enum {
    none,
    allow_sandboxed,
    prompt,
};

pub const SessionPermissionStateProvider = struct {
    context: *anyopaque,
    snapshot_fn: *const fn (
        context: *anyopaque,
        alloc: Allocator,
    ) anyerror!session_permission_state.State,

    pub fn snapshot(
        self: SessionPermissionStateProvider,
        alloc: Allocator,
    ) !session_permission_state.State {
        return self.snapshot_fn(self.context, alloc);
    }
};

/// Borrowed capabilities required for permission admission. The leaf never
/// owns, persists, or extends any referenced runtime state.
pub const Input = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    permission_review_turn: ?permission_auto_classifier.ReviewTurnContext = null,
    permission_grants: []const PermissionGrant,
    permission_rules: types.PermissionRuleSet,
    session_permission_state: ?*const session_permission_state.State = null,
    session_permission_state_provider: ?SessionPermissionStateProvider = null,
    tool_registry: tool_dispatch.Registry,
    worker: *WorkerRuntime,
    permission_prompter: ?permission_prompter.Prompter = null,
    background: *BackgroundRuntime,
    advertised_dynamic_tool_names: []const []const u8,
    mcp_runtime: tool_mcp_runtime.RuntimeCapabilities,
    context_limits: context_limits.Values = .{},
    auto_classifier: permission_auto_classifier.Classifier = .disabled(),
    host_sandbox_default: HostSandboxDefault = .none,
};

fn registeredTool(input: Input, name: []const u8) ?*const tool_dispatch.Tool {
    return input.tool_registry.lookup(name);
}

fn accessScope(input: Input) workspace_access.AccessScope {
    return input.access_scope orelse workspace_access.AccessScope.primaryOnly(input.workspace_root);
}

fn permissionTargetKind(registry: tool_dispatch.Registry, name: []const u8) permissions.PermissionTargetKind {
    return if (registry.lookup(name)) |tool| tool.permission_target_kind else .none;
}

fn toolHasPermissionContract(input: Input, name: []const u8) bool {
    return registeredTool(input, name) != null;
}

fn toolRequiresApproval(input: Input, name: []const u8) bool {
    return if (registeredTool(input, name)) |spec| spec.requires_approval else false;
}

fn registeredTerminalCallReadsOnly(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !bool {
    const tool = registeredTool(input, call.name) orelse return false;
    if (tool.executor_kind != .terminal) return false;
    const decode_ctx = tool_dispatch.DispatchContext{
        .allocator = arena,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
    };
    const decoded = try tool.decode(decode_ctx, call.arguments_json);
    return switch (decoded) {
        .failure => |reason| blk: {
            arena.free(reason);
            break :blk false;
        },
        .input => |tool_input| blk: {
            defer tool_input.deinit(arena);
            if (tool.validate) |validate| {
                if (try validate(decode_ctx, tool_input)) |reason| {
                    arena.free(reason);
                    break :blk false;
                }
            }
            break :blk tool.reads_only_fn(tool_input);
        },
    };
}

fn toolApprovalPolicy(input: Input, name: []const u8) tool_dispatch.ApprovalPolicy {
    return if (registeredTool(input, name)) |spec| spec.approval_policy else .standard;
}

pub fn callUsesCommandAuthority(
    registry: tool_dispatch.Registry,
    arena: Allocator,
    call: ToolCall,
) !bool {
    const tool = registry.lookup(call.name) orelse return false;
    if (tool.executor_kind == .run_command) return true;
    const expected_action = tool.captured_command_action orelse return false;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const action = tool_args.optionalStringArg(args, "action") orelse return false;
    return std.mem.eql(u8, action, expected_action);
}

fn isRunCommandCall(input: Input, arena: Allocator, call: ToolCall) !bool {
    return callUsesCommandAuthority(input.tool_registry, arena, call);
}

fn permissionNameForCall(input: Input, arena: Allocator, call: ToolCall) ![]const u8 {
    return if (try isRunCommandCall(input, arena, call)) "run_command" else call.name;
}

fn permissionTargetKindForCall(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !permissions.PermissionTargetKind {
    return if (try isRunCommandCall(input, arena, call))
        .command_cwd
    else
        permissionTargetKind(input.tool_registry, call.name);
}

fn registeredWebSearchTarget(input: Input, name: []const u8) ?[]const u8 {
    const spec = registeredTool(input, name) orelse return null;
    if (spec.executor_kind != .web_search) return null;
    return spec.name;
}

pub const FileMutationPreflight = union(enum) {
    allowed: file_mutation_contract.FileExecutionAuthorization,
    prompt: file_mutation_contract.FileExecutionAuthorization,
    permission_required: file_mutation_contract.FileExecutionAuthorization,
    policy_denied,
    tool_failure: []const u8,
};

pub const FileMutationPreflightRequest = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    permission_rules: types.PermissionRuleSet,
    session_grants: []const PermissionGrant = &.{},
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant = &.{},
    can_prompt: bool,
    session_permission_state: ?*const session_permission_state.State = null,
    prepare_permission_identity: bool = false,
};

pub const FileMutationPreparationRequest = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
};

pub const PreparedFileMutationCall = struct {
    call_id: []u8,
    arguments_hash: types.ContentHash,
    workspace_root: []u8,
    input: file_mutation_contract.FileMutationInput,
    targets: file_mutation_contract.ResolvedFileMutationTargets,
    workspace_root_owned: bool = true,
    call_id_owned: bool = true,
    input_owned: bool = true,

    pub fn targetPath(self: PreparedFileMutationCall) []const u8 {
        return self.targets.canonical_target_path;
    }

    pub fn externalActionIdentity(
        self: PreparedFileMutationCall,
    ) ?FileMutationActionIdentity {
        if (self.targets.anchor.scope != .external) return null;
        return FileMutationActionIdentity.init(
            self.targets.canonical_target_path,
            self.input,
        );
    }

    pub fn deinit(self: *PreparedFileMutationCall, alloc: Allocator) void {
        if (self.input_owned) {
            self.input.deinit(alloc);
            self.input_owned = false;
        }
        self.targets.deinit(alloc);
        if (self.call_id_owned) {
            alloc.free(self.call_id);
            self.call_id_owned = false;
        }
        if (self.workspace_root_owned) {
            alloc.free(self.workspace_root);
            self.workspace_root_owned = false;
        }
    }

    fn takeInput(self: *PreparedFileMutationCall) file_mutation_contract.FileMutationInput {
        std.debug.assert(self.input_owned);
        self.input_owned = false;
        return self.input;
    }

    fn takeTargets(self: *PreparedFileMutationCall) file_mutation_contract.ResolvedFileMutationTargets {
        std.debug.assert(self.targets.owns_memory);
        const targets = self.targets;
        self.targets.relinquish();
        return targets;
    }
};

/// Canonical, provider-call-ID-independent identity for one external file
/// mutation request. The fixed-size value is safe to retain for one agent turn
/// without retaining decoded tool inputs or filesystem proof allocations.
pub const FileMutationActionIdentity = struct {
    kind: file_mutation_contract.Kind,
    target_hash: types.ContentHash,
    first_argument_hash: types.ContentHash,
    second_argument_hash: types.ContentHash,

    fn init(
        canonical_target_path: []const u8,
        input: file_mutation_contract.FileMutationInput,
    ) FileMutationActionIdentity {
        var identity: FileMutationActionIdentity = .{
            .kind = std.meta.activeTag(input),
            .target_hash = hashIdentityField(canonical_target_path),
            .first_argument_hash = undefined,
            .second_argument_hash = undefined,
        };
        switch (input) {
            .write => |write| {
                identity.first_argument_hash = hashIdentityField(write.content);
                identity.second_argument_hash = hashIdentityField(
                    "write-file-no-second-argument",
                );
            },
            .edit => |edit| {
                identity.first_argument_hash = hashIdentityField(edit.old_string);
                identity.second_argument_hash = hashIdentityField(edit.new_string);
            },
        }
        return identity;
    }

    pub fn eql(
        a: FileMutationActionIdentity,
        b: FileMutationActionIdentity,
    ) bool {
        return std.meta.eql(a, b);
    }
};

fn hashIdentityField(value: []const u8) types.ContentHash {
    var digest: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return digest;
}

pub const FileMutationPreparation = union(enum) {
    prepared: PreparedFileMutationCall,
    tool_failure: []const u8,
};

const FileMutationDecodeResult = union(enum) {
    input: file_mutation_contract.FileMutationInput,
    failure: []const u8,
};

var file_mutation_decode_count: usize = 0;
var file_mutation_resolution_count: usize = 0;

fn decodeFileMutationInput(
    arena: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !FileMutationDecodeResult {
    const tool = registry.lookup(call.name) orelse return .{
        .failure = try arena.dupe(
            u8,
            "file mutation tool is not registered",
        ),
    };
    const kind: file_mutation_contract.Kind = switch (tool.executor_kind) {
        .write_file => .write,
        .edit_file => .edit,
        else => return .{ .failure = try arena.dupe(
            u8,
            "unsupported file mutation tool",
        ) },
    };
    const take_input = tool.take_file_mutation_input_fn orelse return .{
        .failure = try arena.dupe(
            u8,
            "file mutation tool registration is missing canonical input ownership",
        ),
    };

    if (builtin.is_test) file_mutation_decode_count += 1;
    const decode_ctx = tool_dispatch.DispatchContext{ .allocator = arena };
    const decoded = try tool.decode(decode_ctx, call.arguments_json);
    return switch (decoded) {
        .failure => |reason| .{ .failure = reason },
        .input => |tool_input| blk: {
            var tool_input_owned = true;
            defer if (tool_input_owned) tool_input.deinit(arena);
            if (tool.validate) |validate| {
                if (try validate(decode_ctx, tool_input)) |reason| {
                    break :blk .{ .failure = reason };
                }
            }
            var input = take_input(tool_input, arena);
            tool_input_owned = false;
            if (std.meta.activeTag(input) != kind) {
                input.deinit(arena);
                break :blk .{ .failure = try arena.dupe(
                    u8,
                    "file mutation tool registration returned mismatched input kind",
                ) };
            }
            break :blk .{ .input = input };
        },
    };
}

pub fn prepareFileMutationCall(
    alloc: Allocator,
    call: ToolCall,
    request: FileMutationPreparationRequest,
) !FileMutationPreparation {
    var input = switch (try decodeFileMutationInput(
        alloc,
        request.tool_registry,
        call,
    )) {
        .failure => |reason| return .{ .tool_failure = reason },
        .input => |value| value,
    };
    var input_owned = true;
    defer if (input_owned) input.deinit(alloc);

    if (builtin.is_test) file_mutation_resolution_count += 1;
    var targets = switch (try permissions.prepareFileMutationTargets(
        alloc,
        request.workspace_root,
        input,
    )) {
        .target_resolution_failure => |failure| return .{ .tool_failure = try std.fmt.allocPrint(
            alloc,
            "file mutation target resolution failed: {s}",
            .{@tagName(failure)},
        ) },
        .prepared => |value| value,
    };
    errdefer targets.deinit(alloc);

    const workspace_root = try alloc.dupe(u8, request.workspace_root);
    errdefer alloc.free(workspace_root);
    const call_id = try alloc.dupe(u8, call.id);
    var arguments_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    arguments_hasher.update(call.arguments_json);
    input_owned = false;
    return .{ .prepared = .{
        .call_id = call_id,
        .arguments_hash = arguments_hasher.finalResult(),
        .workspace_root = workspace_root,
        .input = input,
        .targets = targets,
    } };
}

pub fn preflightPreparedFileMutation(
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    request: FileMutationPreflightRequest,
) !FileMutationPreflight {
    defer prepared.deinit(arena);

    const expected_kind: file_mutation_contract.Kind =
        if (std.mem.eql(u8, call.name, "write_file"))
            .write
        else if (std.mem.eql(u8, call.name, "edit_file"))
            .edit
        else
            return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    if (std.meta.activeTag(prepared.input) != expected_kind or
        !std.mem.eql(u8, prepared.call_id, call.id) or
        !std.mem.eql(u8, prepared.workspace_root, request.workspace_root))
    {
        return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    }
    var arguments_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    arguments_hasher.update(call.arguments_json);
    if (!std.mem.eql(u8, &prepared.arguments_hash, &arguments_hasher.finalResult())) {
        return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    }

    var input = prepared.takeInput();
    var input_owned = true;
    defer if (input_owned) input.deinit(arena);
    var targets = prepared.takeTargets();

    const policy_result = if (request.permission_mode == .yolo)
        try permissions.authorizePreparedFileMutationTargets(arena, &targets)
    else
        try permissions.evaluatePreparedFileMutationTargetsInScope(
            arena,
            request.access_scope orelse workspace_access.AccessScope.primaryOnly(request.workspace_root),
            expected_kind,
            &targets,
            request.permission_mode,
            request.permission_rules,
            request.session_grants,
            request.local_grants,
        );
    var policy_targets = switch (policy_result) {
        .target_resolution_failure => |failure| {
            return .{ .tool_failure = try std.fmt.allocPrint(
                arena,
                "file mutation target resolution failed: {s}",
                .{@tagName(failure)},
            ) };
        },
        .policy_denied => return .policy_denied,
        .evaluated => |evaluated| evaluated,
    };
    var policy_targets_owned = true;
    defer if (policy_targets_owned) policy_targets.deinitOwned(arena);

    const edit_prompt_required = policy_targets.prompt_required;
    const equality_prompt_required =
        request.permission_mode != .yolo and
        policy_targets.items[0].expected_identity != null and
        try fileMutationEqualityDisclosureRequiresPrompt(
            arena,
            request,
            policy_targets.canonical_target_path,
        );

    var authorization: file_mutation_contract.FileExecutionAuthorization = .{
        .input = input,
        .policy_targets = policy_targets,
        .read_disclosure_required = equality_prompt_required,
    };
    const state_may_decide = if (request.session_permission_state) |state|
        state.rules.items.len > 0
    else
        false;
    if (!edit_prompt_required and
        !equality_prompt_required and
        !state_may_decide and
        !request.prepare_permission_identity)
    {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .allowed = authorization };
    }
    if (!request.can_prompt and edit_prompt_required and equality_prompt_required) {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .permission_required = authorization };
    }

    authorization.prepared = switch (try file_mutation.prepareResolvedTarget(
        arena,
        call,
        input,
        policy_targets,
    )) {
        .semantic_failure => |reason| return .{ .tool_failure = reason },
        .prepared => |value| value,
    };
    if (request.session_permission_state) |state| {
        const key = permissionStateKeyForPreparedFileMutation(
            arena,
            authorization.prepared.?,
        ) catch null;
        if (key) |resolved_key| switch (session_permission_state.decide(state.*, resolved_key)) {
            .deny => return .policy_denied,
            .allow => {
                input_owned = false;
                policy_targets_owned = false;
                return .{ .allowed = authorization };
            },
            .unresolved => {},
        };
    }
    const prompt_required = if (file_mutation_contract.preparedMutationIsNoop(
        authorization.prepared.?,
    ))
        equality_prompt_required
    else
        edit_prompt_required;
    if (!prompt_required or request.prepare_permission_identity) {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .allowed = authorization };
    }
    authorization.approval_intent = if (file_mutation_contract.preparedMutationIsNoop(
        authorization.prepared.?,
    ))
        .equality_disclosure
    else
        .mutation;
    if (!request.can_prompt) {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .permission_required = authorization };
    }
    authorization.grant_offer = permissions.structuredFileGrantOffer(
        arena,
        request.workspace_root,
        call.name,
        policy_targets,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedFileGrantOffer,
        error.ScopeProjectionTooLarge,
        => return .{ .tool_failure = "file mutation permission scope could not be represented safely" },
    };
    input_owned = false;
    policy_targets_owned = false;
    return .{ .prompt = authorization };
}

pub fn preflightFileMutation(
    arena: Allocator,
    call: ToolCall,
    request: FileMutationPreflightRequest,
) !FileMutationPreflight {
    var prepared = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = request.tool_registry,
        .workspace_root = request.workspace_root,
    })) {
        .tool_failure => |reason| return .{ .tool_failure = reason },
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);
    return preflightPreparedFileMutation(arena, call, &prepared, request);
}

fn fileMutationEqualityDisclosureRequiresPrompt(
    arena: Allocator,
    request: FileMutationPreflightRequest,
    target_path: []const u8,
) !bool {
    return switch (try permissions.ruleDecisionFor(
        arena,
        request.permission_rules,
        request.workspace_root,
        "read_file",
        target_path,
        permissionTargetKind(request.tool_registry, "read_file"),
    )) {
        .allow, .none => false,
        .deny => true,
        .ask => !permissions.sessionGrantAllowed(
            request.session_grants,
            "read_file",
            target_path,
        ) and !permissions.sessionGrantAllowed(
            request.local_grants,
            "read_file",
            target_path,
        ),
    };
}

const FileMutationAdmission = union(enum) {
    resolved: command_admission.PermissionOutcome,
    prompt: struct {
        authorization: file_mutation_contract.FileExecutionAuthorization,
    },
};

fn fileMutationTargetsContainConfiguredAsk(
    targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) bool {
    for (targets.items) |target| {
        if (target.rule == .ask and !target.session_grant_allowed) return true;
    }
    return false;
}

fn fileMutationAuthorizationMayUseAutoReview(
    authorization: file_mutation_contract.FileExecutionAuthorization,
) bool {
    if (authorization.prepared == null) return false;
    const intent = authorization.approval_intent orelse return false;
    return intent == .mutation and
        !fileMutationTargetsContainConfiguredAsk(authorization.policy_targets);
}

fn fileMutationAuthorizationMayBypassAutoReview(
    input: Input,
    authorization: file_mutation_contract.FileExecutionAuthorization,
) bool {
    const prepared = authorization.prepared orelse return false;
    const intent = authorization.approval_intent orelse return false;
    const target_path = authorization.policy_targets.canonical_target_path;
    const target_is_reversible = accessScope(input).contains(target_path) or
        std.meta.activeTag(prepared.preimage) == .absent;
    return intent == .mutation and
        !authorization.read_disclosure_required and
        target_is_reversible and
        !sensitiveAutoWriteTarget(target_path) and
        !fileMutationTargetsContainConfiguredAsk(authorization.policy_targets);
}

fn sensitiveAutoWriteTarget(path: []const u8) bool {
    return pathContainsComponentSequence(path, &.{ ".git", "hooks" }) or
        pathContainsComponentSequence(path, &.{ ".git", "config" }) or
        pathContainsComponentSequence(path, &.{ ".git", "config.worktree" }) or
        pathContainsComponentSequence(path, &.{ ".ssh", "authorized_keys" }) or
        pathContainsComponentSequence(path, &.{ ".ssh", "config" }) or
        pathContainsComponentSequence(path, &.{ "Library", "LaunchAgents" }) or
        pathContainsComponentSequence(path, &.{ "Library", "LaunchDaemons" }) or
        pathContainsComponentSequence(path, &.{ ".config", "autostart" }) or
        pathContainsComponentSequence(path, &.{ ".config", "fish", "config.fish" }) or
        pathContainsComponentSequence(path, &.{".zshrc"}) or
        pathContainsComponentSequence(path, &.{".bashrc"}) or
        pathContainsComponentSequence(path, &.{".bash_profile"}) or
        pathContainsComponentSequence(path, &.{".profile"});
}

fn pathContainsComponentSequence(
    path: []const u8,
    expected: []const []const u8,
) bool {
    if (expected.len == 0) return false;
    var matched: usize = 0;
    var index: usize = 0;
    while (index < path.len) {
        while (index < path.len and std.fs.path.isSep(path[index])) : (index += 1) {}
        const start = index;
        while (index < path.len and !std.fs.path.isSep(path[index])) : (index += 1) {}
        if (start == index) break;
        const component = path[start..index];
        if (std.mem.eql(u8, component, expected[matched])) {
            matched += 1;
            if (matched == expected.len) return true;
        } else {
            matched = if (std.mem.eql(u8, component, expected[0])) 1 else 0;
        }
    }
    return false;
}

fn reversibleStructuredToolMayBypassAutoReview(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !bool {
    const tool = registeredTool(input, call.name) orelse return false;
    if (tool.executor_kind != .create_folder) return false;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const path_arg = try tool_args.requiredStringArg(args, "path");
    const target_path = accessScope(input).resolvePath(
        arena,
        path_arg,
        .create,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return !sensitiveAutoWriteTarget(target_path);
}

fn fileMutationPermissionTargets(
    arena: Allocator,
    policy_targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) ![]permissions.PermissionCallTarget {
    const targets = try arena.alloc(
        permissions.PermissionCallTarget,
        policy_targets.items.len,
    );
    for (policy_targets.items, 0..) |item, index| {
        targets[index] = .{
            .role = @tagName(item.kind),
            .path = try arena.dupe(
                u8,
                policy_targets.permissionPath(item),
            ),
        };
    }
    return targets;
}

fn schemaForReview(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    is_dynamic_tool: bool,
) !?[]const u8 {
    if (!is_dynamic_tool) return null;
    const context = input.mcp_runtime.context orelse return null;
    const tool_schema = input.mcp_runtime.tool_schema orelse return null;
    const result = (try tool_schema(
        context,
        arena,
        call.name,
        input.permission_rules,
        input.context_limits,
        input.mcp_runtime.access,
    )) orelse return null;
    return switch (result) {
        .selected => |payload| payload.model_output,
        .rejected => null,
    };
}

fn reviewRequestForCall(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
    is_dynamic_tool: bool,
    file_authorization: ?file_mutation_contract.FileExecutionAuthorization,
) !permission_auto_classifier.ReviewRequest {
    const action: permission_auto_classifier.Action =
        if (file_authorization) |authorization| blk: {
            const prepared = authorization.prepared orelse
                return error.FileMutationNotPrepared;
            break :blk .{ .file_mutation = .{
                .tool_name = call.name,
                .display_path = prepared.display_path,
                .preimage = switch (prepared.preimage) {
                    .absent => .absent,
                    .present => .present,
                },
                .additions = prepared.review.additions,
                .deletions = prepared.review.deletions,
                .review = prepared.review,
            } };
        } else if (try isRunCommandCall(input, arena, call)) blk: {
            const command = try runCommandContext(input, arena, call);
            break :blk .{ .command = .{
                .command = command.command,
                .resolved_cwd = command.resolved_cwd,
                .background = command.background,
                .target_os = command.target_os,
            } };
        } else blk: {
            break :blk .{ .tool = .{
                .tool_name = call.name,
                .arguments_json = call.arguments_json,
                .schema_json = try schemaForReview(
                    input,
                    arena,
                    call,
                    is_dynamic_tool,
                ),
                .schema_required = is_dynamic_tool,
            } };
        };
    return .{
        .workspace_root = input.workspace_root,
        .review_turn = input.permission_review_turn orelse
            return error.PermissionReviewContextUnavailable,
        .targets = targets,
        .action = action,
        .escalation_reason = if (file_authorization != null)
            "tool_requires_approval"
        else if (try isRunCommandCall(input, arena, call))
            "command_requires_approval"
        else if (is_dynamic_tool)
            "selected_dynamic_mcp_requires_approval"
        else
            "tool_requires_approval",
    };
}

/// An unavailable or invalid automatic review never executes anything. It is
/// returned to the primary model as the same recoverable auto denial as ASK.
fn traceReviewerUnavailable(call: ToolCall) void {
    debug_trace.logf(
        "permission",
        "event=auto_review_result tool_name={s} decision=deny reason=reviewer_unavailable fallback=agent_replan call_id={s}",
        .{ call.name, call.id },
    );
}

fn reviewerUnavailableOutcome(call: ToolCall) command_admission.PermissionOutcome {
    traceReviewerUnavailable(call);
    return .{
        .decision = .deny,
        .denial_reason = .auto_denied,
    };
}

const UnresolvedAutoDisposition = enum {
    replan,
    review,
};

fn unresolved_command_disposition(command: []const u8) UnresolvedAutoDisposition {
    return if (command_policy.destructive_effect_for(command) != null)
        .replan
    else
        .review;
}

fn unresolved_tool_disposition(kind: tool_dispatch.ExecutorKind) UnresolvedAutoDisposition {
    return if (kind == .delete_file) .replan else .review;
}

fn deterministic_auto_replan_outcome(call: ToolCall) command_admission.PermissionOutcome {
    debug_trace.logf(
        "permission",
        "event=deterministic_auto_disposition tool_name={s} source=deterministic_policy disposition=replan reviewer_transport=false call_id={s}",
        .{ call.name, call.id },
    );
    return .{
        .decision = .deny,
        .denial_reason = .auto_denied,
    };
}

/// Maps every non-allow automatic review to one recoverable denial. A
/// separately selected human-approval phase bypasses automatic review below.
fn nonAllowAutoReviewOutcome(
    review: permission_auto_classifier.ParseOutcome,
) ?command_admission.PermissionOutcome {
    return switch (review) {
        .invalid => .{
            .decision = .deny,
            .denial_reason = .auto_denied,
        },
        .valid => |result| switch (result.decision) {
            .allow => null,
            .ask => .{
                .decision = .deny,
                .denial_reason = .auto_denied,
                .auto_review_result = result,
            },
        },
    };
}

fn isHumanApprovalPhase(input: Input) bool {
    const review_turn = input.permission_review_turn orelse return false;
    return review_turn.auto_permission_phase == .human_approval;
}

fn automaticReviewOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
    is_dynamic_tool: bool,
    file_authorization: ?file_mutation_contract.FileExecutionAuthorization,
) !command_admission.PermissionOutcome {
    if (isHumanApprovalPhase(input)) return .{
        .decision = .permission_required,
        .denial_reason = .permission_required,
    };
    if (!input.auto_classifier.enabled()) return reviewerUnavailableOutcome(call);
    if (input.permission_review_turn == null) return reviewerUnavailableOutcome(call);

    const request = try reviewRequestForCall(
        input,
        arena,
        call,
        targets,
        is_dynamic_tool,
        file_authorization,
    );
    const review = try runAutomaticReview(input, arena, call, request);
    if (nonAllowAutoReviewOutcome(review)) |blocked| return blocked;
    var outcome = if (file_authorization) |authorization|
        command_admission.PermissionOutcome{
            .decision = .once,
            .execution_authority = .{
                .file_mutation = authorization,
            },
        }
    else
        try permissionOutcomeForDecision(
            input,
            arena,
            call,
            .once,
            .auto_classifier,
        );
    outcome.auto_review_result = review.valid;
    return outcome;
}

fn runAutomaticReview(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    request: permission_auto_classifier.ReviewRequest,
) !permission_auto_classifier.ParseOutcome {
    const started_ms = io_mod.milliTimestamp();
    debug_trace.logf(
        "permission",
        "event=auto_review_start tool_name={s} action_kind={s} call_id={s}",
        .{ call.name, @tagName(std.meta.activeTag(request.action)), call.id },
    );
    const review = input.auto_classifier.review(arena, request) catch |err| {
        debug_trace.logf(
            "permission",
            "event=auto_review_result tool_name={s} decision=cancelled_or_error fallback_reason={s} elapsed_ms={d} execution_started=false call_id={s}",
            .{ call.name, @errorName(err), io_mod.milliTimestamp() - started_ms, call.id },
        );
        return err;
    };
    switch (review) {
        .valid => |result| debug_trace.logf(
            "permission",
            "event=auto_review_result tool_name={s} decision={s} fallback_reason=none elapsed_ms={d} execution_started=false call_id={s}",
            .{ call.name, @tagName(result.decision), io_mod.milliTimestamp() - started_ms, call.id },
        ),
        .invalid => debug_trace.logf(
            "permission",
            "event=auto_review_result tool_name={s} decision=deny denial_reason=auto_denied fallback_reason=invalid_or_unavailable recovery=agent_replan elapsed_ms={d} execution_started=false call_id={s}",
            .{ call.name, io_mod.milliTimestamp() - started_ms, call.id },
        ),
    }
    return review;
}

fn resolveOrdinaryPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
    is_dynamic_tool: bool,
    permission_mode: PermissionMode,
) !command_admission.PermissionOutcome {
    const command_call = try isRunCommandCall(input, arena, call);
    if (command_call) {
        const default_outcome = defaultRunCommandPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
        );
        if (default_outcome.execution_authority != null) return default_outcome;
    }
    if (toolApprovalPolicy(input, call.name) == .ask_only) {
        return if (permission_mode == .auto)
            ordinaryPermissionOutcome(.once)
        else
            .{ .decision = .permission_required };
    }
    if (permission_mode == .auto and
        !command_call and
        !is_dynamic_tool and
        try registeredTerminalCallReadsOnly(input, arena, call))
    {
        return ordinaryPermissionOutcome(.once);
    }
    if (!command_call and !toolRequiresApproval(input, call.name) and !is_dynamic_tool) {
        return ordinaryPermissionOutcome(.once);
    }

    if (permission_mode == .auto) {
        if (command_call) {
            const command = try runCommandContext(input, arena, call);
            if (try command_effect.knownReversibleAutoCommand(
                arena,
                command.command,
                command.background,
            )) {
                return shellPermissionOutcome(
                    command,
                    .once,
                    .auto_mode,
                );
            }
            if (!isHumanApprovalPhase(input) and
                unresolved_command_disposition(command.command) == .replan)
            {
                return deterministic_auto_replan_outcome(call);
            }
        }
        return automaticReviewOutcome(
            input,
            arena,
            call,
            targets,
            is_dynamic_tool,
            null,
        );
    }

    return .{ .decision = .permission_required };
}

fn resolveFileMutationAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !FileMutationAdmission {
    return resolveFileMutationPreflightAdmission(
        input,
        arena,
        call,
        permission_mode,
        try preflightFileMutation(
            arena,
            call,
            fileMutationPreflightRequest(input, permission_mode, local_grants),
        ),
    );
}

fn resolvePreparedFileMutationAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !FileMutationAdmission {
    return resolveFileMutationPreflightAdmission(
        input,
        arena,
        call,
        permission_mode,
        try preflightPreparedFileMutation(
            arena,
            call,
            prepared,
            fileMutationPreflightRequest(input, permission_mode, local_grants),
        ),
    );
}

fn fileMutationPreflightRequest(
    input: Input,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) FileMutationPreflightRequest {
    return .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
        .permission_rules = input.permission_rules,
        .session_grants = input.permission_grants,
        .permission_mode = permission_mode,
        .local_grants = local_grants,
        .can_prompt = input.permission_prompter != null or permission_mode == .auto,
        .session_permission_state = input.session_permission_state,
    };
}

fn resolveFileMutationPreflightAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    preflight: FileMutationPreflight,
) !FileMutationAdmission {
    return switch (preflight) {
        .tool_failure => |reason| .{ .resolved = .{ .tool_failure = reason } },
        .policy_denied => .{ .resolved = .{ .decision = .policy_denied } },
        .allowed => |authorization| .{ .resolved = .{
            .decision = .once,
            .execution_authority = .{ .file_mutation = authorization },
        } },
        .permission_required, .prompt => |authorization| blk: {
            if (permission_mode == .auto and
                fileMutationAuthorizationMayBypassAutoReview(input, authorization))
            {
                break :blk .{ .resolved = .{
                    .decision = .once,
                    .execution_authority = .{ .file_mutation = authorization },
                } };
            }
            if (permission_mode == .auto and
                fileMutationAuthorizationMayUseAutoReview(authorization))
            {
                const targets = try fileMutationPermissionTargets(
                    arena,
                    authorization.policy_targets,
                );
                const reviewed = try automaticReviewOutcome(
                    input,
                    arena,
                    call,
                    targets,
                    false,
                    authorization,
                );
                if (reviewed.decision != .permission_required) {
                    break :blk .{ .resolved = reviewed };
                }
                // Model ask carries auto_review_result. Without a prompter, keep
                // that reviewed outcome instead of dropping the rationale on the
                // prompt unavailable path. Bare reviewer-unavailable still falls
                // through so site requirement tags are preserved.
                if (input.permission_prompter == null and reviewed.auto_review_result != null) {
                    break :blk .{ .resolved = reviewed };
                }
            }
            break :blk .{ .prompt = .{
                .authorization = authorization,
            } };
        },
    };
}

pub fn requestPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    if (input.session_permission_state == null) {
        if (input.session_permission_state_provider) |provider| {
            var snapshot = try provider.snapshot(arena);
            defer snapshot.deinit(arena);
            var resolved = input;
            resolved.session_permission_state = &snapshot;
            resolved.session_permission_state_provider = null;
            return requestPermissionOutcomeResolved(
                resolved,
                arena,
                call,
                permission_mode,
                local_grants,
            );
        }
    }
    return requestPermissionOutcomeResolved(
        input,
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

fn requestPermissionOutcomeResolved(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    if (file_mutation_contract.isToolName(call.name)) {
        return requestFileMutationPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
            local_grants,
        );
    }
    const is_mcp_tool = isAvailableDynamicTool(input, call.name);
    const command_call = try isRunCommandCall(input, arena, call);
    if (!toolHasPermissionContract(input, call.name) and
        !is_mcp_tool and
        !command_call)
    {
        return ordinaryPermissionOutcome(.once);
    }
    const permission_name = try permissionNameForCall(input, arena, call);
    const target_kind = try permissionTargetKindForCall(input, arena, call);
    var targets = permissionTargetsForCall(input, arena, call) catch |err| {
        if (permissionTargetResolutionDecision(call.name, err)) |decision| {
            return .{ .decision = decision };
        }
        if (try permissionTargetResolutionFailureMessage(arena, call.name, err)) |failure| {
            return .{ .tool_failure = failure };
        }
        return err;
    };
    defer targets.deinit(arena);
    const vision_path_authority = visionPathExecutionAuthority(
        arena,
        call,
        targets.items,
    ) catch |err| switch (err) {
        error.InvalidToolArguments => return .{
            .tool_failure = "Vision paths must reference regular files.",
        },
        else => return err,
    };
    const policy_targets = if (vision_path_authority) |authority|
        try visionPathPermissionTargets(arena, authority)
    else
        targets.items;
    const vision_path_label = if (vision_path_authority) |authority|
        try formatVisionPathPermissionLabel(arena, authority)
    else
        null;
    if (permission_mode == .yolo) {
        return bindVisionPathExecutionAuthority(try permissionOutcomeForDecision(
            input,
            arena,
            call,
            .once,
            .yolo,
        ), vision_path_authority);
    }
    var configured_ask = false;
    var all_targets_authorized_by_rule = true;
    var used_session_grant = false;
    for (policy_targets) |target| {
        switch (try permissions.ruleDecisionFor(arena, input.permission_rules, input.workspace_root, permission_name, target.path, target_kind)) {
            .deny => return .{ .decision = .policy_denied },
            .allow => {},
            .ask => {
                if (permissions.sessionGrantAllowed(local_grants, permission_name, target.path)) {
                    used_session_grant = true;
                    continue;
                }
                configured_ask = true;
            },
            .none => all_targets_authorized_by_rule = false,
        }
    }

    if (input.session_permission_state) |state| {
        const key = permissionStateKeyForCall(input, arena, call) catch null;
        if (key) |resolved_key| switch (session_permission_state.decide(state.*, resolved_key)) {
            .deny => return .{
                .decision = .policy_denied,
                .denial_reason = .policy_denied,
            },
            .allow => return bindVisionPathExecutionAuthority(
                try permissionOutcomeForDecision(
                    input,
                    arena,
                    call,
                    .once,
                    .session_state,
                ),
                vision_path_authority,
            ),
            .unresolved => {},
        };
    }

    if (configured_ask) {
        if (input.permission_prompter == null) return .{
            .decision = noninteractivePermissionRequired(call, "configured_rule_ask"),
            .denial_reason = .permission_required,
            .requirement = .configured_rule,
        };
        return bindVisionPathExecutionAuthority(
            try promptPermissionOutcome(
                input,
                arena,
                call,
                null,
                vision_path_label,
                .configured_rule,
            ),
            vision_path_authority,
        );
    }

    if (all_targets_authorized_by_rule) {
        return bindVisionPathExecutionAuthority(try permissionOutcomeForDecision(
            input,
            arena,
            call,
            .once,
            if (used_session_grant) .session_grant else .configured_rule,
        ), vision_path_authority);
    }
    if (sessionGrantsAllowAll(local_grants, permission_name, policy_targets)) {
        return bindVisionPathExecutionAuthority(
            try permissionOutcomeForDecision(input, arena, call, .once, .session_grant),
            vision_path_authority,
        );
    }
    if (permission_mode == .auto and
        try reversibleStructuredToolMayBypassAutoReview(input, arena, call))
    {
        return ordinaryPermissionOutcome(.once);
    }
    if (permission_mode == .auto and !isHumanApprovalPhase(input)) {
        if (registeredTool(input, call.name)) |tool| {
            if (unresolved_tool_disposition(tool.executor_kind) == .replan) {
                return deterministic_auto_replan_outcome(call);
            }
        }
    }
    if (input.host_sandbox_default == .allow_sandboxed and
        try isRunCommandCall(input, arena, call))
    {
        return shellPermissionOutcome(
            try runCommandContext(input, arena, call),
            .once,
            .js_host,
        );
    }
    const resolution = try resolveOrdinaryPermissionOutcome(
        input,
        arena,
        call,
        policy_targets,
        is_mcp_tool,
        permission_mode,
    );
    if (resolution.decision != .permission_required) {
        return bindVisionPathExecutionAuthority(resolution, vision_path_authority);
    }
    const unavailable_requirement: command_admission.PermissionRequirement = .approval_required;
    if (input.permission_prompter == null) {
        _ = noninteractivePermissionRequired(
            call,
            if (try isRunCommandCall(input, arena, call))
                "command_requires_approval"
            else
                "tool_requires_approval",
        );
        var blocked = resolution;
        blocked.denial_reason = .permission_required;
        blocked.requirement = unavailable_requirement;
        return bindVisionPathExecutionAuthority(blocked, vision_path_authority);
    }
    return bindVisionPathExecutionAuthority(
        try promptPermissionOutcome(
            input,
            arena,
            call,
            resolution.auto_review_result,
            vision_path_label,
            unavailable_requirement,
        ),
        vision_path_authority,
    );
}

fn exactApprovalLocalGrants(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    local_grants: []const PermissionGrant,
    authority: command_admission.ToolExecutionAuthority,
) ![]const PermissionGrant {
    switch (authority) {
        .file_mutation => |authorization| {
            const offer = authorization.grant_offer orelse return local_grants;
            const grants = try arena.alloc(
                PermissionGrant,
                local_grants.len + offer.grants.len,
            );
            @memcpy(grants[0..local_grants.len], local_grants);
            @memcpy(grants[local_grants.len..], offer.grants);
            return grants;
        },
        .ordinary, .run_command => {
            var targets = try permissionTargetsForCall(input, arena, call);
            defer targets.deinit(arena);
            const permission_name = try permissionNameForCall(input, arena, call);
            const grants = try arena.alloc(
                PermissionGrant,
                local_grants.len + targets.items.len,
            );
            @memcpy(grants[0..local_grants.len], local_grants);
            for (targets.items, grants[local_grants.len..]) |target, *grant| {
                grant.* = .{
                    .tool_name = try arena.dupe(
                        u8,
                        permissions.permissionNameForTool(permission_name),
                    ),
                    .target_path = try arena.dupe(
                        u8,
                        permissions.patternForSessionGrantMatch(
                            permission_name,
                            target.path,
                        ),
                    ),
                };
            }
            return grants;
        },
        .vision_paths => |vision_authority| {
            const grants = try arena.alloc(
                PermissionGrant,
                local_grants.len + vision_authority.targets.len,
            );
            @memcpy(grants[0..local_grants.len], local_grants);
            for (vision_authority.targets, grants[local_grants.len..]) |target, *grant| {
                grant.* = .{
                    .tool_name = try arena.dupe(
                        u8,
                        permissions.permissionNameForTool(call.name),
                    ),
                    .target_path = try arena.dupe(
                        u8,
                        permissions.patternForSessionGrantMatch(
                            call.name,
                            target.canonical_path,
                        ),
                    ),
                };
            }
            return grants;
        },
    }
}

/// Re-applies the complete current permission policy to the exact child
/// action. A prior exact approval satisfies new Ask decisions for this action,
/// but never bypasses a current Deny decision. Always remains durable through
/// the refreshed shared grant; this local proof covers only the current call.
pub fn revalidateLiveActionPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
    authority: command_admission.ToolExecutionAuthority,
    human_approval: command_admission.HumanApprovalProvenance,
) !command_admission.PermissionOutcome {
    const revalidation_grants = if (human_approval != .none)
        try exactApprovalLocalGrants(
            input,
            arena,
            call,
            local_grants,
            authority,
        )
    else
        local_grants;
    var outcome = switch (authority) {
        .ordinary => try requestPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
            revalidation_grants,
        ),
        .run_command => |expected| blk: {
            const outcome = try requestPermissionOutcome(
                input,
                arena,
                call,
                permission_mode,
                revalidation_grants,
            );
            if (!outcome.decision.isDenied()) {
                const actual = switch (outcome.execution_authority orelse
                    break :blk invalidLiveActionOutcome()) {
                    .run_command => |value| value,
                    .ordinary, .file_mutation, .vision_paths => break :blk invalidLiveActionOutcome(),
                };
                if (!commandAuthorityFingerprint(expected).eql(
                    commandAuthorityFingerprint(actual),
                )) break :blk invalidLiveActionOutcome();
            }
            break :blk outcome;
        },
        .file_mutation => try requestPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
            revalidation_grants,
        ),
        .vision_paths => |expected| blk: {
            const canonical_call = try canonicalVisionPathCall(arena, call, expected);
            const refreshed = try requestPermissionOutcome(
                input,
                arena,
                canonical_call,
                permission_mode,
                revalidation_grants,
            );
            if (!refreshed.decision.isDenied()) {
                const actual = switch (refreshed.execution_authority orelse
                    break :blk invalidLiveActionOutcome()) {
                    .vision_paths => |value| value,
                    .ordinary, .run_command, .file_mutation => break :blk invalidLiveActionOutcome(),
                };
                if (!visionPathAuthoritiesEqual(expected, actual)) {
                    break :blk invalidLiveActionOutcome();
                }
            }
            break :blk refreshed;
        },
    };
    if (human_approval != .none and
        outcome.tool_failure == null and
        !outcome.decision.isDenied())
    {
        outcome.decision = switch (human_approval) {
            .once => .once,
            .always => .always,
            .none => unreachable,
        };
        outcome.human_approval = human_approval;
    }
    return outcome;
}

fn commandAuthorityFingerprint(
    authority: command_admission.CommandExecutionAuthority,
) command_admission.AdmissionFingerprint {
    return switch (authority) {
        .direct_only => |fingerprint| fingerprint,
        .shell_allowed => |allowed| allowed.fingerprint,
    };
}

fn canonicalVisionPathCall(
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.VisionPathExecutionAuthority,
) !ToolCall {
    var request = try vision_contracts.parse_vision_request(arena, call.arguments_json);
    defer request.deinit(arena);
    const paths = request.paths() orelse return error.InvalidToolArguments;
    if (paths.len != authority.targets.len) return error.InvalidToolArguments;

    const canonical_paths = try arena.alloc([]const u8, authority.targets.len);
    for (authority.targets, canonical_paths) |target, *canonical_path| {
        canonical_path.* = target.canonical_path;
    }

    var arguments: std.Io.Writer.Allocating = .init(arena);
    defer arguments.deinit();
    try arguments.writer.writeAll("{\"paths\":");
    try std.json.Stringify.value(canonical_paths, .{}, &arguments.writer);
    try arguments.writer.writeAll(",\"focus\":");
    try std.json.Stringify.value(request.focus, .{}, &arguments.writer);
    try arguments.writer.writeByte('}');
    return .{
        .id = call.id,
        .name = call.name,
        .arguments_json = try arguments.toOwnedSlice(),
    };
}

fn visionPathAuthoritiesEqual(
    expected: command_admission.VisionPathExecutionAuthority,
    actual: command_admission.VisionPathExecutionAuthority,
) bool {
    if (expected.targets.len != actual.targets.len) return false;
    for (expected.targets, actual.targets) |expected_target, actual_target| {
        if (!std.mem.eql(
            u8,
            expected_target.canonical_path,
            actual_target.canonical_path,
        ) or !std.meta.eql(expected_target.identity, actual_target.identity)) {
            return false;
        }
    }
    return true;
}

fn invalidLiveActionOutcome() command_admission.PermissionOutcome {
    return .{
        .decision = .policy_denied,
        .denial_reason = .policy_denied,
        .tool_failure = "live authority no longer matches the prepared action",
    };
}

fn requestFileMutationPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    return requestFileMutationPermissionOutcomeFromAdmission(
        input,
        arena,
        call,
        try resolveFileMutationAdmission(
            input,
            arena,
            call,
            permission_mode,
            local_grants,
        ),
    );
}

pub fn requestPreparedFileMutationPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    return requestFileMutationPermissionOutcomeFromAdmission(
        input,
        arena,
        call,
        try resolvePreparedFileMutationAdmission(
            input,
            arena,
            call,
            prepared,
            permission_mode,
            local_grants,
        ),
    );
}

fn requestFileMutationPermissionOutcomeFromAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    admission: FileMutationAdmission,
) !command_admission.PermissionOutcome {
    return switch (admission) {
        .resolved => |outcome| outcome,
        .prompt => |pending| blk: {
            const unavailable: command_admission.PermissionOutcome = .{
                .decision = .permission_required,
                .denial_reason = .permission_required,
                .requirement = if (fileMutationTargetsContainConfiguredAsk(
                    pending.authorization.policy_targets,
                ))
                    .configured_rule
                else
                    .approval_required,
            };
            const prompter = input.permission_prompter orelse break :blk unavailable;
            var authorization = pending.authorization;
            const request_view = try fileMutationPermissionRequest(
                "file_mutation",
                authorization,
            );
            const review = if (authorization.prepared) |*prepared|
                &prepared.review
            else
                return error.RequestProjectionTooLarge;
            var response = prompter.request(
                std.heap.c_allocator,
                request_view,
                call,
                review,
                authorization.grant_offer.?.grants,
            ) catch |err| switch (err) {
                error.PermissionPromptUnavailable => break :blk unavailable,
                else => return err,
            };
            defer response.deinit();
            var outcome: command_admission.PermissionOutcome = .{
                .decision = response.decision,
                .execution_authority = if (response.decision.isDenied()) null else .{
                    .file_mutation = authorization,
                },
                .human_approval = humanApprovalProvenance(response.decision),
            };
            if (response.decision == .deny) {
                outcome.denial_reason = .user_denied;
            }
            outcome.feedback = try copyPermissionFeedback(arena, &response);
            break :blk outcome;
        },
    };
}

fn fileMutationPermissionRequest(
    label: []const u8,
    authorization: file_mutation_contract.FileExecutionAuthorization,
) permission_request.RequestCloneError!permission_request.PermissionRequest {
    const prepared = authorization.prepared orelse
        return error.RequestProjectionTooLarge;
    const offer = authorization.grant_offer orelse
        return error.RequestProjectionTooLarge;
    const intent = authorization.approval_intent orelse
        return error.RequestProjectionTooLarge;
    const request: permission_request.PermissionRequest = .{
        .label = label,
        .file = .{
            .kind = prepared.kind,
            .intent = intent,
            .preview = prepared.preview,
            .scope = offer.scope,
        },
    };
    _ = try permission_request.fileRequestFootprint(request);
    return request;
}

fn ordinaryPermissionOutcome(decision: ToolPermissionDecision) command_admission.PermissionOutcome {
    return .{
        .decision = decision,
        .execution_authority = if (decision.isDenied()) null else .ordinary,
    };
}

fn visionPathExecutionAuthority(
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
) !?command_admission.VisionPathExecutionAuthority {
    if (!std.mem.eql(u8, call.name, "vision") or
        targets.len == 0 or
        !std.mem.eql(u8, targets[0].role, "image"))
    {
        return null;
    }
    const execution_targets = try arena.alloc(
        command_admission.VisionPathExecutionTarget,
        targets.len,
    );
    for (targets, execution_targets) |target, *execution_target| {
        if (!std.mem.eql(u8, target.role, "image")) {
            return error.InvalidToolArguments;
        }
        var source = image_attachments.openVisionRegularFile(target.path) catch
            return error.InvalidToolArguments;
        defer source.close();
        execution_target.* = .{
            .canonical_path = try arena.dupe(u8, target.path),
            .identity = source.identity,
        };
    }
    return .{ .targets = execution_targets };
}

fn visionPathPermissionTargets(
    arena: Allocator,
    authority: command_admission.VisionPathExecutionAuthority,
) ![]const permissions.PermissionCallTarget {
    const targets = try arena.alloc(
        permissions.PermissionCallTarget,
        authority.targets.len,
    );
    for (authority.targets, targets) |execution_target, *target| {
        target.* = .{
            .role = "image",
            .path = @constCast(execution_target.canonical_path),
        };
    }
    return targets;
}

fn bindVisionPathExecutionAuthority(
    outcome: command_admission.PermissionOutcome,
    vision_authority: ?command_admission.VisionPathExecutionAuthority,
) !command_admission.PermissionOutcome {
    const authority = vision_authority orelse return outcome;
    var bound = outcome;
    if (bound.execution_authority) |execution_authority| {
        switch (execution_authority) {
            .ordinary => bound.execution_authority = .{ .vision_paths = authority },
            .run_command, .file_mutation, .vision_paths => {},
        }
    }
    return bound;
}

fn permissionOutcomeForDecision(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    decision: ToolPermissionDecision,
    source: command_admission.ShellAuthorizationSource,
) !command_admission.PermissionOutcome {
    if (decision.isDenied()) return .{ .decision = decision };
    if (!try isRunCommandCall(input, arena, call)) {
        return ordinaryPermissionOutcome(decision);
    }
    const command_ctx = runCommandContext(input, arena, call) catch {
        return .{ .decision = .permission_required };
    };
    return shellPermissionOutcome(command_ctx, decision, source);
}

fn shellPermissionOutcome(
    command_ctx: command_admission.CommandContext,
    decision: ToolPermissionDecision,
    source: command_admission.ShellAuthorizationSource,
) command_admission.PermissionOutcome {
    if (decision.isDenied()) return .{ .decision = decision };
    return .{
        .decision = decision,
        .execution_authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = source,
        } } },
    };
}

fn permissionOutcomeForResponse(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    response: *const permission_request.OwnedPermissionResponse,
    source: command_admission.ShellAuthorizationSource,
) !command_admission.PermissionOutcome {
    var outcome = try permissionOutcomeForDecision(
        input,
        arena,
        call,
        response.decision,
        source,
    );
    outcome.human_approval = humanApprovalProvenance(response.decision);
    if (response.decision == .deny) outcome.denial_reason = .user_denied;
    outcome.feedback = try copyPermissionFeedback(arena, response);
    return outcome;
}

fn humanApprovalProvenance(
    decision: ToolPermissionDecision,
) command_admission.HumanApprovalProvenance {
    return switch (decision) {
        .once => .once,
        .always => .always,
        .deny, .policy_denied, .permission_required => .none,
    };
}

/// Blocks on the configured interactive permission prompter and converts the
/// response into an outcome.
fn promptPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    auto_review_result: ?permission_auto_classifier.Result,
    label_override: ?[]const u8,
    unavailable_requirement: command_admission.PermissionRequirement,
) !command_admission.PermissionOutcome {
    const request = try interactivePermissionRequest(input, arena, call, label_override);
    const unavailable: command_admission.PermissionOutcome = .{
        .decision = .permission_required,
        .denial_reason = .permission_required,
        .requirement = unavailable_requirement,
        .auto_review_result = auto_review_result,
    };
    const prompter = input.permission_prompter orelse return unavailable;
    const grant_offer = if (try isRunCommandCall(input, arena, call))
        try exactApprovalLocalGrants(input, arena, call, &.{}, .ordinary)
    else
        null;
    var response = prompter.request(
        std.heap.c_allocator,
        request,
        call,
        null,
        grant_offer,
    ) catch |err| switch (err) {
        error.PermissionPromptUnavailable => return unavailable,
        else => return err,
    };
    defer response.deinit();
    var outcome = try permissionOutcomeForResponse(
        input,
        arena,
        call,
        &response,
        if (response.decision == .always) .interactive_always else .interactive_once,
    );
    outcome.auto_review_result = auto_review_result;
    return outcome;
}

fn requestWorkerPermission(
    raw: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    _: ToolCall,
    review: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    const worker: *WorkerRuntime = @ptrCast(@alignCast(raw));
    return worker.requestPermissionBlockingWithReview(alloc, request, review);
}

pub fn workerPrompter(worker: *WorkerRuntime) permission_prompter.Prompter {
    return .{
        .context = @ptrCast(worker),
        .request_fn = requestWorkerPermission,
    };
}

fn copyPermissionFeedback(
    arena: Allocator,
    response: *const permission_request.OwnedPermissionResponse,
) !?[]const u8 {
    const feedback = response.feedback orelse return null;
    if (feedback.len == 0) return null;
    return @as([]const u8, try arena.dupe(u8, feedback));
}

fn defaultRunCommandPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
) command_admission.PermissionOutcome {
    const command_ctx = runCommandContext(input, arena, call) catch {
        return .{ .decision = .permission_required };
    };
    return switch (command_admission.defaultForRunCommand(
        arena,
        command_ctx,
        permission_mode,
    )) {
        .direct_only => |fingerprint| .{
            .decision = .once,
            .execution_authority = .{ .run_command = .{ .direct_only = fingerprint } },
        },
        .approval_required => .{ .decision = .permission_required },
    };
}

pub fn runCommandContext(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !command_admission.CommandContext {
    if (!try isRunCommandCall(input, arena, call)) return error.NotRunCommand;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const command = try tool_args.requiredStringArg(args, "command");
    const tool = registeredTool(input, call.name) orelse return error.NotRunCommand;
    const cwd = switch (tool.captured_command_host) {
        .workspace_clean => try arena.dupe(u8, input.workspace_root),
        .native => blk: {
            const cwd_arg = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
            break :blk if (std.mem.eql(u8, cwd_arg, "."))
                try arena.dupe(u8, input.workspace_root)
            else
                try pathing.resolveWorkspaceOrExternalPath(arena, input.workspace_root, cwd_arg);
        },
    };
    const environment_value: command_environment.Environment = switch (tool.captured_command_host) {
        .workspace_clean => .workspace_clean,
        .native => blk: {
            const profile_raw = tool_args.nullablePlaceholderStringArg(args, "profile");
            const profile: ?command_environment.Profile = if (profile_raw) |raw|
                std.meta.stringToEnum(command_environment.Profile, raw) orelse
                    return error.InvalidCommandProfile
            else
                null;
            var login_shell_buffer: [4096]u8 = undefined;
            const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
            break :blk try shell_resolver.environment(arena, configured, profile);
        },
    };
    return .{
        .command = command,
        .resolved_cwd = cwd,
        .background = false,
        .target_os = builtin.os.tag,
        .environment = environment_value,
    };
}

pub fn permissionStateKeyForCall(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !session_permission_state.RuleKey {
    if (file_mutation_contract.isToolName(call.name)) {
        return error.PreparedFileMutationRequired;
    }
    if (try isRunCommandCall(input, arena, call)) {
        const command = try runCommandContext(input, arena, call);
        return session_permission_state.commandKeyV2(
            arena,
            command.command,
            command.resolved_cwd,
            if (command.background) "background" else "foreground",
            @tagName(command.target_os),
        );
    }

    var canonical: std.Io.Writer.Allocating = .init(arena);
    defer canonical.deinit();
    try writeIdentityField(&canonical.writer, "fx-permission-state-v1");
    var targets = try permissionTargetsForCall(input, arena, call);
    defer targets.deinit(arena);
    try writeIdentityField(&canonical.writer, call.name);
    try writeIdentityField(&canonical.writer, call.arguments_json);
    for (targets.items) |target| {
        try writeIdentityField(&canonical.writer, target.role);
        try writeIdentityField(&canonical.writer, target.path);
    }
    const bytes = try canonical.toOwnedSlice();
    return session_permission_state.RuleKey.init(.structured_tool, bytes);
}

pub const PreparedPermissionStateAction = struct {
    key: session_permission_state.RuleKey,
    display_identity: []const u8,
};

pub fn preparePermissionStateAction(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !PreparedPermissionStateAction {
    if (!file_mutation_contract.isToolName(call.name)) {
        const request = try interactivePermissionRequest(input, arena, call, null);
        return .{
            .key = try permissionStateKeyForCall(input, arena, call),
            .display_identity = try arena.dupe(u8, request.label),
        };
    }

    var prepared_call = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
    })) {
        .prepared => |prepared| prepared,
        .tool_failure => return error.PermissionStatePreparationFailed,
    };
    defer prepared_call.deinit(arena);
    const preflight = try preflightPreparedFileMutation(arena, call, &prepared_call, .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
        .permission_rules = input.permission_rules,
        .permission_mode = .ask,
        .can_prompt = true,
        .prepare_permission_identity = true,
    });
    const authorization = switch (preflight) {
        .allowed, .prompt, .permission_required => |authorization| authorization,
        .policy_denied => return error.PermissionStatePreparationDenied,
        .tool_failure => return error.PermissionStatePreparationFailed,
    };
    const prepared = authorization.prepared orelse
        return error.PermissionStatePreparationFailed;
    return .{
        .key = try permissionStateKeyForPreparedFileMutation(arena, prepared),
        .display_identity = try filePermissionStateDisplay(arena, prepared),
    };
}

fn permissionStateKeyForPreparedFileMutation(
    arena: Allocator,
    prepared: file_mutation_contract.PreparedFileMutation,
) !session_permission_state.RuleKey {
    var canonical: std.Io.Writer.Allocating = .init(arena);
    defer canonical.deinit();
    try writeIdentityField(&canonical.writer, "fx-permission-state-file-v1");
    try writeIdentityField(&canonical.writer, prepared.tool_name);
    try writeIdentityField(&canonical.writer, &prepared.arguments_hash);
    try writeIdentityField(&canonical.writer, prepared.target_path);
    try writeIdentityField(&canonical.writer, @tagName(prepared.kind));
    switch (prepared.preimage) {
        .absent => try writeIdentityField(&canonical.writer, "preimage-absent"),
        .present => |preimage| {
            try writeIdentityField(&canonical.writer, "preimage-present");
            try writeIdentityField(&canonical.writer, &preimage.content_hash);
        },
    }
    var after_hash: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(prepared.after_content, &after_hash, .{});
    try writeIdentityField(&canonical.writer, &after_hash);
    for (prepared.policy_targets.items) |target| {
        try writeIdentityField(
            &canonical.writer,
            prepared.policy_targets.canonical_target_path[0..target.path_end],
        );
        try writeIdentityField(&canonical.writer, @tagName(target.kind));
        try writeIdentityField(&canonical.writer, @tagName(target.disposition));
        if (target.expected_identity) |identity| {
            try writeIdentityU64(&canonical.writer, identity.device);
            try writeIdentityU64(&canonical.writer, identity.inode);
            try writeIdentityField(&canonical.writer, @tagName(identity.kind));
        } else {
            try writeIdentityField(&canonical.writer, "identity-absent");
        }
    }
    const bytes = try canonical.toOwnedSlice();
    return session_permission_state.RuleKey.init(.file_mutation, bytes);
}

fn filePermissionStateDisplay(
    arena: Allocator,
    prepared: file_mutation_contract.PreparedFileMutation,
) ![]const u8 {
    var after_hash: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(prepared.after_content, &after_hash, .{});
    const after_hex = std.fmt.bytesToHex(after_hash[0..8].*, .lower);
    return switch (prepared.preimage) {
        .absent => try std.fmt.allocPrint(
            arena,
            "{s} {s} preimage=absent after={s}",
            .{ prepared.tool_name, prepared.display_path, &after_hex },
        ),
        .present => |preimage| blk: {
            const before_hex = std.fmt.bytesToHex(
                preimage.content_hash[0..8].*,
                .lower,
            );
            break :blk try std.fmt.allocPrint(
                arena,
                "{s} {s} preimage={s} after={s}",
                .{ prepared.tool_name, prepared.display_path, &before_hex, &after_hex },
            );
        },
    };
}

fn writeIdentityU64(writer: *std.Io.Writer, value: u64) !void {
    var bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    try writeIdentityField(writer, &bytes);
}

fn writeIdentityField(writer: *std.Io.Writer, value: []const u8) !void {
    const value_len = std.math.cast(u64, value.len) orelse
        return error.InvalidPermissionIdentity;
    var length: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &length, value_len, .big);
    try writer.writeAll(&length);
    try writer.writeAll(value);
}

fn interactivePermissionRequest(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    label_override: ?[]const u8,
) !permission_request.PermissionRequest {
    if (try isRunCommandCall(input, arena, call)) {
        const context = try runCommandContext(input, arena, call);
        if (label_override) |label| {
            return .{
                .label = label,
                .amendment_allowed = true,
            };
        }
        return .{
            .label = try tool_presentation.formatRunCommandPermissionLabel(
                arena,
                context.command,
            ),
            .command = try command_environment.formatApprovalCommand(
                arena,
                context.environment,
                context.command,
            ),
            .amendment_allowed = true,
        };
    }
    const tool_arguments_preview = if (isAvailableDynamicTool(input, call.name)) blk: {
        const encoded = try text_utils.encodeTerminalSafe(
            arena,
            call.arguments_json,
            permission_request.max_tool_arguments_preview_bytes,
        );
        break :blk encoded.bytes;
    } else null;
    return .{
        .label = label_override orelse try tool_presentation.formatPermissionLabel(
            arena,
            input.tool_registry,
            call,
        ),
        .tool_arguments_preview = tool_arguments_preview,
    };
}

fn formatVisionPathPermissionLabel(
    arena: Allocator,
    authority: command_admission.VisionPathExecutionAuthority,
) ![]const u8 {
    var label_len: usize = "vision ".len;
    for (authority.targets, 0..) |target, index| {
        if (index > 0) label_len = std.math.add(usize, label_len, ", ".len) catch
            return error.RequestProjectionTooLarge;
        label_len = std.math.add(usize, label_len, target.canonical_path.len) catch
            return error.RequestProjectionTooLarge;
        if (label_len > diff_mod.max_encoded_label_bytes) {
            return error.RequestProjectionTooLarge;
        }
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try out.writer.writeAll("vision ");
    for (authority.targets, 0..) |target, index| {
        if (index > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(target.canonical_path);
    }
    return try out.toOwnedSlice();
}

fn noninteractivePermissionRequired(call: ToolCall, reason: []const u8) ToolPermissionDecision {
    debug_trace.logf(
        "core",
        "tool permission unavailable mode=headless approval_required=true reason={s} tool={s}",
        .{ reason, call.name },
    );
    return .permission_required;
}

fn permissionTargetResolutionDecision(tool_name: []const u8, err: anyerror) ?ToolPermissionDecision {
    return switch (err) {
        error.PathOutsideWorkspace => if (std.mem.eql(u8, tool_name, "semantic_search")) .policy_denied else null,
        else => null,
    };
}

pub fn permissionTargetResolutionFailureMessage(
    arena: Allocator,
    tool_name: []const u8,
    err: anyerror,
) !?[]const u8 {
    return switch (err) {
        error.PathOutsideWorkspace,
        error.FileNotFound,
        error.HomeNotSet,
        error.InvalidPath,
        error.WorkspaceUnavailable,
        => try std.fmt.allocPrint(
            arena,
            "Permission target resolution failed for {s}: {s}",
            .{ tool_name, @errorName(err) },
        ),
        else => null,
    };
}

fn permissionTargetsForCall(input: Input, arena: Allocator, call: ToolCall) !permissions.PermissionCallTargets {
    if (isAvailableDynamicTool(input, call.name)) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        items[0] = .{ .role = "target", .path = try arena.dupe(u8, call.name) };
        return .{ .items = items };
    }
    if (registeredWebSearchTarget(input, call.name)) |target_name| {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{
            .role = "target",
            .path = try arena.dupe(u8, target_name),
        };
        return .{ .items = items };
    }
    const tool = registeredTool(input, call.name) orelse return error.UnsupportedTool;
    if (try isRunCommandCall(input, arena, call)) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{
            .role = "target",
            .path = try commandPermissionTarget(input, arena, call),
        };
        return .{ .items = items };
    }
    return permissions.permissionTargetsForCallInScope(
        arena,
        accessScope(input),
        call,
        tool.permission_target_kind,
    );
}

fn commandPermissionTarget(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) ![]u8 {
    const context = try runCommandContext(input, arena, call);
    const identity = try command_environment.permissionCommandIdentity(
        arena,
        context.environment,
        context.command,
    );
    return std.fmt.allocPrint(
        arena,
        "{s}::{s}",
        .{ context.resolved_cwd, identity },
    );
}

fn sessionGrantsAllowAll(grants: []const PermissionGrant, tool_name: []const u8, targets: []const permissions.PermissionCallTarget) bool {
    for (targets) |target| {
        if (!permissions.sessionGrantAllowed(grants, tool_name, target.path)) return false;
    }
    return true;
}

pub fn permissionTargetForCall(input: Input, arena: Allocator, call: ToolCall) ![]const u8 {
    if (isAvailableDynamicTool(input, call.name)) return arena.dupe(u8, call.name);
    if (registeredWebSearchTarget(input, call.name)) |target_name| return arena.dupe(u8, target_name);
    const tool = registeredTool(input, call.name) orelse return error.UnsupportedTool;
    if (try isRunCommandCall(input, arena, call)) {
        return commandPermissionTarget(input, arena, call);
    }
    return permissions.permissionTargetForCallInScope(
        arena,
        accessScope(input),
        call,
        tool.permission_target_kind,
    );
}

/// Resolves the target used only for inherited live-authority checks. A
/// missing existing-path target still needs an authority decision before the
/// tool itself can return its ordinary structured failure.
pub fn permissionTargetForLiveAuthority(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) ![]const u8 {
    return permissionTargetForCall(input, arena, call) catch |err| {
        if (!recoverableExistingPathResolutionFailure(err)) return err;
        const tool = registeredTool(input, call.name) orelse return err;
        if (tool.permission_target_kind != .path_existing or
            std.mem.eql(u8, call.name, "rename_file") or
            std.mem.eql(u8, call.name, "copy_file"))
        {
            return err;
        }
        return permissions.missingPathTargetForCallInScope(
            arena,
            accessScope(input),
            call,
        ) catch |fallback_err| {
            if (!recoverableExistingPathResolutionFailure(fallback_err)) {
                return fallback_err;
            }
            return permissions.unresolvedPathTargetForCallInScope(
                arena,
                accessScope(input),
                call,
            );
        };
    };
}

fn recoverableExistingPathResolutionFailure(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        error.PermissionDenied,
        => true,
        else => false,
    };
}

fn isAvailableDynamicTool(input: Input, name: []const u8) bool {
    return tool_mcp_runtime.isAvailableDynamicTool(.{
        .is_registered_tool = registeredTool(input, name) != null,
        .advertised_dynamic_tool_names = input.advertised_dynamic_tool_names,
        .runtime = input.mcp_runtime,
    }, name);
}

test "permission target resolution never grants authority for a missing home" {
    try std.testing.expectEqual(
        @as(?ToolPermissionDecision, null),
        permissionTargetResolutionDecision("read_file", error.HomeNotSet),
    );
    const failure = (try permissionTargetResolutionFailureMessage(
        std.testing.allocator,
        "read_file",
        error.HomeNotSet,
    )).?;
    defer std.testing.allocator.free(failure);
    try std.testing.expect(std.mem.find(u8, failure, "HomeNotSet") != null);
}

test "interactive terminal exec approval permits command amendments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .tool_registry = test_admission_registry,
        .worker = &worker,
        .background = &background,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
    };

    const foreground = try interactivePermissionRequest(input, arena_state.allocator(), .{
        .id = "foreground",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf foreground\"}",
    }, null);
    try std.testing.expect(foreground.amendment_allowed);
}

test "interactive command approval keeps activity projection out of permission request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .tool_registry = test_admission_registry,
        .worker = &worker,
        .background = &background,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
    };
    const raw_command = "cat <<'EOF'\nline one\nEOF";
    const call: ToolCall = .{
        .id = "multiline",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"cat <<'EOF'\\nline one\\nEOF\"}",
    };

    const activity = (try tool_presentation.formatRunCommandActivity(
        arena,
        input.tool_registry,
        input.workspace_root,
        call,
    )) orelse return error.TestExpectedEqual;
    defer arena.free(activity.detail);
    try std.testing.expectEqualStrings("cat <<'EOF' line one EOF", activity.detail);

    const request = try interactivePermissionRequest(input, arena, call, null);
    try std.testing.expectEqualStrings(
        "terminal.exec cat <<'EOF'\\x0aline one\\x0aEOF",
        request.label,
    );
    const approval_command = request.command orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.startsWith(
        u8,
        approval_command,
        "# terminal.exec profile=user shell=",
    ));
    try std.testing.expect(std.mem.endsWith(u8, approval_command, "\n" ++ raw_command));
}

test "terminal exec omission shares user grants while clean stays isolated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    const input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );

    const omitted = try permissionTargetForCall(input, arena, .{
        .id = "omitted",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf scoped\"}",
    });
    const clean = permissionTargetForCall(input, arena, .{
        .id = "clean",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf scoped\",\"profile\":\"clean\"}",
    }) catch |err| switch (err) {
        error.MissingLoginShell, error.UnsupportedShell => return error.SkipZigTest,
        else => return err,
    };
    const user = try permissionTargetForCall(input, arena, .{
        .id = "user",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf scoped\",\"profile\":\"user\"}",
    });

    try std.testing.expectEqualStrings(omitted, user);
    try std.testing.expect(!std.mem.eql(u8, omitted, clean));
    try std.testing.expect(!std.mem.eql(u8, clean, user));
    const grants = try permissions.suggestedSessionGrants(
        arena,
        input.workspace_root,
        "run_command",
        clean,
        .command_cwd,
    );
    try std.testing.expect(permissions.sessionGrantAllowed(grants, "run_command", clean));
    try std.testing.expect(!permissions.sessionGrantAllowed(grants, "run_command", user));
    try std.testing.expect(!permissions.sessionGrantAllowed(grants, "run_command", omitted));

    const request = try interactivePermissionRequest(input, arena, .{
        .id = "user-prompt",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf scoped\",\"profile\":\"user\"}",
    }, null);
    const approval_command = request.command orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.startsWith(
        u8,
        approval_command,
        "# terminal.exec profile=user shell=",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        approval_command,
        "\nprintf scoped",
    ));
}

test "interactive command approval keeps dangerous-command guidance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .tool_registry = test_admission_registry,
        .worker = &worker,
        .background = &background,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
    };

    const request = try interactivePermissionRequest(input, arena_state.allocator(), .{
        .id = "dangerous",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"git reset --hard\"}",
    }, null);

    try std.testing.expect(std.mem.indexOf(u8, request.label, "risk: command may discard version-control state") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.label, "safer: inspect git status first") != null);
}

test "interactive Vision path approval names every canonical image" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "first.png", "second.png" }) |name| {
        var file = try tmp.dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const first = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "first.png");
    defer alloc.free(first);
    const second = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "second.png");
    defer alloc.free(second);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.vision} };
    var recording = RecordingPrompter{};
    input.permission_prompter = recording.prompter();

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "vision-paths",
            .name = "vision",
            .arguments_json = "{\"paths\":[\"first.png\",\"second.png\"],\"focus\":\"compare\"}",
        },
        .ask,
        &.{},
    );
    const expected = try std.fmt.allocPrint(alloc, "vision {s}, {s}", .{ first, second });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, recording.last_label.?);
    const authority = switch (outcome.execution_authority orelse
        return error.TestExpectedEqual) {
        .vision_paths => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 2), authority.targets.len);
    try std.testing.expectEqualStrings(first, authority.targets[0].canonical_path);
    try std.testing.expectEqualStrings(second, authority.targets[1].canonical_path);
}

test "Vision path admission returns a tool failure for directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.vision} };

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "vision-directory",
            .name = "vision",
            .arguments_json = "{\"paths\":[\".\"],\"focus\":\"inspect\"}",
        },
        .yolo,
        &.{},
    );
    try std.testing.expect(outcome.execution_authority == null);
    try std.testing.expectEqualStrings(
        "Vision paths must reference regular files.",
        outcome.tool_failure orelse return error.TestExpectedEqual,
    );
}

test "Vision path admission retains the canonical execution targets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "target-a.png", "target-b.png" }) |name| {
        var file = try tmp.dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    try tmp.dir.symLink(
        std.testing.io,
        "target-a.png",
        "approved.png",
        .{ .is_directory = false },
    );
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const target_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target-a.png");
    defer alloc.free(target_a);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.vision} };

    const call: ToolCall = .{
        .id = "vision-bound-path",
        .name = "vision",
        .arguments_json = "{\"paths\":[\"approved.png\"],\"focus\":\"inspect\"}",
    };
    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .yolo,
        &.{},
    );
    const authority = switch (outcome.execution_authority orelse
        return error.TestExpectedEqual) {
        .vision_paths => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 1), authority.targets.len);
    try std.testing.expectEqualStrings(target_a, authority.targets[0].canonical_path);

    try tmp.dir.deleteFile(std.testing.io, "approved.png");
    try tmp.dir.symLink(
        std.testing.io,
        "target-b.png",
        "approved.png",
        .{ .is_directory = false },
    );
    try std.testing.expectEqualStrings(target_a, authority.targets[0].canonical_path);

    const revalidated = try revalidateLiveActionPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .ask,
        &.{},
        outcome.execution_authority.?,
        .once,
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, revalidated.decision);
    const revalidated_authority = switch (revalidated.execution_authority orelse
        return error.TestExpectedEqual) {
        .vision_paths => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqualStrings(
        target_a,
        revalidated_authority.targets[0].canonical_path,
    );

    try tmp.dir.deleteFile(std.testing.io, "target-a.png");
    try tmp.dir.symLink(
        std.testing.io,
        "target-b.png",
        "target-a.png",
        .{ .is_directory = false },
    );
    const replaced = try revalidateLiveActionPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .ask,
        &.{},
        outcome.execution_authority.?,
        .once,
    );
    try std.testing.expect(replaced.decision.isDenied());
    try std.testing.expect(replaced.execution_authority == null);
}

test "dynamic MCP admission checks built-in and advertised names before runtime lookup" {
    const CountingMcp = struct {
        calls: usize = 0,

        fn hasTool(raw_ctx: *anyopaque, _: []const u8, _: tool_mcp_runtime.Access) bool {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            return true;
        }
    };

    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var mcp = CountingMcp{};
    const advertised = [_][]const u8{"mcp_example"};
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .worker = &worker,
        .background = &background,
        .tool_registry = test_admission_registry,
        .advertised_dynamic_tool_names = &advertised,
        .mcp_runtime = .{
            .context = @ptrCast(&mcp),
            .has_tool = CountingMcp.hasTool,
        },
    };

    try std.testing.expect(!isAvailableDynamicTool(input, "list_files"));
    try std.testing.expect(!isAvailableDynamicTool(input, "mcp_unadvertised"));
    try std.testing.expectEqual(@as(usize, 0), mcp.calls);
    try std.testing.expect(isAvailableDynamicTool(input, "mcp_example"));
    try std.testing.expectEqual(@as(usize, 1), mcp.calls);
}

test "interactive dynamic MCP approval projects bounded terminal-safe arguments only" {
    const AvailableMcp = struct {
        fn hasTool(_: *anyopaque, _: []const u8, _: tool_mcp_runtime.Access) bool {
            return true;
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var mcp: u8 = 0;
    const advertised = [_][]const u8{"mcp_example"};
    const input: Input = .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .worker = &worker,
        .background = &background,
        .tool_registry = test_admission_registry,
        .advertised_dynamic_tool_names = &advertised,
        .mcp_runtime = .{
            .context = @ptrCast(&mcp),
            .has_tool = AvailableMcp.hasTool,
        },
    };

    const request = try interactivePermissionRequest(input, arena, .{
        .id = "dynamic",
        .name = "mcp_example",
        .arguments_json = "{\"text\":\"line\\n\x1b[31m\"}",
    }, null);
    try std.testing.expectEqualStrings(
        "{\"text\":\"line\\n\\x1b[31m\"}",
        request.tool_arguments_preview.?,
    );

    const non_dynamic = try interactivePermissionRequest(input, arena, .{
        .id = "builtin",
        .name = "list_files",
        .arguments_json = "{\"path\":\".\"}",
    }, null);
    try std.testing.expectEqual(@as(?[]const u8, null), non_dynamic.tool_arguments_preview);

    const oversized = try arena.alloc(
        u8,
        permission_request.max_tool_arguments_preview_bytes + 1,
    );
    @memset(oversized, 'x');
    const bounded = try interactivePermissionRequest(input, arena, .{
        .id = "bounded",
        .name = "mcp_example",
        .arguments_json = oversized,
    }, null);
    try std.testing.expectEqual(
        permission_request.max_tool_arguments_preview_bytes,
        bounded.tool_arguments_preview.?.len,
    );
    try std.testing.expect(std.mem.endsWith(
        u8,
        bounded.tool_arguments_preview.?,
        "...",
    ));
}

test "file mutation preflight reports malformed input before authority construction" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    file_mutation_decode_count = 0;
    const outcome = try preflightFileMutation(arena_state.allocator(), .{
        .id = "malformed",
        .name = "write_file",
        .arguments_json = "{",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = "/tmp/workspace",
        .permission_rules = .{},
        .permission_mode = .auto,
        .can_prompt = false,
    });
    try std.testing.expectEqual(@as(std.meta.Tag(FileMutationPreflight), .tool_failure), std.meta.activeTag(outcome));
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
}

test "prepared file mutation admission decodes and resolves exactly once without legacy checks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    const call: ToolCall = .{
        .id = "prepared-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"nested/file.txt\",\"content\":\"hello\\n\"}",
    };

    file_mutation_decode_count = 0;
    file_mutation_resolution_count = 0;
    file_mutation.resetTargetResolutionCheckCountForTest();
    var prepared = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);

    const expected_target = try std.fs.path.join(arena, &.{ workspace, "nested", "file.txt" });
    try std.testing.expectEqualStrings(expected_target, prepared.targetPath());
    try std.testing.expect(prepared.targets.proofValid());
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 1), file_mutation_resolution_count);

    const outcome = try resolvePreparedFileMutationAdmission(
        input,
        arena,
        call,
        &prepared,
        .ask,
        &.{},
    );
    const authorization = switch (outcome) {
        .prompt => |pending| pending.authorization,
        else => return error.TestExpectedPermissionRequired,
    };
    try std.testing.expect(authorization.prepared != null);
    try std.testing.expectEqualStrings("nested/file.txt", authorization.input.path());
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 1), file_mutation_resolution_count);
    try std.testing.expectEqual(@as(usize, 0), file_mutation.targetResolutionCheckCountForTest());
}

test "external file action identity is canonical across call IDs and distinguishes changed content" {
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
    const absolute_target = try std.fs.path.join(
        arena,
        &.{ external, "denied", "nested", "file.txt" },
    );
    const absolute_arguments = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"denied\\n\"}}",
        .{absolute_target},
    );
    const relative_arguments =
        "{\"content\":\"denied\\n\",\"path\":\"../external/denied/nested/file.txt\"}";
    const changed_arguments =
        "{\"path\":\"../external/denied/nested/file.txt\",\"content\":\"changed\\n\"}";

    var first = switch (try prepareFileMutationCall(arena, .{
        .id = "first-call-id",
        .name = "write_file",
        .arguments_json = absolute_arguments,
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer first.deinit(arena);
    var equivalent = switch (try prepareFileMutationCall(arena, .{
        .id = "different-call-id",
        .name = "write_file",
        .arguments_json = relative_arguments,
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer equivalent.deinit(arena);
    var changed = switch (try prepareFileMutationCall(arena, .{
        .id = "changed-call-id",
        .name = "write_file",
        .arguments_json = changed_arguments,
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer changed.deinit(arena);

    const first_identity = first.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    const equivalent_identity = equivalent.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    const changed_identity = changed.externalActionIdentity() orelse
        return error.TestExpectedExternalAction;
    try std.testing.expect(first_identity.eql(equivalent_identity));
    try std.testing.expect(!first_identity.eql(changed_identity));
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(
            std.testing.io,
            try std.fs.path.join(arena, &.{ external, "denied" }),
            .{},
        ),
    );
}

test "prepared file mutation rejects a changed call without decoding or resolving again" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original: ToolCall = .{
        .id = "bound-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"original.txt\",\"content\":\"original\"}",
    };

    file_mutation_decode_count = 0;
    file_mutation_resolution_count = 0;
    var prepared = switch (try prepareFileMutationCall(arena, original, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);

    const outcome = try preflightPreparedFileMutation(arena, .{
        .id = original.id,
        .name = original.name,
        .arguments_json = "{\"path\":\"changed.txt\",\"content\":\"changed\"}",
    }, &prepared, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
        .permission_rules = .{},
        .permission_mode = .auto,
        .can_prompt = false,
    });
    const reason = switch (outcome) {
        .tool_failure => |value| value,
        else => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings(
        "prepared file mutation no longer matches tool call",
        reason,
    );
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 1), file_mutation_resolution_count);
}

test "file mutation preparation returns semantic failures before permission evaluation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    file_mutation_decode_count = 0;
    file_mutation_resolution_count = 0;
    const malformed = try prepareFileMutationCall(arena, .{
        .id = "malformed",
        .name = "write_file",
        .arguments_json = "{",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    });
    try std.testing.expectEqual(@as(std.meta.Tag(FileMutationPreparation), .tool_failure), std.meta.activeTag(malformed));
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 0), file_mutation_resolution_count);

    file_mutation_decode_count = 0;
    file_mutation_resolution_count = 0;
    const missing_edit = try prepareFileMutationCall(arena, .{
        .id = "missing-edit",
        .name = "edit_file",
        .arguments_json = "{\"path\":\"missing.txt\",\"old_string\":\"before\",\"new_string\":\"after\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    });
    const reason = switch (missing_edit) {
        .tool_failure => |value| value,
        .prepared => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings(
        "file mutation target resolution failed: file_not_found",
        reason,
    );
    try std.testing.expectEqual(@as(usize, 1), file_mutation_decode_count);
    try std.testing.expectEqual(@as(usize, 1), file_mutation_resolution_count);
}

fn checkFileMutationPreparationAllocationFailures(alloc: Allocator, workspace: []const u8) !void {
    var prepared = switch (try prepareFileMutationCall(alloc, .{
        .id = "allocation-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"nested/file.txt\",\"content\":\"hello\\n\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(alloc);
}

test "prepared file mutation cleans every partial allocation failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    try std.testing.checkAllAllocationFailures(
        alloc,
        checkFileMutationPreparationAllocationFailures,
        .{workspace},
    );
}

fn decodeRegistryOwnedWrite(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    if (!std.mem.eql(u8, args_json, "registry-owned")) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "expected registry-owned write input",
        ) };
    }
    return test_builtin_tools.write_file.decode(
        ctx,
        "{\"path\":\"registered.txt\",\"content\":\"registered\\n\"}",
    );
}

test "file mutation preflight uses the supplied registry input contract" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registered_write = test_builtin_tools.write_file;
    registered_write.decode = decodeRegistryOwnedWrite;
    const tools = [_]tool_dispatch.Tool{registered_write};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    var allow_rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("**"),
        .action = .allow,
    }};

    const outcome = try preflightFileMutation(arena, .{
        .id = "registered-write",
        .name = "write_file",
        .arguments_json = "registry-owned",
    }, .{
        .tool_registry = registry,
        .workspace_root = workspace,
        .permission_rules = .{ .rules = &allow_rules },
        .permission_mode = .auto,
        .can_prompt = false,
    });
    const authorization = switch (outcome) {
        .allowed => |value| value,
        else => return error.TestExpectedAllowed,
    };
    try std.testing.expectEqual(
        file_mutation_contract.Kind.write,
        std.meta.activeTag(authorization.input),
    );
    try std.testing.expectEqualStrings(
        "registered.txt",
        authorization.input.write.path,
    );
    try std.testing.expectEqualStrings(
        "registered\n",
        authorization.input.write.content,
    );
}

test "file mutation preflight compatibility wrapper preserves deny and target failure outcomes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("denied.txt"),
        .action = .deny,
    }};

    const denied = try preflightFileMutation(arena, .{
        .id = "denied-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"denied.txt\",\"content\":\"blocked\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
        .permission_rules = .{ .rules = &rules },
        .permission_mode = .auto,
        .can_prompt = false,
    });
    try std.testing.expectEqual(
        @as(std.meta.Tag(FileMutationPreflight), .policy_denied),
        std.meta.activeTag(denied),
    );

    const missing = try preflightFileMutation(arena, .{
        .id = "missing-edit",
        .name = "edit_file",
        .arguments_json = "{\"path\":\"missing.txt\",\"old_string\":\"before\",\"new_string\":\"after\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
        .permission_rules = .{},
        .permission_mode = .auto,
        .can_prompt = false,
    });
    const reason = switch (missing) {
        .tool_failure => |value| value,
        else => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings(
        "file mutation target resolution failed: file_not_found",
        reason,
    );
}

test "file mutation preflight fails closed without registered input ownership" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var unbound_write = test_builtin_tools.write_file;
    unbound_write.take_file_mutation_input_fn = null;
    const tools = [_]tool_dispatch.Tool{unbound_write};
    const registry = tool_dispatch.Registry{ .tools = tools[0..] };
    const outcome = try preflightFileMutation(arena_state.allocator(), .{
        .id = "unbound-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"blocked.txt\",\"content\":\"blocked\"}",
    }, .{
        .tool_registry = registry,
        .workspace_root = "/tmp/workspace",
        .permission_rules = .{},
        .permission_mode = .auto,
        .can_prompt = false,
    });
    const reason = switch (outcome) {
        .tool_failure => |value| value,
        else => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings(
        "file mutation tool registration is missing canonical input ownership",
        reason,
    );
}

test "file mutation kind comes from the registered executor kind, not the tool name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var edit_under_write_name = test_builtin_tools.edit_file;
    edit_under_write_name.name = "write_file";
    const tools = [_]tool_dispatch.Tool{edit_under_write_name};

    const decoded = try decodeFileMutationInput(arena, .{ .tools = tools[0..] }, .{
        .id = "declared-edit",
        .name = "write_file",
        .arguments_json = "{\"path\":\"note.txt\",\"old_string\":\"before\",\"new_string\":\"after\"}",
    });
    switch (decoded) {
        .input => |input| try std.testing.expectEqual(
            file_mutation_contract.Kind.edit,
            std.meta.activeTag(input),
        ),
        .failure => return error.TestExpectedDecodedInput,
    }
}

test "file mutation decode accepts a registered tool under any name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var renamed_write = test_builtin_tools.write_file;
    renamed_write.name = "stage_file";
    const tools = [_]tool_dispatch.Tool{renamed_write};

    const decoded = try decodeFileMutationInput(arena, .{ .tools = tools[0..] }, .{
        .id = "renamed-write",
        .name = "stage_file",
        .arguments_json = "{\"path\":\"note.txt\",\"content\":\"hello\\n\"}",
    });
    switch (decoded) {
        .input => |input| try std.testing.expectEqual(
            file_mutation_contract.Kind.write,
            std.meta.activeTag(input),
        ),
        .failure => return error.TestExpectedDecodedInput,
    }
}

test "file mutation decode rejects a registered tool that is not a mutation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tools = [_]tool_dispatch.Tool{test_builtin_tools.read_file};
    const decoded = try decodeFileMutationInput(arena, .{ .tools = tools[0..] }, .{
        .id = "not-a-mutation",
        .name = "read_file",
        .arguments_json = "{\"path\":\"note.txt\"}",
    });
    const reason = switch (decoded) {
        .failure => |value| value,
        .input => return error.TestExpectedToolFailure,
    };
    try std.testing.expectEqualStrings("unsupported file mutation tool", reason);
}

const FakeAutoClassifier = struct {
    calls: usize = 0,
    decision: permission_auto_classifier.Decision = .allow,
    risk: permission_auto_classifier.Risk = .low,
    authorization: permission_auto_classifier.Authorization = .medium,
    rationale: []const u8 = "test automatic review",
    invalid: bool = false,
    review_model: []const u8 = "",
    review_root_text: []const u8 = "",
    review_target_call_id: []const u8 = "",
    action_tag: ?std.meta.Tag(permission_auto_classifier.Action) = null,
    exact_command: ?[]const u8 = null,
    exact_arguments_json: ?[]const u8 = null,
    schema_json: ?[]const u8 = null,
    file_display_path: ?[]const u8 = null,
    file_additions: usize = 0,
    file_deletions: usize = 0,
    file_review_rows: usize = 0,

    fn classify(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        request: permission_auto_classifier.ReviewRequest,
    ) anyerror!permission_auto_classifier.ParseOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        self.review_model = request.review_turn.model;
        self.review_root_text = request.review_turn.current_root_request;
        self.review_target_call_id = request.review_turn.target_call_id;
        self.action_tag = std.meta.activeTag(request.action);
        switch (request.action) {
            .command => |command| self.exact_command = command.command,
            .file_mutation => |file| {
                self.file_display_path = file.display_path;
                self.file_additions = file.additions;
                self.file_deletions = file.deletions;
                var viewport = try file.review.viewport(alloc, 0, 1);
                defer viewport.deinit(alloc);
                self.file_review_rows = viewport.total_rows;
            },
            .tool => |tool| {
                self.exact_arguments_json = tool.arguments_json;
                self.schema_json = tool.schema_json;
            },
        }
        if (self.invalid) return .invalid;
        return .{ .valid = .{
            .risk = self.risk,
            .authorization = self.authorization,
            .decision = self.decision,
            .rationale = try alloc.dupe(u8, self.rationale),
        } };
    }
};

const test_admission_registry = tool_dispatch.Registry{ .tools = &.{
    test_builtin_tools.list_files,
    test_builtin_tools.terminal,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_builtin_tools.delete_file,
    test_builtin_tools.copy_file,
    test_builtin_tools.create_folder,
} };

fn testInputWithClassifier(
    worker: *WorkerRuntime,
    background: *BackgroundRuntime,
    classifier: permission_auto_classifier.Classifier,
) Input {
    return .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .tool_registry = test_admission_registry,
        .worker = worker,
        .background = background,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
        .auto_classifier = classifier,
        .permission_review_turn = testReviewTurn(),
    };
}

test "exact command approval remains valid across live authority revalidation" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    const input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    const call: ToolCall = .{
        .id = "exact-command-revalidation",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf approved > marker.txt\"}",
    };
    const grants = try exactApprovalLocalGrants(
        input,
        arena,
        call,
        &.{},
        .ordinary,
    );
    var targets = try permissionTargetsForCall(input, arena, call);
    defer targets.deinit(arena);

    try std.testing.expectEqual(@as(usize, 1), grants.len);
    try std.testing.expectEqualStrings("bash", grants[0].tool_name);
    try std.testing.expect(command_environment.isExplicitPermissionCommandIdentity(
        grants[0].target_path,
    ));
    try std.testing.expectEqualStrings(
        "printf approved > marker.txt",
        command_environment.commandFromPermissionIdentity(grants[0].target_path),
    );
    try std.testing.expect(sessionGrantsAllowAll(grants, "bash", targets.items));
}

const test_review_tool_calls = [_]ToolCall{
    .{ .id = "test-review", .name = "terminal", .arguments_json = "{\"action\":\"exec\",\"command\":\"printf test\"}" },
};
const test_review_root_messages = [_][]const u8{"test root request"};

fn testReviewTurn() permission_auto_classifier.ReviewTurnContext {
    return .{
        .model = "openai/gpt-5",
        .pending_assistant = .{ .role = .assistant, .tool_calls = &test_review_tool_calls },
        .target_call_id = "test-review",
        .origin = .root,
        .current_root_request = test_review_root_messages[0],
    };
}

const RecordingPrompter = struct {
    calls: usize = 0,
    decision: ToolPermissionDecision = .once,
    last_call_id: ?[]const u8 = null,
    last_label_len: usize = 0,
    last_label: ?[]const u8 = null,
    last_command: ?[]const u8 = null,
    last_grant_offer: ?[]const PermissionGrant = null,

    fn request(
        raw: *anyopaque,
        alloc: Allocator,
        request_view: permission_request.PermissionRequest,
        call: ToolCall,
        _: ?*const diff_mod.FileReview,
        grant_offer: ?[]const PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.last_call_id = call.id;
        self.last_label_len = request_view.label.len;
        self.last_label = request_view.label;
        self.last_command = request_view.command;
        self.last_grant_offer = grant_offer;
        return permission_request.OwnedPermissionResponse.init(alloc, self.decision, null);
    }

    fn prompter(self: *@This()) permission_prompter.Prompter {
        return .{ .context = @ptrCast(self), .request_fn = request };
    }
};

test "interactive admission routes prompts through the supplied prompter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.permission_prompter = recording.prompter();

    const call = ToolCall{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch generated.txt\"}",
    };
    const outcome = try requestPermissionOutcome(input, arena_state.allocator(), call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expectEqualStrings(call.id, recording.last_call_id.?);
    const grant_offer = recording.last_grant_offer orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), grant_offer.len);
    try std.testing.expectEqualStrings("bash", grant_offer[0].tool_name);
    try std.testing.expect(command_environment.isExplicitPermissionCommandIdentity(
        grant_offer[0].target_path,
    ));
    try std.testing.expectEqualStrings(
        "touch generated.txt",
        command_environment.commandFromPermissionIdentity(grant_offer[0].target_path),
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const authority = outcome.execution_authority.?.run_command;
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.interactive_once,
        authority.shell_allowed.source,
    );

    recording.decision = .deny;
    const denied = try requestPermissionOutcome(input, arena_state.allocator(), call, .ask, &.{});
    try std.testing.expectEqual(@as(usize, 2), recording.calls);
    try std.testing.expectEqual(ToolPermissionDecision.deny, denied.decision);
    try std.testing.expect(denied.execution_authority == null);
}

test "interactive file admission passes its canonical grant offer to the prompter" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.permission_prompter = recording.prompter();
    const arguments_json = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}/note.txt\",\"content\":\"hello\\n\"}}",
        .{workspace},
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "write",
            .name = "write_file",
            .arguments_json = arguments_json,
        },
        .ask,
        &.{},
    );

    const authorization = switch (outcome.execution_authority.?) {
        .file_mutation => |value| value,
        else => return error.TestExpectedEqual,
    };
    const expected = authorization.grant_offer.?.grants;
    const observed = recording.last_grant_offer.?;
    try std.testing.expectEqual(expected.len, observed.len);
    for (expected, observed) |expected_grant, observed_grant| {
        try std.testing.expectEqualStrings(
            expected_grant.tool_name,
            observed_grant.tool_name,
        );
        try std.testing.expectEqualStrings(
            expected_grant.target_path,
            observed_grant.target_path,
        );
    }
}

test "automatic non-allow is recoverable regardless tool approval policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{
        .decision = .ask,
        .risk = .high,
        .authorization = .low,
        .rationale = "Opening the file was not requested.",
    };
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var auto_deny_tool = test_builtin_tools.read_file;
    auto_deny_tool.name = "test_auto_deny_on_ask";
    auto_deny_tool.gateway_schema.name = auto_deny_tool.name;
    auto_deny_tool.requires_approval = true;
    auto_deny_tool.approval_policy = .auto_deny_on_ask;
    auto_deny_tool.label_arg_kind = .none;
    auto_deny_tool.label_arg_default = "test input";
    auto_deny_tool.permission_target_kind = .none;
    const tools = [_]tool_dispatch.Tool{auto_deny_tool};
    input.tool_registry = .{ .tools = tools[0..] };
    input.permission_prompter = recording.prompter();
    const call = ToolCall{
        .id = "auto-deny-on-ask",
        .name = "test_auto_deny_on_ask",
        .arguments_json = "{}",
    };

    const denied = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.deny, denied.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, denied.denial_reason.?);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectEqualStrings(
        "Opening the file was not requested.",
        denied.auto_review_result.?.rationale,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    fake.decision = .allow;
    const allowed = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expectEqual(command_admission.ToolExecutionAuthority.ordinary, allowed.execution_authority.?);
    try std.testing.expectEqual(permission_auto_classifier.Decision.allow, allowed.auto_review_result.?.decision);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    fake.invalid = true;
    const invalid = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.deny, invalid.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, invalid.denial_reason.?);
    try std.testing.expect(invalid.execution_authority == null);
    try std.testing.expect(invalid.auto_review_result == null);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    fake.invalid = false;
    fake.decision = .ask;
    const interactive = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .ask,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, interactive.decision);
    try std.testing.expect(interactive.execution_authority != null);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    input.auto_classifier = permission_auto_classifier.Classifier.disabled();
    const unavailable = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.deny, unavailable.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, unavailable.denial_reason.?);
    try std.testing.expect(unavailable.execution_authority == null);
    try std.testing.expect(unavailable.auto_review_result == null);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

test "incomplete review authority maps to auto denial without reviewer transport" {
    const State = struct {
        review_calls: usize = 0,
        transport_calls: usize = 0,

        fn send(
            raw_ctx: *anyopaque,
            _: Allocator,
            _: []const u8,
            _: []const u8,
            _: std.Io.Clock.Timestamp,
            _: *std.atomic.Value(bool),
        ) anyerror!permission_auto_classifier.TransportOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.transport_calls += 1;
            return .permanent_failure;
        }

        fn review(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            request: permission_auto_classifier.ReviewRequest,
        ) anyerror!permission_auto_classifier.ParseOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.review_calls += 1;
            return permission_auto_classifier.Reviewer.withTransport(.{
                .context = raw_ctx,
                .send_fn = send,
            }, null, 1000).review(alloc, request);
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var state = State{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&state),
            State.review,
        ),
    );
    var review_turn = testReviewTurn();
    review_turn.current_root_request = "";
    input.permission_review_turn = review_turn;

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "test-review",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"touch incomplete.txt\"}",
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(ToolPermissionDecision.deny, outcome.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, outcome.denial_reason.?);
    try std.testing.expect(outcome.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 1), state.review_calls);
    try std.testing.expectEqual(@as(usize, 0), state.transport_calls);
}

test "ask-only policy bypasses prompt and reviewer in auto and uses the ordinary prompt in ask" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var ask_only_tool = test_builtin_tools.read_file;
    ask_only_tool.name = "test_ask_only";
    ask_only_tool.gateway_schema.name = ask_only_tool.name;
    ask_only_tool.requires_approval = true;
    ask_only_tool.approval_policy = .ask_only;
    ask_only_tool.label_arg_kind = .none;
    ask_only_tool.label_arg_default = "test input";
    ask_only_tool.permission_target_kind = .none;
    const tools = [_]tool_dispatch.Tool{ask_only_tool};
    input.tool_registry = .{ .tools = tools[0..] };
    input.permission_prompter = recording.prompter();
    const call = ToolCall{
        .id = "ask-only-permission",
        .name = "test_ask_only",
        .arguments_json = "{}",
    };

    const automatic = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, automatic.decision);
    try std.testing.expectEqual(command_admission.ToolExecutionAuthority.ordinary, automatic.execution_authority.?);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    const interactive = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .ask,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, interactive.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expect(recording.last_label_len > 0);

    recording.decision = .deny;
    const denied = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .ask,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.deny, denied.decision);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 2), recording.calls);
}

test "automatic terminal admission reviews only sensitive typed input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    const list_call = ToolCall{
        .id = "terminal-list",
        .name = "terminal",
        .arguments_json = "{\"action\":\"list\"}",
    };

    const list = try requestPermissionOutcome(input, arena, list_call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, list.decision);
    try std.testing.expectEqual(command_admission.ToolExecutionAuthority.ordinary, list.execution_authority.?);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    const start = try requestPermissionOutcome(input, arena, .{
        .id = "terminal-start",
        .name = "terminal",
        .arguments_json = "{\"action\":\"start\"}",
    }, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, start.decision);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    const asked = try requestPermissionOutcome(input, arena, list_call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, asked.decision);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("terminal"),
        .pattern = @constCast("terminal"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const denied = try requestPermissionOutcome(input, arena, list_call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    rules[0].action = .ask;
    const configured_ask = try requestPermissionOutcome(input, arena, list_call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, configured_ask.decision);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        requestPermissionOutcome(input, arena, .{
            .id = "malformed-terminal-list",
            .name = "terminal",
            .arguments_json = "{",
        }, .auto, &.{}),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "existing tool approval policies retain the standard default" {
    for (test_admission_registry.tools) |tool| {
        try std.testing.expectEqual(tool_dispatch.ApprovalPolicy.standard, tool.approval_policy);
    }
}

test "yolo admission bypasses policy prompts and review after structural validation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var classifier = FakeAutoClassifier{};
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&classifier),
            FakeAutoClassifier.classify,
        ),
    );
    input.permission_prompter = prompter.prompter();
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };

    const allowed = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "yolo-command",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"touch generated.txt\"}",
        },
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.yolo,
        allowed.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), classifier.calls);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);

    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        requestPermissionOutcome(
            input,
            arena_state.allocator(),
            .{
                .id = "malformed-yolo-command",
                .name = "terminal",
                .arguments_json = "{",
            },
            .yolo,
            &.{},
        ),
    );
}

test "yolo file admission preserves canonical mutation authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var classifier = FakeAutoClassifier{};
    var prompter = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&classifier),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    input.permission_prompter = prompter.prompter();
    var rules = [_]types.PermissionRule{
        .{
            .permission = @constCast("write_file"),
            .pattern = @constCast("*"),
            .action = .deny,
        },
        .{
            .permission = @constCast("read_file"),
            .pattern = @constCast("*"),
            .action = .deny,
        },
    };
    input.permission_rules = .{ .rules = &rules };
    const target = try std.fs.path.join(arena, &.{ workspace, "yolo.txt" });
    const arguments = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"ok\\n\"}}",
        .{target},
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "yolo-write",
            .name = "write_file",
            .arguments_json = arguments,
        },
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const authority = outcome.execution_authority orelse return error.TestExpectedEqual;
    switch (authority) {
        .file_mutation => |authorization| {
            try std.testing.expectEqualStrings(target, authorization.input.path());
            try std.testing.expect(authorization.policy_targets.items.len >= 2);
            try std.testing.expect(authorization.policy_targets.items[1].expected_identity != null);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(usize, 0), classifier.calls);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);

    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/yolo.txt", .{
            .truncate = true,
        });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "ok\n");
    }
    const noop = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "yolo-noop-write",
            .name = "write_file",
            .arguments_json = arguments,
        },
        .yolo,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, noop.decision);
    try std.testing.expect(noop.execution_authority != null);
    try std.testing.expectEqual(@as(usize, 0), classifier.calls);
    try std.testing.expectEqual(@as(usize, 0), prompter.calls);
}

test "admission registration follows the supplied registry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );

    const call = ToolCall{
        .id = "cmd",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch generated.txt\"}",
    };
    input.tool_registry = .{};
    try std.testing.expect(!try callUsesCommandAuthority(
        input.tool_registry,
        arena_state.allocator(),
        call,
    ));
    const unregistered = try requestPermissionOutcome(input, arena_state.allocator(), call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, unregistered.decision);
    try std.testing.expectEqual(command_admission.ToolExecutionAuthority.ordinary, unregistered.execution_authority.?);

    input.tool_registry = tool_dispatch.Registry{ .tools = &.{test_builtin_tools.terminal} };
    try std.testing.expect(try callUsesCommandAuthority(
        input.tool_registry,
        arena_state.allocator(),
        call,
    ));
    const registered = try requestPermissionOutcome(input, arena_state.allocator(), call, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, registered.decision);
    try std.testing.expect(registered.execution_authority == null);
}

test "registered subagent commands do not require generic tool approval" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    var subagent = test_builtin_tools.read_file;
    subagent.name = "subagent";
    subagent.gateway_schema.name = "subagent";
    subagent.executor_kind = .subagent;
    subagent.activity_kind = .subagent;
    subagent.label_arg_kind = .none;
    subagent.permission_target_kind = .none;
    input.tool_registry = .{ .tools = &.{subagent} };

    const outcome = try requestPermissionOutcome(input, arena_state.allocator(), .{
        .id = "subagent-create",
        .name = "subagent",
        .arguments_json = "{}",
    }, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(command_admission.ToolExecutionAuthority.ordinary, outcome.execution_authority.?);
}

test "web search permission target follows registered tool metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );

    var provider_search = test_builtin_tools.read_file;
    provider_search.name = "provider_search";
    provider_search.gateway_schema.name = "provider_search";
    provider_search.executor_kind = .web_search;
    provider_search.permission_target_kind = .none;
    const tools = [_]tool_dispatch.Tool{provider_search};
    input.tool_registry = .{ .tools = tools[0..] };

    const target = try permissionTargetForCall(input, arena_state.allocator(), .{
        .id = "provider-search",
        .name = "provider_search",
        .arguments_json = "{\"query\":\"current news\"}",
    });
    try std.testing.expectEqualStrings("provider_search", target);
}

test "permission target kind follows supplied registry metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );

    var provider_read = test_builtin_tools.read_file;
    provider_read.permission_target_kind = .none;
    const tools = [_]tool_dispatch.Tool{provider_read};
    input.tool_registry = .{ .tools = tools[0..] };

    const target = try permissionTargetForCall(input, arena_state.allocator(), .{
        .id = "provider-read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    });
    try std.testing.expectEqualStrings("read_file", target);
}

test "live authority resolves a missing read target without changing ordinary admission" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/src");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const expected = try std.fs.path.join(alloc, &.{ workspace, "src/missing.zig" });
    defer alloc.free(expected);
    const external_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(external_root);
    const external_expected = try std.fs.path.join(
        alloc,
        &.{ external_root, "external-missing.zig" },
    );
    defer alloc.free(external_expected);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.read_file} };
    const call: ToolCall = .{
        .id = "missing-read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/missing.zig\"}",
    };

    try std.testing.expectError(
        error.FileNotFound,
        permissionTargetForCall(input, arena_state.allocator(), call),
    );
    try std.testing.expectEqualStrings(
        expected,
        try permissionTargetForLiveAuthority(
            input,
            arena_state.allocator(),
            call,
        ),
    );
    try std.testing.expectEqualStrings(
        external_expected,
        try permissionTargetForLiveAuthority(
            input,
            arena_state.allocator(),
            .{
                .id = "external-missing-read",
                .name = "read_file",
                .arguments_json = try std.fmt.allocPrint(
                    arena_state.allocator(),
                    "{{\"path\":\"{s}\"}}",
                    .{external_expected},
                ),
            },
        ),
    );
}

test "live authority preserves a non-directory read failure for tool execution" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var blocking_file = try tmp.dir.createFile(io_mod.getIo(), "workspace/not-a-dir", .{});
    blocking_file.close(io_mod.getIo());
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const expected = try std.fs.path.join(alloc, &.{ workspace, "not-a-dir/child.txt" });
    defer alloc.free(expected);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    input.tool_registry = .{ .tools = &.{test_builtin_tools.read_file} };
    const call: ToolCall = .{
        .id = "not-dir-read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"not-a-dir/child.txt\"}",
    };

    if (permissionTargetForCall(input, arena_state.allocator(), call)) |_| {
        return error.TestExpectedPathResolutionFailure;
    } else |err| {
        try std.testing.expect(err == error.FileNotFound or err == error.NotDir);
    }
    try std.testing.expectEqualStrings(
        expected,
        try permissionTargetForLiveAuthority(
            input,
            arena_state.allocator(),
            call,
        ),
    );
}

test "permission rule display follows supplied registry metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );

    var provider_list = test_builtin_tools.list_files;
    provider_list.name = "provider_list";
    provider_list.gateway_schema.name = "provider_list";
    const tools = [_]tool_dispatch.Tool{provider_list};
    input.tool_registry = .{ .tools = tools[0..] };
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("provider_list"),
        .pattern = @constCast("."),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = rules[0..] };

    const outcome = try requestPermissionOutcome(input, arena_state.allocator(), .{
        .id = "provider-list",
        .name = "provider_list",
        .arguments_json = "{}",
    }, .ask, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, outcome.decision);
}

test "automatic review receives exact command and mints matching one-call authority" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    const command = "touch automatic.txt && printf dangerous-tail";
    var fake = FakeAutoClassifier{
        .rationale = "The exact requested command is authorized.",
    };
    const input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "automatic",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"touch automatic.txt && printf dangerous-tail\"}",
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(
        std.meta.Tag(permission_auto_classifier.Action).command,
        fake.action_tag.?,
    );
    try std.testing.expectEqualStrings(command, fake.exact_command.?);
    try std.testing.expectEqualStrings("openai/gpt-5", fake.review_model);
    try std.testing.expectEqualStrings("test root request", fake.review_root_text);
    try std.testing.expectEqualStrings("test-review", fake.review_target_call_id);
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const result = outcome.auto_review_result orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(
        permission_auto_classifier.Decision.allow,
        result.decision,
    );
    try std.testing.expectEqualStrings(
        "The exact requested command is authorized.",
        result.rationale,
    );
    switch ((outcome.execution_authority orelse
        return error.TestExpectedEqual).run_command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| {
            try std.testing.expectEqual(
                command_admission.ShellAuthorizationSource.auto_classifier,
                authority.source,
            );
            try std.testing.expectEqualStrings(
                command,
                authority.fingerprint.command,
            );
        },
    }
}

test "automatic destructive command replans before reviewer or human prompter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{
        .decision = .ask,
        .risk = .high,
        .authorization = .low,
        .rationale = "The command exceeds the user's request.",
    };
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.permission_prompter = recording.prompter();

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "asked",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"rm -rf public\"}",
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);
    try std.testing.expectEqual(ToolPermissionDecision.deny, outcome.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, outcome.denial_reason.?);
    try std.testing.expect(outcome.execution_authority == null);
    try std.testing.expect(outcome.auto_review_result == null);
}

test "configured allow remains authoritative for a destructive command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("rm -rf public"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "configured-destructive",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"rm -rf public\"}",
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.configured_rule,
        outcome.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "delegated command effects remain reviewer owned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{ .decision = .ask };
    const input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );

    for ([_][]const u8{
        "git checkout feature/repro",
        "git switch feature/repro",
        "git pull --ff-only",
        "rtk rm -rf generated",
        "printf ok # harmless; rm victim",
        "cat <<EOF\nrm victim\nEOF",
        "rm --help",
        "rm",
        "rm -f; printf ok",
        "git rm --dry-run; printf ok",
        "rm -f < input.txt",
        "git clean -hf",
        "git rm -hf tracked.txt",
        "git reset -hq --hard",
    }) |command| {
        const arguments_json = try std.fmt.allocPrint(
            arena_state.allocator(),
            "{{\"action\":\"exec\",\"command\":{f}}}",
            .{std.json.fmt(command, .{})},
        );
        const outcome = try requestPermissionOutcome(
            input,
            arena_state.allocator(),
            .{
                .id = command,
                .name = "terminal",
                .arguments_json = arguments_json,
            },
            .auto,
            &.{},
        );
        try std.testing.expectEqual(ToolPermissionDecision.deny, outcome.decision);
        try std.testing.expect(outcome.auto_review_result != null);
    }
    try std.testing.expectEqual(@as(usize, 14), fake.calls);
}

test "automatic delete replans before reviewer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    var victim = try tmp.dir.createFile(
        std.testing.io,
        "workspace/victim.txt",
        .{ .truncate = true },
    );
    defer victim.close(std.testing.io);
    try victim.writeStreamingAll(std.testing.io, "keep\n");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const target = try std.fs.path.join(alloc, &.{ workspace, "victim.txt" });
    defer alloc.free(target);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    const arguments_json = try std.fmt.allocPrint(
        arena_state.allocator(),
        "{{\"path\":{f}}}",
        .{std.json.fmt(target, .{})},
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "delete-victim",
            .name = "delete_file",
            .arguments_json = arguments_json,
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.deny, outcome.decision);
    try std.testing.expectEqual(
        types.ToolPermissionDenialReason.auto_denied,
        outcome.denial_reason.?,
    );
    try std.testing.expect(outcome.execution_authority == null);
}

test "automatic reviewer ask returns a recoverable denial without a prompter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{
        .decision = .ask,
        .risk = .high,
        .authorization = .low,
        .rationale = "The command exceeds the user's request.",
    };
    const input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "asked",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"touch public\"}",
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.deny, outcome.decision);
    try std.testing.expectEqual(
        types.ToolPermissionDenialReason.auto_denied,
        outcome.denial_reason.?,
    );
    try std.testing.expect(outcome.execution_authority == null);
    try std.testing.expectEqualStrings(
        "The command exceeds the user's request.",
        outcome.auto_review_result.?.rationale,
    );
}

test "invalid automatic review returns to the agent before prompting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{ .invalid = true };
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.permission_prompter = recording.prompter();

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "invalid",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"touch invalid.txt\"}",
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);
    try std.testing.expectEqual(ToolPermissionDecision.deny, outcome.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, outcome.denial_reason.?);
    try std.testing.expect(outcome.execution_authority == null);
    try std.testing.expect(outcome.auto_review_result == null);
}

test "invalid automatic review returns a recoverable denial without a prompter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{ .invalid = true };
    const input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "invalid",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"touch invalid.txt\"}",
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.deny, outcome.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, outcome.denial_reason.?);
    try std.testing.expect(outcome.execution_authority == null);
    try std.testing.expect(outcome.auto_review_result == null);
}

test "human approval phase bypasses automatic review" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{ .decision = .ask };
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var review_turn = testReviewTurn();
    review_turn.auto_permission_phase = .human_approval;
    input.permission_review_turn = review_turn;
    input.permission_prompter = recording.prompter();
    const call = ToolCall{
        .id = "exhausted",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch exhausted.txt\"}",
    };

    const approved = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, approved.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expectEqualStrings(call.id, recording.last_call_id.?);

    input.permission_prompter = null;
    const headless = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, headless.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.permission_required, headless.denial_reason.?);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

test "human approval phase bypasses deterministic destructive replan" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{ .decision = .ask };
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var review_turn = testReviewTurn();
    review_turn.auto_permission_phase = .human_approval;
    input.permission_review_turn = review_turn;
    input.permission_prompter = recording.prompter();

    const approved = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "destructive-human-approval",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"rm -rf disposable-dir\"}",
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(ToolPermissionDecision.once, approved.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

test "configured command authority skips automatic review" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );

    const direct = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "direct",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"pwd\"}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_classifier,
        direct.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("touch *"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };
    var review_turn = testReviewTurn();
    review_turn.auto_permission_phase = .human_approval;
    input.permission_review_turn = review_turn;
    input.permission_prompter = recording.prompter();
    const configured = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "configured",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"touch configured.txt\"}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.configured_rule,
        configured.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);

    const compound = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "compound",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"touch configured.txt && printf bypass\"}",
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.interactive_once,
        compound.execution_authority.?.run_command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

test "automatic clean direct command bypasses the reviewer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{ .decision = .ask };
    const input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );

    const outcome = requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "clean-direct",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"pwd\",\"profile\":\"clean\"}",
        },
        .auto,
        &.{},
    ) catch |err| switch (err) {
        error.MissingLoginShell, error.UnsupportedShell => return error.SkipZigTest,
        else => return err,
    };

    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    const authority = outcome.execution_authority orelse return error.TestExpectedEqual;
    switch (authority.run_command) {
        .direct_only => |fingerprint| try std.testing.expectEqual(
            std.meta.Tag(command_environment.Environment).clean,
            std.meta.activeTag(fingerprint.environment),
        ),
        .shell_allowed => return error.TestExpectedDirectOnly,
    }
}

test "known reversible auto commands bypass the reviewer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    const input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    for ([_][]const u8{
        "node -v && npm -v",
        "git status --short --branch",
        "git fetch origin main",
        "npm install 2>&1",
        "npm run dev",
        "zig build test",
    }) |command| {
        const arguments = try std.fmt.allocPrint(
            arena_state.allocator(),
            "{{\"action\":\"exec\",\"command\":{f}}}",
            .{std.json.fmt(command, .{})},
        );
        const outcome = try requestPermissionOutcome(
            input,
            arena_state.allocator(),
            .{ .id = "ordinary", .name = "terminal", .arguments_json = arguments },
            .auto,
            &.{},
        );
        try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
        try std.testing.expectEqual(
            command_admission.ShellAuthorizationSource.auto_mode,
            outcome.execution_authority.?.run_command.shell_allowed.source,
        );
    }
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "session deny narrows configured command allow" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    var recording = RecordingPrompter{};
    var review_turn = testReviewTurn();
    review_turn.auto_permission_phase = .human_approval;
    input.permission_review_turn = review_turn;
    input.permission_prompter = recording.prompter();
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("touch *"),
        .action = .allow,
    }};
    input.permission_rules = .{ .rules = &rules };
    const call = ToolCall{
        .id = "configured-session-deny",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch configured.txt\"}",
    };
    const key = try permissionStateKeyForCall(input, arena, call);
    try std.testing.expect(std.mem.find(u8, key.canonical, "fx-permission-state-v2") != null);
    try std.testing.expect(std.mem.find(u8, key.canonical, "restricted") == null);
    try std.testing.expect(std.mem.find(u8, key.canonical, "none") == null);
    var empty: session_permission_state.State = .{};
    defer empty.deinit(alloc);
    var applied = try session_permission_state.apply(alloc, empty, .{ .set = .{
        .key = key,
        .display_identity = "touch configured.txt",
        .decision = .deny,
        .expected_generation = null,
    } });
    var state = applied.takeApplied() orelse return error.TestExpectedAppliedState;
    defer state.deinit(alloc);
    input.session_permission_state = &state;

    const denied = try requestPermissionOutcome(
        input,
        arena,
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 0), recording.calls);
}

test "prepared session deny blocks local file mutation without setup effects" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.workspace_root = workspace;
    const call = ToolCall{
        .id = "prepared-file-session-deny",
        .name = "write_file",
        .arguments_json = "{\"path\":\"blocked.txt\",\"content\":\"blocked\"}",
    };
    const identity = try preparePermissionStateAction(input, arena, call);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(io_mod.getIo(), "workspace/blocked.txt", .{}),
    );
    var empty: session_permission_state.State = .{};
    defer empty.deinit(alloc);
    var applied = try session_permission_state.apply(alloc, empty, .{ .set = .{
        .key = identity.key,
        .display_identity = identity.display_identity,
        .decision = .deny,
        .expected_generation = null,
    } });
    var state = applied.takeApplied() orelse return error.TestExpectedAppliedState;
    defer state.deinit(alloc);
    input.session_permission_state = &state;

    const denied = try requestPermissionOutcome(input, arena, call, .auto, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expect(denied.execution_authority == null);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(io_mod.getIo(), "workspace/blocked.txt", .{}),
    );
}

test "js host workspace sandbox default is lowest priority and prompt disables it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.disabled(),
    );
    input.host_sandbox_default = .allow_sandboxed;
    const call = ToolCall{
        .id = "browser-command",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"touch created.txt\"}",
    };

    const allowed = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, allowed.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.js_host,
        allowed.execution_authority.?.run_command.shell_allowed.source,
    );

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("bash"),
        .pattern = @constCast("touch *"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const denied = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.policy_denied, denied.decision);
    try std.testing.expect(denied.execution_authority == null);

    rules[0].action = .ask;
    const asked = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, asked.decision);
    try std.testing.expect(asked.execution_authority == null);

    rules[0].action = .allow;
    const explicitly_allowed = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, explicitly_allowed.decision);
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.configured_rule,
        explicitly_allowed.execution_authority.?.run_command.shell_allowed.source,
    );

    input.permission_rules = .{};
    input.host_sandbox_default = .prompt;
    const prompted = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        call,
        .auto,
        &.{},
    );
    try std.testing.expectEqual(ToolPermissionDecision.deny, prompted.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.auto_denied, prompted.denial_reason.?);
    try std.testing.expect(prompted.execution_authority == null);
}

test "built-in structured review sends exact arguments without redundant schema" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.permission_review_turn = testReviewTurn();

    const arguments = "{\"action\":\"start\",\"command\":\"printf ready\",\"backend\":\"native\"}";
    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "terminal-start-review",
            .name = "terminal",
            .arguments_json = arguments,
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings(arguments, fake.exact_arguments_json.?);
    try std.testing.expect(fake.schema_json == null);
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
}

test "selected dynamic MCP review receives exact arguments and advertised schema" {
    const Mcp = struct {
        fn hasTool(_: *anyopaque, name: []const u8, _: tool_mcp_runtime.Access) bool {
            return std.mem.eql(u8, name, "mcp_example_write");
        }

        fn schema(
            _: *anyopaque,
            alloc: Allocator,
            name: []const u8,
            _: types.PermissionRuleSet,
            _: context_limits.Values,
            _: tool_mcp_runtime.Access,
        ) anyerror!?tool_mcp_runtime.ToolSchemaResult {
            if (!std.mem.eql(u8, name, "mcp_example_write")) return null;
            return .{ .selected = .{ .model_output = try alloc.dupe(
                u8,
                "{\"name\":\"mcp_example_write\",\"inputSchema\":{\"type\":\"object\"}}",
            ) } };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var background: BackgroundRuntime = .{};
    defer background.deinit(std.testing.allocator);
    var marker: u8 = 0;
    var fake = FakeAutoClassifier{};
    const advertised = [_][]const u8{"mcp_example_write"};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.advertised_dynamic_tool_names = &advertised;
    input.mcp_runtime = .{
        .context = @ptrCast(&marker),
        .has_tool = Mcp.hasTool,
        .tool_schema = Mcp.schema,
    };

    const arguments = "{\"path\":\"outside.txt\",\"value\":\"exact\"}";
    const outcome = try requestPermissionOutcome(
        input,
        arena_state.allocator(),
        .{
            .id = "mcp-review",
            .name = "mcp_example_write",
            .arguments_json = arguments,
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings(arguments, fake.exact_arguments_json.?);
    try std.testing.expect(
        std.mem.find(u8, fake.schema_json.?, "mcp_example_write") != null,
    );
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expect(outcome.execution_authority != null);
}

test "external prepared file review carries frozen path and diff authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");

    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "external",
    );
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    const target_path = try std.fs.path.join(
        arena,
        &.{ external, "desktop-test.txt" },
    );
    {
        var existing = try tmp.dir.createFile(
            io_mod.getIo(),
            "external/desktop-test.txt",
            .{ .truncate = true },
        );
        defer existing.close(io_mod.getIo());
        try existing.writeStreamingAll(io_mod.getIo(), "before\n");
    }
    const arguments_json = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
        .{target_path},
    );
    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "write",
            .name = "write_file",
            .arguments_json = arguments_json,
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(
        std.meta.Tag(permission_auto_classifier.Action).file_mutation,
        fake.action_tag.?,
    );
    try std.testing.expectEqualStrings(
        target_path,
        fake.file_display_path.?,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.file_additions);
    try std.testing.expectEqual(@as(usize, 1), fake.file_deletions);
    try std.testing.expect(fake.file_review_rows > 0);
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const authority = outcome.execution_authority orelse
        return error.TestExpectedEqual;
    const authorization = switch (authority) {
        .file_mutation => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expect(authorization.prepared != null);
    try std.testing.expectEqualStrings(
        target_path,
        authorization.input.path(),
    );
}

test "human approval phase routes prepared file mutation through the prompter" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    {
        var existing = try tmp.dir.createFile(
            io_mod.getIo(),
            "external/prepared.txt",
            .{ .truncate = true },
        );
        defer existing.close(io_mod.getIo());
        try existing.writeStreamingAll(io_mod.getIo(), "before\n");
    }

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var recording = RecordingPrompter{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    var review_turn = testReviewTurn();
    review_turn.auto_permission_phase = .human_approval;
    input.permission_review_turn = review_turn;
    input.permission_prompter = recording.prompter();
    input.workspace_root = workspace;

    const target_path = try std.fs.path.join(arena, &.{ external, "prepared.txt" });
    const arguments_json = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
        .{target_path},
    );
    const call: ToolCall = .{
        .id = "prepared-human-approval",
        .name = "write_file",
        .arguments_json = arguments_json,
    };
    var prepared = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);

    const outcome = try requestPreparedFileMutationPermissionOutcome(
        input,
        arena,
        call,
        &prepared,
        .auto,
        &.{},
    );

    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
    try std.testing.expectEqualStrings(call.id, recording.last_call_id.?);
}

test "automatic workspace write uses reversible admission without reviewer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var editable = try tmp.dir.createFile(
        io_mod.getIo(),
        "workspace/editable.txt",
        .{ .truncate = true },
    );
    defer editable.close(io_mod.getIo());
    try editable.writeStreamingAll(io_mod.getIo(), "before\n");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    const target_path = try std.fs.path.join(arena, &.{ workspace, "note.txt" });
    const arguments_json = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
        .{target_path},
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "workspace-write",
            .name = "write_file",
            .arguments_json = arguments_json,
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    const authority = outcome.execution_authority orelse
        return error.TestExpectedEqual;
    const authorization = switch (authority) {
        .file_mutation => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expect(authorization.prepared != null);
    try std.testing.expectEqualStrings(target_path, authorization.input.path());

    const edit_target = try std.fs.path.join(arena, &.{ workspace, "editable.txt" });
    const edit_arguments = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"old_string\":\"before\",\"new_string\":\"after\"}}",
        .{edit_target},
    );
    const edit_outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "workspace-edit",
            .name = "edit_file",
            .arguments_json = edit_arguments,
        },
        .auto,
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.once, edit_outcome.decision);
    try std.testing.expect(edit_outcome.execution_authority.? == .file_mutation);
}

test "automatic added-root write bypasses reviewer while untrusted external write does not" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "added");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const added = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "added");
    defer alloc.free(added);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    var additional = [_]workspace_access.Entry{.{
        .path = @constCast(added),
        .saved = false,
        .command_line = true,
        .available = true,
        .active = true,
    }};
    input.access_scope = .{
        .primary_directory = workspace,
        .additional_directories = &additional,
    };

    const cases = [_]struct {
        id: []const u8,
        root: []const u8,
        expected_review_calls: usize,
    }{
        .{ .id = "added-write", .root = added, .expected_review_calls = 0 },
        .{ .id = "external-write", .root = external, .expected_review_calls = 0 },
    };
    for (cases) |case| {
        const target_path = try std.fs.path.join(arena, &.{ case.root, "note.txt" });
        const arguments_json = try std.fmt.allocPrint(
            arena,
            "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
            .{target_path},
        );
        const outcome = try requestPermissionOutcome(
            input,
            arena,
            .{
                .id = case.id,
                .name = "write_file",
                .arguments_json = arguments_json,
            },
            .auto,
            &.{},
        );
        try std.testing.expectEqual(case.expected_review_calls, fake.calls);
        try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
        const authority = outcome.execution_authority orelse
            return error.TestExpectedEqual;
        try std.testing.expect(authority == .file_mutation);
    }
}

test "automatic trusted-root write keeps persistence targets on reviewer path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git/hooks");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.ssh");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/Library/LaunchAgents");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;

    const relative_targets = [_][]const u8{
        ".git/hooks/pre-commit",
        ".git/config",
        ".ssh/authorized_keys",
        "Library/LaunchAgents/com.fx.smoke.plist",
    };
    for (relative_targets, 0..) |relative_target, index| {
        const target_path = try std.fs.path.join(arena, &.{ workspace, relative_target });
        const arguments_json = try std.fmt.allocPrint(
            arena,
            "{{\"path\":\"{s}\",\"content\":\"test\\n\"}}",
            .{target_path},
        );
        const outcome = try requestPermissionOutcome(
            input,
            arena,
            .{
                .id = relative_target,
                .name = "write_file",
                .arguments_json = arguments_json,
            },
            .auto,
            &.{},
        );
        try std.testing.expectEqual(index + 1, fake.calls);
        try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
    }
}

test "automatic trusted-root overwrite preserves configured read disclosure review" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var original = try tmp.dir.createFile(
        io_mod.getIo(),
        "workspace/secret.txt",
        .{ .truncate = true },
    );
    defer original.close(io_mod.getIo());
    try original.writeStreamingAll(io_mod.getIo(), "before\n");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("read_file"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    input.permission_rules = .{ .rules = &rules };
    const target_path = try std.fs.path.join(arena, &.{ workspace, "secret.txt" });
    const arguments_json = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"after\\n\"}}",
        .{target_path},
    );

    const outcome = try requestPermissionOutcome(
        input,
        arena,
        .{
            .id = "read-disclosure-write",
            .name = "write_file",
            .arguments_json = arguments_json,
        },
        .auto,
        &.{},
    );

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
}

test "automatic trusted-root folder creation bypasses reviewer while external does not" {
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
    var worker: WorkerRuntime = .{};
    defer worker.deinit(alloc);
    var background: BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var fake = FakeAutoClassifier{};
    var input = testInputWithClassifier(
        &worker,
        &background,
        permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeAutoClassifier.classify,
        ),
    );
    input.workspace_root = workspace;

    const cases = [_]struct {
        id: []const u8,
        target: []const u8,
        expected_review_calls: usize,
    }{
        .{
            .id = "workspace-folder",
            .target = try std.fs.path.join(arena, &.{ workspace, "generated" }),
            .expected_review_calls = 0,
        },
        .{
            .id = "git-hooks-folder",
            .target = try std.fs.path.join(arena, &.{ workspace, ".git", "hooks" }),
            .expected_review_calls = 1,
        },
        .{
            .id = "external-folder",
            .target = try std.fs.path.join(arena, &.{ external, "generated" }),
            .expected_review_calls = 2,
        },
    };
    for (cases) |case| {
        const arguments_json = try std.fmt.allocPrint(
            arena,
            "{{\"path\":\"{s}\"}}",
            .{case.target},
        );
        const outcome = try requestPermissionOutcome(
            input,
            arena,
            .{
                .id = case.id,
                .name = "create_folder",
                .arguments_json = arguments_json,
            },
            .auto,
            &.{},
        );
        try std.testing.expectEqual(case.expected_review_calls, fake.calls);
        try std.testing.expectEqual(ToolPermissionDecision.once, outcome.decision);
        try std.testing.expectEqual(
            command_admission.ToolExecutionAuthority.ordinary,
            outcome.execution_authority.?,
        );
    }
}

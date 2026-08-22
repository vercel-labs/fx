const std = @import("std");
const command_environment = @import("../execution/command_environment.zig");

const io_mod = @import("../shared/io.zig");
const pathing = @import("../workspace/pathing.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const text_utils = @import("../shared/text_utils.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const vision_contracts = @import("../agent/runtime/vision_contracts.zig");
const tool_args = @import("../tooling/tool_args.zig");
const output_contracts = @import("../output/output_contracts.zig");
const types = @import("../shared/types.zig");

pub const PermissionMode = types.PermissionMode;
pub const ToolPermissionDecision = types.ToolPermissionDecision;

pub const PermissionCallTarget = struct {
    role: []const u8,
    path: []u8,
};

pub const PermissionCallTargets = struct {
    items: []PermissionCallTarget,

    pub fn deinit(self: *PermissionCallTargets, alloc: std.mem.Allocator) void {
        for (self.items) |target| alloc.free(target.path);
        alloc.free(self.items);
        self.* = .{ .items = &.{} };
    }
};

const ResolvedPermissionCallTarget = struct {
    role: []const u8,
    path: []const u8,
};

pub const PermissionEngine = struct {
    mode: types.PermissionMode = .ask,
    grants: std.ArrayList(types.PermissionGrant) = .empty,
    rules: types.PermissionRuleSet = .{},

    pub fn deinit(self: *PermissionEngine, alloc: std.mem.Allocator) void {
        clearAllowedTools(alloc, &self.grants);
        self.grants.deinit(alloc);
        self.rules.deinit(alloc);
    }

    pub fn clear(self: *PermissionEngine, alloc: std.mem.Allocator) void {
        clearAllowedTools(alloc, &self.grants);
    }

    pub fn isAllowed(self: PermissionEngine, tool_name: []const u8, target_path: []const u8) bool {
        return isToolAllowed(self.grants.items, tool_name, target_path);
    }

    pub fn allow(self: *PermissionEngine, alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !void {
        try allowToolForSession(alloc, &self.grants, tool_name, target_path);
    }

    pub fn replaceRules(self: *PermissionEngine, alloc: std.mem.Allocator, next_rules: types.PermissionRuleSet) void {
        self.rules.deinit(alloc);
        self.rules = next_rules;
    }

    pub fn configuredRuleDecision(self: PermissionEngine, alloc: std.mem.Allocator, workspace_root: []const u8, tool_name: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) !RuleDecision {
        return ruleDecisionFor(alloc, self.rules, workspace_root, tool_name, target_path, target_kind);
    }

    pub fn formatPermissionsText(self: PermissionEngine, alloc: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
        return formatPermissionsStatus(alloc, workspace_root, self.mode, self.grants.items, self.rules);
    }

    pub fn formatPermissionsNoticeBody(self: PermissionEngine, alloc: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
        return (output_contracts.PermissionsSnapshot{
            .workspace_root = workspace_root,
            .mode = self.mode,
            .grants = self.grants.items,
            .rules = self.rules,
        }).renderInteractiveBody(alloc);
    }
};

pub const RuleDecision = types.RuleDecision;

pub const PermissionTargetKind = enum {
    none,
    path_existing,
    path_optional_existing,
    path_create_parent,
    path_existing_parent,
    command_cwd,
    url,
};

pub const web_search_permission = "web_search";
pub const web_fetch_permission = "web_fetch";
pub const yolo_warning_text = "YOLO enabled: fx permission checks disabled";

pub fn isWebSearchToolName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, web_search_permission);
}

pub fn isWebFetchToolName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, web_fetch_permission);
}

pub fn permissionModeLabel(mode: PermissionMode) []const u8 {
    return switch (mode) {
        .ask => "ask",
        .auto => "auto",
        .yolo => "yolo",
    };
}

pub fn permissionDecisionFromIndex(index: u8) ToolPermissionDecision {
    return switch (index) {
        0 => .once,
        1 => .always,
        else => .deny,
    };
}

pub fn clearAllowedTools(alloc: std.mem.Allocator, grants: *std.ArrayList(types.PermissionGrant)) void {
    for (grants.items) |grant| {
        alloc.free(grant.tool_name);
        alloc.free(grant.target_path);
    }
    grants.clearRetainingCapacity();
}

pub fn isToolAllowed(grants: []const types.PermissionGrant, tool_name: []const u8, target_path: []const u8) bool {
    for (grants) |entry| {
        if (std.mem.eql(u8, entry.tool_name, tool_name) and std.mem.eql(u8, entry.target_path, target_path)) {
            return true;
        }
    }
    return false;
}

pub fn allowToolForSession(
    alloc: std.mem.Allocator,
    grants: *std.ArrayList(types.PermissionGrant),
    permission_name: []const u8,
    pattern: []const u8,
) !void {
    if (isToolAllowed(grants.items, permission_name, pattern)) return;
    try appendOwnedGrant(alloc, grants, permission_name, pattern);
}

pub fn permissionTargetForCall(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) ![]const u8 {
    if (isTypedFileMutationTool(call.name)) {
        return error.TypedFileMutationTargetRequired;
    }

    if (std.mem.eql(u8, call.name, "install_skill")) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        const source = try tool_args.requiredStringArg(args, "source");
        if (tool_args.optionalStringArg(args, "skill")) |skill| {
            return std.fmt.allocPrint(arena, "{s}#{s}", .{ source, skill });
        }
        return arena.dupe(u8, source);
    }

    if (std.mem.eql(u8, call.name, "skill")) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        return arena.dupe(u8, try tool_args.requiredStringArg(args, "name"));
    }

    if (isWebSearchToolName(call.name)) {
        return arena.dupe(u8, web_search_permission);
    }

    if (isWebFetchToolName(call.name)) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        return webFetchDomainTargetForUrl(arena, try tool_args.requiredStringArg(args, "url"));
    }

    if (std.mem.eql(u8, call.name, "rename_file")) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        const old_path = try tool_args.requiredStringArg(args, "old_path");
        return resolveFileToolPath(arena, workspace_root, call.name, old_path, .existing);
    }

    if (std.mem.eql(u8, call.name, "copy_file")) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        const source = try tool_args.requiredStringArg(args, "source");
        return resolveFileToolPath(arena, workspace_root, call.name, source, .existing);
    }

    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);

    return switch (target_kind) {
        .command_cwd => blk: {
            const command = try tool_args.requiredStringArg(args, "command");
            const cwd = try resolveCommandCwdFromArgs(arena, workspace_root, args);
            break :blk std.fmt.allocPrint(arena, "{s}::{s}", .{ cwd, command });
        },
        .url => arena.dupe(u8, try tool_args.requiredStringArg(args, "url")),
        .path_optional_existing => blk: {
            const path_arg = tool_args.optionalStringArg(args, "path") orelse ".";
            break :blk if (std.mem.eql(u8, path_arg, "."))
                arena.dupe(u8, workspace_root)
            else
                try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .existing);
        },
        .path_create_parent => blk: {
            const path_arg = try tool_args.requiredStringArg(args, "path");
            const target_path = try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .create);
            break :blk std.fs.path.dirname(target_path) orelse target_path;
        },
        .path_existing_parent => blk: {
            const path_arg = try tool_args.requiredStringArg(args, "path");
            const target_path = try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .existing);
            break :blk std.fs.path.dirname(target_path) orelse target_path;
        },
        .path_existing => blk: {
            const path_arg = try tool_args.requiredStringArg(args, "path");
            break :blk try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .existing);
        },
        .none => try arena.dupe(u8, call.name),
    };
}

pub fn resolveCommandCwdForCallInScope(
    alloc: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const args = try tool_args.parseToolArgsObject(scratch, call.arguments_json);
    const cwd = try resolveCommandCwdFromArgsInScope(scratch, scope, args);
    return alloc.dupe(u8, cwd);
}

fn resolveCommandCwdFromArgs(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    args: std.json.ObjectMap,
) ![]const u8 {
    const cwd_input = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
    if (std.mem.eql(u8, cwd_input, ".")) return arena.dupe(u8, workspace_root);
    return pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, cwd_input);
}

fn resolveCommandCwdFromArgsInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    args: std.json.ObjectMap,
) ![]const u8 {
    const cwd_input = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
    if (std.mem.eql(u8, cwd_input, ".")) return arena.dupe(u8, scope.primary_directory);
    return pathing.resolveWorkspaceOrExternalPath(arena, scope.primary_directory, cwd_input);
}

pub fn permissionTargetsForCall(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) !PermissionCallTargets {
    if (isTypedFileMutationTool(call.name)) {
        return error.TypedFileMutationTargetRequired;
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    if (std.mem.eql(u8, call.name, "vision")) {
        const request = vision_contracts.parse_vision_request(
            scratch,
            call.arguments_json,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolArguments,
        };
        defer request.deinit(scratch);
        if (request.paths()) |paths| {
            const targets = try scratch.alloc(ResolvedPermissionCallTarget, paths.len);
            for (paths, 0..) |path, index| {
                const resolved = try pathing.resolveWorkspaceOrExternalPath(
                    scratch,
                    workspace_root,
                    path,
                );
                for (targets[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.path, resolved)) {
                        return error.InvalidToolArguments;
                    }
                }
                targets[index] = .{ .role = "image", .path = resolved };
            }
            return ownedPermissionCallTargets(alloc, targets);
        }
    }

    if (std.mem.eql(u8, call.name, "rename_file")) {
        const args = try tool_args.parseToolArgsObject(scratch, call.arguments_json);
        const old_path = try tool_args.requiredStringArg(args, "old_path");
        const new_path = try tool_args.requiredStringArg(args, "new_path");
        const source = try resolveFileToolPath(scratch, workspace_root, call.name, old_path, .existing);
        const destination = try resolveFileToolPath(scratch, workspace_root, call.name, new_path, .create);
        return ownedPermissionCallTargets(alloc, &.{
            .{ .role = "source", .path = source },
            .{ .role = "destination", .path = destination },
        });
    }

    if (std.mem.eql(u8, call.name, "copy_file")) {
        const args = try tool_args.parseToolArgsObject(scratch, call.arguments_json);
        const source_arg = try tool_args.requiredStringArg(args, "source");
        const destination_arg = try tool_args.requiredStringArg(args, "destination");
        const source = try resolveFileToolPath(scratch, workspace_root, call.name, source_arg, .existing);
        const destination = try resolveFileToolPath(scratch, workspace_root, call.name, destination_arg, .create);
        return ownedPermissionCallTargets(alloc, &.{
            .{ .role = "source", .path = source },
            .{ .role = "destination", .path = destination },
        });
    }

    if (std.mem.eql(u8, call.name, "create_folder")) {
        const args = try tool_args.parseToolArgsObject(scratch, call.arguments_json);
        const path_arg = try tool_args.requiredStringArg(args, "path");
        const target = try resolveFileToolPath(scratch, workspace_root, call.name, path_arg, .create);
        const parent = std.fs.path.dirname(target) orelse target;
        return ownedPermissionCallTargets(alloc, &.{
            .{ .role = "target", .path = target },
            .{ .role = "parent", .path = parent },
        });
    }

    const target = try permissionTargetForCall(scratch, workspace_root, call, target_kind);
    return ownedPermissionCallTargets(alloc, &.{.{ .role = "target", .path = target }});
}

pub fn permissionTargetsForCallInScope(
    alloc: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) !PermissionCallTargets {
    if (target_kind != .command_cwd and !std.mem.eql(u8, call.name, "semantic_search")) {
        return permissionTargetsForCall(alloc, scope.primary_directory, call, target_kind);
    }
    const target = try permissionTargetForCallInScope(alloc, scope, call, target_kind);
    defer alloc.free(@constCast(target));
    return ownedPermissionCallTargets(alloc, &.{.{ .role = "target", .path = target }});
}

pub fn permissionTargetForCallInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) ![]const u8 {
    if (std.mem.eql(u8, call.name, "semantic_search")) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        const path_arg = tool_args.optionalStringArg(args, "path") orelse ".";
        return if (std.mem.eql(u8, path_arg, "."))
            arena.dupe(u8, scope.primary_directory)
        else
            scope.resolvePath(arena, path_arg, .existing);
    }
    if (target_kind != .command_cwd) {
        return permissionTargetForCall(arena, scope.primary_directory, call, target_kind);
    }
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const command = try tool_args.requiredStringArg(args, "command");
    const cwd = try resolveCommandCwdFromArgsInScope(arena, scope, args);
    return std.fmt.allocPrint(arena, "{s}::{s}", .{ cwd, command });
}

/// Resolves the canonical requested path without requiring it to exist.
/// Callers must first establish that the tool's ordinary target contract is
/// an existing `path` argument.
pub fn missingPathTargetForCallInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
) ![]const u8 {
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const path_arg = try tool_args.requiredStringArg(args, "path");
    return resolveFileToolPath(
        arena,
        scope.primary_directory,
        call.name,
        path_arg,
        .create,
    );
}

/// Returns a normalized scope-checked identity for an existing-path request
/// whose filesystem lookup failed before the tool could report that failure.
/// This does not establish that the path exists or authorize execution.
pub fn unresolvedPathTargetForCallInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
) ![]const u8 {
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const raw = std.mem.trim(
        u8,
        try tool_args.requiredStringArg(args, "path"),
        " \t\r\n",
    );
    if (raw.len == 0 or raw.len > std.fs.max_path_bytes or
        !std.unicode.utf8ValidateSlice(raw) or
        std.mem.findScalar(u8, raw, 0) != null or
        std.mem.startsWith(u8, raw, "~"))
    {
        return error.InvalidPath;
    }
    const resolved = if (std.fs.path.isAbsolute(raw))
        try std.fs.path.resolve(arena, &.{raw})
    else
        try std.fs.path.resolve(arena, &.{ scope.primary_directory, raw });
    if (!scope.contains(resolved)) return error.PathOutsideWorkspace;
    return resolved;
}

fn isTypedFileMutationTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit_file");
}

const FileTargetEvaluationError = error{
    OutOfMemory,
    Canceled,
    Unexpected,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

const FileTargetResolverError = @typeInfo(@typeInfo(@TypeOf(pathing.resolveFileMutationTargetBounded)).@"fn".return_type.?).error_union.error_set;

const FileTargetDraft = struct {
    kind: file_mutation_contract.PermissionTargetKind,
    disposition: file_mutation_contract.FileTargetDisposition,
    path_end: usize,
    expected_identity: ?file_mutation_contract.FileIdentity,
    rule: types.RuleDecision = .none,
    session_grant_allowed: bool = false,
};

const FileTargetWalk = struct {
    anchor_identity: file_mutation_contract.FileIdentity,
    target_identity: ?file_mutation_contract.FileIdentity,
};

const FileTargetWalkResult = union(enum) {
    failure: file_mutation_contract.FileTargetResolutionFailure,
    ok: FileTargetWalk,
};

const FileTargetPolicyDecision = union(enum) {
    denied_target_index: usize,
    prompt_required: bool,
};

pub fn prepareFileMutationTargets(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    input: file_mutation_contract.FileMutationInput,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPreparationResult {
    const mode: types.ResolveMode = switch (input) {
        .write => .create,
        .edit => .existing,
    };

    var primary_path_scratch: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var secondary_path_scratch: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var bounded_component_scratch: [file_mutation_contract.max_file_target_components]pathing.BoundedFileTargetComponent = undefined;
    const bounded = pathing.resolveFileMutationTargetBounded(
        workspace_root,
        input.path(),
        mode,
        &primary_path_scratch,
        &secondary_path_scratch,
        &bounded_component_scratch,
    ) catch |err| {
        const failure = normalizeFileTargetResolverError(err) catch |operational| return operational;
        return .{ .target_resolution_failure = failure };
    };

    if (!boundedResolutionValid(bounded)) {
        return .{ .target_resolution_failure = .invalid_path };
    }

    const component_count = bounded.relative_components.len;
    const traversal_count = component_count - 1;
    const worst_case_item_count = @max(component_count, 2);
    const proof_charge = file_mutation_contract.proofCharge(
        bounded.canonical_target_path.len,
        component_count,
        traversal_count,
        worst_case_item_count,
    ) orelse return .{ .target_resolution_failure = .policy_proof_too_large };
    if (proof_charge > file_mutation_contract.max_file_target_proof_bytes) {
        return .{ .target_resolution_failure = .policy_proof_too_large };
    }

    var traversal_scratch: [file_mutation_contract.max_file_target_components]file_mutation_contract.TraversalDirectory = undefined;
    const traversal = traversal_scratch[0..traversal_count];
    const walk = switch (try walkFileTargetDirectories(bounded, mode, traversal)) {
        .failure => |failure| return .{ .target_resolution_failure = failure },
        .ok => |value| value,
    };

    var draft_scratch: [file_mutation_contract.max_file_target_components + 1]FileTargetDraft = undefined;
    const item_count = assembleFileTargetDrafts(bounded, walk, traversal, &draft_scratch);
    const drafts = draft_scratch[0..item_count];

    return .{ .prepared = try ownedResolvedFileTargets(
        alloc,
        bounded,
        walk.anchor_identity,
        traversal,
        drafts,
    ) };
}

pub fn evaluatePreparedFileMutationTargets(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    kind: file_mutation_contract.Kind,
    prepared: *file_mutation_contract.ResolvedFileMutationTargets,
    permission_mode: types.PermissionMode,
    rules: types.PermissionRuleSet,
    session_grants: []const types.PermissionGrant,
    local_grants: []const types.PermissionGrant,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPolicyResult {
    return evaluatePreparedFileMutationTargetsInScope(
        alloc,
        workspace_access.AccessScope.primaryOnly(workspace_root),
        kind,
        prepared,
        permission_mode,
        rules,
        session_grants,
        local_grants,
    );
}

pub fn evaluatePreparedFileMutationTargetsInScope(
    alloc: std.mem.Allocator,
    access_scope: workspace_access.AccessScope,
    kind: file_mutation_contract.Kind,
    prepared: *file_mutation_contract.ResolvedFileMutationTargets,
    _: types.PermissionMode,
    rules: types.PermissionRuleSet,
    session_grants: []const types.PermissionGrant,
    local_grants: []const types.PermissionGrant,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPolicyResult {
    const workspace_root = access_scope.primary_directory;
    var resolved = prepared.*;
    prepared.relinquish();
    defer resolved.deinit(alloc);
    if (!resolved.proofValid()) {
        return .{ .target_resolution_failure = .invalid_path };
    }

    var draft_scratch: [file_mutation_contract.max_file_target_components + 1]FileTargetDraft = undefined;
    const drafts = draft_scratch[0..resolved.items.len];
    for (resolved.items, drafts) |item, *draft| {
        draft.* = .{
            .kind = item.kind,
            .disposition = item.disposition,
            .path_end = item.path_end,
            .expected_identity = item.expected_identity,
        };
    }

    const tool_name = switch (kind) {
        .write => "write_file",
        .edit => "edit_file",
    };
    const prompt_required = switch (decideFileTargetPolicy(
        resolved.canonical_target_path,
        workspace_root,
        tool_name,
        rules,
        session_grants,
        local_grants,
        drafts,
    )) {
        .denied_target_index => |target_index| return .{ .policy_denied = .{ .target_index = target_index } },
        .prompt_required => |prompt| prompt,
    };

    const evaluated = try policyEvaluatedTargetsFromResolved(
        alloc,
        &resolved,
        drafts,
        prompt_required,
    );
    return .{ .evaluated = evaluated };
}

/// Consumes a structurally validated target proof and projects policy-neutral
/// execution targets for YOLO admission.
pub fn authorizePreparedFileMutationTargets(
    alloc: std.mem.Allocator,
    prepared: *file_mutation_contract.ResolvedFileMutationTargets,
) error{OutOfMemory}!file_mutation_contract.FileTargetPolicyResult {
    var resolved = prepared.*;
    prepared.relinquish();
    defer resolved.deinit(alloc);
    if (!resolved.proofValid()) {
        return .{ .target_resolution_failure = .invalid_path };
    }

    var draft_scratch: [file_mutation_contract.max_file_target_components + 1]FileTargetDraft = undefined;
    const drafts = draft_scratch[0..resolved.items.len];
    for (resolved.items, drafts) |item, *draft| {
        draft.* = .{
            .kind = item.kind,
            .disposition = item.disposition,
            .path_end = item.path_end,
            .expected_identity = item.expected_identity,
            .rule = .allow,
        };
    }

    return .{ .evaluated = try policyEvaluatedTargetsFromResolved(
        alloc,
        &resolved,
        drafts,
        false,
    ) };
}

pub fn evaluateFileMutationTargets(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    input: file_mutation_contract.FileMutationInput,
    permission_mode: types.PermissionMode,
    rules: types.PermissionRuleSet,
    session_grants: []const types.PermissionGrant,
    local_grants: []const types.PermissionGrant,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPolicyResult {
    var prepared = switch (try prepareFileMutationTargets(
        alloc,
        workspace_root,
        input,
    )) {
        .target_resolution_failure => |failure| return .{ .target_resolution_failure = failure },
        .prepared => |value| value,
    };
    return evaluatePreparedFileMutationTargets(
        alloc,
        workspace_root,
        std.meta.activeTag(input),
        &prepared,
        permission_mode,
        rules,
        session_grants,
        local_grants,
    );
}

fn walkFileTargetDirectories(
    bounded: pathing.BoundedFileTargetResolution,
    mode: types.ResolveMode,
    traversal: []file_mutation_contract.TraversalDirectory,
) FileTargetEvaluationError!FileTargetWalkResult {
    const zio = io_mod.getIo();
    var current_dir = std.Io.Dir.openDirAbsolute(
        zio,
        bounded.canonical_target_path[0..bounded.anchor_path_end],
        .{ .follow_symlinks = false },
    ) catch |err| {
        const failure = normalizeDirOpenError(err) catch |operational| return operational;
        return .{ .failure = failure };
    };
    defer current_dir.close(zio);

    const anchor_stat = current_dir.statFile(zio, ".", .{ .follow_symlinks = false }) catch |err| {
        const failure = normalizeStatFileError(err) catch |operational| return operational;
        return .{ .failure = failure };
    };
    if (anchor_stat.kind != .directory) {
        return .{ .failure = .not_directory };
    }
    const anchor_identity = pathing.fileIdentity(
        try pathing.descriptorDevice(current_dir.handle),
        anchor_stat,
    );

    var missing_parent_seen = false;
    for (bounded.relative_components[0..traversal.len], 0..) |component, component_index| {
        const path_end = component.end;
        if (missing_parent_seen) {
            traversal[component_index] = .{
                .component_index = component_index,
                .path_end = path_end,
                .state = .{ .create = .{ .permission_target_index = undefined } },
            };
            continue;
        }

        const component_name = bounded.canonical_target_path[component.start..component.end];
        const next_dir = current_dir.openDir(zio, component_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                if (mode == .existing) {
                    return .{ .failure = .file_not_found };
                }
                missing_parent_seen = true;
                traversal[component_index] = .{
                    .component_index = component_index,
                    .path_end = path_end,
                    .state = .{ .create = .{ .permission_target_index = undefined } },
                };
                continue;
            },
            else => {
                const failure = normalizeDirOpenError(err) catch |operational| return operational;
                return .{ .failure = failure };
            },
        };

        const child_stat = next_dir.statFile(zio, ".", .{ .follow_symlinks = false }) catch |err| {
            next_dir.close(zio);
            const failure = normalizeStatFileError(err) catch |operational| return operational;
            return .{ .failure = failure };
        };
        if (child_stat.kind != .directory) {
            next_dir.close(zio);
            return .{ .failure = .not_directory };
        }
        const child_device = pathing.descriptorDevice(next_dir.handle) catch |err| {
            next_dir.close(zio);
            return err;
        };
        const child_identity = pathing.fileIdentity(child_device, child_stat);
        traversal[component_index] = .{
            .component_index = component_index,
            .path_end = path_end,
            .state = .{ .existing = child_identity },
        };

        current_dir.close(zio);
        current_dir = next_dir;
    }

    const target_component = bounded.relative_components[bounded.relative_components.len - 1];
    const target_name = bounded.canonical_target_path[target_component.start..target_component.end];
    var target_identity: ?file_mutation_contract.FileIdentity = null;
    if (!missing_parent_seen) {
        const target_stat = current_dir.statFile(zio, target_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => if (mode == .existing) {
                return .{ .failure = .file_not_found };
            } else null,
            else => {
                const failure = normalizeStatFileError(err) catch |operational| return operational;
                return .{ .failure = failure };
            },
        };
        if (target_stat) |stat| {
            target_identity = pathing.fileIdentity(
                try pathing.directoryEntryDevice(current_dir, target_name),
                stat,
            );
        }
    }

    return .{ .ok = .{
        .anchor_identity = anchor_identity,
        .target_identity = target_identity,
    } };
}

fn assembleFileTargetDrafts(
    bounded: pathing.BoundedFileTargetResolution,
    walk: FileTargetWalk,
    traversal: []file_mutation_contract.TraversalDirectory,
    drafts: []FileTargetDraft,
) usize {
    var item_count: usize = 0;
    drafts[item_count] = .{
        .kind = .target,
        .disposition = .target_entry,
        .path_end = bounded.canonical_target_path.len,
        .expected_identity = walk.target_identity,
    };
    item_count += 1;

    if (traversal.len == 0) {
        drafts[item_count] = .{
            .kind = .parent,
            .disposition = .existing_parent,
            .path_end = bounded.anchor_path_end,
            .expected_identity = walk.anchor_identity,
        };
    } else {
        const parent_index = traversal.len - 1;
        drafts[item_count] = switch (traversal[parent_index].state) {
            .existing => |identity| .{
                .kind = .parent,
                .disposition = .existing_parent,
                .path_end = traversal[parent_index].path_end,
                .expected_identity = identity,
            },
            .create => .{
                .kind = .parent,
                .disposition = .create_parent,
                .path_end = traversal[parent_index].path_end,
                .expected_identity = null,
            },
        };
        switch (traversal[parent_index].state) {
            .existing => {},
            .create => traversal[parent_index].state.create.permission_target_index = item_count,
        }
    }
    item_count += 1;

    var parent_index = if (traversal.len > 1) traversal.len - 1 else 0;
    while (parent_index > 0) {
        parent_index -= 1;
        switch (traversal[parent_index].state) {
            .existing => {},
            .create => {
                traversal[parent_index].state.create.permission_target_index = item_count;
                drafts[item_count] = .{
                    .kind = .parent,
                    .disposition = .create_parent,
                    .path_end = traversal[parent_index].path_end,
                    .expected_identity = null,
                };
                item_count += 1;
            },
        }
    }
    return item_count;
}

fn decideFileTargetPolicy(
    canonical_target_path: []const u8,
    workspace_root: []const u8,
    tool_name: []const u8,
    rules: types.PermissionRuleSet,
    session_grants: []const types.PermissionGrant,
    local_grants: []const types.PermissionGrant,
    drafts: []FileTargetDraft,
) FileTargetPolicyDecision {
    var first_denied_index: ?usize = null;
    for (drafts, 0..) |*draft, index| {
        const target_path = canonical_target_path[0..draft.path_end];
        draft.rule = fileTargetRuleDecision(rules, workspace_root, tool_name, target_path);
        draft.session_grant_allowed =
            sessionGrantAllowed(session_grants, tool_name, target_path) or
            sessionGrantAllowed(local_grants, tool_name, target_path);
        if (draft.rule == .deny and first_denied_index == null) {
            first_denied_index = index;
        }
    }
    if (first_denied_index) |target_index| {
        return .{ .denied_target_index = target_index };
    }

    var prompt_required = false;
    for (drafts) |draft| {
        if (draft.session_grant_allowed) continue;
        switch (draft.rule) {
            .allow => {},
            .ask => prompt_required = true,
            .none => prompt_required = true,
            .deny => unreachable,
        }
    }
    return .{ .prompt_required = prompt_required };
}

fn ownedResolvedFileTargets(
    alloc: std.mem.Allocator,
    bounded: pathing.BoundedFileTargetResolution,
    anchor_identity: file_mutation_contract.FileIdentity,
    traversal: []const file_mutation_contract.TraversalDirectory,
    drafts: []const FileTargetDraft,
) error{OutOfMemory}!file_mutation_contract.ResolvedFileMutationTargets {
    const canonical_target_path = try alloc.dupe(u8, bounded.canonical_target_path);
    errdefer alloc.free(canonical_target_path);
    const relative_components = try alloc.alloc(file_mutation_contract.PathSpan, bounded.relative_components.len);
    errdefer alloc.free(relative_components);
    const traversal_directories = try alloc.alloc(file_mutation_contract.TraversalDirectory, traversal.len);
    errdefer alloc.free(traversal_directories);
    const items = try alloc.alloc(file_mutation_contract.ResolvedPermissionTarget, drafts.len);
    errdefer alloc.free(items);

    for (bounded.relative_components, relative_components) |source, *destination| {
        destination.* = .{ .start = source.start, .end = source.end };
    }
    @memcpy(traversal_directories, traversal);
    for (drafts, items) |draft, *item| {
        item.* = .{
            .kind = draft.kind,
            .disposition = draft.disposition,
            .path_end = draft.path_end,
            .expected_identity = draft.expected_identity,
        };
    }

    return .{
        .canonical_target_path = canonical_target_path,
        .anchor = .{
            .scope = if (bounded.anchor_is_external) .external else .workspace,
            .path_end = bounded.anchor_path_end,
            .identity = anchor_identity,
            .relative_components = relative_components,
        },
        .traversal_directories = traversal_directories,
        .items = items,
    };
}

fn policyEvaluatedTargetsFromResolved(
    alloc: std.mem.Allocator,
    resolved: *file_mutation_contract.ResolvedFileMutationTargets,
    drafts: []const FileTargetDraft,
    prompt_required: bool,
) error{OutOfMemory}!file_mutation_contract.PolicyEvaluatedFileTargets {
    const items = try alloc.alloc(file_mutation_contract.EvaluatedPermissionTarget, drafts.len);
    errdefer alloc.free(items);
    for (drafts, items) |draft, *item| {
        item.* = .{
            .kind = draft.kind,
            .disposition = draft.disposition,
            .path_end = draft.path_end,
            .expected_identity = draft.expected_identity,
            .rule = draft.rule,
            .session_grant_allowed = draft.session_grant_allowed,
        };
    }

    alloc.free(@constCast(resolved.items));
    const evaluated: file_mutation_contract.PolicyEvaluatedFileTargets = .{
        .canonical_target_path = resolved.canonical_target_path,
        .anchor = resolved.anchor,
        .traversal_directories = resolved.traversal_directories,
        .items = items,
        .prompt_required = prompt_required,
    };
    resolved.relinquish();
    return evaluated;
}

fn boundedResolutionValid(resolution: pathing.BoundedFileTargetResolution) bool {
    if (resolution.canonical_target_path.len == 0) return false;
    if (!std.fs.path.isAbsolute(resolution.canonical_target_path)) return false;
    if (resolution.anchor_path_end == 0 or resolution.anchor_path_end > resolution.canonical_target_path.len) return false;
    if (resolution.relative_components.len == 0) return false;
    if (resolution.relative_components.len > file_mutation_contract.max_file_target_components) return false;

    var expected_start = if (resolution.anchor_path_end == 1)
        resolution.anchor_path_end
    else
        resolution.anchor_path_end + 1;
    for (resolution.relative_components) |component| {
        if (component.start != expected_start) return false;
        if (component.end <= component.start or component.end > resolution.canonical_target_path.len) return false;
        expected_start = component.end + 1;
    }
    return resolution.relative_components[resolution.relative_components.len - 1].end == resolution.canonical_target_path.len;
}

fn fileTargetRuleDecision(
    rules: types.PermissionRuleSet,
    workspace_root: []const u8,
    tool_name: []const u8,
    target_path: []const u8,
) types.RuleDecision {
    const pattern = if (pathing.pathInside(workspace_root, target_path))
        workspaceRelativePermissionPath(workspace_root, target_path)
    else
        target_path;
    return evaluateRulesetForTool(rules.rules, permissionNameForTool(tool_name), tool_name, pattern) orelse .none;
}

fn workspaceRelativePermissionPath(workspace_root: []const u8, target_path: []const u8) []const u8 {
    if (std.mem.eql(u8, workspace_root, target_path)) return ".";
    if (std.mem.eql(u8, workspace_root, "/")) return target_path[1..];
    return target_path[workspace_root.len + 1 ..];
}

fn normalizeFileTargetResolverError(err: FileTargetResolverError) FileTargetEvaluationError!file_mutation_contract.FileTargetResolutionFailure {
    return switch (err) {
        error.PathOutsideWorkspace => .path_outside_workspace,
        error.FileNotFound => .file_not_found,
        error.HomeNotSet => .home_not_set,
        error.InvalidPath => .invalid_path,
        error.WorkspaceUnavailable => .workspace_unavailable,
        error.TooManyPathComponents => .too_many_path_components,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.NotDir => .not_directory,
        error.SymLinkLoop => .symlink_loop,
        error.NameTooLong => .name_too_long,
        error.BadPathName => .bad_path_name,
        error.NotLink, error.IsDir, error.PathAlreadyExists => .path_state_changed,
        error.OperationUnsupported, error.UnsupportedReparsePointType => .unsupported_path_operation,
        error.NoDevice,
        error.NetworkNotFound,
        error.UnrecognizedVolume,
        error.InputOutput,
        error.FileSystem,
        error.FileTooBig,
        error.NoSpaceLeft,
        error.ReadOnlyFileSystem,
        error.DeviceBusy,
        error.FileBusy,
        error.PipeBusy,
        error.FileLocksUnsupported,
        error.WouldBlock,
        error.AntivirusInterference,
        error.Streaming,
        => .filesystem_unavailable,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn normalizeDirOpenError(err: std.Io.Dir.OpenError) FileTargetEvaluationError!file_mutation_contract.FileTargetResolutionFailure {
    return switch (err) {
        error.FileNotFound => .file_not_found,
        error.NotDir => .not_directory,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.SymLinkLoop => .symlink_loop,
        error.NoDevice, error.NetworkNotFound => .filesystem_unavailable,
        error.NameTooLong => .name_too_long,
        error.BadPathName => .bad_path_name,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn normalizeStatFileError(err: std.Io.Dir.StatFileError) FileTargetEvaluationError!file_mutation_contract.FileTargetResolutionFailure {
    return switch (err) {
        error.FileNotFound => .file_not_found,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.NotDir => .not_directory,
        error.SymLinkLoop => .symlink_loop,
        error.NameTooLong => .name_too_long,
        error.BadPathName => .bad_path_name,
        error.IsDir, error.PathAlreadyExists => .path_state_changed,
        error.PipeBusy,
        error.NoDevice,
        error.NetworkNotFound,
        error.AntivirusInterference,
        error.FileTooBig,
        error.NoSpaceLeft,
        error.ReadOnlyFileSystem,
        error.DeviceBusy,
        error.FileLocksUnsupported,
        error.FileBusy,
        error.WouldBlock,
        error.Streaming,
        => .filesystem_unavailable,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn ownedPermissionCallTargets(
    alloc: std.mem.Allocator,
    source: []const ResolvedPermissionCallTarget,
) !PermissionCallTargets {
    const items = try alloc.alloc(PermissionCallTarget, source.len);
    errdefer alloc.free(items);

    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |target| alloc.free(target.path);
    }

    for (source, 0..) |target, index| {
        items[index] = .{
            .role = target.role,
            .path = try alloc.dupe(u8, target.path),
        };
        initialized += 1;
    }
    return .{ .items = items };
}

pub fn resolveFileToolPath(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    tool_name: []const u8,
    path_arg: []const u8,
    mode: types.ResolveMode,
) ![]const u8 {
    if (!allowsExternalPath(tool_name)) {
        return pathing.resolveWorkspacePath(arena, workspace_root, path_arg, mode);
    }

    return switch (mode) {
        .existing => pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, path_arg),
        .create => pathing.resolveWorkspaceOrExternalCreatePath(arena, workspace_root, path_arg),
    };
}

const external_path_tools = [_][]const u8{
    "read_file",
    "list_files",
    "glob_files",
    "grep_files",
    "open_file",
    "file_info",
    "write_file",
    "edit_file",
    "delete_file",
    "create_folder",
    "copy_file",
    "rename_file",
};

pub fn allowsExternalPath(tool_name: []const u8) bool {
    for (external_path_tools) |eligible| {
        if (std.mem.eql(u8, tool_name, eligible)) return true;
    }
    return false;
}

test "allowsExternalPath preserves the exact eligible tool set" {
    const expected = [_][]const u8{
        "read_file",
        "list_files",
        "glob_files",
        "grep_files",
        "open_file",
        "file_info",
        "write_file",
        "edit_file",
        "delete_file",
        "create_folder",
        "copy_file",
        "rename_file",
    };

    try std.testing.expectEqual(expected.len, external_path_tools.len);
    for (expected, external_path_tools) |expected_name, actual_name| {
        try std.testing.expectEqualStrings(expected_name, actual_name);
        try std.testing.expect(allowsExternalPath(expected_name));
    }
    try std.testing.expect(!allowsExternalPath("semantic_search"));
    try std.testing.expect(!allowsExternalPath("run_command"));
    try std.testing.expect(!allowsExternalPath("missing_tool"));
}

pub fn isFilesystemMutationTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit_file") or
        std.mem.eql(u8, tool_name, "delete_file") or
        std.mem.eql(u8, tool_name, "create_folder") or
        std.mem.eql(u8, tool_name, "copy_file") or
        std.mem.eql(u8, tool_name, "rename_file");
}

pub fn displayTargetForPolicy(alloc: std.mem.Allocator, workspace_root: []const u8, tool_name: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) ![]u8 {
    if (std.mem.eql(u8, tool_name, "copy_file") or std.mem.eql(u8, tool_name, "rename_file")) {
        return displayPathTarget(alloc, workspace_root, target_path);
    }

    return switch (target_kind) {
        .command_cwd => displayCommandTarget(alloc, workspace_root, target_path),
        .path_existing, .path_optional_existing, .path_create_parent, .path_existing_parent => displayPathTarget(alloc, workspace_root, target_path),
        else => alloc.dupe(u8, target_path),
    };
}

pub fn ruleDecisionFor(alloc: std.mem.Allocator, rules: types.PermissionRuleSet, workspace_root: []const u8, tool_name: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) !RuleDecision {
    const permission = permissionNameForTool(tool_name);
    const pattern = try patternForRuleMatch(alloc, workspace_root, tool_name, target_path, target_kind);
    defer alloc.free(pattern);

    return evaluateRulesetForTool(rules.rules, permission, tool_name, pattern) orelse .none;
}

pub fn ruleDecisionForPermissionPattern(rules: types.PermissionRuleSet, permission: []const u8, pattern: []const u8, fallback: RuleDecision) RuleDecision {
    return evaluateRuleset(rules.rules, permission, pattern) orelse fallback;
}

pub fn rulesDenyAllTargetsForPermission(rules: types.PermissionRuleSet, permission: []const u8) bool {
    return rulesDenyAllTargetsForPermissionAndTool(rules, permission, null);
}

pub fn rulesDenyAllTargetsForTool(rules: types.PermissionRuleSet, tool_name: []const u8) bool {
    if (isWebFetchToolName(tool_name)) return false;
    return rulesDenyAllTargetsForPermissionAndTool(rules, permissionNameForTool(tool_name), tool_name);
}

fn rulesDenyAllTargetsForPermissionAndTool(rules: types.PermissionRuleSet, permission: []const u8, tool_name: ?[]const u8) bool {
    var last_global_deny_index: ?usize = null;
    for (rules.rules, 0..) |rule, index| {
        if (!ruleMatchesPermission(rule.permission, permission, tool_name)) continue;
        if (!isGlobalTargetPattern(rule.pattern)) continue;
        last_global_deny_index = switch (rule.action) {
            .allow, .ask => null,
            .deny => index,
        };
    }

    const deny_index = last_global_deny_index orelse return false;
    for (rules.rules[deny_index + 1 ..]) |rule| {
        if (!ruleMatchesPermission(rule.permission, permission, tool_name)) continue;
        switch (rule.action) {
            .deny => {},
            .allow, .ask => {
                const decision = evaluateRulesetForTool(rules.rules, permission, tool_name, rule.pattern) orelse .none;
                if (decision == .allow or decision == .ask) return false;
            },
        }
    }

    return true;
}

pub fn sessionGrantAllowed(grants: []const types.PermissionGrant, tool_name: []const u8, target_path: []const u8) bool {
    const permission = permissionNameForTool(tool_name);
    const pattern = patternForSessionGrantMatch(tool_name, target_path);

    if (std.mem.eql(u8, permission, web_fetch_permission)) {
        if (!isCanonicalWebFetchDomainPattern(pattern)) return false;
        for (grants) |grant| {
            if (!std.mem.eql(u8, grant.tool_name, web_fetch_permission)) continue;
            if (!isCanonicalWebFetchDomainPattern(grant.target_path)) continue;
            if (std.mem.eql(u8, grant.target_path, pattern)) return true;
        }
        return false;
    }

    for (grants) |grant| {
        if (!permissionPatternMatchesTool(grant.tool_name, permission, tool_name)) continue;
        if (std.mem.eql(u8, permission, "bash")) {
            if (!std.mem.eql(u8, grant.target_path, pattern)) continue;
        } else if (!permissionPatternMatchesTarget(grant.target_path, pattern)) continue;
        return true;
    }
    return false;
}

const path_always_permissions = [_][]const u8{
    "edit",
    "create_folder",
    "open_file",
    "rename_file",
    "copy_file",
    "read",
    "list",
    "glob",
    "grep",
};

pub fn suggestedSessionGrants(alloc: std.mem.Allocator, workspace_root: []const u8, tool_name: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) ![]types.PermissionGrant {
    const permission = permissionNameForTool(tool_name);
    var grants: std.ArrayList(types.PermissionGrant) = .empty;
    errdefer {
        clearAllowedTools(alloc, &grants);
        grants.deinit(alloc);
    }

    if (std.mem.eql(u8, permission, "bash")) {
        const command = patternForSessionGrantMatch(tool_name, target_path);

        try appendOwnedGrant(alloc, &grants, "bash", command);
        return grants.toOwnedSlice(alloc);
    }

    if (shouldSuggestBroadPathGrants(tool_name, target_kind) and workspace_root.len > 0 and pathing.pathInside(workspace_root, target_path)) {
        const workspace_pattern = try directoryTreePattern(alloc, workspace_root);
        defer alloc.free(workspace_pattern);

        for (path_always_permissions) |path_permission| {
            try appendOwnedGrant(alloc, &grants, path_permission, workspace_pattern);
        }
        return grants.toOwnedSlice(alloc);
    }

    if (shouldSuggestBroadPathGrants(tool_name, target_kind)) {
        if (externalPathGrantRoot(alloc, workspace_root, target_path)) |external_root| {
            defer alloc.free(external_root);
            const external_pattern = try directoryTreePattern(alloc, external_root);
            defer alloc.free(external_pattern);

            try appendOwnedGrant(alloc, &grants, permission, external_pattern);
            return grants.toOwnedSlice(alloc);
        }
    }

    try appendOwnedGrant(alloc, &grants, permission, patternForSessionGrantMatch(tool_name, target_path));
    return grants.toOwnedSlice(alloc);
}

pub const FileGrantOfferError = error{
    OutOfMemory,
    UnsupportedFileGrantOffer,
    ScopeProjectionTooLarge,
};

pub fn structuredFileGrantOffer(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    tool_name: []const u8,
    targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) FileGrantOfferError!file_mutation_contract.FileGrantOffer {
    if (!file_mutation_contract.isToolName(tool_name)) {
        return error.UnsupportedFileGrantOffer;
    }

    var grants: std.ArrayList(types.PermissionGrant) = .empty;
    errdefer {
        clearAllowedTools(alloc, &grants);
        grants.deinit(alloc);
    }
    for (targets.items) |target| {
        const suggestions = suggestedSessionGrants(
            alloc,
            workspace_root,
            tool_name,
            targets.permissionPath(target),
            .path_existing,
        ) catch return error.OutOfMemory;
        defer types.freePermissionGrantSlice(alloc, suggestions);
        for (suggestions) |grant| {
            if (!isStructuredFilePermission(grant.tool_name)) {
                return error.UnsupportedFileGrantOffer;
            }
            try appendNormalizedFileGrant(
                alloc,
                &grants,
                grant.tool_name,
                grant.target_path,
            );
        }
    }
    if (grants.items.len == 0) return error.UnsupportedFileGrantOffer;

    const scope: file_mutation_contract.FileApprovalScope = switch (targets.anchor.scope) {
        .workspace => blk: {
            const workspace_pattern = directoryTreePattern(
                alloc,
                workspace_root,
            ) catch return error.OutOfMemory;
            defer alloc.free(workspace_pattern);
            _ = literalDirectoryTreeRoot(workspace_pattern) orelse
                return error.UnsupportedFileGrantOffer;
            for (grants.items) |grant| {
                if (!std.mem.eql(u8, grant.target_path, workspace_pattern)) {
                    return error.UnsupportedFileGrantOffer;
                }
            }
            break :blk .workspace_files;
        },
        .external => blk: {
            const first_root = literalDirectoryTreeRoot(
                grants.items[0].target_path,
            ) orelse return error.UnsupportedFileGrantOffer;
            for (grants.items[1..]) |grant| {
                const root = literalDirectoryTreeRoot(grant.target_path) orelse
                    return error.UnsupportedFileGrantOffer;
                if (!std.mem.eql(u8, first_root, root)) {
                    return error.UnsupportedFileGrantOffer;
                }
            }
            const encoded_root = text_utils.encodeTerminalSafePathTail(
                alloc,
                first_root,
                file_mutation_contract.max_external_scope_tail_bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PathBasenameTooLong => return error.ScopeProjectionTooLarge,
            };
            break :blk .{ .external_tree = encoded_root.bytes };
        },
    };
    errdefer switch (scope) {
        .workspace_files => {},
        .external_tree => |root_tail| alloc.free(@constCast(root_tail)),
    };

    return .{
        .grants = try grants.toOwnedSlice(alloc),
        .scope = scope,
    };
}

fn isStructuredFilePermission(permission: []const u8) bool {
    for (path_always_permissions) |candidate| {
        if (std.mem.eql(u8, permission, candidate)) return true;
    }
    return false;
}

fn appendNormalizedFileGrant(
    alloc: std.mem.Allocator,
    grants: *std.ArrayList(types.PermissionGrant),
    permission: []const u8,
    pattern: []const u8,
) error{OutOfMemory}!void {
    var index: usize = 0;
    while (index < grants.items.len) {
        const current = grants.items[index];
        if (!std.mem.eql(u8, current.tool_name, permission)) {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, current.target_path, pattern) or
            directoryTreePatternContains(current.target_path, pattern))
        {
            return;
        }
        if (directoryTreePatternContains(pattern, current.target_path)) {
            const removed = grants.orderedRemove(index);
            alloc.free(removed.tool_name);
            alloc.free(removed.target_path);
            continue;
        }
        index += 1;
    }
    try appendOwnedGrant(alloc, grants, permission, pattern);
}

fn directoryTreePatternContains(
    broader_pattern: []const u8,
    narrower_pattern: []const u8,
) bool {
    const broader_root = directoryTreeRoot(broader_pattern) orelse return false;
    const narrower_root = directoryTreeRoot(narrower_pattern) orelse return false;
    return std.mem.eql(u8, broader_root, narrower_root) or
        pathing.pathInside(broader_root, narrower_root);
}

fn directoryTreeRoot(pattern: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, pattern, "/**")) return null;
    const root = pattern[0 .. pattern.len - "/**".len];
    return if (root.len == 0) "/" else root;
}

fn literalDirectoryTreeRoot(pattern: []const u8) ?[]const u8 {
    const root = directoryTreeRoot(pattern) orelse return null;
    if (std.mem.findScalar(u8, root, '*') != null) return null;
    if (std.mem.findScalar(u8, root, '?') != null) return null;
    return root;
}

fn appendOwnedGrant(
    alloc: std.mem.Allocator,
    grants: *std.ArrayList(types.PermissionGrant),
    permission_name: []const u8,
    pattern: []const u8,
) !void {
    const owned_permission = try alloc.dupe(u8, permission_name);
    errdefer alloc.free(owned_permission);

    const owned_pattern = try alloc.dupe(u8, pattern);
    errdefer alloc.free(owned_pattern);

    try grants.append(alloc, .{
        .tool_name = owned_permission,
        .target_path = owned_pattern,
    });
}

pub fn formatPermissionsStatus(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    mode: types.PermissionMode,
    grants: []const types.PermissionGrant,
    rules: types.PermissionRuleSet,
) ![]u8 {
    return (output_contracts.PermissionsSnapshot{
        .workspace_root = workspace_root,
        .mode = mode,
        .grants = grants,
        .rules = rules,
    }).renderText(alloc);
}

pub fn permissionNameForTool(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "read_file")) return "read";
    if (std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "edit_file")) return "edit";
    if (std.mem.eql(u8, tool_name, "list_files")) return "list";
    if (std.mem.eql(u8, tool_name, "glob_files")) return "glob";
    if (std.mem.eql(u8, tool_name, "grep_files")) return "grep";
    if (std.mem.eql(u8, tool_name, "run_command")) return "bash";
    if (isWebFetchToolName(tool_name)) return web_fetch_permission;
    if (std.mem.eql(u8, tool_name, "skill") or std.mem.eql(u8, tool_name, "install_skill")) return "skill";
    return tool_name;
}

pub fn permissionRuleCategoryForGrant(permission_name: []const u8) ?[]const u8 {
    return permissionNameForTool(permission_name);
}

/// Returns the persistent rule pattern for a session grant. Caller owns the returned slice.
pub fn permissionRulePatternForGrant(alloc: std.mem.Allocator, workspace_root: []const u8, permission_name: []const u8, pattern: []const u8) ![]u8 {
    const permission = permissionNameForTool(permission_name);
    if (isWebSearchToolName(permission)) return alloc.dupe(u8, "*");
    if (std.mem.eql(u8, permission, web_fetch_permission)) return canonicalWebFetchDomainPattern(alloc, pattern);
    if (std.mem.eql(u8, permission, "bash")) {
        if (command_environment.isExplicitPermissionCommandIdentity(pattern)) {
            return alloc.dupe(u8, pattern);
        }
        if (std.mem.find(u8, pattern, "::")) |separator| {
            return alloc.dupe(u8, pattern[separator + 2 ..]);
        }
        return alloc.dupe(u8, pattern);
    }

    if (std.mem.eql(u8, permission, "url") or
        std.mem.eql(u8, permission, "skill"))
    {
        return alloc.dupe(u8, pattern);
    }

    if (std.fs.path.isAbsolute(pattern) and pathing.pathInside(workspace_root, pattern)) {
        if (directoryTreePatternMatches(pattern, workspace_root)) return alloc.dupe(u8, "*");

        const relative = std.fs.path.relative(alloc, "/", null, workspace_root, pattern) catch return alloc.dupe(u8, pattern);
        if (relative.len == 0) {
            alloc.free(relative);
            return alloc.dupe(u8, "*");
        }
        return relative;
    }

    return alloc.dupe(u8, pattern);
}

fn patternForRuleMatch(alloc: std.mem.Allocator, workspace_root: []const u8, tool_name: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) ![]u8 {
    const permission = permissionNameForTool(tool_name);
    if (std.mem.eql(u8, permission, web_fetch_permission)) {
        return alloc.dupe(u8, target_path);
    }
    if (std.mem.eql(u8, permission, "bash")) {
        const identity = if (command_environment.isExplicitPermissionCommandIdentity(target_path))
            target_path
        else if (std.mem.find(u8, target_path, "::")) |separator|
            target_path[separator + 2 ..]
        else
            target_path;
        return alloc.dupe(u8, command_environment.commandFromPermissionIdentity(identity));
    }
    return displayTargetForPolicy(alloc, workspace_root, tool_name, target_path, target_kind);
}

pub fn patternForSessionGrantMatch(tool_name: []const u8, target_path: []const u8) []const u8 {
    const permission = permissionNameForTool(tool_name);
    if (std.mem.eql(u8, permission, "bash")) {
        if (command_environment.isExplicitPermissionCommandIdentity(target_path)) {
            return target_path;
        }
        if (std.mem.find(u8, target_path, "::")) |separator| return target_path[separator + 2 ..];
    }
    return target_path;
}

fn isPathBasedTool(target_kind: PermissionTargetKind) bool {
    return switch (target_kind) {
        .path_existing, .path_optional_existing, .path_create_parent, .path_existing_parent => true,
        else => false,
    };
}

fn shouldSuggestBroadPathGrants(tool_name: []const u8, target_kind: PermissionTargetKind) bool {
    if (std.mem.eql(u8, tool_name, "delete_file")) return false;
    if (std.mem.eql(u8, tool_name, "file_info")) return false;
    if (std.mem.eql(u8, tool_name, "semantic_search")) return false;
    if (std.mem.eql(u8, tool_name, "copy_file") or std.mem.eql(u8, tool_name, "rename_file")) return false;
    return isPathBasedTool(target_kind);
}

fn externalPathGrantRoot(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8) ?[]u8 {
    if (!std.fs.path.isAbsolute(target_path)) return null;
    if (workspace_root.len > 0 and pathing.pathInside(workspace_root, target_path)) return null;

    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), target_path, .{}) catch null;
    if (stat) |s| {
        if (s.kind == .directory) return alloc.dupe(u8, target_path) catch null;
    }

    const parent = std.fs.path.dirname(target_path) orelse return null;
    return alloc.dupe(u8, parent) catch null;
}

fn directoryTreePattern(alloc: std.mem.Allocator, dir_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, dir_path, "/")) return std.fmt.allocPrint(alloc, "{s}**", .{dir_path});
    return std.fmt.allocPrint(alloc, "{s}/**", .{dir_path});
}

fn evaluateRuleset(rules: []const types.PermissionRule, permission: []const u8, pattern: []const u8) ?RuleDecision {
    return evaluateRulesetForTool(rules, permission, null, pattern);
}

fn evaluateRulesetForTool(rules: []const types.PermissionRule, permission: []const u8, tool_name: ?[]const u8, pattern: []const u8) ?RuleDecision {
    if (std.mem.eql(u8, permission, web_fetch_permission)) {
        return evaluateWebFetchRuleset(rules, pattern);
    }

    var matched: ?RuleDecision = null;
    for (rules) |rule| {
        if (!ruleMatchesPermission(rule.permission, permission, tool_name)) continue;
        const action: RuleDecision = switch (rule.action) {
            .allow => .allow,
            .ask => .ask,
            .deny => .deny,
        };
        if (!ruleTargetMatches(permission, action, rule.pattern, pattern)) continue;
        matched = action;
    }
    return matched;
}

fn evaluateWebFetchRuleset(rules: []const types.PermissionRule, pattern: []const u8) ?RuleDecision {
    if (!isCanonicalWebFetchDomainPattern(pattern)) return null;

    var matched: ?RuleDecision = null;
    for (rules) |rule| {
        if (!std.mem.eql(u8, rule.permission, web_fetch_permission)) continue;
        if (!isCanonicalWebFetchDomainPattern(rule.pattern)) continue;
        if (!std.mem.eql(u8, rule.pattern, pattern)) continue;
        matched = switch (rule.action) {
            .allow => .allow,
            .ask => .ask,
            .deny => .deny,
        };
    }
    return matched;
}

pub fn webFetchRuleWarningCount(rules: []const types.PermissionRule) usize {
    var count: usize = 0;
    for (rules) |rule| {
        if (!std.mem.eql(u8, rule.permission, web_fetch_permission)) continue;
        if (isCanonicalWebFetchDomainPattern(rule.pattern)) continue;
        count += 1;
    }
    return count;
}

fn ruleMatchesPermission(rule_permission: []const u8, permission: []const u8, tool_name: ?[]const u8) bool {
    if (wildcardMatch(rule_permission, permission)) return true;
    const name = tool_name orelse return false;
    if (wildcardMatch(rule_permission, name)) return true;
    return false;
}

fn permissionPatternMatchesTool(pattern: []const u8, permission: []const u8, tool_name: ?[]const u8) bool {
    return ruleMatchesPermission(pattern, permission, tool_name);
}

fn permissionPatternMatchesTarget(pattern: []const u8, candidate: []const u8) bool {
    if (directoryTreePatternMatches(pattern, candidate)) return true;
    return wildcardMatch(pattern, candidate);
}

fn ruleTargetMatches(permission: []const u8, action: RuleDecision, pattern: []const u8, candidate: []const u8) bool {
    if (action != .allow or
        !std.mem.eql(u8, permission, "bash"))
    {
        return permissionPatternMatchesTarget(pattern, candidate);
    }

    if (!containsWildcard(pattern)) return std.mem.eql(u8, pattern, candidate);
    if (!isStaticCommand(pattern, true) or !isStaticCommand(candidate, false)) return false;
    return staticCommandWildcardMatch(pattern, candidate);
}

fn containsWildcard(pattern: []const u8) bool {
    return std.mem.findScalar(u8, pattern, '*') != null or
        std.mem.findScalar(u8, pattern, '?') != null;
}

fn isStaticCommand(command: []const u8, allow_wildcards: bool) bool {
    if (command.len == 0) return false;
    if (firstWordIsAssignment(command)) return false;

    var index: usize = 0;
    var in_word = false;
    while (index < command.len) {
        const char = command[index];
        if (char == ' ' or char == '\t') {
            if (!in_word) return false;
            while (index < command.len and (command[index] == ' ' or command[index] == '\t')) : (index += 1) {}
            if (index == command.len) return false;
            in_word = false;
            continue;
        }

        if (char == '\'') {
            const literal_start = index + 1;
            const literal_end = std.mem.findScalarPos(u8, command, literal_start, '\'') orelse return false;
            const literal = command[literal_start..literal_end];
            if (!std.unicode.utf8ValidateSlice(literal)) return false;
            if (std.mem.findScalar(u8, literal, 0) != null or
                std.mem.findScalar(u8, literal, '\r') != null or
                std.mem.findScalar(u8, literal, '\n') != null)
            {
                return false;
            }
            in_word = true;
            index = literal_end + 1;
            continue;
        }

        if (!isStaticUnquotedByte(char) and !(allow_wildcards and (char == '*' or char == '?'))) return false;
        in_word = true;
        index += 1;
    }
    return in_word;
}

fn firstWordIsAssignment(command: []const u8) bool {
    const first_word_end = std.mem.findAny(u8, command, " \t") orelse command.len;
    const first_word = command[0..first_word_end];
    const equals = std.mem.findScalar(u8, first_word, '=') orelse return false;
    const name = first_word[0..equals];
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }
    return true;
}

fn isStaticUnquotedByte(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or switch (char) {
        '_', '.', '/', ',', ':', '+', '=', '%', '@', '-' => true,
        else => false,
    };
}

fn staticCommandWildcardMatch(pattern: []const u8, candidate: []const u8) bool {
    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var in_single_quote = false;
    var star_index: ?usize = null;
    var star_candidate_index: usize = 0;

    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len) {
            const char = pattern[pattern_index];
            if (!in_single_quote and char == '*') {
                star_index = pattern_index;
                pattern_index += 1;
                star_candidate_index = candidate_index;
                continue;
            }
            if ((!in_single_quote and char == '?') or char == candidate[candidate_index]) {
                if (char == '\'') in_single_quote = !in_single_quote;
                pattern_index += 1;
                candidate_index += 1;
                continue;
            }
        }

        const star = star_index orelse return false;
        star_candidate_index += 1;
        candidate_index = star_candidate_index;
        pattern_index = star + 1;
        in_single_quote = false;
    }

    while (pattern_index < pattern.len and !in_single_quote and pattern[pattern_index] == '*') : (pattern_index += 1) {}
    return pattern_index == pattern.len;
}

fn directoryTreePatternMatches(pattern: []const u8, candidate: []const u8) bool {
    if (!std.mem.endsWith(u8, pattern, "/**")) return false;
    if (std.mem.eql(u8, pattern, "/**")) return std.mem.startsWith(u8, candidate, "/");

    const dir = pattern[0 .. pattern.len - "/**".len];
    if (std.mem.eql(u8, candidate, dir)) return true;
    return candidate.len > dir.len and
        std.mem.startsWith(u8, candidate, dir) and
        candidate[dir.len] == '/';
}

fn wildcardMatch(pattern: []const u8, candidate: []const u8) bool {
    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var star_index: ?usize = null;
    var star_candidate_index: usize = 0;

    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or pattern[pattern_index] == candidate[candidate_index]))
        {
            pattern_index += 1;
            candidate_index += 1;
            continue;
        }
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_candidate_index = candidate_index;
            continue;
        }

        const star = star_index orelse return false;
        star_candidate_index += 1;
        candidate_index = star_candidate_index;
        pattern_index = star + 1;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') : (pattern_index += 1) {}
    return pattern_index == pattern.len;
}

fn isGlobalTargetPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    for (pattern) |char| {
        if (char != '*') return false;
    }
    return true;
}

pub fn webFetchDomainTargetForUrl(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    const scheme_end = std.mem.find(u8, url, "://") orelse return error.InvalidToolArguments;
    const authority_start = scheme_end + "://".len;
    const authority_end = authorityEnd(url, authority_start);
    if (authority_end == authority_start) return error.InvalidToolArguments;

    const authority = url[authority_start..authority_end];
    if (std.mem.findScalar(u8, authority, '@') != null) return error.InvalidToolArguments;
    const host = hostFromAuthority(authority) orelse return error.InvalidToolArguments;
    return canonicalWebFetchDomainPattern(alloc, host);
}

pub fn canonicalWebFetchDomainPattern(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const host_raw = if (std.mem.startsWith(u8, raw, "domain:")) raw["domain:".len..] else raw;
    if (std.mem.find(u8, host_raw, "://") != null) return error.InvalidToolArguments;
    if (std.mem.findScalar(u8, host_raw, '/') != null) return error.InvalidToolArguments;
    if (std.mem.findScalar(u8, host_raw, '*') != null) return error.InvalidToolArguments;
    if (std.mem.findScalar(u8, host_raw, '?') != null) return error.InvalidToolArguments;

    const host = stripOneRootDot(host_raw);
    if (!isCanonicalizableWebFetchHost(host)) return error.InvalidToolArguments;

    const target = try alloc.alloc(u8, "domain:".len + host.len);
    errdefer alloc.free(target);
    @memcpy(target[0.."domain:".len], "domain:");
    for (host, 0..) |char, index| {
        target["domain:".len + index] = std.ascii.toLower(char);
    }
    return target;
}

pub fn isCanonicalWebFetchDomainPattern(pattern: []const u8) bool {
    if (!std.mem.startsWith(u8, pattern, "domain:")) return false;
    const host = pattern["domain:".len..];
    if (!isCanonicalizableWebFetchHost(host)) return false;
    if (std.mem.endsWith(u8, host, ".")) return false;
    for (host) |char| {
        if (std.ascii.isAlphabetic(char) and std.ascii.isUpper(char)) return false;
    }
    return true;
}

fn stripOneRootDot(host: []const u8) []const u8 {
    if (host.len > 1 and host[host.len - 1] == '.') return host[0 .. host.len - 1];
    return host;
}

fn isCanonicalizableWebFetchHost(host: []const u8) bool {
    if (host.len == 0) return false;
    if (host[0] == '[') return isCanonicalizableWebFetchIpv6Literal(host);
    if (std.mem.findScalar(u8, host, ':') != null) return false;
    var label_len: usize = 0;
    for (host) |char| {
        if (char <= 0x20 or char >= 0x7f) return false;
        if (char == '*' or char == '?' or char == '/' or char == '\\') return false;
        if (char == '.') {
            if (label_len == 0) return false;
            label_len = 0;
            continue;
        }
        if (!std.ascii.isAlphanumeric(char) and char != '-') return false;
        label_len += 1;
    }
    return label_len > 0;
}

fn isCanonicalizableWebFetchIpv6Literal(host: []const u8) bool {
    if (host.len < 3 or host[host.len - 1] != ']') return false;
    const inner = host[1 .. host.len - 1];
    if (std.mem.findScalar(u8, inner, '%') != null) return false;
    for (inner) |char| {
        if (char <= 0x20 or char >= 0x7f) return false;
        if (std.ascii.isAlphabetic(char) and std.ascii.isUpper(char)) return false;
        if (!std.ascii.isHex(char) and char != ':' and char != '.') return false;
    }
    _ = std.Io.net.Ip6Address.parse(inner, 0) catch return false;
    return true;
}

fn authorityEnd(url: []const u8, start: usize) usize {
    var index = start;
    while (index < url.len) : (index += 1) {
        switch (url[index]) {
            '/', '?', '#' => return index,
            else => {},
        }
    }
    return url.len;
}

fn hostFromAuthority(authority: []const u8) ?[]const u8 {
    if (authority.len == 0) return null;
    if (authority[0] == '[') {
        const end = std.mem.findScalar(u8, authority, ']') orelse return null;
        if (end == 1) return null;
        if (end + 1 < authority.len and authority[end + 1] != ':') return null;
        return authority[0 .. end + 1];
    }

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse authority.len;
    if (colon == 0) return null;
    return authority[0..colon];
}

fn displayPathTarget(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(target_path) and pathing.pathInside(workspace_root, target_path)) {
        const relative = std.fs.path.relative(alloc, "/", null, workspace_root, target_path) catch return alloc.dupe(u8, target_path);
        if (relative.len == 0) {
            alloc.free(relative);
            return alloc.dupe(u8, ".");
        }
        return relative;
    }
    return alloc.dupe(u8, target_path);
}

fn displayCommandTarget(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8) ![]u8 {
    const separator = std.mem.find(u8, target_path, "::") orelse return alloc.dupe(u8, target_path);
    const cwd = target_path[0..separator];
    const command = command_environment.commandFromPermissionIdentity(
        target_path[separator + 2 ..],
    );

    const display_cwd = try (if (std.mem.eql(u8, cwd, workspace_root))
        alloc.dupe(u8, ".")
    else if (std.fs.path.isAbsolute(cwd) and pathing.pathInside(workspace_root, cwd))
        (std.fs.path.relative(alloc, "/", null, workspace_root, cwd) catch alloc.dupe(u8, cwd))
    else
        alloc.dupe(u8, cwd));
    defer alloc.free(display_cwd);

    return std.fmt.allocPrint(alloc, "{s}::{s}", .{ display_cwd, command });
}

fn ownedRuleSet(alloc: std.mem.Allocator, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !types.PermissionRuleSet {
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

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn expectGrant(grant: types.PermissionGrant, permission: []const u8, pattern: []const u8) !void {
    try std.testing.expectEqualStrings(permission, grant.tool_name);
    try std.testing.expectEqualStrings(pattern, grant.target_path);
}

fn freeGrants(alloc: std.mem.Allocator, grants: []types.PermissionGrant) void {
    for (grants) |grant| {
        alloc.free(grant.tool_name);
        alloc.free(grant.target_path);
    }
    alloc.free(grants);
}

fn checkAllowToolForSessionAllocFailures(alloc: std.mem.Allocator) !void {
    var grants: std.ArrayList(types.PermissionGrant) = .empty;
    defer {
        clearAllowedTools(alloc, &grants);
        grants.deinit(alloc);
    }

    try allowToolForSession(alloc, &grants, "edit", "/tmp/workspace/src/main.zig");
}

fn checkSuggestedSessionGrantsAllocFailures(alloc: std.mem.Allocator) !void {
    const command_grants = try suggestedSessionGrants(alloc, "/tmp/workspace", "run_command", "/tmp/workspace::git status --short", .command_cwd);
    defer freeGrants(alloc, command_grants);

    const path_grants = try suggestedSessionGrants(alloc, "/tmp/workspace", "write_file", "/tmp/workspace/src/main.zig", .path_create_parent);
    defer freeGrants(alloc, path_grants);
}

test "PermissionEngine stores deduplicates clears replaces and deinitializes owned state" {
    const alloc = std.testing.allocator;

    var engine = PermissionEngine{};
    defer engine.deinit(alloc);

    try engine.allow(alloc, "edit", "/tmp/workspace");
    try engine.allow(alloc, "edit", "/tmp/workspace");

    try std.testing.expectEqual(@as(usize, 1), engine.grants.items.len);
    try std.testing.expect(engine.isAllowed("edit", "/tmp/workspace"));

    var first_rules = try ownedRuleSet(alloc, "edit", "src/*", .allow);
    engine.replaceRules(alloc, first_rules);
    first_rules = .{};

    var second_rules = try ownedRuleSet(alloc, "read", "README.md", .ask);
    engine.replaceRules(alloc, second_rules);
    second_rules = .{};

    try std.testing.expectEqual(@as(usize, 1), engine.rules.rules.len);
    try std.testing.expectEqualStrings("read", engine.rules.rules[0].permission);

    engine.clear(alloc);
    try std.testing.expectEqual(@as(usize, 0), engine.grants.items.len);
    try std.testing.expectEqual(@as(usize, 1), engine.rules.rules.len);
}

test "permissionModeLabel maps active permission mode labels" {
    try std.testing.expectEqualStrings("ask", permissionModeLabel(.ask));
    try std.testing.expectEqualStrings("auto", permissionModeLabel(.auto));
}

test "permissionDecisionFromIndex maps approval choices" {
    try std.testing.expectEqual(ToolPermissionDecision.once, permissionDecisionFromIndex(0));
    try std.testing.expectEqual(ToolPermissionDecision.always, permissionDecisionFromIndex(1));
    try std.testing.expectEqual(ToolPermissionDecision.deny, permissionDecisionFromIndex(2));
    try std.testing.expectEqual(ToolPermissionDecision.deny, permissionDecisionFromIndex(99));
}

test "isToolAllowed remains exact match only" {
    const grants = [_]types.PermissionGrant{
        .{ .tool_name = @constCast("edit"), .target_path = @constCast("/tmp/workspace/*") },
        .{ .tool_name = @constCast("bash"), .target_path = @constCast("git *") },
    };

    try std.testing.expect(isToolAllowed(&grants, "edit", "/tmp/workspace/*"));
    try std.testing.expect(!isToolAllowed(&grants, "edit", "/tmp/workspace/file.zig"));
    try std.testing.expect(!isToolAllowed(&grants, "write_file", "/tmp/workspace/*"));
    try std.testing.expect(!isToolAllowed(&grants, "run_command", "git status"));
}

test "sessionGrantAllowed maps tool categories and matches command grants exactly" {
    const grants = [_]types.PermissionGrant{
        .{ .tool_name = @constCast("bash"), .target_path = @constCast("git status") },
        .{ .tool_name = @constCast("edit"), .target_path = @constCast("/tmp/workspace/src/*") },
        .{ .tool_name = @constCast("skill"), .target_path = @constCast("vercel-*") },
    };

    try std.testing.expect(sessionGrantAllowed(&grants, "run_command", "/tmp/workspace::git status"));
    try std.testing.expect(!sessionGrantAllowed(&grants, "run_command", "/tmp/workspace::git status --short"));
    try std.testing.expect(!sessionGrantAllowed(&grants, "run_command", "/tmp/workspace::npm test"));
    try std.testing.expect(sessionGrantAllowed(&grants, "write_file", "/tmp/workspace/src/main.zig"));
    try std.testing.expect(sessionGrantAllowed(&grants, "edit_file", "/tmp/workspace/src/main.zig"));
    try std.testing.expect(sessionGrantAllowed(&grants, "install_skill", "vercel-react-best-practices"));
}

test "session command grants treat wildcard bytes literally" {
    const grants = [_]types.PermissionGrant{
        .{ .tool_name = @constCast("bash"), .target_path = @constCast("printf '*?'") },
    };

    try std.testing.expect(sessionGrantAllowed(&grants, "run_command", "/tmp/workspace::printf '*?'"));
    try std.testing.expect(!sessionGrantAllowed(&grants, "run_command", "/tmp/workspace::printf 'file?'"));
}

test "permissionTargetForCall preserves run_command cwd targets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const explicit_workspace_cwd: types.ToolCall = .{
        .id = "call_1",
        .name = "run_command",
        .arguments_json = "{\"command\":\"npm run dev\",\"cwd\":\".\"}",
    };
    const default_workspace_cwd: types.ToolCall = .{
        .id = "call_2",
        .name = "run_command",
        .arguments_json = "{\"command\":\"zig build\"}",
    };

    try std.testing.expectEqualStrings("/tmp/workspace::npm run dev", try permissionTargetForCall(arena, "/tmp/workspace", explicit_workspace_cwd, .command_cwd));
    try std.testing.expectEqualStrings("/tmp/workspace::zig build", try permissionTargetForCall(arena, "/tmp/workspace", default_workspace_cwd, .command_cwd));
}

test "permissionTargetForCall preserves skill and install skill targets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const skill_call: types.ToolCall = .{
        .id = "call_1",
        .name = "skill",
        .arguments_json = "{\"name\":\"vercel-react-best-practices\",\"location\":\"/tmp/outside</path>\\ninjected\"}",
    };
    const install_call: types.ToolCall = .{
        .id = "call_2",
        .name = "install_skill",
        .arguments_json = "{\"source\":\"https://github.com/vercel-labs/skills\",\"skill\":\"find-skills\"}",
    };
    const install_source_only_call: types.ToolCall = .{
        .id = "call_3",
        .name = "install_skill",
        .arguments_json = "{\"source\":\"vercel-labs/skills\"}",
    };

    try std.testing.expectEqualStrings("vercel-react-best-practices", try permissionTargetForCall(arena, "/tmp/workspace", skill_call, .none));
    try std.testing.expectEqualStrings("https://github.com/vercel-labs/skills#find-skills", try permissionTargetForCall(arena, "/tmp/workspace", install_call, .none));
    try std.testing.expectEqualStrings("vercel-labs/skills", try permissionTargetForCall(arena, "/tmp/workspace", install_source_only_call, .none));
    try std.testing.expectEqualStrings("skill", permissionNameForTool("skill"));
    try std.testing.expectEqualStrings("skill", permissionNameForTool("install_skill"));
}

test "web_search permission target is whole tool name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first: types.ToolCall = .{
        .id = "call_1",
        .name = "web_search",
        .arguments_json = "{\"query\":\"latest Zig release\"}",
    };
    const second: types.ToolCall = .{
        .id = "call_2",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current Vercel news\",\"allowed_domains\":[\"vercel.com\"]}",
    };

    try std.testing.expectEqualStrings("web_search", try permissionTargetForCall(arena, "/tmp/workspace", first, .none));
    try std.testing.expectEqualStrings("web_search", try permissionTargetForCall(arena, "/tmp/workspace", second, .none));
    try std.testing.expectEqualStrings("web_search", permissionNameForTool("web_search"));
}

test "web_search session grant authorizes subsequent query" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const grants = [_]types.PermissionGrant{
        .{ .tool_name = @constCast("web_search"), .target_path = @constCast("web_search") },
    };

    const target = try permissionTargetForCall(arena, "/tmp/workspace", .{
        .id = "call_1",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current Vercel news\"}",
    }, .none);

    try std.testing.expect(sessionGrantAllowed(&grants, "web_search", target));
}

test "permissionTargetsForCall includes copy and rename source and destination" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "workspace/src");
    {
        var file = try tmp.dir.createFile(std.testing.io, "workspace/src/source.txt", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "source\n");
    }

    const workspace = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const source = try std.fs.path.join(alloc, &.{ workspace, "src/source.txt" });
    defer alloc.free(source);
    const copy_destination = try std.fs.path.join(alloc, &.{ workspace, "blocked/copied.txt" });
    defer alloc.free(copy_destination);
    const rename_destination = try std.fs.path.join(alloc, &.{ workspace, "renamed/source.txt" });
    defer alloc.free(rename_destination);

    const rename_call: types.ToolCall = .{
        .id = "call_1",
        .name = "rename_file",
        .arguments_json = "{\"old_path\":\"src/source.txt\",\"new_path\":\"renamed/source.txt\"}",
    };
    const copy_call: types.ToolCall = .{
        .id = "call_2",
        .name = "copy_file",
        .arguments_json = "{\"source\":\"src/source.txt\",\"destination\":\"blocked/copied.txt\"}",
    };

    var copy_targets = try permissionTargetsForCall(alloc, workspace, copy_call, .none);
    defer copy_targets.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), copy_targets.items.len);
    try std.testing.expectEqualStrings("source", copy_targets.items[0].role);
    try std.testing.expectEqualStrings(source, copy_targets.items[0].path);
    try std.testing.expectEqualStrings("destination", copy_targets.items[1].role);
    try std.testing.expectEqualStrings(copy_destination, copy_targets.items[1].path);

    var rename_targets = try permissionTargetsForCall(alloc, workspace, rename_call, .none);
    defer rename_targets.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), rename_targets.items.len);
    try std.testing.expectEqualStrings("source", rename_targets.items[0].role);
    try std.testing.expectEqualStrings(source, rename_targets.items[0].path);
    try std.testing.expectEqualStrings("destination", rename_targets.items[1].role);
    try std.testing.expectEqualStrings(rename_destination, rename_targets.items[1].path);

    var rules = try ownedRuleSet(alloc, "copy_file", "blocked/*", .deny);
    defer rules.deinit(alloc);
    try std.testing.expectEqual(.deny, try ruleDecisionFor(alloc, rules, workspace, "copy_file", copy_targets.items[1].path, .none));
}

test "permissionTargetsForCall exposes every canonical Vision path" {
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
    const arguments = try std.fmt.allocPrint(
        alloc,
        "{{\"paths\":[\"first.png\",\"{s}\"],\"focus\":\"compare\"}}",
        .{second},
    );
    defer alloc.free(arguments);

    var targets = try permissionTargetsForCall(alloc, workspace, .{
        .id = "vision_paths",
        .name = "vision",
        .arguments_json = arguments,
    }, .none);
    defer targets.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), targets.items.len);
    try std.testing.expectEqualStrings("image", targets.items[0].role);
    try std.testing.expectEqualStrings(first, targets.items[0].path);
    try std.testing.expectEqualStrings("image", targets.items[1].role);
    try std.testing.expectEqualStrings(second, targets.items[1].path);

    var id_targets = try permissionTargetsForCall(alloc, workspace, .{
        .id = "vision_ids",
        .name = "vision",
        .arguments_json = "{\"image_ids\":[1],\"focus\":\"inspect\"}",
    }, .none);
    defer id_targets.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), id_targets.items.len);
    try std.testing.expectEqualStrings("vision", id_targets.items[0].path);
}

test "permissionTargetsForCall rejects duplicate canonical Vision paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "image.png", .{});
    file.close(std.testing.io);

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const absolute = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "image.png");
    defer alloc.free(absolute);
    const arguments = try std.fmt.allocPrint(
        alloc,
        "{{\"paths\":[\"image.png\",\"{s}\"],\"focus\":\"compare\"}}",
        .{absolute},
    );
    defer alloc.free(arguments);

    try std.testing.expectError(
        error.InvalidToolArguments,
        permissionTargetsForCall(alloc, workspace, .{
            .id = "vision_duplicate_paths",
            .name = "vision",
            .arguments_json = arguments,
        }, .none),
    );
}

test "permissionTargetForCall covers active target kinds" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "workspace/src");
    {
        var file = try tmp.dir.createFile(std.testing.io, "workspace/src/app.zig", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "pub fn main() void {}\n");
    }

    const workspace = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const src_dir = try std.fs.path.join(alloc, &.{ workspace, "src" });
    defer alloc.free(src_dir);
    const app_file = try std.fs.path.join(alloc, &.{ workspace, "src/app.zig" });
    defer alloc.free(app_file);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct {
        call: types.ToolCall,
        target_kind: PermissionTargetKind,
        expected: []const u8,
    }{
        .{
            .call = .{ .id = "list", .name = "list_files", .arguments_json = "{}" },
            .target_kind = .path_optional_existing,
            .expected = workspace,
        },
        .{
            .call = .{ .id = "grep", .name = "grep_files", .arguments_json = "{\"pattern\":\"main\",\"path\":\"src\"}" },
            .target_kind = .path_optional_existing,
            .expected = src_dir,
        },
        .{
            .call = .{ .id = "read", .name = "read_file", .arguments_json = "{\"path\":\"src/app.zig\"}" },
            .target_kind = .path_existing,
            .expected = app_file,
        },
        .{
            .call = .{ .id = "mkdir", .name = "create_folder", .arguments_json = "{\"path\":\"src/generated\"}" },
            .target_kind = .path_create_parent,
            .expected = src_dir,
        },
        .{
            .call = .{ .id = "memory", .name = "memory", .arguments_json = "{\"action\":\"list\"}" },
            .target_kind = .none,
            .expected = "memory",
        },
        .{
            .call = .{ .id = "ask", .name = "ask_user_question", .arguments_json = "{}" },
            .target_kind = .none,
            .expected = "ask_user_question",
        },
    };

    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, try permissionTargetForCall(arena, workspace, case.call, case.target_kind));
    }
}

test "permissionTargetForCall resolves external absolute file tool targets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try tmp.dir.createDirPath(std.testing.io, "external");
    {
        var file = try tmp.dir.createFile(std.testing.io, "external/app.zig", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "pub fn main() void {}\n");
    }

    const workspace = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external_file = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, "external/app.zig");
    defer alloc.free(external_file);
    const external_new_file = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(external_file).?, "new.zig" });
    defer alloc.free(external_new_file);
    const external_new_dir = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(external_file).?, "nested" });
    defer alloc.free(external_new_dir);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const read_call: types.ToolCall = .{
        .id = "read",
        .name = "read_file",
        .arguments_json = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{external_file}),
    };
    try std.testing.expectEqualStrings(external_file, try permissionTargetForCall(arena, workspace, read_call, .path_existing));

    const write_call: types.ToolCall = .{
        .id = "write",
        .name = "write_file",
        .arguments_json = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"content\":\"\"}}", .{external_new_file}),
    };
    try std.testing.expectError(
        error.TypedFileMutationTargetRequired,
        permissionTargetForCall(arena, workspace, write_call, .none),
    );

    const edit_call: types.ToolCall = .{
        .id = "edit",
        .name = "edit_file",
        .arguments_json = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"old_string\":\"main\",\"new_string\":\"start\"}}", .{external_file}),
    };
    try std.testing.expectError(
        error.TypedFileMutationTargetRequired,
        permissionTargetForCall(arena, workspace, edit_call, .none),
    );

    const delete_call: types.ToolCall = .{
        .id = "delete",
        .name = "delete_file",
        .arguments_json = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{external_file}),
    };
    try std.testing.expectEqualStrings(external_file, try permissionTargetForCall(arena, workspace, delete_call, .path_existing));

    const create_folder_call: types.ToolCall = .{
        .id = "mkdir",
        .name = "create_folder",
        .arguments_json = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{external_new_dir}),
    };
    try std.testing.expectEqualStrings(std.fs.path.dirname(external_new_dir).?, try permissionTargetForCall(arena, workspace, create_folder_call, .path_create_parent));

    const file_info_call: types.ToolCall = .{
        .id = "info",
        .name = "file_info",
        .arguments_json = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{external_file}),
    };
    try std.testing.expectEqualStrings(external_file, try permissionTargetForCall(arena, workspace, file_info_call, .path_existing));

    const open_call: types.ToolCall = .{
        .id = "open",
        .name = "open_file",
        .arguments_json = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{external_file}),
    };
    try std.testing.expectEqualStrings(external_file, try permissionTargetForCall(arena, workspace, open_call, .path_existing));
}

test "permissionTargetsForCall resolves external copy and rename pairs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try tmp.dir.createDirPath(std.testing.io, "external");
    {
        var file = try tmp.dir.createFile(std.testing.io, "external/source.txt", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "source\n");
    }

    const workspace = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external_source = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, "external/source.txt");
    defer alloc.free(external_source);
    const external_dir = std.fs.path.dirname(external_source).?;
    const external_copy_dest = try std.fs.path.join(alloc, &.{ external_dir, "copied.txt" });
    defer alloc.free(external_copy_dest);
    const external_rename_dest = try std.fs.path.join(alloc, &.{ external_dir, "renamed.txt" });
    defer alloc.free(external_rename_dest);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var copy_targets = try permissionTargetsForCall(alloc, workspace, .{
        .id = "copy",
        .name = "copy_file",
        .arguments_json = try std.fmt.allocPrint(arena, "{{\"source\":\"{s}\",\"destination\":\"{s}\"}}", .{ external_source, external_copy_dest }),
    }, .none);
    defer copy_targets.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), copy_targets.items.len);
    try std.testing.expectEqualStrings(external_source, copy_targets.items[0].path);
    try std.testing.expectEqualStrings(external_copy_dest, copy_targets.items[1].path);

    var rename_targets = try permissionTargetsForCall(alloc, workspace, .{
        .id = "rename",
        .name = "rename_file",
        .arguments_json = try std.fmt.allocPrint(arena, "{{\"old_path\":\"{s}\",\"new_path\":\"{s}\"}}", .{ external_source, external_rename_dest }),
    }, .none);
    defer rename_targets.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), rename_targets.items.len);
    try std.testing.expectEqualStrings(external_source, rename_targets.items[0].path);
    try std.testing.expectEqualStrings(external_rename_dest, rename_targets.items[1].path);
}

test "command cwd accepts external paths without widening workspace-only search" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "shared/src");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);
    const active_entries = [_]workspace_access.Entry{.{
        .path = @constCast(shared),
        .saved = true,
        .command_line = false,
        .available = true,
        .active = true,
    }};
    const active_scope = workspace_access.AccessScope{
        .primary_directory = workspace,
        .additional_directories = &active_entries,
    };
    const removed_scope = workspace_access.AccessScope.primaryOnly(workspace);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const call = types.ToolCall{
        .id = "cwd",
        .name = "run_command",
        .arguments_json = try std.fmt.allocPrint(arena_state.allocator(), "{{\"command\":\"pwd\",\"cwd\":\"{s}\"}}", .{shared}),
    };
    const cwd = try resolveCommandCwdForCallInScope(alloc, active_scope, call);
    defer alloc.free(cwd);
    try std.testing.expectEqualStrings(shared, cwd);
    const external_cwd = try resolveCommandCwdForCallInScope(alloc, removed_scope, call);
    defer alloc.free(external_cwd);
    try std.testing.expectEqualStrings(shared, external_cwd);

    const search_call = types.ToolCall{
        .id = "search",
        .name = "semantic_search",
        .arguments_json = try std.fmt.allocPrint(arena_state.allocator(), "{{\"query\":\"needle\",\"path\":\"{s}\"}}", .{shared}),
    };
    const search_target = try permissionTargetForCallInScope(arena_state.allocator(), active_scope, search_call, .path_optional_existing);
    try std.testing.expectEqualStrings(shared, search_target);
    try std.testing.expectError(
        error.PathOutsideWorkspace,
        permissionTargetForCallInScope(arena_state.allocator(), removed_scope, search_call, .path_optional_existing),
    );
}

test "copy and rename session grants stay exact for role-specific targets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "external/source.txt", .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "source\n");
    }

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const source = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external/source.txt");
    defer alloc.free(source);

    const grants = try suggestedSessionGrants(alloc, workspace, "copy_file", source, .none);
    defer types.freePermissionGrantSlice(alloc, grants);

    try std.testing.expectEqual(@as(usize, 1), grants.len);
    try std.testing.expectEqualStrings("copy_file", grants[0].tool_name);
    try std.testing.expectEqualStrings(source, grants[0].target_path);
}

test "displayTargetForPolicy renders workspace-relative paths and command cwd" {
    const alloc = std.testing.allocator;

    const root_path = try displayTargetForPolicy(alloc, "/tmp/workspace", "read_file", "/tmp/workspace", .path_existing);
    defer alloc.free(root_path);
    try std.testing.expectEqualStrings(".", root_path);

    const nested_path = try displayTargetForPolicy(alloc, "/tmp/workspace", "write_file", "/tmp/workspace/src/app.zig", .path_create_parent);
    defer alloc.free(nested_path);
    try std.testing.expectEqualStrings("src/app.zig", nested_path);

    const root_command = try displayTargetForPolicy(alloc, "/tmp/workspace", "run_command", "/tmp/workspace::zig build test", .command_cwd);
    defer alloc.free(root_command);
    try std.testing.expectEqualStrings(".::zig build test", root_command);

    const nested_command = try displayTargetForPolicy(alloc, "/tmp/workspace", "run_command", "/tmp/workspace/packages/app::npm test", .command_cwd);
    defer alloc.free(nested_command);
    try std.testing.expectEqualStrings("packages/app::npm test", nested_command);

    const external_command = try displayTargetForPolicy(alloc, "/tmp/workspace", "run_command", "/tmp/other::npm test", .command_cwd);
    defer alloc.free(external_command);
    try std.testing.expectEqualStrings("/tmp/other::npm test", external_command);

    const unknown = try displayTargetForPolicy(alloc, "/tmp/workspace", "unknown_tool", "/tmp/workspace/src/app.zig", .none);
    defer alloc.free(unknown);
    try std.testing.expectEqualStrings("/tmp/workspace/src/app.zig", unknown);
}

test "ruleDecisionForPermissionPattern matches direct inputs and fallback" {
    var rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("bash"), .pattern = @constCast("git *"), .action = .allow },
        .{ .permission = @constCast("bash"), .pattern = @constCast("git push *"), .action = .deny },
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/?ain.zig"), .action = .ask },
    };
    const rules: types.PermissionRuleSet = .{ .rules = rules_buf[0..] };

    try std.testing.expectEqual(RuleDecision.allow, ruleDecisionForPermissionPattern(rules, "bash", "git status", .none));
    try std.testing.expectEqual(RuleDecision.deny, ruleDecisionForPermissionPattern(rules, "bash", "git push origin main", .none));
    try std.testing.expectEqual(RuleDecision.ask, ruleDecisionForPermissionPattern(rules, "edit", "src/main.zig", .none));
    try std.testing.expectEqual(RuleDecision.none, ruleDecisionForPermissionPattern(rules, "read", "README.md", .none));
    try std.testing.expectEqual(RuleDecision.ask, ruleDecisionForPermissionPattern(rules, "read", "README.md", .ask));
}

test "configured wildcard command allows only static command grammar" {
    var rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("*"), .pattern = @constCast("printf *"), .action = .allow },
    };
    const rules: types.PermissionRuleSet = .{ .rules = &rules_buf };

    try std.testing.expectEqual(RuleDecision.allow, ruleDecisionForPermissionPattern(rules, "bash", "printf safe", .none));
    try std.testing.expectEqual(RuleDecision.allow, ruleDecisionForPermissionPattern(rules, "bash", "printf 'safe value'", .none));
    try std.testing.expectEqual(RuleDecision.none, ruleDecisionForPermissionPattern(rules, "bash", "printf safe && touch /tmp/fx-marker", .none));
    try std.testing.expectEqual(RuleDecision.none, ruleDecisionForPermissionPattern(rules, "bash", "printf \"$(touch /tmp/fx-marker)\"", .none));
}

test "configured command rules require exact matching outside static grammar" {
    var exact_rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("bash"), .pattern = @constCast("printf \"$(date)\""), .action = .allow },
    };
    const exact_rules: types.PermissionRuleSet = .{ .rules = &exact_rules_buf };

    try std.testing.expectEqual(RuleDecision.allow, ruleDecisionForPermissionPattern(exact_rules, "bash", "printf \"$(date)\"", .none));
    try std.testing.expectEqual(RuleDecision.none, ruleDecisionForPermissionPattern(exact_rules, "bash", "printf \"$(touch /tmp/fx-marker)\"", .none));

    var dynamic_pattern_rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("bash"), .pattern = @constCast("printf \"*\""), .action = .allow },
    };
    try std.testing.expectEqual(
        RuleDecision.none,
        ruleDecisionForPermissionPattern(.{ .rules = &dynamic_pattern_rules_buf }, "bash", "printf \"safe\"", .none),
    );
}

test "configured command deny and ask retain generic wildcard matching" {
    var rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("bash"), .pattern = @constCast("printf *"), .action = .deny },
        .{ .permission = @constCast("custom"), .pattern = @constCast("printf *"), .action = .ask },
    };
    const rules: types.PermissionRuleSet = .{ .rules = &rules_buf };

    try std.testing.expectEqual(RuleDecision.deny, ruleDecisionForPermissionPattern(rules, "bash", "printf safe && touch /tmp/fx-marker", .none));
    try std.testing.expectEqual(RuleDecision.ask, ruleDecisionForPermissionPattern(rules, "custom", "printf \"$(touch /tmp/fx-marker)\"", .none));
}

test "static command grammar is an explicit allowlist" {
    for ([_][]const u8{
        "git status --short",
        "printf 'safe value'",
        "printf ''",
        "tool foo/bar:baz,+qux=value%@host",
        "printf 'Grüße'",
    }) |command| {
        try std.testing.expect(isStaticCommand(command, false));
    }

    for ([_][]const u8{
        "",
        " leading",
        "trailing ",
        "FOO=bar command",
        "FOO='bar' command",
        "echo \"dynamic\"",
        "echo $HOME",
        "echo `pwd`",
        "echo ~",
        "echo [ab]",
        "echo #comment",
        "echo foo\\bar",
        "echo one && echo two",
        "echo one | cat",
        "echo one > out",
        "(echo one)",
        "echo one\necho two",
        "echo 'unterminated",
    }) |command| {
        try std.testing.expect(!isStaticCommand(command, false));
    }

    try std.testing.expect(isStaticCommand("git * --?", true));
    try std.testing.expect(!isStaticCommand("git * --?", false));
    try std.testing.expect(isStaticCommand("printf '*'", false));
}

test "generic wildcard matching remains total for maximum command-sized input" {
    const candidate = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(candidate);
    @memset(candidate, 'x');
    try std.testing.expect(wildcardMatch("*", candidate));
    try std.testing.expect(!wildcardMatch("?", candidate));
}

test "rulesDenyAllTargetsForPermission honors last matching overrides" {
    var later_allow_rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("*"), .action = .deny },
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/*"), .action = .allow },
    };
    try std.testing.expect(!rulesDenyAllTargetsForPermission(.{ .rules = &later_allow_rules }, "edit"));

    var later_deny_rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/*"), .action = .allow },
        .{ .permission = @constCast("edit"), .pattern = @constCast("*"), .action = .deny },
    };
    try std.testing.expect(rulesDenyAllTargetsForPermission(.{ .rules = &later_deny_rules }, "edit"));

    var target_deny_rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/*"), .action = .deny },
    };
    try std.testing.expect(!rulesDenyAllTargetsForPermission(.{ .rules = &target_deny_rules }, "edit"));
}

test "command permission target treats a textual null cwd as absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = try permissionTargetForCall(arena, "/tmp/workspace", .{
        .id = "terminal",
        .name = "terminal",
        .arguments_json = "{\"action\":\"exec\",\"command\":\"ls\",\"cwd\":\" NULL \"}",
    }, .command_cwd);

    try std.testing.expectEqualStrings("/tmp/workspace::ls", target);
}

test "web_fetch permission target is canonical domain rather than full url" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = try permissionTargetForCall(arena, "/tmp/workspace", .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://Example.COM./docs?q=1\",\"prompt\":\"extract\"}",
    }, .none);

    try std.testing.expectEqualStrings("domain:example.com", target);
}

test "web_fetch permission target supports bracketed ipv6 literal urls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = try permissionTargetForCall(arena, "/tmp/workspace", .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://[2606:4700:4700::1111]/dns-query\",\"prompt\":\"extract\"}",
    }, .none);

    try std.testing.expectEqualStrings("domain:[2606:4700:4700::1111]", target);
    try std.testing.expect(isCanonicalWebFetchDomainPattern(target));
}

test "web_fetch exact matcher never calls generic url wildcard matcher" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try permissionTargetForCall(arena, "/tmp/workspace", .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.com/docs\",\"prompt\":\"extract\"}",
    }, .none);

    var rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("url"), .pattern = @constCast("https://example.com/*"), .action = .allow },
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:*.com"), .action = .allow },
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:example.com?"), .action = .allow },
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:example.com"), .action = .allow },
    };
    const rules: types.PermissionRuleSet = .{ .rules = &rules_buf };

    var generic_only = [_]types.PermissionRule{
        .{ .permission = @constCast("url"), .pattern = @constCast("https://example.com/*"), .action = .allow },
    };
    try std.testing.expectEqual(RuleDecision.none, try ruleDecisionFor(alloc, .{ .rules = &generic_only }, "/tmp/workspace", "web_fetch", target, .none));
    try std.testing.expectEqual(RuleDecision.allow, try ruleDecisionFor(alloc, rules, "/tmp/workspace", "web_fetch", target, .none));
}

test "web_fetch grants do not authorize other tools" {
    const grants = [_]types.PermissionGrant{
        .{ .tool_name = @constCast("web_fetch"), .target_path = @constCast("domain:example.com") },
    };

    try std.testing.expect(sessionGrantAllowed(&grants, "web_fetch", "domain:example.com"));
    try std.testing.expect(!sessionGrantAllowed(&grants, "web_fetch", "domain:example.org"));
    try std.testing.expect(!sessionGrantAllowed(&grants, "open_file", "https://example.com/docs"));
    try std.testing.expect(!sessionGrantAllowed(&grants, "run_command", "https://example.com/docs"));
}

test "web_fetch allowlist rejects wildcard and hand edited broad authorization" {
    const alloc = std.testing.allocator;
    var rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("*"), .action = .allow },
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:*"), .action = .allow },
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:example.?om"), .action = .allow },
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("https://example.com/*"), .action = .allow },
    };
    const rules: types.PermissionRuleSet = .{ .rules = &rules_buf };

    try std.testing.expectEqual(RuleDecision.none, try ruleDecisionFor(alloc, rules, "/tmp/workspace", "web_fetch", "domain:example.com", .none));
}

test "web_fetch malformed hand edited rules warn without disabling unrelated permissions" {
    const alloc = std.testing.allocator;
    var rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("*"), .action = .allow },
    };
    const rules: types.PermissionRuleSet = .{ .rules = &rules_buf };

    try std.testing.expectEqual(RuleDecision.none, try ruleDecisionFor(alloc, rules, "/tmp/workspace", "web_fetch", "domain:example.com", .none));
    try std.testing.expectEqual(@as(usize, 1), webFetchRuleWarningCount(rules.rules));
}

test "permissionRulePatternForGrant preserves explicit command environment identity" {
    const alloc = std.testing.allocator;

    const command = try permissionRulePatternForGrant(alloc, "/tmp/workspace", "bash", "/tmp/workspace::zig build");
    defer alloc.free(command);
    try std.testing.expectEqualStrings("zig build", command);

    const explicit_identity = try command_environment.permissionCommandIdentity(
        alloc,
        .{ .user = "/opt/bin::zsh" },
        "zig build",
    );
    defer alloc.free(explicit_identity);
    const explicit_target = try std.fmt.allocPrint(alloc, "/tmp/workspace::{s}", .{explicit_identity});
    defer alloc.free(explicit_target);
    const explicit_command = try permissionRulePatternForGrant(alloc, "/tmp/workspace", "bash", explicit_target);
    defer alloc.free(explicit_command);
    try std.testing.expectEqualStrings(explicit_identity, explicit_command);
    const bare_explicit_command = try permissionRulePatternForGrant(
        alloc,
        "/tmp/workspace",
        "bash",
        explicit_identity,
    );
    defer alloc.free(bare_explicit_command);
    try std.testing.expectEqualStrings(explicit_identity, bare_explicit_command);

    const path = try permissionRulePatternForGrant(alloc, "/tmp/workspace", "edit", "/tmp/workspace/src/*");
    defer alloc.free(path);
    try std.testing.expectEqualStrings("src/*", path);

    const workspace = try permissionRulePatternForGrant(alloc, "/tmp/workspace", "edit", "/tmp/workspace/**");
    defer alloc.free(workspace);
    try std.testing.expectEqualStrings("*", workspace);

    const external = try permissionRulePatternForGrant(alloc, "/tmp/workspace", "read", "/tmp/external/**");
    defer alloc.free(external);
    try std.testing.expectEqualStrings("/tmp/external/**", external);
}

test "configured command rules match explicit environments by command" {
    const alloc = std.testing.allocator;
    var rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("bash"), .pattern = @constCast("zig *"), .action = .allow },
    };
    const rules: types.PermissionRuleSet = .{ .rules = &rules_buf };

    const identity = try command_environment.permissionCommandIdentity(
        alloc,
        .{ .clean = "/bin/zsh" },
        "zig build test",
    );
    defer alloc.free(identity);
    const target = try std.fmt.allocPrint(alloc, "/tmp/workspace::{s}", .{identity});
    defer alloc.free(target);

    try std.testing.expectEqual(
        RuleDecision.allow,
        try ruleDecisionFor(alloc, rules, "/tmp/workspace", "run_command", target, .command_cwd),
    );
}

test "directory tree permission patterns match directory and descendants only" {
    var rules_buf = [_]types.PermissionRule{
        .{ .permission = @constCast("read"), .pattern = @constCast("/tmp/external/**"), .action = .allow },
    };
    const rules: types.PermissionRuleSet = .{ .rules = rules_buf[0..] };

    try std.testing.expectEqual(RuleDecision.allow, try ruleDecisionFor(std.testing.allocator, rules, "/tmp/workspace", "read_file", "/tmp/external", .path_existing));
    try std.testing.expectEqual(RuleDecision.allow, try ruleDecisionFor(std.testing.allocator, rules, "/tmp/workspace", "read_file", "/tmp/external/file.txt", .path_existing));
    try std.testing.expectEqual(RuleDecision.none, try ruleDecisionFor(std.testing.allocator, rules, "/tmp/workspace", "read_file", "/tmp/external-other/file.txt", .path_existing));
}

test "suggestedSessionGrants returns exact command suggestions with stripped cwd" {
    const alloc = std.testing.allocator;

    const grants = try suggestedSessionGrants(alloc, "/tmp/workspace", "run_command", "/tmp/workspace::git status --short", .command_cwd);
    defer freeGrants(alloc, grants);

    try std.testing.expectEqual(@as(usize, 1), grants.len);
    try expectGrant(grants[0], "bash", "git status --short");
}

test "suggestedSessionGrants returns exact broad workspace path suggestions" {
    const alloc = std.testing.allocator;

    const grants = try suggestedSessionGrants(alloc, "/tmp/workspace", "write_file", "/tmp/workspace/src/main.zig", .path_create_parent);
    defer freeGrants(alloc, grants);

    try std.testing.expectEqual(@as(usize, path_always_permissions.len), grants.len);
    for (path_always_permissions, 0..) |permission, i| {
        try expectGrant(grants[i], permission, "/tmp/workspace/**");
    }
}

test "suggestedSessionGrants uses registered path metadata for provider tools" {
    const alloc = std.testing.allocator;
    const grants = try suggestedSessionGrants(
        alloc,
        "/tmp/workspace",
        "provider_list",
        "/tmp/workspace/src",
        .path_optional_existing,
    );
    defer freeGrants(alloc, grants);

    try std.testing.expectEqual(@as(usize, path_always_permissions.len), grants.len);
    for (path_always_permissions, 0..) |permission, i| {
        try expectGrant(grants[i], permission, "/tmp/workspace/**");
    }

    const unknown = try suggestedSessionGrants(
        alloc,
        "/tmp/workspace",
        "unknown_tool",
        "/tmp/workspace/src",
        .none,
    );
    defer freeGrants(alloc, unknown);
    try std.testing.expectEqual(@as(usize, 1), unknown.len);
    try expectGrant(unknown[0], "unknown_tool", "/tmp/workspace/src");
}

test "suggestedSessionGrants excludes narrow path tools from broad grants" {
    const alloc = std.testing.allocator;

    const cases = [_]struct {
        tool_name: []const u8,
        permission: []const u8,
    }{
        .{ .tool_name = "delete_file", .permission = "delete_file" },
        .{ .tool_name = "file_info", .permission = "file_info" },
        .{ .tool_name = "semantic_search", .permission = "semantic_search" },
    };

    for (cases) |case| {
        const grants = try suggestedSessionGrants(alloc, "/tmp/workspace", case.tool_name, "/tmp/workspace/src/main.zig", .path_existing);
        defer freeGrants(alloc, grants);

        try std.testing.expectEqual(@as(usize, 1), grants.len);
        try expectGrant(grants[0], case.permission, "/tmp/workspace/src/main.zig");
    }
}

test "suggestedSessionGrants returns external directory tree read grant" {
    const alloc = std.testing.allocator;

    const grants = try suggestedSessionGrants(alloc, "/tmp/workspace", "read_file", "/tmp/external/hosts", .path_existing);
    defer freeGrants(alloc, grants);

    try std.testing.expectEqual(@as(usize, 1), grants.len);
    try expectGrant(grants[0], "read", "/tmp/external/**");
    try std.testing.expect(sessionGrantAllowed(grants, "read_file", "/tmp/external"));
    try std.testing.expect(sessionGrantAllowed(grants, "read_file", "/tmp/external/hosts"));
    try std.testing.expect(!sessionGrantAllowed(grants, "read_file", "/tmp/external-other/hosts"));
}

fn testFileTargets(
    canonical_path: []const u8,
    external: bool,
    items: *[1]file_mutation_contract.EvaluatedPermissionTarget,
) file_mutation_contract.PolicyEvaluatedFileTargets {
    items.* = .{.{
        .kind = .target,
        .disposition = .target_entry,
        .path_end = canonical_path.len,
        .expected_identity = null,
        .rule = .ask,
        .session_grant_allowed = true,
    }};
    return .{
        .canonical_target_path = canonical_path,
        .anchor = .{
            .scope = if (external) .external else .workspace,
            .path_end = canonical_path.len,
            .identity = .{
                .device = 0,
                .inode = 0,
                .kind = .directory,
            },
            .relative_components = &.{},
        },
        .traversal_directories = &.{},
        .items = items,
        .prompt_required = true,
    };
}

fn deinitTestFileGrantOffer(
    alloc: std.mem.Allocator,
    offer: file_mutation_contract.FileGrantOffer,
) void {
    types.freePermissionGrantSlice(alloc, @constCast(offer.grants));
    switch (offer.scope) {
        .workspace_files => {},
        .external_tree => |root_tail| alloc.free(@constCast(root_tail)),
    }
}

fn checkStructuredFileGrantOfferAllocationFailures(
    alloc: std.mem.Allocator,
) !void {
    var items: [1]file_mutation_contract.EvaluatedPermissionTarget = undefined;
    const offer = try structuredFileGrantOffer(
        alloc,
        "/tmp/workspace",
        "write_file",
        testFileTargets("/tmp/workspace/src/main.zig", false, &items),
    );
    defer deinitTestFileGrantOffer(alloc, offer);
    try std.testing.expect(offer.scope == .workspace_files);
}

fn checkExternalStructuredFileGrantOfferAllocationFailures(
    alloc: std.mem.Allocator,
) !void {
    var items: [1]file_mutation_contract.EvaluatedPermissionTarget = undefined;
    const offer = try structuredFileGrantOffer(
        alloc,
        "/tmp/workspace",
        "edit_file",
        testFileTargets("/tmp/external/project/file.txt", true, &items),
    );
    defer deinitTestFileGrantOffer(alloc, offer);
    try std.testing.expectEqualStrings(
        "/tmp/external/project",
        offer.scope.external_tree,
    );
}

test "structured file grant offer cleans partial allocations" {
    const alloc = std.testing.allocator;
    var items: [1]file_mutation_contract.EvaluatedPermissionTarget = undefined;
    const offer = try structuredFileGrantOffer(
        alloc,
        "/tmp/workspace",
        "write_file",
        testFileTargets("/tmp/workspace/src/main.zig", false, &items),
    );
    defer deinitTestFileGrantOffer(alloc, offer);

    try std.testing.expect(offer.scope == .workspace_files);
    try std.testing.expectEqual(path_always_permissions.len, offer.grants.len);
    for (offer.grants) |grant| {
        try std.testing.expectEqualStrings("/tmp/workspace/**", grant.target_path);
    }

    try std.testing.checkAllAllocationFailures(
        alloc,
        checkStructuredFileGrantOfferAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        alloc,
        checkExternalStructuredFileGrantOfferAllocationFailures,
        .{},
    );
}

test "structured file grant offer rejects a scope that understates its grants" {
    var items: [1]file_mutation_contract.EvaluatedPermissionTarget = undefined;
    try std.testing.expectError(
        error.UnsupportedFileGrantOffer,
        structuredFileGrantOffer(
            std.testing.allocator,
            "/tmp/workspace",
            "write_file",
            testFileTargets("/tmp/external/file.txt", false, &items),
        ),
    );
}

test "structured file grant offer rejects wildcard-bearing literal roots" {
    const Scope = enum { workspace, external };
    const tools = [_]struct {
        name: []const u8,
        basename: []const u8,
    }{
        .{ .name = "write_file", .basename = "write.txt" },
        .{ .name = "edit_file", .basename = "edit.txt" },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]u8{ '*', '?' }) |wildcard| {
        for ([_]Scope{ .workspace, .external }) |scope| {
            const external = scope == .external;
            const root_prefix = if (external) "external" else "workspace";
            const literal_root = try std.fmt.allocPrint(
                arena,
                "/tmp/{s}{c}literal",
                .{ root_prefix, wildcard },
            );
            const workspace_root = if (external) "/tmp/workspace" else literal_root;

            for (tools) |tool| {
                var items: [1]file_mutation_contract.EvaluatedPermissionTarget = undefined;
                const target_path = try std.fs.path.join(
                    arena,
                    &.{ literal_root, tool.basename },
                );
                try std.testing.expectError(
                    error.UnsupportedFileGrantOffer,
                    structuredFileGrantOffer(
                        arena,
                        workspace_root,
                        tool.name,
                        testFileTargets(target_path, external, &items),
                    ),
                );
            }
        }
    }
}

test "generic session matcher retains wildcard tree semantics" {
    const grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("edit"),
        .target_path = @constCast("/tmp/workspace*literal/**"),
    }};

    try std.testing.expect(sessionGrantAllowed(
        &grants,
        "write_file",
        "/tmp/workspaceZZliteral/escaped.txt",
    ));
}

test "formatPermissionsStatus adapts core grants and rules without taking field ownership" {
    const alloc = std.testing.allocator;

    var grants = [_]types.PermissionGrant{.{
        .tool_name = try alloc.dupe(u8, "edit"),
        .target_path = try alloc.dupe(u8, "/tmp/workspace/src/main.zig"),
    }};
    defer {
        alloc.free(grants[0].tool_name);
        alloc.free(grants[0].target_path);
    }

    var rules = types.PermissionRuleSet{
        .rules = try alloc.alloc(types.PermissionRule, 1),
    };
    defer rules.deinit(alloc);
    rules.rules[0] = .{
        .permission = try alloc.dupe(u8, "edit"),
        .pattern = try alloc.dupe(u8, "src/*"),
        .action = .allow,
    };

    const text = try formatPermissionsStatus(alloc, "/tmp/workspace", .ask, grants[0..], rules);
    defer alloc.free(text);

    try expectContains(text, "[permissions] mode=ask\n");
    try expectContains(text, "[permissions] configured rules:\n");
    try expectContains(text, " - allow edit -> src/*\n");
    try expectContains(text, "[permissions] session grants:\n");
    try expectContains(text, " - edit -> src/main.zig\n");
}

test "allowToolForSession cleans up all partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllowToolForSessionAllocFailures, .{});
}

test "suggestedSessionGrants cleans up all partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSuggestedSessionGrantsAllocFailures, .{});
}

fn testWriteMutationInput(path: []const u8) file_mutation_contract.FileMutationInput {
    return .{ .write = .{
        .path = @constCast(path),
        .content = @constCast("x"),
    } };
}

fn testEditMutationInput(path: []const u8) file_mutation_contract.FileMutationInput {
    return .{ .edit = .{
        .path = @constCast(path),
        .old_string = @constCast("a"),
        .new_string = @constCast("b"),
    } };
}

test "file target preparation owns a policy-neutral proof consumed by policy evaluation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/existing");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var prepared = switch (try prepareFileMutationTargets(
        alloc,
        workspace,
        testWriteMutationInput("existing/nested/file.txt"),
    )) {
        .target_resolution_failure => return error.TestUnexpectedResult,
        .prepared => |value| value,
    };
    defer prepared.deinit(alloc);

    try std.testing.expect(prepared.proofValid());
    try std.testing.expectEqualStrings(workspace, prepared.anchorPath());
    try std.testing.expectEqual(@as(usize, 3), prepared.anchor.relative_components.len);
    try std.testing.expectEqual(@as(usize, 2), prepared.traversal_directories.len);
    try std.testing.expectEqual(@as(usize, 2), prepared.items.len);
    const canonical_ptr = prepared.canonical_target_path.ptr;

    const result = try evaluatePreparedFileMutationTargets(
        alloc,
        workspace,
        .write,
        &prepared,
        .ask,
        .{},
        &.{},
        &.{},
    );
    var evaluated = switch (result) {
        .evaluated => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer evaluated.deinitOwned(alloc);

    try std.testing.expect(!prepared.owns_memory);
    try std.testing.expectEqual(canonical_ptr, evaluated.canonical_target_path.ptr);
    try std.testing.expect(evaluated.prompt_required);
    try std.testing.expect(evaluated.proofValid());
}

fn checkFileTargetPreparationAllocationFailures(alloc: std.mem.Allocator, workspace: []const u8) !void {
    var prepared = switch (try prepareFileMutationTargets(
        alloc,
        workspace,
        testWriteMutationInput("existing/nested/file.txt"),
    )) {
        .target_resolution_failure => return error.TestUnexpectedResult,
        .prepared => |value| value,
    };
    defer prepared.deinit(alloc);
}

test "file target preparation cleans every partial allocation failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/existing");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    try std.testing.checkAllAllocationFailures(
        alloc,
        checkFileTargetPreparationAllocationFailures,
        .{workspace},
    );
}

test "file target evaluator returns ordered complete workspace proof" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/existing");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const result = try evaluateFileMutationTargets(
        arena,
        workspace,
        testWriteMutationInput("existing/a/b/file.txt"),
        .ask,
        .{},
        &.{},
        &.{},
    );

    const evaluated = switch (result) {
        .evaluated => |value| value,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqualStrings(workspace, evaluated.anchorPath());
    try std.testing.expectEqual(.workspace, evaluated.anchor.scope);
    try std.testing.expectEqual(.directory, evaluated.anchor.identity.kind);
    try std.testing.expect(evaluated.anchor.identity.inode != 0);
    try std.testing.expect(evaluated.anchor.identity.device != 0);
    try std.testing.expectEqual(@as(usize, 4), evaluated.anchor.relative_components.len);
    try std.testing.expectEqualStrings("existing", evaluated.component(evaluated.anchor.relative_components[0]));
    try std.testing.expectEqualStrings("a", evaluated.component(evaluated.anchor.relative_components[1]));
    try std.testing.expectEqualStrings("b", evaluated.component(evaluated.anchor.relative_components[2]));
    try std.testing.expectEqualStrings("file.txt", evaluated.component(evaluated.anchor.relative_components[3]));

    try std.testing.expectEqual(@as(usize, 3), evaluated.traversal_directories.len);
    try std.testing.expectEqual(@as(usize, 0), evaluated.traversal_directories[0].component_index);
    try std.testing.expectEqual(.directory, evaluated.traversal_directories[0].state.existing.kind);
    try std.testing.expect(evaluated.traversal_directories[0].state.existing.inode != evaluated.anchor.identity.inode);
    try std.testing.expectEqual(@as(usize, 2), evaluated.traversal_directories[1].state.create.permission_target_index);
    try std.testing.expectEqual(@as(usize, 1), evaluated.traversal_directories[2].state.create.permission_target_index);

    try std.testing.expectEqual(@as(usize, 3), evaluated.items.len);
    try std.testing.expectEqual(.target, evaluated.items[0].kind);
    try std.testing.expectEqual(.target_entry, evaluated.items[0].disposition);
    try std.testing.expect(evaluated.items[0].expected_identity == null);
    try std.testing.expectEqualStrings("existing/a/b/file.txt", evaluated.permissionPath(evaluated.items[0])[workspace.len + 1 ..]);
    try std.testing.expectEqual(.parent, evaluated.items[1].kind);
    try std.testing.expectEqual(.create_parent, evaluated.items[1].disposition);
    try std.testing.expectEqualStrings("existing/a/b", evaluated.permissionPath(evaluated.items[1])[workspace.len + 1 ..]);
    try std.testing.expectEqual(.parent, evaluated.items[2].kind);
    try std.testing.expectEqual(.create_parent, evaluated.items[2].disposition);
    try std.testing.expectEqualStrings("existing/a", evaluated.permissionPath(evaluated.items[2])[workspace.len + 1 ..]);
    try std.testing.expect(evaluated.prompt_required);
}

test "file target evaluator scans immediate parent deny after target ask" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/existing");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("existing/a/b/file.txt"), .action = .ask },
        .{ .permission = @constCast("edit"), .pattern = @constCast("existing/a/b"), .action = .deny },
    };

    const result = try evaluateFileMutationTargets(
        arena,
        workspace,
        testWriteMutationInput("existing/a/b/file.txt"),
        .ask,
        .{ .rules = &rules },
        &.{},
        &.{},
    );

    switch (result) {
        .policy_denied => |denied| try std.testing.expectEqual(@as(usize, 1), denied.target_index),
        else => return error.TestUnexpectedResult,
    }
}

test "file target evaluator scans intermediate deny before grants" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/existing");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("existing/a/b/file.txt"), .action = .ask },
        .{ .permission = @constCast("edit"), .pattern = @constCast("existing/a"), .action = .deny },
    };
    const grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("edit"),
        .target_path = @constCast("/**"),
    }};

    const result = try evaluateFileMutationTargets(
        arena,
        workspace,
        testWriteMutationInput("existing/a/b/file.txt"),
        .ask,
        .{ .rules = &rules },
        &grants,
        &.{},
    );

    switch (result) {
        .policy_denied => |denied| try std.testing.expectEqual(@as(usize, 2), denied.target_index),
        else => return error.TestUnexpectedResult,
    }
}

test "file target evaluator records existing traversal and target identities" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/existing/deeper");
    var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/existing/deeper/file.txt", .{});
    file.close(io_mod.getIo());

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const expected_target = try std.fs.path.join(arena, &.{ workspace, "existing", "deeper", "file.txt" });
    const expected_target_stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), expected_target, .{ .follow_symlinks = false });

    const result = try evaluateFileMutationTargets(
        arena,
        workspace,
        testEditMutationInput("existing/deeper/file.txt"),
        .auto,
        .{},
        &.{},
        &.{},
    );
    const evaluated = switch (result) {
        .evaluated => |value| value,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expect(evaluated.prompt_required);
    try std.testing.expectEqual(@as(usize, 2), evaluated.traversal_directories.len);
    try std.testing.expectEqual(.directory, evaluated.traversal_directories[0].state.existing.kind);
    try std.testing.expectEqual(.directory, evaluated.traversal_directories[1].state.existing.kind);
    try std.testing.expectEqual(@as(usize, 2), evaluated.items.len);
    try std.testing.expectEqual(.file, evaluated.items[0].expected_identity.?.kind);
    try std.testing.expectEqual(@as(u64, @intCast(expected_target_stat.inode)), evaluated.items[0].expected_identity.?.inode);
    try std.testing.expectEqual(.existing_parent, evaluated.items[1].disposition);
    try std.testing.expectEqual(
        evaluated.traversal_directories[1].state.existing.inode,
        evaluated.items[1].expected_identity.?.inode,
    );
}

test "file target evaluator binds external parent and grant state" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    var file = try tmp.dir.createFile(io_mod.getIo(), "external/file.txt", .{});
    file.close(io_mod.getIo());

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    const target = try std.fs.path.join(arena, &.{ external, "file.txt" });
    const grants = [_]types.PermissionGrant{.{
        .tool_name = @constCast("edit"),
        .target_path = @constCast("/**"),
    }};

    const result = try evaluateFileMutationTargets(
        arena,
        workspace,
        testEditMutationInput(target),
        .ask,
        .{},
        &grants,
        &.{},
    );
    const evaluated = switch (result) {
        .evaluated => |value| value,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(.external, evaluated.anchor.scope);
    try std.testing.expectEqualStrings(external, evaluated.anchorPath());
    try std.testing.expectEqual(.directory, evaluated.anchor.identity.kind);
    try std.testing.expect(evaluated.anchor.identity.device != 0);
    try std.testing.expectEqual(@as(usize, 1), evaluated.anchor.relative_components.len);
    try std.testing.expectEqual(@as(usize, 0), evaluated.traversal_directories.len);
    try std.testing.expectEqual(@as(usize, 2), evaluated.items.len);
    try std.testing.expect(evaluated.items[0].session_grant_allowed);
    try std.testing.expect(evaluated.items[1].session_grant_allowed);
    try std.testing.expect(!evaluated.prompt_required);
    try std.testing.expectEqual(
        evaluated.anchor.identity.inode,
        evaluated.items[1].expected_identity.?.inode,
    );
}

test "file target evaluator requires approval for unconfigured external target in auto mode" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");

    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    const target = try std.fs.path.join(arena, &.{ external, "new", "file.txt" });

    const result = try evaluateFileMutationTargets(
        arena,
        workspace,
        testWriteMutationInput(target),
        .auto,
        .{},
        &.{},
        &.{},
    );
    const evaluated = switch (result) {
        .evaluated => |value| value,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(.external, evaluated.anchor.scope);
    try std.testing.expectEqualStrings(external, evaluated.anchorPath());
    try std.testing.expectEqual(@as(usize, 2), evaluated.anchor.relative_components.len);
    try std.testing.expectEqual(@as(usize, 1), evaluated.traversal_directories.len);
    try std.testing.expectEqual(@as(usize, 1), evaluated.traversal_directories[0].state.create.permission_target_index);
    try std.testing.expect(evaluated.prompt_required);
}

test "file target evaluator propagates only operational failures" {
    try std.testing.expectError(error.Canceled, normalizeFileTargetResolverError(error.Canceled));
    try std.testing.expectError(error.Unexpected, normalizeFileTargetResolverError(error.Unexpected));
    try std.testing.expectError(error.SystemResources, normalizeDirOpenError(error.SystemResources));
    try std.testing.expectError(error.ProcessFdQuotaExceeded, normalizeDirOpenError(error.ProcessFdQuotaExceeded));
    try std.testing.expectError(error.SystemFdQuotaExceeded, normalizeStatFileError(error.SystemFdQuotaExceeded));

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        evaluateFileMutationTargets(
            failing.allocator(),
            workspace,
            testWriteMutationInput("file.txt"),
            .auto,
            .{},
            &.{},
            &.{},
        ),
    );
    try std.testing.expect(failing.has_induced_failure);
}

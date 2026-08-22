const std = @import("std");
const background_runtime = @import("../background/background_runtime.zig");
const change_tracker = @import("change_tracker.zig");
const session_runtime = @import("../session/session.zig");
const types = @import("../shared/types.zig");
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    pub const scoped_rules: usize = 32;
    pub const project_omission_records: usize = 32;
    pub const git_read_budget_ns: i128 = 50 * std.time.ns_per_ms;
    pub const git_metadata_file_bytes: usize = 4096;
    pub const git_config_file_bytes: usize = 16 * 1024;
    pub const git_index_file_bytes: u64 = 16 * 1024;
    pub const git_index_entries: u32 = 32;
};

pub const ProviderError = Allocator.Error || error{
    NoSpaceLeft,
    WriteFailed,
};

pub const GatheredContribution = struct {
    provider_id: []u8,
    content: []u8,
};

pub const TargetKind = enum {
    file,
    directory,
};

pub const ApplicableTarget = struct {
    path: []const u8,
    kind: TargetKind,
};

/// Returns owned target storage whose paths remain owned by `images`.
pub fn applicableTargetsForImages(
    alloc: Allocator,
    images: []const types.ImageAttachment,
) Allocator.Error![]ApplicableTarget {
    if (images.len == 0) return &.{};
    const targets = try alloc.alloc(ApplicableTarget, images.len);
    for (images, targets) |image, *target| {
        target.* = .{ .path = image.path, .kind = .file };
    }
    return targets;
}

pub const OmissionReason = enum {
    home_unavailable,
    home_outside_workspace,
    unsafe_target,
    unreadable,
    oversized,
    non_regular,
    symlink,
    selection_cap,

    pub fn label(self: OmissionReason) []const u8 {
        return switch (self) {
            .home_unavailable => "home unavailable",
            .home_outside_workspace => "workspace is not below home",
            .unsafe_target => "unsafe target",
            .unreadable => "unreadable rule file",
            .oversized => "oversized rule file",
            .non_regular => "non-regular rule file",
            .symlink => "symlinked rule file",
            .selection_cap => "selection cap",
        };
    }
};

pub const ContextOmissionInput = struct {
    source: []const u8,
    reason: OmissionReason,
};

pub const ContextOmissionSummary = struct {
    omitted_count: usize,
    reason_counts: [std.meta.fields(OmissionReason).len]usize,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

pub const ContextOmissionSummaryBuilder = struct {
    omitted_count: usize = 0,
    reason_counts: [std.meta.fields(OmissionReason).len]usize = @splat(0),
    hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),

    pub fn add(self: *ContextOmissionSummaryBuilder, source: []const u8, reason: OmissionReason) void {
        self.omitted_count += 1;
        self.reason_counts[@intFromEnum(reason)] += 1;
        self.hasher.update("fx.context.omission-record\x00");
        self.hasher.update(&.{@intFromEnum(reason)});
        hashUsize(&self.hasher, source.len);
        self.hasher.update(source);
    }

    pub fn merge(self: *ContextOmissionSummaryBuilder, summary: ContextOmissionSummary) void {
        if (summary.omitted_count == 0) return;
        self.omitted_count += summary.omitted_count;
        for (&self.reason_counts, summary.reason_counts) |*count, additional| count.* += additional;
        self.hasher.update("fx.context.omission-summary\x00");
        hashUsize(&self.hasher, summary.omitted_count);
        for (summary.reason_counts) |count| hashUsize(&self.hasher, count);
        self.hasher.update(&summary.digest);
    }

    pub fn finish(self: *const ContextOmissionSummaryBuilder) ?ContextOmissionSummary {
        if (self.omitted_count == 0) return null;
        var hasher = self.hasher;
        return .{
            .omitted_count = self.omitted_count,
            .reason_counts = self.reason_counts,
            .digest = hasher.finalResult(),
        };
    }
};

fn hashUsize(hasher: *std.crypto.hash.sha2.Sha256, value: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .big);
    hasher.update(&bytes);
}

pub const InitialContextInput = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    targets: []const ApplicableTarget = &.{},
    omissions: []const ContextOmissionInput = &.{},
    omission_summary: ?ContextOmissionSummary = null,
    context_limits: context_limits.Values = .{},
};

pub const LaterContextInput = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    targets: []const ApplicableTarget,
    delivered_sources: []const []const u8,
    evaluated_endpoints: []const []const u8,
    context_limits: context_limits.Values = .{},
};

/// Owns provider-produced context bytes and delivery-state additions. The
/// caller must call deinit with the allocator passed to the provider.
pub const ProviderContext = struct {
    content: ?[]u8 = null,
    delivered_sources: [][]u8 = &.{},
    evaluated_endpoints: [][]u8 = &.{},
    notices: [][]u8 = &.{},

    pub fn deinit(self: *ProviderContext, alloc: Allocator) void {
        if (self.content) |content| {
            if (content.len > 0) alloc.free(content);
        }
        freeOwnedStrings(alloc, self.delivered_sources);
        freeOwnedStrings(alloc, self.evaluated_endpoints);
        freeOwnedStrings(alloc, self.notices);
        self.* = .{};
    }

    pub fn modelVisibleBytes(self: ProviderContext) []const u8 {
        return self.content orelse "";
    }
};

/// Owns gathered contribution bytes and provenance. The caller must call
/// deinit with the allocator passed to gatherDefaultSnapshot or dupe.
pub const GatheredContextSnapshot = struct {
    contribution: ?GatheredContribution = null,
    delivered_sources: [][]u8 = &.{},
    evaluated_endpoints: [][]u8 = &.{},
    notices: [][]u8 = &.{},

    pub fn deinit(self: *GatheredContextSnapshot, alloc: Allocator) void {
        if (self.contribution) |contribution| {
            if (contribution.provider_id.len > 0) alloc.free(contribution.provider_id);
            if (contribution.content.len > 0) alloc.free(contribution.content);
        }
        freeOwnedStrings(alloc, self.delivered_sources);
        freeOwnedStrings(alloc, self.evaluated_endpoints);
        freeOwnedStrings(alloc, self.notices);
        self.* = .{};
    }

    pub fn dupe(self: GatheredContextSnapshot, alloc: Allocator) Allocator.Error!GatheredContextSnapshot {
        var result: GatheredContextSnapshot = .{};
        errdefer result.deinit(alloc);
        if (self.contribution) |contribution| {
            result.contribution = try dupeContribution(alloc, contribution);
        }
        result.delivered_sources = try dupeOwnedStrings(alloc, self.delivered_sources);
        result.evaluated_endpoints = try dupeOwnedStrings(alloc, self.evaluated_endpoints);
        result.notices = try dupeOwnedStrings(alloc, self.notices);
        return result;
    }

    pub fn modelVisibleBytes(self: GatheredContextSnapshot) []const u8 {
        return if (self.contribution) |contribution| contribution.content else "";
    }
};

pub const DeliveryState = struct {
    delivered_sources: std.ArrayList([]u8) = .empty,
    evaluated_endpoints: std.ArrayList([]u8) = .empty,

    pub fn initFromSnapshot(alloc: Allocator, snapshot: GatheredContextSnapshot) Allocator.Error!DeliveryState {
        var state: DeliveryState = .{};
        errdefer state.deinit(alloc);
        try appendDupedStrings(alloc, &state.delivered_sources, snapshot.delivered_sources);
        try appendDupedStrings(alloc, &state.evaluated_endpoints, snapshot.evaluated_endpoints);
        return state;
    }

    pub fn deinit(self: *DeliveryState, alloc: Allocator) void {
        for (self.delivered_sources.items) |source| alloc.free(source);
        self.delivered_sources.deinit(alloc);
        for (self.evaluated_endpoints.items) |endpoint| alloc.free(endpoint);
        self.evaluated_endpoints.deinit(alloc);
        self.* = .{};
    }

    pub fn commit(self: *DeliveryState, alloc: Allocator, selected: *ProviderContext) Allocator.Error!void {
        try self.delivered_sources.ensureUnusedCapacity(alloc, selected.delivered_sources.len);
        try self.evaluated_endpoints.ensureUnusedCapacity(alloc, selected.evaluated_endpoints.len);
        for (selected.delivered_sources) |source| self.delivered_sources.appendAssumeCapacity(source);
        for (selected.evaluated_endpoints) |endpoint| self.evaluated_endpoints.appendAssumeCapacity(endpoint);
        if (selected.delivered_sources.len > 0) alloc.free(selected.delivered_sources);
        if (selected.evaluated_endpoints.len > 0) alloc.free(selected.evaluated_endpoints);
        selected.delivered_sources = &.{};
        selected.evaluated_endpoints = &.{};
    }
};

pub const StaticContextInput = struct {
    project_context: []const u8,
};

pub const HostWorkspaceContext = struct {
    root: []const u8,
    cwd: []const u8,
    home: []const u8,
};

pub const TransientContextInput = struct {
    workspace_root: []const u8,
    host_workspace: ?HostWorkspaceContext = null,
    access_scope: ?workspace_access.AccessScope = null,
    interactive: bool,
    permission_mode: types.PermissionMode,
    tracker: ?*change_tracker.ChangeTracker,
    background: *background_runtime.BackgroundRuntime,
    session: *session_runtime.SessionRuntime,
};

pub const Provider = struct {
    id: []const u8,
    gather_project_context_fn: *const fn (Allocator, InitialContextInput) ProviderError!ProviderContext,
    select_applicable_project_context_fn: *const fn (Allocator, LaterContextInput) ProviderError!ProviderContext,
    append_static_fn: *const fn (StaticContextInput, Allocator, *std.ArrayList(types.ChatMessage)) ProviderError!void,
    append_transient_fn: *const fn (TransientContextInput, Allocator, *std.ArrayList(types.ChatMessage)) ProviderError!void,

    pub fn gatherProjectContext(self: Provider, alloc: Allocator, input: InitialContextInput) ProviderError!ProviderContext {
        return self.gather_project_context_fn(alloc, input);
    }

    pub fn selectApplicableProjectContext(self: Provider, alloc: Allocator, input: LaterContextInput) ProviderError!ProviderContext {
        return self.select_applicable_project_context_fn(alloc, input);
    }

    pub fn appendStatic(self: Provider, input: StaticContextInput, alloc: Allocator, messages: *std.ArrayList(types.ChatMessage)) ProviderError!void {
        return self.append_static_fn(input, alloc, messages);
    }

    pub fn appendTransient(self: Provider, input: TransientContextInput, alloc: Allocator, messages: *std.ArrayList(types.ChatMessage)) ProviderError!void {
        return self.append_transient_fn(input, alloc, messages);
    }
};

pub fn selectNoApplicableProjectContext(_: Allocator, _: LaterContextInput) ProviderError!ProviderContext {
    return .{};
}

pub const Registry = struct {
    default_provider: Provider,

    pub fn defaultProvider(self: Registry) Provider {
        return self.default_provider;
    }

    pub fn gatherDefaultSnapshot(self: Registry, alloc: Allocator, input: InitialContextInput) ProviderError!GatheredContextSnapshot {
        const provider = self.defaultProvider();
        var gathered = try provider.gatherProjectContext(alloc, input);
        errdefer gathered.deinit(alloc);

        var snapshot: GatheredContextSnapshot = .{
            .delivered_sources = gathered.delivered_sources,
            .evaluated_endpoints = gathered.evaluated_endpoints,
            .notices = gathered.notices,
        };
        gathered.delivered_sources = &.{};
        gathered.evaluated_endpoints = &.{};
        gathered.notices = &.{};
        errdefer snapshot.deinit(alloc);

        if (gathered.content) |content| {
            if (content.len > 0) {
                const provider_id = try alloc.dupe(u8, provider.id);
                snapshot.contribution = .{
                    .provider_id = provider_id,
                    .content = content,
                };
                gathered.content = null;
            } else {
                alloc.free(content);
                gathered.content = null;
            }
        }
        return snapshot;
    }

    pub fn selectDefaultApplicableContext(self: Registry, alloc: Allocator, input: LaterContextInput) ProviderError!ProviderContext {
        return self.defaultProvider().selectApplicableProjectContext(alloc, input);
    }

    pub fn appendDefaultStatic(self: Registry, input: StaticContextInput, alloc: Allocator, messages: *std.ArrayList(types.ChatMessage)) ProviderError!void {
        return self.defaultProvider().appendStatic(input, alloc, messages);
    }

    pub fn appendDefaultTransient(self: Registry, input: TransientContextInput, alloc: Allocator, messages: *std.ArrayList(types.ChatMessage)) ProviderError!void {
        return self.defaultProvider().appendTransient(input, alloc, messages);
    }
};

fn freeOwnedStrings(alloc: Allocator, strings: [][]u8) void {
    for (strings) |string| alloc.free(string);
    if (strings.len > 0) alloc.free(strings);
}

fn dupeContribution(alloc: Allocator, contribution: GatheredContribution) Allocator.Error!GatheredContribution {
    const provider_id = try alloc.dupe(u8, contribution.provider_id);
    errdefer if (provider_id.len > 0) alloc.free(provider_id);
    const content = try alloc.dupe(u8, contribution.content);
    return .{ .provider_id = provider_id, .content = content };
}

fn dupeOwnedStrings(alloc: Allocator, strings: []const []const u8) Allocator.Error![][]u8 {
    if (strings.len == 0) return &.{};
    const result = try alloc.alloc([]u8, strings.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |string| alloc.free(string);
        alloc.free(result);
    }
    for (strings, 0..) |string, index| {
        result[index] = try alloc.dupe(u8, string);
        initialized += 1;
    }
    return result;
}

fn appendDupedStrings(alloc: Allocator, destination: *std.ArrayList([]u8), strings: []const []const u8) Allocator.Error!void {
    try destination.ensureUnusedCapacity(alloc, strings.len);
    for (strings) |string| {
        destination.appendAssumeCapacity(try alloc.dupe(u8, string));
    }
}

pub const contract_name = "fx.shared_model_context.v1";

pub const Fragment = enum {
    workspace_identity,
    repo_identity,
    scoped_instructions,
    available_tools,
    permission_mode,
    environment_metadata,
    session_metadata,

    fn label(self: Fragment) []const u8 {
        return switch (self) {
            .workspace_identity => "workspace_identity",
            .repo_identity => "repo_identity",
            .scoped_instructions => "scoped_instructions",
            .available_tools => "available_tools",
            .permission_mode => "permission_mode",
            .environment_metadata => "environment_metadata",
            .session_metadata => "session_metadata",
        };
    }

    fn contractText(self: Fragment) []const u8 {
        return switch (self) {
            .workspace_identity => "workspace root and current directory",
            .repo_identity => "git branch, worktree state, and sanitized GitHub origin when known",
            .scoped_instructions => "bounded global, workspace, and nested scoped rules plus the bounded visible skill catalog",
            .available_tools => "gateway-advertised tool schemas after permission, deferred MCP discovery, and entrypoint filtering",
            .permission_mode => "captured ask, auto, or yolo baseline for the active turn without rule or grant contents",
            .environment_metadata => "OS, shell, date, home directory, and live/non-live background runtime hints",
            .session_metadata => "model, step budget, max tool-result bytes, conversation history, grants, loaded skills, and persisted session id when present",
        };
    }
};

pub const EntryPoint = enum {
    interactive,
    ask,
    acp,
    subagent,

    fn label(self: EntryPoint) []const u8 {
        return switch (self) {
            .interactive => "interactive",
            .ask => "fx ask",
            .acp => "ACP",
            .subagent => "subagent",
        };
    }
};

pub const DriftStatus = enum {
    intentional,
    temporary,
    phase12_follow_up,

    fn label(self: DriftStatus) []const u8 {
        return switch (self) {
            .intentional => "intentional",
            .temporary => "temporary",
            .phase12_follow_up => "phase12_follow_up",
        };
    }
};

pub const EntrypointInventory = struct {
    entrypoint: EntryPoint,
    assembly_path: []const u8,
    static_context: []const u8,
    transient_context: []const u8,
    tools: []const u8,
    permission: []const u8,
    session: []const u8,
    drift_status: DriftStatus,
    drift: []const u8,
};

const required_fragments = [_]Fragment{
    .workspace_identity,
    .repo_identity,
    .scoped_instructions,
    .available_tools,
    .permission_mode,
    .environment_metadata,
    .session_metadata,
};

const current_inventory = [_]EntrypointInventory{
    .{
        .entrypoint = .interactive,
        .assembly_path = "main.App.enqueuePrompt -> app_agent_runtime.processQueuedPrompt -> agent_runtime dependencies",
        .static_context = "builtins/context captures one global/root/ancestor/applicable AGENTS.md snapshot before enqueue, then adds scoped deltas from effective structured tool targets",
        .transient_context = "tool_runtime transient context each model step: env_context, captured permission mode, background runtime, non-live background history",
        .tools = "App.snapshotGatewayToolProjection pairs full tool advertisement with included custom-provider guidance after permission and deferred MCP discovery",
        .permission = "PermissionEngine mode, persistent rules, and session grants are enforced by interactive permission prompts",
        .session = "live SessionRuntime history plus persisted session/log/artifact stores when enabled",
        .drift_status = .intentional,
        .drift = "live terminal approvals, clarification UI, and full interactive tool surface differ from headless entrypoints by design",
    },
    .{
        .entrypoint = .ask,
        .assembly_path = "cli_ask.runPromptInternal -> agent_runtime dependencies",
        .static_context = "builtins/context captures one global/root/ancestor/applicable AGENTS.md snapshot before the prompt, then adds scoped deltas from effective structured tool targets",
        .transient_context = "tool_runtime transient context each model step with captured permission mode, noninteractive output callbacks, and no live user question path",
        .tools = "mode-filtered paired tool advertisement and included custom-provider guidance with permission rules and deferred MCP discovery",
        .permission = "ask, --auto, or --yolo mode; approval-required actions fail with a noninteractive blocker instead of prompting unless yolo bypasses Fx policy",
        .session = "fresh headless SessionRuntime, optional persisted session id, empty prior history, no local approval grants",
        .drift_status = .intentional,
        .drift = "noninteractive permission blockers and absent live clarification UI differ from interactive by design",
    },
    .{
        .entrypoint = .acp,
        .assembly_path = "acp.prompt.handlePrompt -> agent_runtime dependencies",
        .static_context = "builtins/context captures one global/root/ancestor/applicable AGENTS.md snapshot from accepted local resources before each ACP prompt, then adds scoped tool-target deltas",
        .transient_context = "tool_runtime transient context each model step using the prompt-captured permission mode, ACP session state, and noninteractive tool/update callbacks",
        .tools = "mode-filtered paired tool advertisement and included custom-provider guidance with ACP session permission rules, deferred MCP discovery",
        .permission = "ACP session mode ask/auto; approval-required actions map to refusal or policy decisions instead of terminal prompts",
        .session = "active ACP session id, selected model, mode, persisted history on load, and session runtime history",
        .drift_status = .intentional,
        .drift = "ACP JSON-RPC session updates and refusal mapping differ from terminal output by protocol contract",
    },
    .{
        .entrypoint = .subagent,
        .assembly_path = "subagent.agent_adapter.run -> execution.runNormalAgentTurn -> agent_runtime dependencies",
        .static_context = "reuses the launching surface's project-context snapshot bytes and its system and skill prompt sections; child delivery state starts empty so scoped tool-target deltas are re-evaluated for the child",
        .transient_context = "tool_runtime transient context each model step over the child SessionRuntime with noninteractive output callbacks and no live user question path",
        .tools = "identical to the launching surface's own gateway tool advertisement: permission-filtered builtins, deferred MCP discovery tools, and the subagent tool for nested children",
        .permission = "per-child ask/auto/yolo mode (new children default to yolo) resolves live host authority per action for tools, roots, integrations, rules, and grants, revalidating the retained action identity whenever the authority generation advances before the effect",
        .session = "ordinary child session resumed for write from the shared session store for one-off and persistent children, canonical child history restored from and committed back to that session, and per-child model and effort from the stored child configuration",
        .drift_status = .intentional,
        .drift = "separate child session and history, noninteractive child callbacks, approvals projected to the parent and human surfaces, and bounded parent/child delivery instead of transcript merging",
    },
};

pub fn requiredFragments() []const Fragment {
    return required_fragments[0..];
}

pub fn inventory() []const EntrypointInventory {
    return current_inventory[0..];
}

pub fn writeMinimumContractSnapshot(writer: *std.Io.Writer) !void {
    try writer.print("contract: {s}\n", .{contract_name});
    try writer.writeAll("required_fragments:\n");
    for (requiredFragments()) |fragment| {
        try writer.print("- {s}: {s}\n", .{ fragment.label(), fragment.contractText() });
    }
}

pub fn writeEntrypointInventorySnapshot(writer: *std.Io.Writer) !void {
    try writer.print("contract: {s}\n", .{contract_name});
    try writer.writeAll("entrypoints:\n");
    for (inventory()) |item| {
        try writer.print("- entrypoint: {s}\n", .{item.entrypoint.label()});
        try writer.print("  assembly_path: {s}\n", .{item.assembly_path});
        try writer.print("  static_context: {s}\n", .{item.static_context});
        try writer.print("  transient_context: {s}\n", .{item.transient_context});
        try writer.print("  tools: {s}\n", .{item.tools});
        try writer.print("  permission: {s}\n", .{item.permission});
        try writer.print("  session: {s}\n", .{item.session});
        try writer.print("  drift_status: {s}\n", .{item.drift_status.label()});
        try writer.print("  drift: {s}\n", .{item.drift});
    }
}

pub fn writeEntrypointLayoutSnapshot(writer: *std.Io.Writer) !void {
    try writer.print("contract: {s}\n", .{contract_name});
    try writer.writeAll(
        \\model_visible_layout:
        \\- entrypoint: interactive
        \\  static_context_refresh: one applicable snapshot before enqueue; scoped deltas attach before affected tool execution
        \\  stable_prefix_initial_order: system_prompt, effective_custom_tool_guidance, visible_skills, optional_model_prompt_overlay, optional_interruption_or_resume_intent_context, shared_project_context, mcp_server_catalog, optional_prepared_parent_turn_delivery_context
        \\  stable_prefix_later_additions: applicable_project_context_deltas committed mid-turn when a tool batch has applicable targets
        \\  per_step_overlay_order: explicit_skill_chunks, transient_runtime_context
        \\  user_prompt_position: after stable system context and history
        \\  intentional_difference: live terminal approvals and clarification UI
        \\- entrypoint: fx ask
        \\  static_context_refresh: one applicable snapshot before the prompt; scoped deltas attach before affected tool execution
        \\  stable_prefix_initial_order: system_prompt, effective_custom_tool_guidance, visible_skills, optional_model_prompt_overlay, optional_interruption_or_resume_intent_context, shared_project_context, mcp_server_catalog, optional_prepared_parent_turn_delivery_context
        \\  stable_prefix_later_additions: applicable_project_context_deltas committed mid-turn when a tool batch has applicable targets
        \\  per_step_overlay_order: explicit_skill_chunks, transient_runtime_context
        \\  user_prompt_position: after stable system context and empty or saved history
        \\  intentional_difference: approval-required actions become noninteractive blockers
        \\- entrypoint: ACP
        \\  static_context_refresh: one applicable snapshot per ACP prompt including accepted local resource targets; scoped deltas attach before affected tool execution
        \\  stable_prefix_initial_order: system_prompt, effective_custom_tool_guidance, visible_skills, optional_model_prompt_overlay, optional_interruption_or_resume_intent_context, shared_project_context, mcp_server_catalog, optional_prepared_parent_turn_delivery_context
        \\  stable_prefix_later_additions: applicable_project_context_deltas committed mid-turn when a tool batch has applicable targets
        \\  per_step_overlay_order: explicit_skill_chunks, transient_runtime_context
        \\  user_prompt_position: after stable system context and ACP session history
        \\  intentional_difference: ACP protocol maps prompts, refusals, and updates to JSON-RPC session messages
        \\- entrypoint: subagent
        \\  static_context_refresh: the launching surface's snapshot with empty child delivery state; scoped deltas attach before affected tool execution
        \\  stable_prefix_initial_order: system_prompt, effective_custom_tool_guidance, visible_skills, optional_model_prompt_overlay, optional_interruption_or_resume_intent_context, shared_project_context, mcp_server_catalog, optional_prepared_parent_turn_delivery_context
        \\  stable_prefix_later_additions: applicable_project_context_deltas committed mid-turn when a tool batch has applicable targets
        \\  per_step_overlay_order: explicit_skill_chunks, transient_runtime_context
        \\  user_prompt_position: after stable system context and canonical child session history
        \\  intentional_difference: separate child session history, parent-projected approvals, and bounded parent/child delivery
        \\
    );
}

fn snapshotMinimumContract(alloc: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeMinimumContractSnapshot(&out.writer);
    return try alloc.dupe(u8, out.written());
}

fn snapshotEntrypointInventory(alloc: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeEntrypointInventorySnapshot(&out.writer);
    return try alloc.dupe(u8, out.written());
}

fn snapshotEntrypointLayout(alloc: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeEntrypointLayoutSnapshot(&out.writer);
    return try alloc.dupe(u8, out.written());
}

test "context limits preserve the established provider policy" {
    try std.testing.expectEqual(@as(usize, 32), Limits.scoped_rules);
    try std.testing.expectEqual(@as(i128, 50 * std.time.ns_per_ms), Limits.git_read_budget_ns);
    try std.testing.expectEqual(@as(usize, 4096), Limits.git_metadata_file_bytes);
    try std.testing.expectEqual(@as(usize, 16 * 1024), Limits.git_config_file_bytes);
    try std.testing.expectEqual(@as(u64, 16 * 1024), Limits.git_index_file_bytes);
    try std.testing.expectEqual(@as(u32, 32), Limits.git_index_entries);
}

test "image attachments project to borrowed file context targets" {
    const images = [_]types.ImageAttachment{
        .{ .id = 1, .path = @constCast("/workspace/a.png"), .media_type = @constCast("image/png") },
        .{ .id = 2, .path = @constCast("/workspace/b.jpg"), .media_type = @constCast("image/jpeg") },
    };
    const targets = try applicableTargetsForImages(std.testing.allocator, &images);
    defer std.testing.allocator.free(targets);

    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqual(TargetKind.file, targets[0].kind);
    try std.testing.expectEqualStrings(images[0].path, targets[0].path);
    try std.testing.expect(targets[0].path.ptr == images[0].path.ptr);
    try std.testing.expectEqual(TargetKind.file, targets[1].kind);
    try std.testing.expectEqualStrings(images[1].path, targets[1].path);
    try std.testing.expectEqual(
        @as(usize, 0),
        (try applicableTargetsForImages(std.testing.allocator, &.{})).len,
    );
}

test "minimum shared model context contract snapshot" {
    const snapshot = try snapshotMinimumContract(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expectEqualStrings(
        \\contract: fx.shared_model_context.v1
        \\required_fragments:
        \\- workspace_identity: workspace root and current directory
        \\- repo_identity: git branch, worktree state, and sanitized GitHub origin when known
        \\- scoped_instructions: bounded global, workspace, and nested scoped rules plus the bounded visible skill catalog
        \\- available_tools: gateway-advertised tool schemas after permission, deferred MCP discovery, and entrypoint filtering
        \\- permission_mode: captured ask, auto, or yolo baseline for the active turn without rule or grant contents
        \\- environment_metadata: OS, shell, date, home directory, and live/non-live background runtime hints
        \\- session_metadata: model, step budget, max tool-result bytes, conversation history, grants, loaded skills, and persisted session id when present
        \\
    ,
        snapshot,
    );
}

test "entrypoint context inventory snapshot documents current deltas" {
    const snapshot = try snapshotEntrypointInventory(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expectEqualStrings(
        \\contract: fx.shared_model_context.v1
        \\entrypoints:
        \\- entrypoint: interactive
        \\  assembly_path: main.App.enqueuePrompt -> app_agent_runtime.processQueuedPrompt -> agent_runtime dependencies
        \\  static_context: builtins/context captures one global/root/ancestor/applicable AGENTS.md snapshot before enqueue, then adds scoped deltas from effective structured tool targets
        \\  transient_context: tool_runtime transient context each model step: env_context, captured permission mode, background runtime, non-live background history
        \\  tools: App.snapshotGatewayToolProjection pairs full tool advertisement with included custom-provider guidance after permission and deferred MCP discovery
        \\  permission: PermissionEngine mode, persistent rules, and session grants are enforced by interactive permission prompts
        \\  session: live SessionRuntime history plus persisted session/log/artifact stores when enabled
        \\  drift_status: intentional
        \\  drift: live terminal approvals, clarification UI, and full interactive tool surface differ from headless entrypoints by design
        \\- entrypoint: fx ask
        \\  assembly_path: cli_ask.runPromptInternal -> agent_runtime dependencies
        \\  static_context: builtins/context captures one global/root/ancestor/applicable AGENTS.md snapshot before the prompt, then adds scoped deltas from effective structured tool targets
        \\  transient_context: tool_runtime transient context each model step with captured permission mode, noninteractive output callbacks, and no live user question path
        \\  tools: mode-filtered paired tool advertisement and included custom-provider guidance with permission rules and deferred MCP discovery
        \\  permission: ask, --auto, or --yolo mode; approval-required actions fail with a noninteractive blocker instead of prompting unless yolo bypasses Fx policy
        \\  session: fresh headless SessionRuntime, optional persisted session id, empty prior history, no local approval grants
        \\  drift_status: intentional
        \\  drift: noninteractive permission blockers and absent live clarification UI differ from interactive by design
        \\- entrypoint: ACP
        \\  assembly_path: acp.prompt.handlePrompt -> agent_runtime dependencies
        \\  static_context: builtins/context captures one global/root/ancestor/applicable AGENTS.md snapshot from accepted local resources before each ACP prompt, then adds scoped tool-target deltas
        \\  transient_context: tool_runtime transient context each model step using the prompt-captured permission mode, ACP session state, and noninteractive tool/update callbacks
        \\  tools: mode-filtered paired tool advertisement and included custom-provider guidance with ACP session permission rules, deferred MCP discovery
        \\  permission: ACP session mode ask/auto; approval-required actions map to refusal or policy decisions instead of terminal prompts
        \\  session: active ACP session id, selected model, mode, persisted history on load, and session runtime history
        \\  drift_status: intentional
        \\  drift: ACP JSON-RPC session updates and refusal mapping differ from terminal output by protocol contract
        \\- entrypoint: subagent
        \\  assembly_path: subagent.agent_adapter.run -> execution.runNormalAgentTurn -> agent_runtime dependencies
        \\  static_context: reuses the launching surface's project-context snapshot bytes and its system and skill prompt sections; child delivery state starts empty so scoped tool-target deltas are re-evaluated for the child
        \\  transient_context: tool_runtime transient context each model step over the child SessionRuntime with noninteractive output callbacks and no live user question path
        \\  tools: identical to the launching surface's own gateway tool advertisement: permission-filtered builtins, deferred MCP discovery tools, and the subagent tool for nested children
        \\  permission: per-child ask/auto/yolo mode (new children default to yolo) resolves live host authority per action for tools, roots, integrations, rules, and grants, revalidating the retained action identity whenever the authority generation advances before the effect
        \\  session: ordinary child session resumed for write from the shared session store for one-off and persistent children, canonical child history restored from and committed back to that session, and per-child model and effort from the stored child configuration
        \\  drift_status: intentional
        \\  drift: separate child session and history, noninteractive child callbacks, approvals projected to the parent and human surfaces, and bounded parent/child delivery instead of transcript merging
        \\
    ,
        snapshot,
    );
}

test "entrypoint model-visible layout snapshot covers major entrypoints" {
    const snapshot = try snapshotEntrypointLayout(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expectEqualStrings(
        \\contract: fx.shared_model_context.v1
        \\model_visible_layout:
        \\- entrypoint: interactive
        \\  static_context_refresh: one applicable snapshot before enqueue; scoped deltas attach before affected tool execution
        \\  stable_prefix_initial_order: system_prompt, effective_custom_tool_guidance, visible_skills, optional_model_prompt_overlay, optional_interruption_or_resume_intent_context, shared_project_context, mcp_server_catalog, optional_prepared_parent_turn_delivery_context
        \\  stable_prefix_later_additions: applicable_project_context_deltas committed mid-turn when a tool batch has applicable targets
        \\  per_step_overlay_order: explicit_skill_chunks, transient_runtime_context
        \\  user_prompt_position: after stable system context and history
        \\  intentional_difference: live terminal approvals and clarification UI
        \\- entrypoint: fx ask
        \\  static_context_refresh: one applicable snapshot before the prompt; scoped deltas attach before affected tool execution
        \\  stable_prefix_initial_order: system_prompt, effective_custom_tool_guidance, visible_skills, optional_model_prompt_overlay, optional_interruption_or_resume_intent_context, shared_project_context, mcp_server_catalog, optional_prepared_parent_turn_delivery_context
        \\  stable_prefix_later_additions: applicable_project_context_deltas committed mid-turn when a tool batch has applicable targets
        \\  per_step_overlay_order: explicit_skill_chunks, transient_runtime_context
        \\  user_prompt_position: after stable system context and empty or saved history
        \\  intentional_difference: approval-required actions become noninteractive blockers
        \\- entrypoint: ACP
        \\  static_context_refresh: one applicable snapshot per ACP prompt including accepted local resource targets; scoped deltas attach before affected tool execution
        \\  stable_prefix_initial_order: system_prompt, effective_custom_tool_guidance, visible_skills, optional_model_prompt_overlay, optional_interruption_or_resume_intent_context, shared_project_context, mcp_server_catalog, optional_prepared_parent_turn_delivery_context
        \\  stable_prefix_later_additions: applicable_project_context_deltas committed mid-turn when a tool batch has applicable targets
        \\  per_step_overlay_order: explicit_skill_chunks, transient_runtime_context
        \\  user_prompt_position: after stable system context and ACP session history
        \\  intentional_difference: ACP protocol maps prompts, refusals, and updates to JSON-RPC session messages
        \\- entrypoint: subagent
        \\  static_context_refresh: the launching surface's snapshot with empty child delivery state; scoped deltas attach before affected tool execution
        \\  stable_prefix_initial_order: system_prompt, effective_custom_tool_guidance, visible_skills, optional_model_prompt_overlay, optional_interruption_or_resume_intent_context, shared_project_context, mcp_server_catalog, optional_prepared_parent_turn_delivery_context
        \\  stable_prefix_later_additions: applicable_project_context_deltas committed mid-turn when a tool batch has applicable targets
        \\  per_step_overlay_order: explicit_skill_chunks, transient_runtime_context
        \\  user_prompt_position: after stable system context and canonical child session history
        \\  intentional_difference: separate child session history, parent-projected approvals, and bounded parent/child delivery
        \\
    ,
        snapshot,
    );
}

test "context registry routes the default provider" {
    const Fixture = struct {
        fn gather(alloc: Allocator, input: InitialContextInput) ProviderError!ProviderContext {
            return .{ .content = try std.fmt.allocPrint(alloc, "project:{s}", .{input.workspace_root}) };
        }

        fn appendStatic(input: StaticContextInput, alloc: Allocator, messages: *std.ArrayList(types.ChatMessage)) ProviderError!void {
            try messages.append(alloc, .{ .role = .system, .content = input.project_context });
        }

        fn appendTransient(input: TransientContextInput, alloc: Allocator, messages: *std.ArrayList(types.ChatMessage)) ProviderError!void {
            const content = try std.fmt.allocPrint(alloc, "runtime:{s}", .{input.workspace_root});
            try messages.append(alloc, .{ .role = .system, .content = content });
        }
    };

    const provider = Provider{
        .id = "test.default_context",
        .gather_project_context_fn = Fixture.gather,
        .select_applicable_project_context_fn = selectNoApplicableProjectContext,
        .append_static_fn = Fixture.appendStatic,
        .append_transient_fn = Fixture.appendTransient,
    };
    const registry = Registry{ .default_provider = provider };
    const alloc = std.testing.allocator;
    var snapshot = try registry.gatherDefaultSnapshot(alloc, .{ .workspace_root = "/workspace" });
    defer snapshot.deinit(alloc);
    const contribution = snapshot.contribution orelse return error.TestExpectedEqual;

    var background: background_runtime.BackgroundRuntime = .{};
    defer background.deinit(alloc);
    var session: session_runtime.SessionRuntime = .{ .max_history_turns = 4 };
    defer session.deinit(alloc);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    defer messages.deinit(arena);

    try registry.appendDefaultStatic(.{ .project_context = snapshot.modelVisibleBytes() }, arena, &messages);
    try registry.appendDefaultTransient(.{
        .workspace_root = "/workspace",
        .interactive = true,
        .permission_mode = .ask,
        .tracker = &tracker,
        .background = &background,
        .session = &session,
    }, arena, &messages);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("test.default_context", contribution.provider_id);
    try std.testing.expectEqualStrings("project:/workspace", messages.items[0].content.?);
    try std.testing.expectEqualStrings("runtime:/workspace", messages.items[1].content.?);
}

test "gathered context snapshot duplicates provenance and content ownership" {
    const Fixture = struct {
        fn gather(alloc: Allocator, _: InitialContextInput) ProviderError!ProviderContext {
            var context: ProviderContext = .{};
            errdefer context.deinit(alloc);
            context.content = try alloc.dupe(u8, "queued context");
            context.delivered_sources = try dupeOwnedStrings(alloc, &.{"/workspace/AGENTS.md"});
            context.evaluated_endpoints = try dupeOwnedStrings(alloc, &.{"/workspace/src"});
            return context;
        }

        fn appendStatic(_: StaticContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) ProviderError!void {}

        fn appendTransient(_: TransientContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) ProviderError!void {}
    };

    const registry = Registry{ .default_provider = .{
        .id = "test.queue_context",
        .gather_project_context_fn = Fixture.gather,
        .select_applicable_project_context_fn = selectNoApplicableProjectContext,
        .append_static_fn = Fixture.appendStatic,
        .append_transient_fn = Fixture.appendTransient,
    } };
    const alloc = std.testing.allocator;
    var live = try registry.gatherDefaultSnapshot(alloc, .{ .workspace_root = "/workspace" });
    var queued = try live.dupe(alloc);
    defer queued.deinit(alloc);
    live.deinit(alloc);

    const contribution = queued.contribution orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("test.queue_context", contribution.provider_id);
    try std.testing.expectEqualStrings("queued context", contribution.content);
    try std.testing.expectEqualStrings("queued context", queued.modelVisibleBytes());
    try std.testing.expectEqualStrings("/workspace/AGENTS.md", queued.delivered_sources[0]);
    try std.testing.expectEqualStrings("/workspace/src", queued.evaluated_endpoints[0]);
}

test "delivery state copies snapshot seeds and atomically takes selection identities" {
    const alloc = std.testing.allocator;
    var snapshot: GatheredContextSnapshot = .{
        .delivered_sources = try dupeOwnedStrings(alloc, &.{"/workspace/AGENTS.md"}),
        .evaluated_endpoints = try dupeOwnedStrings(alloc, &.{"/workspace/src"}),
    };
    var state = try DeliveryState.initFromSnapshot(alloc, snapshot);
    defer state.deinit(alloc);
    snapshot.deinit(alloc);

    try std.testing.expectEqualStrings("/workspace/AGENTS.md", state.delivered_sources.items[0]);
    try std.testing.expectEqualStrings("/workspace/src", state.evaluated_endpoints.items[0]);

    var selected: ProviderContext = .{
        .content = try alloc.dupe(u8, "later context"),
        .delivered_sources = try dupeOwnedStrings(alloc, &.{"/workspace/src/AGENTS.md"}),
        .evaluated_endpoints = try dupeOwnedStrings(alloc, &.{"/workspace/src/nested"}),
    };
    defer selected.deinit(alloc);
    try state.commit(alloc, &selected);

    try std.testing.expectEqual(@as(usize, 0), selected.delivered_sources.len);
    try std.testing.expectEqual(@as(usize, 0), selected.evaluated_endpoints.len);
    try std.testing.expectEqual(@as(usize, 2), state.delivered_sources.items.len);
    try std.testing.expectEqual(@as(usize, 2), state.evaluated_endpoints.items.len);
    try std.testing.expectEqualStrings("/workspace/src/AGENTS.md", state.delivered_sources.items[1]);
    try std.testing.expectEqualStrings("/workspace/src/nested", state.evaluated_endpoints.items[1]);
}

test "delivery state commit leaves selection identities owned on reserve failure" {
    const alloc = std.testing.allocator;
    var selected: ProviderContext = .{
        .delivered_sources = try dupeOwnedStrings(alloc, &.{"/workspace/src/AGENTS.md"}),
        .evaluated_endpoints = try dupeOwnedStrings(alloc, &.{"/workspace/src/nested"}),
    };
    defer selected.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 1 });
    var state: DeliveryState = .{};
    defer state.deinit(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, state.commit(failing.allocator(), &selected));

    try std.testing.expectEqual(@as(usize, 0), state.delivered_sources.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.evaluated_endpoints.items.len);
    try std.testing.expectEqual(@as(usize, 1), selected.delivered_sources.len);
    try std.testing.expectEqual(@as(usize, 1), selected.evaluated_endpoints.len);
}

test "gathered context snapshot cleans partial allocation failures" {
    const Fixture = struct {
        fn gather(alloc: Allocator, _: InitialContextInput) ProviderError!ProviderContext {
            var context: ProviderContext = .{};
            errdefer context.deinit(alloc);
            context.content = try alloc.dupe(u8, "project context");
            context.delivered_sources = try dupeOwnedStrings(alloc, &.{"/workspace/AGENTS.md"});
            context.evaluated_endpoints = try dupeOwnedStrings(alloc, &.{"/workspace/src"});
            return context;
        }

        fn appendStatic(_: StaticContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) ProviderError!void {}

        fn appendTransient(_: TransientContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) ProviderError!void {}
    };

    const registry = Registry{ .default_provider = .{
        .id = "test.failure_context",
        .gather_project_context_fn = Fixture.gather,
        .select_applicable_project_context_fn = selectNoApplicableProjectContext,
        .append_static_fn = Fixture.appendStatic,
        .append_transient_fn = Fixture.appendTransient,
    } };
    const backing = std.testing.allocator;

    var gather_probe = std.testing.FailingAllocator.init(backing, .{});
    var gathered = try registry.gatherDefaultSnapshot(gather_probe.allocator(), .{ .workspace_root = "/workspace" });
    gathered.deinit(gather_probe.allocator());
    try std.testing.expectEqual(gather_probe.allocated_bytes, gather_probe.freed_bytes);

    for (0..gather_probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (registry.gatherDefaultSnapshot(failing.allocator(), .{ .workspace_root = "/workspace" })) |snapshot| {
            var owned = snapshot;
            owned.deinit(failing.allocator());
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }

    var live = try registry.gatherDefaultSnapshot(backing, .{ .workspace_root = "/workspace" });
    defer live.deinit(backing);
    var dupe_probe = std.testing.FailingAllocator.init(backing, .{});
    var duplicated = try live.dupe(dupe_probe.allocator());
    duplicated.deinit(dupe_probe.allocator());
    try std.testing.expectEqual(dupe_probe.allocated_bytes, dupe_probe.freed_bytes);

    for (0..dupe_probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (live.dupe(failing.allocator())) |snapshot| {
            var owned = snapshot;
            owned.deinit(failing.allocator());
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

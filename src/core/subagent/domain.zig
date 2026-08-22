const std = @import("std");
const mcp_access = @import("../mcp/access_policy.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_layout = @import("../session/session_layout.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");

const Allocator = std.mem.Allocator;

pub const max_name_bytes: usize = 128;
pub const max_model_bytes: usize = 256;
pub const max_prompt_bytes: usize = 64 * 1024;
pub const max_message_bytes: usize = 64 * 1024;
pub const max_root_user_evidence_bytes: usize = 8 * 1024;
pub const max_cancellation_reason_bytes: usize = 512;
pub const max_operation_id_bytes: usize = 128;
pub const max_admission_items: usize = 256;
pub const max_admission_item_bytes: usize = 4096;
pub const max_milestones: usize = 32;
pub const max_stop_conditions: usize = 8;
pub const default_page_limit: usize = 50;
pub const max_page_limit: usize = 100;
pub const max_inspect_wait_ms: u64 = 60_000;

pub const Mode = enum {
    one_off,
    persistent,
};

pub const State = enum {
    idle,
    queued,
    running,
    awaiting_approval,
    interrupted,
    completed,
    failed,
    cancelled,
    archived,
};

pub const TerminalEvents = struct {
    completed: bool = true,
    failed: bool = true,
    cancelled: bool = true,
};

pub const StopCondition = enum {
    terminal,
    duration_elapsed,
};

pub const NotificationPolicyInput = struct {
    terminal: TerminalEvents = .{},
    milestones: []const []const u8 = &.{},
    report_interval_ms: ?u64 = null,
    report_duration_ms: ?u64 = null,
    stop_conditions: []const StopCondition = &.{.terminal},
};

pub const NotificationPolicy = struct {
    terminal: TerminalEvents = .{},
    milestones: [][]u8,
    report_interval_ms: ?u64 = null,
    report_duration_ms: ?u64 = null,
    stop_conditions: []StopCondition,

    pub fn deinit(self: *NotificationPolicy, alloc: Allocator) void {
        for (self.milestones) |name| alloc.free(name);
        alloc.free(self.milestones);
        alloc.free(self.stop_conditions);
        self.* = undefined;
    }

    /// Returns an owned copy; caller frees it with `deinit`.
    pub fn clone(self: NotificationPolicy, alloc: Allocator) !NotificationPolicy {
        const milestones = try cloneStrings(alloc, self.milestones);
        errdefer freeStrings(alloc, milestones);
        return .{
            .terminal = self.terminal,
            .milestones = milestones,
            .report_interval_ms = self.report_interval_ms,
            .report_duration_ms = self.report_duration_ms,
            .stop_conditions = try alloc.dupe(StopCondition, self.stop_conditions),
        };
    }
};

pub const Configuration = struct {
    name: []u8,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
    permission_mode: types.PermissionMode = .yolo,
    notifications: NotificationPolicy,

    pub fn deinit(self: *Configuration, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.model) |model| alloc.free(model);
        self.notifications.deinit(alloc);
        self.* = undefined;
    }

    /// Returns an owned copy; caller frees it with `deinit`.
    pub fn clone(self: Configuration, alloc: Allocator) !Configuration {
        const name = try alloc.dupe(u8, self.name);
        errdefer alloc.free(name);
        const model = if (self.model) |value| try alloc.dupe(u8, value) else null;
        errdefer if (model) |value| alloc.free(value);
        return .{
            .name = name,
            .model = model,
            .effort = self.effort,
            .permission_mode = self.permission_mode,
            .notifications = try self.notifications.clone(alloc),
        };
    }
};

pub const InspectSection = enum {
    status,
    messages,
    tool_activity,
    events,
    configuration,
    relationship,
};

pub const InspectWaitUntil = enum {
    settled,
};

pub const InspectWaitInput = struct {
    until: ?InspectWaitUntil = null,
    after_generation: ?u64 = null,
    timeout_ms: ?u64 = null,
};

pub const InspectWait = struct {
    until: InspectWaitUntil,
    after_generation: ?u64,
    timeout_ms: u64,
};

pub const RelationshipAction = enum {
    attach,
    detach,
    reparent,
};

pub const LifecycleAction = enum {
    cancel,
    @"resume",
    close,
    reopen,
};

pub const CreateInput = struct {
    name: ?[]const u8 = null,
    mode: ?Mode = null,
    prompt: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    permission_mode: ?types.PermissionMode = null,
    notifications: ?NotificationPolicyInput = null,
};

pub const InspectInput = struct {
    id: ?[]const u8 = null,
    sections: []const InspectSection = &.{},
    cursor: ?[]const u8 = null,
    limit: ?usize = null,
    wait: ?InspectWaitInput = null,
};

pub const MessageSendInput = struct {
    id: []const u8,
    content: []const u8,
};

pub const MessageMilestoneInput = struct {
    name: []const u8,
};

pub const MessageInput = struct {
    send: ?MessageSendInput = null,
    milestone: ?MessageMilestoneInput = null,
};

pub const RelationshipInput = struct {
    action: RelationshipAction,
    id: []const u8,
    parent_id: ?[]const u8 = null,
};

pub const ConfigureInput = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    permission_mode: ?types.PermissionMode = null,
    notifications: ?NotificationPolicyInput = null,
};

pub const LifecycleInput = struct {
    id: []const u8,
    action: LifecycleAction,
};

pub const CommandInput = struct {
    create: ?CreateInput = null,
    inspect: ?InspectInput = null,
    message: ?MessageInput = null,
    relationship: ?RelationshipInput = null,
    configure: ?ConfigureInput = null,
    lifecycle: ?LifecycleInput = null,
};

pub const CreateCommand = struct {
    configuration: Configuration,
    mode: Mode,
    prompt: ?[]u8,
    permission_mode_explicit: bool,

    fn deinit(self: *CreateCommand, alloc: Allocator) void {
        self.configuration.deinit(alloc);
        if (self.prompt) |prompt| alloc.free(prompt);
        self.* = undefined;
    }
};

pub const InspectCommand = struct {
    id: []u8,
    sections: []InspectSection,
    cursor: ?[]u8,
    limit: usize,
    wait: ?InspectWait,

    fn deinit(self: *InspectCommand, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.sections);
        if (self.cursor) |cursor| alloc.free(cursor);
        self.* = undefined;
    }
};

pub const MessageCommand = union(enum) {
    send: struct {
        id: []u8,
        content: []u8,
    },
    milestone: struct {
        name: []u8,
    },

    fn deinit(self: *MessageCommand, alloc: Allocator) void {
        switch (self.*) {
            .send => |value| {
                alloc.free(value.id);
                alloc.free(value.content);
            },
            .milestone => |value| alloc.free(value.name),
        }
        self.* = undefined;
    }
};

pub const RelationshipCommand = struct {
    action: RelationshipAction,
    id: []u8,
    parent_id: ?[]u8,

    fn deinit(self: *RelationshipCommand, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.parent_id) |id| alloc.free(id);
        self.* = undefined;
    }
};

pub const ConfigureCommand = struct {
    id: []u8,
    name: ?[]u8,
    model: ?[]u8,
    effort: ?types.ReasoningEffort,
    permission_mode: ?types.PermissionMode,
    notifications: ?NotificationPolicy,

    fn deinit(self: *ConfigureCommand, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.name) |name| alloc.free(name);
        if (self.model) |model| alloc.free(model);
        if (self.notifications) |*notifications| notifications.deinit(alloc);
        self.* = undefined;
    }
};

pub const LifecycleCommand = struct {
    id: []u8,
    action: LifecycleAction,

    fn deinit(self: *LifecycleCommand, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }
};

pub const Command = union(enum) {
    create: CreateCommand,
    inspect: InspectCommand,
    message: MessageCommand,
    relationship: RelationshipCommand,
    configure: ConfigureCommand,
    lifecycle: LifecycleCommand,

    pub fn deinit(self: *Command, alloc: Allocator) void {
        switch (self.*) {
            .create => |*value| value.deinit(alloc),
            .inspect => |*value| value.deinit(alloc),
            .message => |*value| value.deinit(alloc),
            .relationship => |*value| value.deinit(alloc),
            .configure => |*value| value.deinit(alloc),
            .lifecycle => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const QueueStatus = enum {
    pending,
    running,
    awaiting_approval,
    completed,
    failed,
    cancelled,
    interrupted,
};

/// Immutable authority and routing values captured for one admitted child turn.
/// All slices are allocator-owned and must be released with `deinit`.
pub const AdmissionSnapshot = struct {
    parent_id: []u8,
    source_id: []u8,
    model: []u8,
    provider: model_provider.ProviderId = .gateway,
    effort: types.ReasoningEffort,
    permission_mode: types.PermissionMode = .yolo,
    tool_names: [][]u8,
    rules: types.PermissionRuleSet,
    grants: []types.PermissionGrant,
    permission_state: session_permission_state.State = .{},
    integration_names: [][]u8,
    authority_generation: u64 = 0,
    mcp_view: ?mcp_access.View = null,

    pub fn deinit(self: *AdmissionSnapshot, alloc: Allocator) void {
        alloc.free(self.parent_id);
        alloc.free(self.source_id);
        alloc.free(self.model);
        freeStrings(alloc, self.tool_names);
        self.rules.deinit(alloc);
        types.freePermissionGrantSlice(alloc, self.grants);
        self.permission_state.deinit(alloc);
        freeStrings(alloc, self.integration_names);
        if (self.mcp_view) |*view| view.deinit(alloc);
        self.* = undefined;
    }

    /// Returns an owned copy; caller frees it with `deinit`.
    pub fn clone(self: AdmissionSnapshot, alloc: Allocator) !AdmissionSnapshot {
        const parent_id = try alloc.dupe(u8, self.parent_id);
        errdefer alloc.free(parent_id);
        const source_id = try alloc.dupe(u8, self.source_id);
        errdefer alloc.free(source_id);
        const model = try alloc.dupe(u8, self.model);
        errdefer alloc.free(model);
        const tool_names = try cloneStrings(alloc, self.tool_names);
        errdefer freeStrings(alloc, tool_names);
        var rules = try types.dupePermissionRuleSet(alloc, self.rules);
        errdefer rules.deinit(alloc);
        const grants = try types.dupePermissionGrantSlice(alloc, self.grants);
        errdefer types.freePermissionGrantSlice(alloc, grants);
        const permission_state = try session_permission_state.dupe(
            alloc,
            self.permission_state,
        );
        errdefer {
            var value = permission_state;
            value.deinit(alloc);
        }
        var mcp_view = if (self.mcp_view) |view| try view.clone(alloc) else null;
        errdefer if (mcp_view) |*view| view.deinit(alloc);
        const integration_names = try cloneStrings(alloc, self.integration_names);
        return .{
            .parent_id = parent_id,
            .source_id = source_id,
            .model = model,
            .provider = self.provider,
            .effort = self.effort,
            .permission_mode = self.permission_mode,
            .tool_names = tool_names,
            .rules = rules,
            .grants = grants,
            .permission_state = permission_state,
            .integration_names = integration_names,
            .authority_generation = self.authority_generation,
            .mcp_view = mcp_view,
        };
    }
};

pub const AdmissionInput = struct {
    parent_id: []const u8,
    source_id: []const u8,
    model: []const u8,
    provider: model_provider.ProviderId = .gateway,
    effort: types.ReasoningEffort,
    permission_mode: types.PermissionMode = .yolo,
    tool_names: []const []const u8 = &.{},
    rules: types.PermissionRuleSet = .{},
    grants: []const types.PermissionGrant = &.{},
    permission_state: session_permission_state.State = .{},
    integration_names: []const []const u8 = &.{},
    authority_generation: u64 = 0,
    mcp_view: ?mcp_access.View = null,
};

pub const AdmissionError = error{
    OutOfMemory,
    InvalidModel,
    TooManyAdmissionItems,
    InvalidAdmissionItem,
};

/// Validates and owns an immutable child-turn admission snapshot.
pub fn captureAdmission(
    alloc: Allocator,
    input: AdmissionInput,
) AdmissionError!AdmissionSnapshot {
    validateId(input.parent_id) catch return error.InvalidAdmissionItem;
    validateId(input.source_id) catch return error.InvalidAdmissionItem;
    validateBoundedText(input.model, max_model_bytes, error.InvalidModel) catch
        return error.InvalidModel;
    if (input.tool_names.len > max_admission_items or
        input.rules.rules.len > max_admission_items or
        input.grants.len > max_admission_items or
        input.integration_names.len > max_admission_items)
    {
        return error.TooManyAdmissionItems;
    }
    try validateAdmissionStrings(input.tool_names);
    try validateAdmissionStrings(input.integration_names);
    for (input.rules.rules) |rule| {
        try validateAdmissionText(rule.permission);
        try validateAdmissionText(rule.pattern);
    }
    for (input.grants) |grant| {
        try validateAdmissionText(grant.tool_name);
        try validateAdmissionText(grant.target_path);
    }
    session_permission_state.validate(input.permission_state) catch
        return error.InvalidAdmissionItem;

    const parent_id = try alloc.dupe(u8, input.parent_id);
    errdefer alloc.free(parent_id);
    const source_id = try alloc.dupe(u8, input.source_id);
    errdefer alloc.free(source_id);
    const model = try alloc.dupe(u8, input.model);
    errdefer alloc.free(model);
    const tool_names = try cloneStrings(alloc, input.tool_names);
    errdefer freeStrings(alloc, tool_names);
    var rules = try types.dupePermissionRuleSet(alloc, input.rules);
    errdefer rules.deinit(alloc);
    const grants = try types.dupePermissionGrantSlice(alloc, input.grants);
    errdefer types.freePermissionGrantSlice(alloc, grants);
    const permission_state = session_permission_state.dupe(
        alloc,
        input.permission_state,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAdmissionItem,
    };
    errdefer {
        var value = permission_state;
        value.deinit(alloc);
    }
    var mcp_view = if (input.mcp_view) |view| try view.clone(alloc) else null;
    errdefer if (mcp_view) |*view| view.deinit(alloc);
    const integration_names = try cloneStrings(alloc, input.integration_names);
    return .{
        .parent_id = parent_id,
        .source_id = source_id,
        .model = model,
        .provider = input.provider,
        .effort = input.effort,
        .permission_mode = input.permission_mode,
        .tool_names = tool_names,
        .rules = rules,
        .grants = grants,
        .permission_state = permission_state,
        .integration_names = integration_names,
        .authority_generation = input.authority_generation,
        .mcp_view = mcp_view,
    };
}

fn validateAdmissionStrings(values: []const []const u8) AdmissionError!void {
    for (values) |value| try validateAdmissionText(value);
}

fn validateAdmissionText(value: []const u8) AdmissionError!void {
    validateBoundedText(value, max_admission_item_bytes, error.InvalidMessage) catch
        return error.InvalidAdmissionItem;
}

pub const QueuedMessage = struct {
    id: []u8,
    source_id: []u8,
    content: []u8,
    root_user_intent_context: []u8 = &.{},
    root_user_messages: [][]u8 = &.{},
    root_user_evidence_complete: bool = false,
    status: QueueStatus = .pending,
    cancellation_reason: ?[]u8 = null,
    created_at_ms: i64,

    pub fn deinit(self: *QueuedMessage, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.source_id);
        alloc.free(self.content);
        if (self.root_user_intent_context.len > 0) {
            alloc.free(self.root_user_intent_context);
        }
        freeStrings(alloc, self.root_user_messages);
        if (self.cancellation_reason) |reason| alloc.free(reason);
        self.* = undefined;
    }

    /// Returns an owned copy; caller frees it with `deinit`.
    pub fn clone(self: QueuedMessage, alloc: Allocator) !QueuedMessage {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const source_id = try alloc.dupe(u8, self.source_id);
        errdefer alloc.free(source_id);
        const content = try alloc.dupe(u8, self.content);
        errdefer alloc.free(content);
        const root_user_intent_context = try alloc.dupe(
            u8,
            self.root_user_intent_context,
        );
        errdefer alloc.free(root_user_intent_context);
        const root_user_messages = try cloneStrings(alloc, self.root_user_messages);
        errdefer freeStrings(alloc, root_user_messages);
        const reason = if (self.cancellation_reason) |value|
            try alloc.dupe(u8, value)
        else
            null;
        return .{
            .id = id,
            .source_id = source_id,
            .content = content,
            .root_user_intent_context = root_user_intent_context,
            .root_user_messages = root_user_messages,
            .root_user_evidence_complete = self.root_user_evidence_complete,
            .status = self.status,
            .cancellation_reason = reason,
            .created_at_ms = self.created_at_ms,
        };
    }
};

pub const EventKind = union(enum) {
    created,
    message_queued: struct { message_id: []u8 },
    relationship_changed: struct {
        previous_parent_id: ?[]u8,
        parent_id: ?[]u8,
    },
    configured,
    lifecycle_changed: struct {
        previous: State,
        current: State,
    },
    work_transition: struct {
        work_item_id: []u8,
        previous: ?QueueStatus,
        current: QueueStatus,
        reason: ?[]u8,
    },
    milestone_emitted: struct {
        operation_id: []u8,
        source_child_id: []u8,
        target_parent_id: []u8,
        work_item_id: []u8,
        name: []u8,
    },

    pub fn deinit(self: *EventKind, alloc: Allocator) void {
        switch (self.*) {
            .created, .configured, .lifecycle_changed => {},
            .message_queued => |value| alloc.free(value.message_id),
            .relationship_changed => |value| {
                if (value.previous_parent_id) |id| alloc.free(id);
                if (value.parent_id) |id| alloc.free(id);
            },
            .work_transition => |value| {
                alloc.free(value.work_item_id);
                if (value.reason) |reason| alloc.free(reason);
            },
            .milestone_emitted => |value| {
                alloc.free(value.operation_id);
                alloc.free(value.source_child_id);
                alloc.free(value.target_parent_id);
                alloc.free(value.work_item_id);
                alloc.free(value.name);
            },
        }
        self.* = undefined;
    }
};

pub const Event = struct {
    sequence: u64,
    revision: u64,
    id: []u8,
    timestamp_ms: i64,
    kind: EventKind,

    pub fn deinit(self: *Event, alloc: Allocator) void {
        alloc.free(self.id);
        self.kind.deinit(alloc);
        self.* = undefined;
    }

    /// Returns an owned copy; caller frees it with `deinit`.
    pub fn clone(self: Event, alloc: Allocator) !Event {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        return .{
            .sequence = self.sequence,
            .revision = self.revision,
            .id = id,
            .timestamp_ms = self.timestamp_ms,
            .kind = try cloneEventKind(alloc, self.kind),
        };
    }
};

pub const OutcomeCode = enum {
    created,
    message_queued,
    relationship_changed,
    configured,
    lifecycle_changed,
    milestone_emitted,
};

/// Internal issuance domains have independent replay horizons. These values
/// are manager metadata; they are never accepted from model command fields.
pub const OperationIdentitySource = enum {
    model,
    human,
};

pub const OperationIdentityAuthority = enum {
    process_local,
    manager,
};

pub const BoundOperationIdentity = struct {
    source: OperationIdentitySource,
    epoch: u64,
    authority: OperationIdentityAuthority,
};

pub const OperationReceipt = struct {
    id: []u8,
    request_fingerprint: [32]u8,
    fingerprint: [32]u8,
    code: OutcomeCode,
    target_id: []u8,
    generation: u64,
    event_sequence: u64,
    identity_source: ?OperationIdentitySource = null,
    identity_epoch: ?u64 = null,

    pub fn deinit(self: *OperationReceipt, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.target_id);
        self.* = undefined;
    }

    /// Returns an owned copy; caller frees it with `deinit`.
    pub fn clone(self: OperationReceipt, alloc: Allocator) !OperationReceipt {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        return .{
            .id = id,
            .request_fingerprint = self.request_fingerprint,
            .fingerprint = self.fingerprint,
            .code = self.code,
            .target_id = try alloc.dupe(u8, self.target_id),
            .generation = self.generation,
            .event_sequence = self.event_sequence,
            .identity_source = self.identity_source,
            .identity_epoch = self.identity_epoch,
        };
    }
};

pub const ValidationError = error{
    InvalidBranchSelection,
    InvalidNestedBranchSelection,
    MissingName,
    MissingMode,
    MissingOneOffPrompt,
    MissingInspectId,
    InvalidId,
    InvalidName,
    InvalidModel,
    InvalidPrompt,
    InvalidMessage,
    InvalidOperationId,
    InvalidNotificationPolicy,
    DuplicateMilestone,
    DuplicateStopCondition,
    InvalidInspectSections,
    InvalidInspectWait,
    InvalidCursor,
    InvalidPageLimit,
    InvalidRelationship,
    EmptyConfiguration,
    OutOfMemory,
};

/// Validates and owns a command. Caller frees the result with `Command.deinit`.
pub fn validateCommand(
    alloc: Allocator,
    input: CommandInput,
) ValidationError!Command {
    var selected: usize = 0;
    if (input.create != null) selected += 1;
    if (input.inspect != null) selected += 1;
    if (input.message != null) selected += 1;
    if (input.relationship != null) selected += 1;
    if (input.configure != null) selected += 1;
    if (input.lifecycle != null) selected += 1;
    if (selected != 1) return error.InvalidBranchSelection;

    if (input.create) |value| return .{ .create = try validateCreate(alloc, value) };
    if (input.inspect) |value| return .{ .inspect = try validateInspect(alloc, value) };
    if (input.message) |value| return .{ .message = try validateMessage(alloc, value) };
    if (input.relationship) |value| {
        return .{ .relationship = try validateRelationship(alloc, value) };
    }
    if (input.configure) |value| {
        return .{ .configure = try validateConfigure(alloc, value) };
    }
    return .{ .lifecycle = try validateLifecycle(alloc, input.lifecycle.?) };
}

fn validateCreate(alloc: Allocator, input: CreateInput) ValidationError!CreateCommand {
    const name_raw = input.name orelse return error.MissingName;
    const mode = input.mode orelse return error.MissingMode;
    if (mode == .one_off and input.prompt == null) return error.MissingOneOffPrompt;
    try validateName(name_raw);
    if (input.model) |model| try validateModel(model);
    if (input.prompt) |prompt| try validateBoundedText(prompt, max_prompt_bytes, error.InvalidPrompt);

    const name = try alloc.dupe(u8, name_raw);
    errdefer alloc.free(name);
    const model = if (input.model) |value| try alloc.dupe(u8, value) else null;
    errdefer if (model) |value| alloc.free(value);
    var notifications = try validateNotificationPolicy(alloc, input.notifications orelse .{});
    errdefer notifications.deinit(alloc);
    const prompt = if (input.prompt) |value| try alloc.dupe(u8, value) else null;
    return .{
        .configuration = .{
            .name = name,
            .model = model,
            .effort = input.effort,
            .permission_mode = input.permission_mode orelse .yolo,
            .notifications = notifications,
        },
        .mode = mode,
        .prompt = prompt,
        .permission_mode_explicit = input.permission_mode != null,
    };
}

fn validateInspect(alloc: Allocator, input: InspectInput) ValidationError!InspectCommand {
    const id_raw = input.id orelse return error.MissingInspectId;
    try validateId(id_raw);
    if (input.sections.len == 0 or input.sections.len > @typeInfo(InspectSection).@"enum".fields.len) {
        return error.InvalidInspectSections;
    }
    for (input.sections, 0..) |section, index| {
        for (input.sections[0..index]) |prior| {
            if (section == prior) return error.InvalidInspectSections;
        }
    }
    const limit = input.limit orelse default_page_limit;
    if (limit == 0 or limit > max_page_limit) return error.InvalidPageLimit;
    if (input.cursor) |cursor| _ = parseCursor(cursor) catch return error.InvalidCursor;
    const wait = if (input.wait) |requested| blk: {
        if (input.cursor != null or !containsInspectSection(input.sections, .status)) {
            return error.InvalidInspectWait;
        }
        const until = requested.until orelse return error.InvalidInspectWait;
        const timeout_ms = requested.timeout_ms orelse return error.InvalidInspectWait;
        if (timeout_ms == 0 or timeout_ms > max_inspect_wait_ms) {
            return error.InvalidInspectWait;
        }
        break :blk InspectWait{
            .until = until,
            .after_generation = requested.after_generation,
            .timeout_ms = timeout_ms,
        };
    } else null;

    const id = try alloc.dupe(u8, id_raw);
    errdefer alloc.free(id);
    const sections = try alloc.dupe(InspectSection, input.sections);
    errdefer alloc.free(sections);
    return .{
        .id = id,
        .sections = sections,
        .cursor = if (input.cursor) |cursor| try alloc.dupe(u8, cursor) else null,
        .limit = limit,
        .wait = wait,
    };
}

fn containsInspectSection(
    sections: []const InspectSection,
    expected: InspectSection,
) bool {
    for (sections) |section| {
        if (section == expected) return true;
    }
    return false;
}

/// Pure wait predicate over one authoritative inspection snapshot.
pub fn inspectWaitSatisfied(
    wait: InspectWait,
    generation: u64,
    state: State,
) bool {
    if (wait.after_generation) |after| {
        if (generation <= after) return false;
    }
    return switch (wait.until) {
        .settled => switch (state) {
            .idle,
            .interrupted,
            .completed,
            .failed,
            .cancelled,
            .archived,
            => true,
            .queued, .running, .awaiting_approval => false,
        },
    };
}

fn validateMessage(alloc: Allocator, input: MessageInput) ValidationError!MessageCommand {
    const selected = @as(usize, @intFromBool(input.send != null)) +
        @as(usize, @intFromBool(input.milestone != null));
    if (selected != 1) return error.InvalidNestedBranchSelection;
    if (input.send) |value| {
        try validateId(value.id);
        try validateBoundedText(value.content, max_message_bytes, error.InvalidMessage);
        const id = try alloc.dupe(u8, value.id);
        errdefer alloc.free(id);
        return .{ .send = .{
            .id = id,
            .content = try alloc.dupe(u8, value.content),
        } };
    }
    const value = input.milestone.?;
    try validateName(value.name);
    return .{ .milestone = .{ .name = try alloc.dupe(u8, value.name) } };
}

fn validateRelationship(
    alloc: Allocator,
    input: RelationshipInput,
) ValidationError!RelationshipCommand {
    try validateId(input.id);
    if (input.parent_id) |id| try validateId(id);
    switch (input.action) {
        .attach => {},
        .detach => if (input.parent_id != null) return error.InvalidRelationship,
        .reparent => if (input.parent_id == null) return error.InvalidRelationship,
    }
    if (input.parent_id) |parent_id| {
        if (std.mem.eql(u8, input.id, parent_id)) return error.InvalidRelationship;
    }

    const id = try alloc.dupe(u8, input.id);
    errdefer alloc.free(id);
    return .{
        .action = input.action,
        .id = id,
        .parent_id = if (input.parent_id) |parent_id|
            try alloc.dupe(u8, parent_id)
        else
            null,
    };
}

fn validateConfigure(alloc: Allocator, input: ConfigureInput) ValidationError!ConfigureCommand {
    try validateId(input.id);
    if (input.name == null and input.model == null and input.effort == null and
        input.permission_mode == null and input.notifications == null)
    {
        return error.EmptyConfiguration;
    }
    if (input.name) |name| try validateName(name);
    if (input.model) |model| try validateModel(model);

    const id = try alloc.dupe(u8, input.id);
    errdefer alloc.free(id);
    const name = if (input.name) |value| try alloc.dupe(u8, value) else null;
    errdefer if (name) |value| alloc.free(value);
    const model = if (input.model) |value| try alloc.dupe(u8, value) else null;
    errdefer if (model) |value| alloc.free(value);
    return .{
        .id = id,
        .name = name,
        .model = model,
        .effort = input.effort,
        .permission_mode = input.permission_mode,
        .notifications = if (input.notifications) |value|
            try validateNotificationPolicy(alloc, value)
        else
            null,
    };
}

fn validateLifecycle(alloc: Allocator, input: LifecycleInput) ValidationError!LifecycleCommand {
    try validateId(input.id);
    return .{
        .id = try alloc.dupe(u8, input.id),
        .action = input.action,
    };
}

/// Returns an owned notification policy; caller frees it with `deinit`.
pub fn validateNotificationPolicy(
    alloc: Allocator,
    input: NotificationPolicyInput,
) ValidationError!NotificationPolicy {
    if (input.milestones.len > max_milestones or
        input.stop_conditions.len > max_stop_conditions)
    {
        return error.InvalidNotificationPolicy;
    }
    if (input.report_duration_ms != null and input.report_interval_ms == null) {
        return error.InvalidNotificationPolicy;
    }
    if (input.report_interval_ms) |interval| {
        if (interval == 0) return error.InvalidNotificationPolicy;
    }
    if (input.report_duration_ms) |duration| {
        if (duration == 0) return error.InvalidNotificationPolicy;
    }
    for (input.milestones, 0..) |name, index| {
        try validateName(name);
        for (input.milestones[0..index]) |prior| {
            if (std.mem.eql(u8, name, prior)) return error.DuplicateMilestone;
        }
    }
    var has_duration_stop = false;
    for (input.stop_conditions, 0..) |condition, index| {
        for (input.stop_conditions[0..index]) |prior| {
            if (condition == prior) return error.DuplicateStopCondition;
        }
        if (condition == .duration_elapsed and input.report_duration_ms == null) {
            return error.InvalidNotificationPolicy;
        }
        has_duration_stop = has_duration_stop or condition == .duration_elapsed;
    }
    const add_duration_stop =
        input.report_duration_ms != null and !has_duration_stop;
    const stop_count =
        input.stop_conditions.len + @intFromBool(add_duration_stop);
    if (stop_count > max_stop_conditions) {
        return error.InvalidNotificationPolicy;
    }

    const milestones = try cloneStrings(alloc, input.milestones);
    errdefer freeStrings(alloc, milestones);
    const stop_conditions = try alloc.alloc(StopCondition, stop_count);
    errdefer alloc.free(stop_conditions);
    @memcpy(stop_conditions[0..input.stop_conditions.len], input.stop_conditions);
    if (add_duration_stop) {
        stop_conditions[stop_conditions.len - 1] = .duration_elapsed;
    }
    return .{
        .terminal = input.terminal,
        .milestones = milestones,
        .report_interval_ms = input.report_interval_ms,
        .report_duration_ms = input.report_duration_ms,
        .stop_conditions = stop_conditions,
    };
}

pub fn validateId(id: []const u8) ValidationError!void {
    session_layout.validateSessionId(id) catch return error.InvalidId;
}

pub fn validateOperationId(id: []const u8) ValidationError!void {
    if (id.len == 0 or id.len > max_operation_id_bytes) {
        return error.InvalidOperationId;
    }
    for (id) |byte| {
        if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte)) {
            return error.InvalidOperationId;
        }
    }
}

fn validateName(name: []const u8) ValidationError!void {
    try validateBoundedText(name, max_name_bytes, error.InvalidName);
}

fn validateModel(model: []const u8) ValidationError!void {
    try validateBoundedText(model, max_model_bytes, error.InvalidModel);
}

fn validateBoundedText(
    text: []const u8,
    max_bytes: usize,
    invalid: ValidationError,
) ValidationError!void {
    if (text.len == 0 or text.len > max_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return invalid;
    }
    for (text) |byte| {
        if (byte == 0) return invalid;
    }
}

pub const TransitionError = error{
    InvalidLifecycleTransition,
};

pub fn nextLifecycleState(
    mode: Mode,
    current: State,
    action: LifecycleAction,
    has_pending_messages: bool,
    archived_from: ?State,
) TransitionError!State {
    return switch (action) {
        .cancel => switch (current) {
            .queued, .running, .awaiting_approval, .interrupted => if (mode == .persistent)
                .idle
            else
                .cancelled,
            .idle, .completed, .failed, .cancelled, .archived => error.InvalidLifecycleTransition,
        },
        .@"resume" => switch (current) {
            .interrupted => if (has_pending_messages) .queued else .idle,
            .queued => if (has_pending_messages) .queued else error.InvalidLifecycleTransition,
            else => error.InvalidLifecycleTransition,
        },
        .close => if (current == .archived)
            error.InvalidLifecycleTransition
        else
            .archived,
        .reopen => if (current != .archived)
            error.InvalidLifecycleTransition
        else if (has_pending_messages)
            .queued
        else switch (archived_from orelse .idle) {
            .completed, .failed, .cancelled => |terminal| terminal,
            else => .idle,
        },
    };
}

/// Pure restart reconciliation. Live work is never resumed implicitly.
pub fn stateAfterRestart(state: State) State {
    return switch (state) {
        .queued, .running, .awaiting_approval => .interrupted,
        else => state,
    };
}

pub const Cursor = struct {
    generation: u64,
    offset: usize,
};

pub const PageWindow = struct {
    start: usize,
    end: usize,
    has_more: bool,
};

pub const PageDecision = union(enum) {
    page: PageWindow,
    stale_cursor,
};

pub fn decidePage(
    total: usize,
    generation: u64,
    cursor: ?Cursor,
    limit: usize,
) ValidationError!PageDecision {
    if (limit == 0 or limit > max_page_limit) return error.InvalidPageLimit;
    const start = if (cursor) |value| blk: {
        if (value.generation != generation or value.offset > total) {
            return .stale_cursor;
        }
        break :blk value.offset;
    } else 0;
    const end = std.math.add(usize, start, limit) catch total;
    return .{ .page = .{
        .start = start,
        .end = @min(end, total),
        .has_more = end < total,
    } };
}

pub fn parseCursor(text: []const u8) ValidationError!Cursor {
    var parts = std.mem.splitScalar(u8, text, ':');
    const version = parts.next() orelse return error.InvalidCursor;
    const generation_raw = parts.next() orelse return error.InvalidCursor;
    const offset_raw = parts.next() orelse return error.InvalidCursor;
    if (parts.next() != null or !std.mem.eql(u8, version, "v1")) {
        return error.InvalidCursor;
    }
    return .{
        .generation = std.fmt.parseUnsigned(u64, generation_raw, 10) catch
            return error.InvalidCursor,
        .offset = std.fmt.parseUnsigned(usize, offset_raw, 10) catch
            return error.InvalidCursor,
    };
}

/// Returns an owned opaque cursor; caller frees it with `alloc.free`.
pub fn encodeCursor(alloc: Allocator, cursor: Cursor) ![]u8 {
    return std.fmt.allocPrint(alloc, "v1:{d}:{d}", .{
        cursor.generation,
        cursor.offset,
    });
}

pub const OperationFingerprintInput = struct {
    command: Command,
    actor_id: []const u8,
    target_id: []const u8,
    source_id: ?[]const u8 = null,
    effective_parent_id: ?[]const u8 = null,
    bootstrap_configuration: ?Configuration = null,
};

pub const OperationRequestFingerprintInput = struct {
    command: Command,
    actor_id: []const u8,
    target_id: []const u8,
    source_id: ?[]const u8 = null,
    effective_parent_id: ?[]const u8 = null,
};

pub fn operationRequestFingerprint(input: OperationRequestFingerprintInput) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.operation-request.v1\x00");
    hashString(&hash, input.actor_id);
    hashString(&hash, input.target_id);
    hashOptionalString(&hash, input.source_id);
    hashOptionalString(&hash, input.effective_parent_id);
    switch (input.command) {
        .create => |value| {
            hash.update("create\x00");
            hashConfiguration(&hash, value.configuration);
            hashString(&hash, @tagName(value.mode));
            hashOptionalString(&hash, value.prompt);
        },
        .inspect => |value| {
            hash.update("inspect\x00");
            hashString(&hash, value.id);
            hashInteger(&hash, value.sections.len);
            for (value.sections) |section| hashString(&hash, @tagName(section));
            hashOptionalString(&hash, value.cursor);
            hashInteger(&hash, value.limit);
            if (value.wait) |wait| {
                hash.update("1");
                hashString(&hash, @tagName(wait.until));
                hashOptionalInteger(&hash, wait.after_generation);
                hashInteger(&hash, wait.timeout_ms);
            } else hash.update("0");
        },
        .message => |message| switch (message) {
            .send => |value| {
                hash.update("message.send\x00");
                hashString(&hash, value.id);
                hashString(&hash, value.content);
            },
            .milestone => |value| {
                hash.update("message.milestone\x00");
                hashString(&hash, value.name);
            },
        },
        .relationship => |value| {
            hash.update("relationship\x00");
            hashString(&hash, @tagName(value.action));
            hashString(&hash, value.id);
            hashOptionalString(&hash, value.parent_id);
        },
        .configure => |value| {
            hash.update("configure\x00");
            hashString(&hash, value.id);
            hashOptionalString(&hash, value.name);
            hashOptionalString(&hash, value.model);
            hashOptionalEffort(&hash, value.effort);
            if (value.permission_mode) |permission_mode| {
                hash.update("permission_mode\x00");
                hashString(&hash, @tagName(permission_mode));
            }
            if (value.notifications) |notifications| {
                hash.update("1");
                hashNotifications(&hash, notifications);
            } else hash.update("0");
        },
        .lifecycle => |value| {
            hash.update("lifecycle\x00");
            hashString(&hash, value.id);
            hashString(&hash, @tagName(value.action));
        },
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Reproduces the request identity used before child permission mode became
/// configurable. This is only valid for a create request that omitted the new
/// field and is used solely to replay an already-committed legacy operation.
pub fn legacyImplicitAutoCreateRequestFingerprint(
    input: OperationRequestFingerprintInput,
) ?[32]u8 {
    const create = switch (input.command) {
        .create => |value| value,
        else => return null,
    };
    if (create.permission_mode_explicit) return null;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.operation-request.v1\x00");
    hashString(&hash, input.actor_id);
    hashString(&hash, input.target_id);
    hashOptionalString(&hash, input.source_id);
    hashOptionalString(&hash, input.effective_parent_id);
    hash.update("create\x00");
    hashLegacyConfiguration(&hash, create.configuration);
    hashString(&hash, @tagName(create.mode));
    hashOptionalString(&hash, create.prompt);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn operationFingerprint(input: OperationFingerprintInput) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.operation-effect.v1\x00");
    const request_fingerprint = operationRequestFingerprint(.{
        .command = input.command,
        .actor_id = input.actor_id,
        .target_id = input.target_id,
        .source_id = input.source_id,
        .effective_parent_id = input.effective_parent_id,
    });
    hash.update(&request_fingerprint);
    if (input.bootstrap_configuration) |configuration| {
        hash.update("1");
        hashConfiguration(&hash, configuration);
    } else hash.update("0");
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashConfiguration(
    hash: *std.crypto.hash.sha2.Sha256,
    configuration: Configuration,
) void {
    hashString(hash, configuration.name);
    hashOptionalString(hash, configuration.model);
    hashOptionalEffort(hash, configuration.effort);
    hashString(hash, @tagName(configuration.permission_mode));
    hashNotifications(hash, configuration.notifications);
}

fn hashLegacyConfiguration(
    hash: *std.crypto.hash.sha2.Sha256,
    configuration: Configuration,
) void {
    hashString(hash, configuration.name);
    hashOptionalString(hash, configuration.model);
    hashOptionalEffort(hash, configuration.effort);
    hashNotifications(hash, configuration.notifications);
}

fn hashNotifications(
    hash: *std.crypto.hash.sha2.Sha256,
    notifications: NotificationPolicy,
) void {
    hash.update(if (notifications.terminal.completed) "1" else "0");
    hash.update(if (notifications.terminal.failed) "1" else "0");
    hash.update(if (notifications.terminal.cancelled) "1" else "0");
    hashInteger(hash, notifications.milestones.len);
    for (notifications.milestones) |name| hashString(hash, name);
    hashOptionalInteger(hash, notifications.report_interval_ms);
    hashOptionalInteger(hash, notifications.report_duration_ms);
    hashInteger(hash, notifications.stop_conditions.len);
    for (notifications.stop_conditions) |condition| hashString(hash, @tagName(condition));
}

fn hashOptionalString(
    hash: *std.crypto.hash.sha2.Sha256,
    value: ?[]const u8,
) void {
    if (value) |text| {
        hash.update("1");
        hashString(hash, text);
    } else hash.update("0");
}

fn hashOptionalEffort(
    hash: *std.crypto.hash.sha2.Sha256,
    value: ?types.ReasoningEffort,
) void {
    if (value) |effort| {
        hash.update("1");
        hashString(hash, effort.label());
    } else hash.update("0");
}

fn hashOptionalInteger(
    hash: *std.crypto.hash.sha2.Sha256,
    value: ?u64,
) void {
    if (value) |number| {
        hash.update("1");
        hashInteger(hash, number);
    } else hash.update("0");
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashInteger(hash, value.len);
    hash.update(value);
}

fn hashInteger(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn cloneStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const cloned = try alloc.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |value| alloc.free(value);
        alloc.free(cloned);
    }
    for (values) |value| {
        cloned[initialized] = try alloc.dupe(u8, value);
        initialized += 1;
    }
    return cloned;
}

fn cloneEventKind(alloc: Allocator, kind: EventKind) !EventKind {
    return switch (kind) {
        .created => .created,
        .configured => .configured,
        .message_queued => |value| .{ .message_queued = .{
            .message_id = try alloc.dupe(u8, value.message_id),
        } },
        .relationship_changed => |value| blk: {
            const previous = if (value.previous_parent_id) |parent|
                try alloc.dupe(u8, parent)
            else
                null;
            errdefer if (previous) |parent| alloc.free(parent);
            break :blk .{ .relationship_changed = .{
                .previous_parent_id = previous,
                .parent_id = if (value.parent_id) |parent|
                    try alloc.dupe(u8, parent)
                else
                    null,
            } };
        },
        .lifecycle_changed => |value| .{ .lifecycle_changed = value },
        .work_transition => |value| blk: {
            const work_item_id = try alloc.dupe(u8, value.work_item_id);
            errdefer alloc.free(work_item_id);
            break :blk .{ .work_transition = .{
                .work_item_id = work_item_id,
                .previous = value.previous,
                .current = value.current,
                .reason = if (value.reason) |reason| try alloc.dupe(u8, reason) else null,
            } };
        },
        .milestone_emitted => |value| blk: {
            const operation_id = try alloc.dupe(u8, value.operation_id);
            errdefer alloc.free(operation_id);
            const source_id = try alloc.dupe(u8, value.source_child_id);
            errdefer alloc.free(source_id);
            const target_id = try alloc.dupe(u8, value.target_parent_id);
            errdefer alloc.free(target_id);
            const work_id = try alloc.dupe(u8, value.work_item_id);
            errdefer alloc.free(work_id);
            break :blk .{ .milestone_emitted = .{
                .operation_id = operation_id,
                .source_child_id = source_id,
                .target_parent_id = target_id,
                .work_item_id = work_id,
                .name = try alloc.dupe(u8, value.name),
            } };
        },
    };
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

test "validation preserves six branches and nested message variants" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(error.InvalidBranchSelection, validateCommand(alloc, .{}));
    try std.testing.expectError(
        error.InvalidBranchSelection,
        validateCommand(alloc, .{
            .create = .{ .name = "child", .mode = .persistent },
            .lifecycle = .{ .id = "child-id", .action = .close },
        }),
    );
    try std.testing.expectError(
        error.InvalidNestedBranchSelection,
        validateCommand(alloc, .{ .message = .{} }),
    );
    try std.testing.expectError(
        error.InvalidNestedBranchSelection,
        validateCommand(alloc, .{ .message = .{
            .send = .{ .id = "child-id", .content = "work" },
            .milestone = .{ .name = "halfway" },
        } }),
    );

    var send = try validateCommand(alloc, .{ .message = .{ .send = .{
        .id = "child-id",
        .content = "continue",
    } } });
    defer send.deinit(alloc);
    switch (send) {
        .message => |message| switch (message) {
            .send => |value| try std.testing.expectEqualStrings("continue", value.content),
            .milestone => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    var milestone = try validateCommand(alloc, .{ .message = .{ .milestone = .{
        .name = "halfway",
    } } });
    defer milestone.deinit(alloc);

    var create_default = try validateCommand(alloc, .{ .create = .{
        .name = "default-yolo",
        .mode = .persistent,
    } });
    defer create_default.deinit(alloc);
    try std.testing.expectEqual(
        types.PermissionMode.yolo,
        create_default.create.configuration.permission_mode,
    );
    var create_one_off = try validateCommand(alloc, .{ .create = .{
        .name = "default-yolo-once",
        .mode = .one_off,
        .prompt = "work",
    } });
    defer create_one_off.deinit(alloc);
    try std.testing.expectEqual(
        types.PermissionMode.yolo,
        create_one_off.create.configuration.permission_mode,
    );
    var create_auto = try validateCommand(alloc, .{ .create = .{
        .name = "explicit-auto",
        .mode = .persistent,
        .permission_mode = .auto,
    } });
    defer create_auto.deinit(alloc);
    try std.testing.expectEqual(
        types.PermissionMode.auto,
        create_auto.create.configuration.permission_mode,
    );

    var inspect = try validateCommand(alloc, .{ .inspect = .{
        .id = "child-id",
        .sections = &.{.status},
        .wait = .{
            .until = .settled,
            .after_generation = 7,
            .timeout_ms = 1_000,
        },
    } });
    defer inspect.deinit(alloc);
    try std.testing.expectEqual(
        InspectWait{
            .until = .settled,
            .after_generation = 7,
            .timeout_ms = 1_000,
        },
        inspect.inspect.wait.?,
    );
    var relationship = try validateCommand(alloc, .{ .relationship = .{
        .action = .attach,
        .id = "child-id",
        .parent_id = "parent-id",
    } });
    defer relationship.deinit(alloc);
    var configure = try validateCommand(alloc, .{ .configure = .{
        .id = "child-id",
        .permission_mode = .ask,
    } });
    defer configure.deinit(alloc);
    try std.testing.expectEqual(
        types.PermissionMode.ask,
        configure.configure.permission_mode.?,
    );
    var lifecycle = try validateCommand(alloc, .{ .lifecycle = .{
        .id = "child-id",
        .action = .close,
    } });
    defer lifecycle.deinit(alloc);
}

test "create inspect relationship configure and lifecycle validation rejects invalid contracts" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.MissingName,
        validateCommand(alloc, .{ .create = .{ .mode = .persistent } }),
    );
    try std.testing.expectError(
        error.MissingMode,
        validateCommand(alloc, .{ .create = .{ .name = "child" } }),
    );
    try std.testing.expectError(
        error.MissingOneOffPrompt,
        validateCommand(alloc, .{ .create = .{
            .name = "one off",
            .mode = .one_off,
        } }),
    );
    try std.testing.expectError(
        error.MissingInspectId,
        validateCommand(alloc, .{ .inspect = .{ .sections = &.{.status} } }),
    );
    try std.testing.expectError(
        error.InvalidInspectSections,
        validateCommand(alloc, .{ .inspect = .{
            .id = "child-id",
            .sections = &.{ .status, .status },
        } }),
    );
    try std.testing.expectError(
        error.InvalidInspectWait,
        validateCommand(alloc, .{ .inspect = .{
            .id = "child-id",
            .sections = &.{.messages},
            .wait = .{ .until = .settled, .timeout_ms = 1_000 },
        } }),
    );
    try std.testing.expectError(
        error.InvalidInspectWait,
        validateCommand(alloc, .{ .inspect = .{
            .id = "child-id",
            .sections = &.{.status},
            .cursor = "v1:1:0",
            .wait = .{ .until = .settled, .timeout_ms = 1_000 },
        } }),
    );
    try std.testing.expectError(
        error.InvalidInspectWait,
        validateCommand(alloc, .{ .inspect = .{
            .id = "child-id",
            .sections = &.{.status},
            .wait = .{ .until = .settled, .timeout_ms = 0 },
        } }),
    );
    try std.testing.expectError(
        error.InvalidInspectWait,
        validateCommand(alloc, .{ .inspect = .{
            .id = "child-id",
            .sections = &.{.status},
            .wait = .{
                .until = .settled,
                .timeout_ms = max_inspect_wait_ms + 1,
            },
        } }),
    );
    try std.testing.expectError(
        error.InvalidInspectWait,
        validateCommand(alloc, .{ .inspect = .{
            .id = "child-id",
            .sections = &.{.status},
            .wait = .{ .until = .settled },
        } }),
    );
    try std.testing.expectError(
        error.InvalidRelationship,
        validateCommand(alloc, .{ .relationship = .{
            .action = .reparent,
            .id = "child-id",
        } }),
    );
    try std.testing.expectError(
        error.EmptyConfiguration,
        validateCommand(alloc, .{ .configure = .{ .id = "child-id" } }),
    );

    var create = try validateCommand(alloc, .{ .create = .{
        .name = "research",
        .mode = .persistent,
        .prompt = "inspect the store",
        .model = "openai/gpt-5",
        .notifications = .{
            .milestones = &.{"halfway"},
            .report_interval_ms = 1000,
            .report_duration_ms = 5000,
            .stop_conditions = &.{ .terminal, .duration_elapsed },
        },
    } });
    defer create.deinit(alloc);
}

test "inspect wait predicate requires a settled state after the requested generation" {
    const wait = InspectWait{
        .until = .settled,
        .after_generation = 4,
        .timeout_ms = 1_000,
    };
    try std.testing.expect(!inspectWaitSatisfied(wait, 4, .idle));
    try std.testing.expect(!inspectWaitSatisfied(wait, 5, .queued));
    try std.testing.expect(!inspectWaitSatisfied(wait, 5, .running));
    try std.testing.expect(!inspectWaitSatisfied(wait, 5, .awaiting_approval));
    inline for (.{
        State.idle,
        State.interrupted,
        State.completed,
        State.failed,
        State.cancelled,
        State.archived,
    }) |state| {
        try std.testing.expect(inspectWaitSatisfied(wait, 5, state));
    }
}

test "queued external work accepts only an explicit resume retry" {
    try std.testing.expectEqual(
        State.queued,
        try nextLifecycleState(.persistent, .queued, .@"resume", true, null),
    );
    try std.testing.expectError(
        error.InvalidLifecycleTransition,
        nextLifecycleState(.persistent, .queued, .@"resume", false, null),
    );
}

test "operation fingerprint canonically includes resolved durable identities" {
    const alloc = std.testing.allocator;
    var command = try validateCommand(alloc, .{ .message = .{ .send = .{
        .id = "child-id",
        .content = "continue",
    } } });
    defer command.deinit(alloc);

    const base = OperationFingerprintInput{
        .command = command,
        .actor_id = "parent-a",
        .target_id = "child-id",
        .source_id = "parent-a",
        .effective_parent_id = "parent-a",
    };
    const first = operationFingerprint(base);
    const replay = operationFingerprint(base);
    try std.testing.expectEqualSlices(u8, &first, &replay);

    var changed_actor = base;
    changed_actor.actor_id = "parent-b";
    const actor_fingerprint = operationFingerprint(changed_actor);
    try std.testing.expect(!std.mem.eql(u8, &first, &actor_fingerprint));
    var changed_source = base;
    changed_source.source_id = "parent-b";
    const source_fingerprint = operationFingerprint(changed_source);
    try std.testing.expect(!std.mem.eql(u8, &first, &source_fingerprint));
    var changed_parent = base;
    changed_parent.effective_parent_id = "parent-b";
    const parent_fingerprint = operationFingerprint(changed_parent);
    try std.testing.expect(!std.mem.eql(u8, &first, &parent_fingerprint));

    const request = OperationRequestFingerprintInput{
        .command = command,
        .actor_id = base.actor_id,
        .target_id = base.target_id,
        .source_id = base.source_id,
        .effective_parent_id = base.effective_parent_id,
    };
    const request_fingerprint = operationRequestFingerprint(request);
    const same_request = operationRequestFingerprint(request);
    try std.testing.expectEqualSlices(u8, &request_fingerprint, &same_request);
    var effect_with_bootstrap = base;
    effect_with_bootstrap.bootstrap_configuration = .{
        .name = @constCast("bootstrap"),
        .model = @constCast("model/a"),
        .effort = types.ReasoningEffort.literal("high"),
        .notifications = .{
            .terminal = .{},
            .milestones = @constCast(&[_][]u8{}),
            .report_interval_ms = null,
            .report_duration_ms = null,
            .stop_conditions = @constCast(&[_]StopCondition{}),
        },
    };
    const effect_fingerprint = operationFingerprint(effect_with_bootstrap);
    try std.testing.expect(!std.mem.eql(u8, &first, &effect_fingerprint));
    var changed_permission = effect_with_bootstrap;
    changed_permission.bootstrap_configuration.?.permission_mode = .auto;
    const permission_fingerprint = operationFingerprint(changed_permission);
    try std.testing.expect(!std.mem.eql(
        u8,
        &effect_fingerprint,
        &permission_fingerprint,
    ));

    var configure_auto = try validateCommand(alloc, .{ .configure = .{
        .id = "child-id",
        .permission_mode = .auto,
    } });
    defer configure_auto.deinit(alloc);
    var configure_yolo = try validateCommand(alloc, .{ .configure = .{
        .id = "child-id",
        .permission_mode = .yolo,
    } });
    defer configure_yolo.deinit(alloc);
    const configure_auto_fingerprint = operationRequestFingerprint(.{
        .command = configure_auto,
        .actor_id = "parent-a",
        .target_id = "child-id",
    });
    const configure_yolo_fingerprint = operationRequestFingerprint(.{
        .command = configure_yolo,
        .actor_id = "parent-a",
        .target_id = "child-id",
    });
    try std.testing.expect(!std.mem.eql(
        u8,
        &configure_auto_fingerprint,
        &configure_yolo_fingerprint,
    ));
}

test "implicit yolo create retains the legacy auto replay identity only as fallback" {
    const alloc = std.testing.allocator;
    var implicit = try validateCommand(alloc, .{ .create = .{
        .name = "legacy-child",
        .mode = .persistent,
    } });
    defer implicit.deinit(alloc);
    const input = OperationRequestFingerprintInput{
        .command = implicit,
        .actor_id = "parent",
        .target_id = "",
        .effective_parent_id = "parent",
    };
    const current = operationRequestFingerprint(input);
    const legacy = legacyImplicitAutoCreateRequestFingerprint(input) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, &current, &legacy));

    var explicit = try validateCommand(alloc, .{ .create = .{
        .name = "legacy-child",
        .mode = .persistent,
        .permission_mode = .yolo,
    } });
    defer explicit.deinit(alloc);
    try std.testing.expect(legacyImplicitAutoCreateRequestFingerprint(.{
        .command = explicit,
        .actor_id = "parent",
        .target_id = "",
        .effective_parent_id = "parent",
    }) == null);
}

test "notification validation rejects duplicates and inconsistent duration" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.DuplicateMilestone,
        validateNotificationPolicy(alloc, .{ .milestones = &.{ "halfway", "halfway" } }),
    );
    try std.testing.expectError(
        error.InvalidNotificationPolicy,
        validateNotificationPolicy(alloc, .{ .report_duration_ms = 1000 }),
    );
    try std.testing.expectError(
        error.InvalidNotificationPolicy,
        validateNotificationPolicy(alloc, .{ .stop_conditions = &.{.duration_elapsed} }),
    );
}

test "notification duration always becomes an effective stop condition" {
    const alloc = std.testing.allocator;
    var policy = try validateNotificationPolicy(alloc, .{
        .report_interval_ms = 200,
        .report_duration_ms = 1500,
        .stop_conditions = &.{.terminal},
    });
    defer policy.deinit(alloc);

    try std.testing.expectEqualSlices(
        StopCondition,
        &.{ .terminal, .duration_elapsed },
        policy.stop_conditions,
    );

    var duration_only = try validateNotificationPolicy(alloc, .{
        .report_interval_ms = 100,
        .report_duration_ms = 500,
        .stop_conditions = &.{},
    });
    defer duration_only.deinit(alloc);
    try std.testing.expectEqualSlices(
        StopCondition,
        &.{.duration_elapsed},
        duration_only.stop_conditions,
    );
}

test "owned validation values clean up after failing allocations" {
    const alloc = std.testing.allocator;
    var succeeded = false;
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = index });
        const result = validateCommand(failing.allocator(), .{ .create = .{
            .name = "research",
            .mode = .persistent,
            .prompt = "inspect",
            .model = "openai/gpt-5",
            .notifications = .{ .milestones = &.{ "halfway", "verified" } },
        } });
        if (result) |value| {
            var command = value;
            command.deinit(failing.allocator());
            succeeded = true;
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expect(succeeded);
}

test "lifecycle transitions are pure and explicit" {
    try std.testing.expectEqual(
        State.idle,
        try nextLifecycleState(.persistent, .queued, .cancel, true, null),
    );
    try std.testing.expectEqual(
        State.cancelled,
        try nextLifecycleState(.one_off, .running, .cancel, false, null),
    );
    try std.testing.expectEqual(
        State.queued,
        try nextLifecycleState(.persistent, .interrupted, .@"resume", true, null),
    );
    try std.testing.expectEqual(
        State.archived,
        try nextLifecycleState(.persistent, .idle, .close, false, null),
    );
    try std.testing.expectEqual(
        State.completed,
        try nextLifecycleState(.one_off, .archived, .reopen, false, .completed),
    );
    try std.testing.expectError(
        error.InvalidLifecycleTransition,
        nextLifecycleState(.persistent, .idle, .@"resume", false, null),
    );
    try std.testing.expectEqual(State.interrupted, stateAfterRestart(.running));
    try std.testing.expectEqual(State.interrupted, stateAfterRestart(.awaiting_approval));
    try std.testing.expectEqual(State.interrupted, stateAfterRestart(.queued));
}

test "pagination rejects stale cursors and bounds pages" {
    const first = try decidePage(5, 3, null, 2);
    try std.testing.expectEqual(@as(usize, 0), first.page.start);
    try std.testing.expectEqual(@as(usize, 2), first.page.end);
    try std.testing.expect(first.page.has_more);

    const stale = try decidePage(5, 4, .{ .generation = 3, .offset = 2 }, 2);
    try std.testing.expect(stale == .stale_cursor);
    const cursor_text = try encodeCursor(std.testing.allocator, .{
        .generation = 7,
        .offset = 4,
    });
    defer std.testing.allocator.free(cursor_text);
    const cursor = try parseCursor(cursor_text);
    try std.testing.expectEqual(@as(u64, 7), cursor.generation);
    try std.testing.expectEqual(@as(usize, 4), cursor.offset);
}

test "queued message clone owns inherited root user context" {
    const alloc = std.testing.allocator;
    var root_user_messages = try alloc.alloc([]u8, 2);
    root_user_messages[0] = try alloc.dupe(u8, "Do not modify files.");
    root_user_messages[1] = try alloc.dupe(u8, "Inspect storage only.");
    var message = QueuedMessage{
        .id = try alloc.dupe(u8, "work-1"),
        .source_id = try alloc.dupe(u8, "root-session"),
        .content = try alloc.dupe(u8, "inspect the requested file"),
        .root_user_intent_context = try alloc.dupe(
            u8,
            "current_request: inspect the requested file\n",
        ),
        .root_user_messages = root_user_messages,
        .root_user_evidence_complete = true,
        .created_at_ms = 1,
    };
    defer message.deinit(alloc);
    var cloned = try message.clone(alloc);
    defer cloned.deinit(alloc);

    message.root_user_intent_context[17] = 'X';
    try std.testing.expectEqualStrings(
        "current_request: inspect the requested file\n",
        cloned.root_user_intent_context,
    );
    message.root_user_messages[0][0] = 'X';
    try std.testing.expect(cloned.root_user_evidence_complete);
    try std.testing.expectEqualStrings(
        "Do not modify files.",
        cloned.root_user_messages[0],
    );
    try std.testing.expectEqualStrings(
        "Inspect storage only.",
        cloned.root_user_messages[1],
    );
}

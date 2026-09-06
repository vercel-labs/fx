const std = @import("std");
const mcp_access = @import("../mcp/access_policy.zig");
const model_provider = @import("../config/model_provider.zig");
const session_layout = @import("../session/session_layout.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_model_bytes: usize = 256;
pub const max_prompt_bytes: usize = 64 * 1024;
pub const max_message_bytes: usize = 64 * 1024;
pub const max_agent_name_bytes: usize = 64;
pub const max_instructions_bytes: usize = 64 * 1024;
pub const max_cancellation_reason_bytes: usize = 512;
pub const max_admission_items: usize = 256;
pub const max_admission_item_bytes: usize = 4096;

pub const QueuedMessage = struct {
    id: []u8,
    source_id: []u8,
    content: []u8,
    system_prompt_overlay: []u8 = &.{},
    root_user_intent_context: []u8 = &.{},
    root_user_messages: [][]u8 = &.{},
    root_user_evidence_complete: bool = false,
    created_at_ms: i64,

    pub fn deinit(self: *QueuedMessage, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.source_id);
        alloc.free(self.content);
        if (self.system_prompt_overlay.len > 0) {
            alloc.free(self.system_prompt_overlay);
        }
        if (self.root_user_intent_context.len > 0) {
            alloc.free(self.root_user_intent_context);
        }
        freeStrings(alloc, self.root_user_messages);
        self.* = undefined;
    }
};

/// Immutable authority captured once for one child turn.
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

pub fn captureAdmission(
    alloc: Allocator,
    input: AdmissionInput,
) AdmissionError!AdmissionSnapshot {
    validateId(input.parent_id) catch return error.InvalidAdmissionItem;
    validateId(input.source_id) catch return error.InvalidAdmissionItem;
    validateBoundedText(input.model, max_model_bytes) catch return error.InvalidModel;
    if (input.tool_names.len > max_admission_items or
        input.rules.rules.len > max_admission_items or
        input.grants.len > max_admission_items or
        input.integration_names.len > max_admission_items)
    {
        return error.TooManyAdmissionItems;
    }
    try validateStrings(input.tool_names);
    try validateStrings(input.integration_names);
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

pub const ValidationError = error{
    InvalidId,
};

pub fn validateId(id: []const u8) ValidationError!void {
    session_layout.validateSessionId(id) catch return error.InvalidId;
}

pub fn validAgentName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_agent_name_bytes) return false;
    if (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and
            byte != '_' and byte != '-')
        {
            return false;
        }
    }
    return true;
}

pub fn validInstructions(instructions: []const u8) bool {
    if (instructions.len > max_instructions_bytes or
        !std.unicode.utf8ValidateSlice(instructions)) return false;
    return std.mem.findScalar(u8, instructions, 0) == null;
}

fn validateStrings(values: []const []const u8) AdmissionError!void {
    for (values) |value| try validateAdmissionText(value);
}

fn validateAdmissionText(value: []const u8) AdmissionError!void {
    validateBoundedText(value, max_admission_item_bytes) catch
        return error.InvalidAdmissionItem;
}

fn validateBoundedText(text: []const u8, max_bytes: usize) error{InvalidText}!void {
    if (text.len == 0 or text.len > max_bytes or
        !std.unicode.utf8ValidateSlice(text))
    {
        return error.InvalidText;
    }
    for (text) |byte| if (byte == 0) return error.InvalidText;
}

fn cloneStrings(
    alloc: Allocator,
    source: []const []const u8,
) Allocator.Error![][]u8 {
    const result = try alloc.alloc([]u8, source.len);
    var built: usize = 0;
    errdefer {
        for (result[0..built]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (source) |value| {
        result[built] = try alloc.dupe(u8, value);
        built += 1;
    }
    return result;
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

test "captured admission owns independent authority slices" {
    const alloc = std.testing.allocator;
    var snapshot = try captureAdmission(alloc, .{
        .parent_id = "01J00000000000000000000000",
        .source_id = "01J00000000000000000000000",
        .model = "test/model",
        .effort = .auto,
        .tool_names = &.{"read_file"},
    });
    defer snapshot.deinit(alloc);
    try std.testing.expectEqualStrings("read_file", snapshot.tool_names[0]);
}

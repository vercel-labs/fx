const std = @import("std");
const domain = @import("../../core/subagent/domain.zig");
const tool_provider = @import("../../core/subagent/tool_provider.zig");
const tool_result = @import("../../core/subagent/tool_result.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const types = @import("../../core/shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    command: domain.Command,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        self.command.deinit(alloc);
        self.* = undefined;
    }
};

const DecodeError = error{
    OutOfMemory,
    InvalidRoot,
    MissingCommand,
    UnknownField,
    InvalidFieldType,
    MissingField,
    InvalidEnum,
    InvalidInteger,
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch {
        return decodeFailure(ctx, "invalid_json") catch return error.OutOfMemory;
    };
    defer parsed.deinit();

    const command_input = parseRoot(arena, parsed.value) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return decodeFailure(ctx, decodeErrorCode(err)) catch return error.OutOfMemory;
    };
    const command = domain.validateCommand(ctx.allocator, command_input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return decodeFailure(ctx, validationErrorCode(err)) catch return error.OutOfMemory;
    };
    errdefer {
        var owned = command;
        owned.deinit(ctx.allocator);
    }

    const input = try ctx.allocator.create(Input);
    input.* = .{ .command = command };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn decodeFailure(ctx: tool_dispatch.DispatchContext, code: []const u8) !tool_dispatch.DecodeResult {
    return .{ .failure = try tool_result.failureAlloc(
        ctx.allocator,
        ctx.tool_call_id,
        null,
        "rejected",
        code,
        false,
        null,
    ) };
}

fn decodeErrorCode(err: DecodeError) []const u8 {
    return switch (err) {
        error.OutOfMemory => unreachable,
        error.InvalidRoot => "invalid_root",
        error.MissingCommand => "missing_command",
        error.UnknownField => "unknown_field",
        error.InvalidFieldType => "invalid_field_type",
        error.MissingField => "missing_field",
        error.InvalidEnum => "invalid_enum",
        error.InvalidInteger => "invalid_integer",
    };
}

fn validationErrorCode(err: domain.ValidationError) []const u8 {
    return switch (err) {
        error.InvalidBranchSelection => "invalid_branch_selection",
        error.InvalidNestedBranchSelection => "invalid_nested_branch_selection",
        error.MissingName => "missing_name",
        error.MissingMode => "missing_mode",
        error.MissingOneOffPrompt => "missing_one_off_prompt",
        error.MissingInspectId => "missing_inspect_id",
        error.InvalidId => "invalid_id",
        error.InvalidName => "invalid_name",
        error.InvalidModel => "invalid_model",
        error.InvalidPrompt => "invalid_prompt",
        error.InvalidMessage => "invalid_message",
        error.InvalidOperationId => "invalid_operation_id",
        error.InvalidNotificationPolicy => "invalid_notification_policy",
        error.DuplicateMilestone => "duplicate_milestone",
        error.DuplicateStopCondition => "duplicate_stop_condition",
        error.InvalidInspectSections => "invalid_inspect_sections",
        error.InvalidInspectWait => "invalid_inspect_wait",
        error.InvalidCursor => "invalid_cursor",
        error.InvalidPageLimit => "invalid_page_limit",
        error.InvalidRelationship => "invalid_relationship",
        error.EmptyConfiguration => "empty_configuration",
        error.OutOfMemory => unreachable,
    };
}

fn parseRoot(arena: Allocator, value: std.json.Value) (DecodeError || Allocator.Error)!domain.CommandInput {
    const root = try objectValue(value);
    try rejectUnknown(root, &.{"command"});
    const command_value = root.get("command") orelse return error.MissingCommand;
    const command = try objectValue(command_value);
    try rejectUnknown(command, &.{ "create", "inspect", "message", "relationship", "configure", "lifecycle" });

    return .{
        .create = if (command.get("create")) |branch| try parseCreate(arena, branch) else null,
        .inspect = if (command.get("inspect")) |branch| try parseInspect(arena, branch) else null,
        .message = if (command.get("message")) |branch| try parseMessage(arena, branch) else null,
        .relationship = if (command.get("relationship")) |branch| try parseRelationship(branch) else null,
        .configure = if (command.get("configure")) |branch| try parseConfigure(arena, branch) else null,
        .lifecycle = if (command.get("lifecycle")) |branch| try parseLifecycle(branch) else null,
    };
}

fn parseCreate(arena: Allocator, value: std.json.Value) (DecodeError || Allocator.Error)!domain.CreateInput {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "name", "profile", "mode", "prompt", "model", "effort", "permission_mode", "notifications" });
    return .{
        .name = try optionalString(object, "name"),
        .profile = try optionalString(object, "profile"),
        .mode = if (try optionalString(object, "mode")) |raw| try parseMode(raw) else null,
        .prompt = try optionalString(object, "prompt"),
        .model = try optionalString(object, "model"),
        .effort = if (try optionalString(object, "effort")) |raw|
            types.ReasoningEffort.parse(raw) orelse return error.InvalidEnum
        else
            null,
        .permission_mode = if (try optionalString(object, "permission_mode")) |raw|
            std.meta.stringToEnum(types.PermissionMode, raw) orelse
                return error.InvalidEnum
        else
            null,
        .notifications = if (object.get("notifications")) |raw| try parseNotifications(arena, raw) else null,
    };
}

fn parseInspect(arena: Allocator, value: std.json.Value) (DecodeError || Allocator.Error)!domain.InspectInput {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "id", "sections", "cursor", "limit", "wait" });
    return .{
        .id = try optionalString(object, "id"),
        .sections = if (object.get("sections")) |raw| try parseInspectSections(arena, raw) else &.{},
        .cursor = try optionalString(object, "cursor"),
        .limit = if (object.get("limit")) |raw| try positiveUsize(raw) else null,
        .wait = if (object.get("wait")) |raw| try parseInspectWait(raw) else null,
    };
}

fn parseInspectWait(value: std.json.Value) DecodeError!domain.InspectWaitInput {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "until", "after_generation", "timeout_ms" });
    return .{
        .until = if (try optionalString(object, "until")) |raw|
            if (std.mem.eql(u8, raw, "settled"))
                .settled
            else
                return error.InvalidEnum
        else
            null,
        .after_generation = if (object.get("after_generation")) |raw|
            try nonNegativeU64(raw)
        else
            null,
        .timeout_ms = if (object.get("timeout_ms")) |raw|
            try positiveU64(raw)
        else
            null,
    };
}

fn parseMessage(arena: Allocator, value: std.json.Value) (DecodeError || Allocator.Error)!domain.MessageInput {
    _ = arena;
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "send", "milestone" });
    return .{
        .send = if (object.get("send")) |raw| try parseSend(raw) else null,
        .milestone = if (object.get("milestone")) |raw| try parseMilestone(raw) else null,
    };
}

fn parseSend(value: std.json.Value) DecodeError!domain.MessageSendInput {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "id", "content" });
    return .{
        .id = try requiredString(object, "id"),
        .content = try requiredString(object, "content"),
    };
}

fn parseMilestone(value: std.json.Value) DecodeError!domain.MessageMilestoneInput {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{"name"});
    return .{ .name = try requiredString(object, "name") };
}

fn parseRelationship(value: std.json.Value) DecodeError!domain.RelationshipInput {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "action", "id", "parent_id" });
    const action_raw = try requiredString(object, "action");
    const action: domain.RelationshipAction = if (std.mem.eql(u8, action_raw, "attach"))
        .attach
    else if (std.mem.eql(u8, action_raw, "detach"))
        .detach
    else if (std.mem.eql(u8, action_raw, "reparent"))
        .reparent
    else
        return error.InvalidEnum;
    return .{
        .action = action,
        .id = try requiredString(object, "id"),
        .parent_id = try optionalString(object, "parent_id"),
    };
}

fn parseConfigure(arena: Allocator, value: std.json.Value) (DecodeError || Allocator.Error)!domain.ConfigureInput {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "id", "name", "model", "effort", "permission_mode", "notifications" });
    return .{
        .id = try requiredString(object, "id"),
        .name = try optionalString(object, "name"),
        .model = try optionalString(object, "model"),
        .effort = if (try optionalString(object, "effort")) |raw|
            types.ReasoningEffort.parse(raw) orelse return error.InvalidEnum
        else
            null,
        .permission_mode = if (try optionalString(object, "permission_mode")) |raw|
            std.meta.stringToEnum(types.PermissionMode, raw) orelse
                return error.InvalidEnum
        else
            null,
        .notifications = if (object.get("notifications")) |raw| try parseNotifications(arena, raw) else null,
    };
}

fn parseLifecycle(value: std.json.Value) DecodeError!domain.LifecycleInput {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "id", "action" });
    const action_raw = try requiredString(object, "action");
    const action: domain.LifecycleAction = if (std.mem.eql(u8, action_raw, "cancel"))
        .cancel
    else if (std.mem.eql(u8, action_raw, "resume"))
        .@"resume"
    else if (std.mem.eql(u8, action_raw, "close"))
        .close
    else if (std.mem.eql(u8, action_raw, "reopen"))
        .reopen
    else
        return error.InvalidEnum;
    return .{
        .id = try requiredString(object, "id"),
        .action = action,
    };
}

fn parseNotifications(
    arena: Allocator,
    value: std.json.Value,
) (DecodeError || Allocator.Error)!domain.NotificationPolicyInput {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "terminal", "milestones", "report_interval_ms", "report_duration_ms", "stop_conditions" });
    var result = domain.NotificationPolicyInput{};
    if (object.get("terminal")) |raw| result.terminal = try parseTerminal(raw);
    if (object.get("milestones")) |raw| result.milestones = try parseStringArray(arena, raw);
    if (object.get("report_interval_ms")) |raw| result.report_interval_ms = try positiveU64(raw);
    if (object.get("report_duration_ms")) |raw| result.report_duration_ms = try positiveU64(raw);
    if (object.get("stop_conditions")) |raw| result.stop_conditions = try parseStopConditions(arena, raw);
    return result;
}

fn parseTerminal(value: std.json.Value) DecodeError!domain.TerminalEvents {
    const object = try objectValue(value);
    try rejectUnknown(object, &.{ "completed", "failed", "cancelled" });
    var result = domain.TerminalEvents{};
    if (object.get("completed")) |raw| result.completed = try boolValue(raw);
    if (object.get("failed")) |raw| result.failed = try boolValue(raw);
    if (object.get("cancelled")) |raw| result.cancelled = try boolValue(raw);
    return result;
}

fn parseInspectSections(arena: Allocator, value: std.json.Value) (DecodeError || Allocator.Error)![]domain.InspectSection {
    if (value != .array) return error.InvalidFieldType;
    const out = try arena.alloc(domain.InspectSection, value.array.items.len);
    for (value.array.items, 0..) |item, index| {
        const raw = try stringValue(item);
        out[index] = if (std.mem.eql(u8, raw, "status"))
            .status
        else if (std.mem.eql(u8, raw, "messages"))
            .messages
        else if (std.mem.eql(u8, raw, "tool_activity"))
            .tool_activity
        else if (std.mem.eql(u8, raw, "events"))
            .events
        else if (std.mem.eql(u8, raw, "configuration"))
            .configuration
        else if (std.mem.eql(u8, raw, "relationship"))
            .relationship
        else
            return error.InvalidEnum;
    }
    return out;
}

fn parseStopConditions(arena: Allocator, value: std.json.Value) (DecodeError || Allocator.Error)![]domain.StopCondition {
    if (value != .array) return error.InvalidFieldType;
    const out = try arena.alloc(domain.StopCondition, value.array.items.len);
    for (value.array.items, 0..) |item, index| {
        const raw = try stringValue(item);
        out[index] = if (std.mem.eql(u8, raw, "terminal"))
            .terminal
        else if (std.mem.eql(u8, raw, "duration_elapsed"))
            .duration_elapsed
        else
            return error.InvalidEnum;
    }
    return out;
}

fn parseStringArray(arena: Allocator, value: std.json.Value) (DecodeError || Allocator.Error)![][]const u8 {
    if (value != .array) return error.InvalidFieldType;
    const out = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, index| out[index] = try stringValue(item);
    return out;
}

fn parseMode(raw: []const u8) DecodeError!domain.Mode {
    if (std.mem.eql(u8, raw, "one_off")) return .one_off;
    if (std.mem.eql(u8, raw, "persistent")) return .persistent;
    return error.InvalidEnum;
}

fn objectValue(value: std.json.Value) DecodeError!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidFieldType;
}

fn stringValue(value: std.json.Value) DecodeError![]const u8 {
    return if (value == .string) value.string else error.InvalidFieldType;
}

fn boolValue(value: std.json.Value) DecodeError!bool {
    return if (value == .bool) value.bool else error.InvalidFieldType;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) DecodeError![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return stringValue(value);
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) DecodeError!?[]const u8 {
    const value = object.get(key) orelse return null;
    return try stringValue(value);
}

fn positiveU64(value: std.json.Value) DecodeError!u64 {
    if (value != .integer or value.integer <= 0) return error.InvalidInteger;
    return std.math.cast(u64, value.integer) orelse error.InvalidInteger;
}

fn nonNegativeU64(value: std.json.Value) DecodeError!u64 {
    if (value != .integer or value.integer < 0) return error.InvalidInteger;
    return std.math.cast(u64, value.integer) orelse error.InvalidInteger;
}

fn positiveUsize(value: std.json.Value) DecodeError!usize {
    const parsed = try positiveU64(value);
    return std.math.cast(usize, parsed) orelse error.InvalidInteger;
}

fn rejectUnknown(object: std.json.ObjectMap, allowed: []const []const u8) DecodeError!void {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
        } else return error.UnknownField;
    }
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.subagent_provider orelse {
        const body = tool_result.failureAlloc(
            ctx.allocator,
            ctx.tool_call_id,
            null,
            "rejected",
            "host_unavailable",
            false,
            null,
        ) catch |err| return switch (err) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        };
        return .{ .failure = body };
    };
    const result = try provider.execute(
        ctx.allocator,
        &erased.as(Input).command,
        ctx.tool_call_id,
    );
    return switch (result.status) {
        .success => .{ .success = result.body },
        .failure => .{ .failure = result.body },
    };
}

pub fn readsOnly(input: tool_dispatch.ToolInput) bool {
    return switch (input.as(Input).command) {
        .inspect => true,
        else => false,
    };
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn expectDecodeFailure(args_json: []const u8, code: []const u8) !void {
    const alloc = std.testing.allocator;
    const result = try decode(.{ .allocator = alloc }, args_json);
    switch (result) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| {
            defer alloc.free(message);
            const needle = try std.fmt.allocPrint(alloc, "\"error_code\":\"{s}\"", .{code});
            defer alloc.free(needle);
            try std.testing.expect(std.mem.find(u8, message, needle) != null);
        },
    }
}

fn expectCommandTag(args_json: []const u8, expected: std.meta.Tag(domain.Command)) !void {
    const alloc = std.testing.allocator;
    const result = try decode(.{ .allocator = alloc }, args_json);
    switch (result) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(expected, std.meta.activeTag(input.as(Input).command));
        },
    }
}

test "call executes a validated command through the registered provider" {
    const Fixture = struct {
        calls: usize = 0,
        command: ?*domain.Command = null,
        invocation_id: ?[]const u8 = null,

        fn execute(
            raw_context: ?*anyopaque,
            alloc: Allocator,
            command: *domain.Command,
            invocation_id: []const u8,
        ) Allocator.Error!tool_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            self.calls += 1;
            self.command = command;
            self.invocation_id = invocation_id;
            return .{
                .status = .success,
                .body = try alloc.dupe(u8, "{\"ok\":true}"),
            };
        }
    };

    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc, .tool_call_id = "call-1" },
        "{\"command\":{\"inspect\":{\"id\":\"child-1\",\"sections\":[\"status\"]}}}",
    );
    var fixture = Fixture{};
    switch (decoded) {
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const result = try call(.{
                .allocator = alloc,
                .tool_call_id = "call-1",
                .subagent_provider = .{
                    .context = &fixture,
                    .execute_fn = Fixture.execute,
                },
            }, input);
            defer result.deinit(alloc);
            switch (result) {
                .success => |body| try std.testing.expectEqualStrings("{\"ok\":true}", body),
                .failure => return error.TestUnexpectedResult,
            }
            try std.testing.expect(fixture.command.? == &input.as(Input).command);
            try std.testing.expectEqual(.inspect, std.meta.activeTag(fixture.command.?.*));
            try std.testing.expectEqualStrings("child-1", fixture.command.?.inspect.id);
            try std.testing.expectEqualStrings("call-1", fixture.invocation_id.?);
        },
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "call reports structured host unavailability without a provider" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc, .tool_call_id = "call-1" },
        "{\"command\":{\"inspect\":{\"id\":\"child-1\",\"sections\":[\"status\"]}}}",
    );
    switch (decoded) {
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const result = try call(
                .{ .allocator = alloc, .tool_call_id = "call-1" },
                input,
            );
            defer result.deinit(alloc);
            switch (result) {
                .success => return error.TestUnexpectedResult,
                .failure => |body| try std.testing.expect(std.mem.find(
                    u8,
                    body,
                    "\"error_code\":\"host_unavailable\"",
                ) != null),
            }
        },
    }
}

test "decode accepts every canonical command branch" {
    try expectCommandTag("{\"command\":{\"create\":{\"name\":\"worker\",\"mode\":\"one_off\",\"prompt\":\"do it\"}}}", .create);
    try expectCommandTag("{\"command\":{\"inspect\":{\"id\":\"01J00000000000000000000000\",\"sections\":[\"status\"]}}}", .inspect);
    try expectCommandTag("{\"command\":{\"inspect\":{\"id\":\"01J00000000000000000000000\",\"sections\":[\"status\",\"messages\"],\"wait\":{\"until\":\"settled\",\"after_generation\":3,\"timeout_ms\":30000}}}}", .inspect);
    try expectCommandTag("{\"command\":{\"message\":{\"send\":{\"id\":\"01J00000000000000000000000\",\"content\":\"hello\"}}}}", .message);
    try expectCommandTag("{\"command\":{\"message\":{\"milestone\":{\"name\":\"compiled\"}}}}", .message);
    try expectCommandTag("{\"command\":{\"relationship\":{\"action\":\"detach\",\"id\":\"01J00000000000000000000000\"}}}", .relationship);
    try expectCommandTag("{\"command\":{\"configure\":{\"id\":\"01J00000000000000000000000\",\"name\":\"renamed\"}}}", .configure);
    try expectCommandTag("{\"command\":{\"lifecycle\":{\"id\":\"01J00000000000000000000000\",\"action\":\"cancel\"}}}", .lifecycle);
}

test "decode preserves configured child permission mode and defaults create to yolo" {
    const alloc = std.testing.allocator;
    const default_result = try decode(
        .{ .allocator = alloc },
        "{\"command\":{\"create\":{\"name\":\"worker\",\"mode\":\"persistent\"}}}",
    );
    switch (default_result) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(
                types.PermissionMode.yolo,
                input.as(Input).command.create.configuration.permission_mode,
            );
        },
    }

    const configured_result = try decode(
        .{ .allocator = alloc },
        "{\"command\":{\"configure\":{\"id\":\"01J00000000000000000000000\",\"permission_mode\":\"ask\"}}}",
    );
    switch (configured_result) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(
                types.PermissionMode.ask,
                input.as(Input).command.configure.permission_mode.?,
            );
        },
    }
    try expectDecodeFailure(
        "{\"command\":{\"create\":{\"name\":\"worker\",\"mode\":\"persistent\",\"permission_mode\":\"unsafe\"}}}",
        "invalid_enum",
    );
}

test "decode rejects branch ambiguity unknown fields and missing inspect id" {
    try expectDecodeFailure("{\"command\":{}}", "invalid_branch_selection");
    try expectDecodeFailure("{\"command\":{\"inspect\":{\"id\":\"01J00000000000000000000000\",\"sections\":[\"status\"]},\"lifecycle\":{\"id\":\"01J00000000000000000000000\",\"action\":\"cancel\"}}}", "invalid_branch_selection");
    try expectDecodeFailure("{\"command\":{\"message\":{\"send\":{\"id\":\"01J00000000000000000000000\",\"content\":\"hello\"},\"milestone\":{\"name\":\"compiled\"}}}}", "invalid_nested_branch_selection");
    try expectDecodeFailure("{\"command\":{\"inspect\":{\"sections\":[\"status\"]}}}", "missing_inspect_id");
    try expectDecodeFailure("{\"command\":{\"inspect\":{\"id\":\"01J00000000000000000000000\",\"sections\":[\"status\"],\"extra\":true}}}", "unknown_field");
    try expectDecodeFailure("{\"command\":{\"inspect\":{\"id\":\"01J00000000000000000000000\",\"sections\":[\"status\"],\"wait\":{\"until\":\"settled\"}}}}", "invalid_inspect_wait");
    try expectDecodeFailure("{\"command\":{\"inspect\":{\"id\":\"01J00000000000000000000000\",\"sections\":[\"status\"],\"wait\":{\"timeout_ms\":30000}}}}", "invalid_inspect_wait");
    try expectDecodeFailure("{\"command\":{\"inspect\":{\"id\":\"01J00000000000000000000000\",\"sections\":[\"messages\"],\"wait\":{\"until\":\"settled\",\"timeout_ms\":30000}}}}", "invalid_inspect_wait");
    try expectDecodeFailure("{\"command\":{\"inspect\":{\"id\":\"01J00000000000000000000000\",\"sections\":[\"status\"],\"wait\":{\"until\":\"settled\",\"timeout_ms\":30000,\"extra\":true}}}}", "unknown_field");
    try expectDecodeFailure("{\"command\":{\"create\":{\"mode\":\"persistent\"}}}", "missing_name");
    try expectDecodeFailure("{\"command\":{\"create\":{\"name\":\"worker\"}}}", "missing_mode");
    try expectDecodeFailure("{\"command\":{\"create\":{\"name\":\"worker\",\"mode\":\"one_off\"}}}", "missing_one_off_prompt");
    try expectDecodeFailure("{\"command\":{\"relationship\":{\"action\":\"adopt\",\"id\":\"01J00000000000000000000000\"}}}", "invalid_enum");
    try expectDecodeFailure("{\"command\":{\"lifecycle\":{\"id\":\"01J00000000000000000000000\",\"action\":\"delete\"}}}", "invalid_enum");
}

test "decode accepts every relationship and lifecycle action" {
    inline for (.{
        "{\"command\":{\"relationship\":{\"action\":\"attach\",\"id\":\"01J00000000000000000000000\"}}}",
        "{\"command\":{\"relationship\":{\"action\":\"detach\",\"id\":\"01J00000000000000000000000\"}}}",
        "{\"command\":{\"relationship\":{\"action\":\"reparent\",\"id\":\"01J00000000000000000000000\",\"parent_id\":\"01J00000000000000000000001\"}}}",
    }) |args| {
        try expectCommandTag(args, .relationship);
    }
    inline for (.{ "cancel", "resume", "close", "reopen" }) |action| {
        const args = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"command\":{{\"lifecycle\":{{\"id\":\"01J00000000000000000000000\",\"action\":\"{s}\"}}}}}}",
            .{action},
        );
        defer std.testing.allocator.free(args);
        try expectCommandTag(args, .lifecycle);
    }
}

test "ordinary milestone-shaped content remains an ordinary send" {
    const alloc = std.testing.allocator;
    const result = try decode(
        .{ .allocator = alloc },
        "{\"command\":{\"message\":{\"send\":{\"id\":\"01J00000000000000000000000\",\"content\":\"milestone: compiled\"}}}}",
    );
    switch (result) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            switch (input.as(Input).command.message) {
                .send => |send| try std.testing.expectEqualStrings("milestone: compiled", send.content),
                .milestone => return error.TestUnexpectedResult,
            }
        },
    }
}

test "decode rejects oversized content before runtime effects" {
    const alloc = std.testing.allocator;
    const content = try alloc.alloc(u8, domain.max_message_bytes + 1);
    defer alloc.free(content);
    @memset(content, 'x');
    const args = try std.fmt.allocPrint(alloc, "{{\"command\":{{\"message\":{{\"send\":{{\"id\":\"01J00000000000000000000000\",\"content\":\"{s}\"}}}}}}}}", .{content});
    defer alloc.free(args);
    try expectDecodeFailure(args, "invalid_message");
}

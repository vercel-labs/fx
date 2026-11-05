const std = @import("std");
const model_contract = @import("../../core/subagent/model_contract.zig");
const tool_provider = @import("../../core/subagent/tool_provider.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    request: model_contract.Request,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        self.request.deinit(alloc);
        self.* = undefined;
    }
};

const DecodeError = error{
    OutOfMemory,
    InvalidFieldType,
    MissingField,
    UnknownField,
    InvalidEnum,
};

/// Fields each action takes. The flat model schema for this tool in
/// src/builtins/tools.zig advertises exactly these, which a test there checks.
pub const message_fields = [_][]const u8{ "action", "agent", "instructions", "message", "report", "model", "effort", "profile" };
/// wait wakes on the next report or message from any subagent. Models
/// often name the one they started, so agent is accepted and does not
/// narrow the wait; the report that arrives names its sender.
pub const wait_fields = [_][]const u8{ "action", "agent" };
pub const status_fields = [_][]const u8{ "action", "agent" };
pub const stop_fields = [_][]const u8{ "action", "agent" };
pub const close_fields = [_][]const u8{ "action", "agent" };

/// Where a rejected call went wrong, so the correction can name it.
const Problem = struct {
    field: []const u8 = "",
    action: []const u8 = "",
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch {
        return decodeFailure(ctx, "invalid_json", null) catch return error.OutOfMemory;
    };
    defer parsed.deinit();

    var problem: Problem = .{};
    const request_input = parseRoot(parsed.value, &problem) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("subagent", "request decode rejected code={s} field={s}", .{ decodeErrorCode(err), problem.field });
        const correction = try problemText(arena, err, problem);
        return decodeFailure(ctx, decodeErrorCode(err), correction) catch return error.OutOfMemory;
    };
    const request = model_contract.validateRequest(ctx.allocator, request_input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("subagent", "request validation rejected code={s}", .{validationErrorCode(err)});
        return decodeFailure(ctx, validationErrorCode(err), null) catch return error.OutOfMemory;
    };
    errdefer {
        var owned = request;
        owned.deinit(ctx.allocator);
    }

    const input = try ctx.allocator.create(Input);
    input.* = .{ .request = request };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn decodeFailure(
    ctx: tool_dispatch.DispatchContext,
    code: []const u8,
    correction: ?[]const u8,
) !tool_dispatch.DecodeResult {
    return .{ .failure = try model_contract.encodeResultAlloc(ctx.allocator, .{
        .ok = false,
        .result = correction,
        .error_code = code,
    }) };
}

/// Pure: the correction a model sees for a call that failed to decode.
fn problemText(arena: Allocator, err: DecodeError, problem: Problem) Allocator.Error![]const u8 {
    const fields = "message takes agent, message, instructions, report, model, effort, and profile; wait and status take an optional agent; stop and close take agent.";
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidEnum => "action must be \"message\", \"wait\", \"status\", \"stop\", or \"close\".",
        error.MissingField => if (std.mem.eql(u8, problem.field, "action"))
            "action is required: \"message\" with agent and message, \"wait\", \"status\", or \"stop\" or \"close\" with agent."
        else if (std.mem.eql(u8, problem.action, "stop"))
            "stop needs agent."
        else if (std.mem.eql(u8, problem.action, "close"))
            "close needs agent."
        else
            "message needs agent and message.",
        error.UnknownField => if (problem.action.len == 0)
            try arena.print("{s} cannot sit beside request. Put every field at the top level without request.", .{problem.field})
        else
            try arena.print("{s} does not apply to {s}. " ++ fields, .{ problem.field, problem.action }),
        error.InvalidFieldType => if (problem.field.len == 0)
            "subagent arguments must be a JSON object."
        else if (std.mem.eql(u8, problem.field, "request"))
            "request must be an object. Put the fields at the top level instead."
        else
            try arena.print("{s} must be a string.", .{problem.field}),
    };
}

fn decodeErrorCode(err: DecodeError) []const u8 {
    return switch (err) {
        error.OutOfMemory => unreachable,
        error.InvalidFieldType => "invalid_field_type",
        error.MissingField => "missing_field",
        error.UnknownField => "unknown_field",
        error.InvalidEnum => "invalid_enum",
    };
}

fn validationErrorCode(err: model_contract.ValidationError) []const u8 {
    return switch (err) {
        error.OutOfMemory => unreachable,
        error.InvalidAgent => "invalid_agent",
        error.InvalidReport => "invalid_report",
        error.InvalidParentMessage => "invalid_parent_message",
        error.InvalidInstructions => "invalid_instructions",
        error.InvalidMessage => "invalid_message",
        error.InvalidModel => "invalid_model",
        error.InvalidEffort => "invalid_effort",
        error.InvalidProfile => "invalid_profile",
    };
}

fn parseRoot(value: std.json.Value, problem: *Problem) DecodeError!model_contract.RequestInput {
    const root = try objectValue(value);
    const request = if (root.get("request")) |request_value| blk: {
        try rejectUnknown(root, &.{"request"}, problem);
        problem.field = "request";
        const object = try objectValue(request_value);
        problem.field = "";
        break :blk object;
    } else root;
    const action = try requiredString(request, "action", problem);

    if (std.mem.eql(u8, action, "message")) {
        problem.action = "message";
        try rejectOutsideAction(request, &message_fields, problem);
        return .{ .message = .{
            .agent = try requiredString(request, "agent", problem),
            .instructions = try optionalString(request, "instructions", problem),
            .message = try requiredString(request, "message", problem),
            .report = try optionalString(request, "report", problem),
            .model = try optionalString(request, "model", problem),
            .effort = try optionalString(request, "effort", problem),
            .profile = try optionalString(request, "profile", problem),
        } };
    }
    if (std.mem.eql(u8, action, "wait")) {
        problem.action = "wait";
        try rejectOutsideAction(request, &wait_fields, problem);
        if (try optionalString(request, "agent", problem)) |agent| {
            debug_trace.logf(
                "subagent",
                "wait ignored agent=\"{f}\": wait returns the next report from any subagent",
                .{std.zig.fmtString(agent)},
            );
        }
        return .wait;
    }
    if (std.mem.eql(u8, action, "status")) {
        problem.action = "status";
        try rejectOutsideAction(request, &status_fields, problem);
        return .{ .status = .{ .agent = try optionalString(request, "agent", problem) } };
    }
    if (std.mem.eql(u8, action, "stop")) {
        problem.action = "stop";
        try rejectOutsideAction(request, &stop_fields, problem);
        return .{ .stop = .{ .agent = try requiredString(request, "agent", problem) } };
    }
    if (std.mem.eql(u8, action, "close")) {
        problem.action = "close";
        try rejectOutsideAction(request, &close_fields, problem);
        return .{ .close = .{ .agent = try requiredString(request, "agent", problem) } };
    }
    return error.InvalidEnum;
}

fn objectValue(value: std.json.Value) DecodeError!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidFieldType;
}

fn stringValue(value: std.json.Value) DecodeError![]const u8 {
    return if (value == .string) value.string else error.InvalidFieldType;
}

fn requiredString(
    object: std.json.ObjectMap,
    key: []const u8,
    problem: *Problem,
) DecodeError![]const u8 {
    problem.field = key;
    const value = object.get(key) orelse return error.MissingField;
    return stringValue(value);
}

fn optionalString(
    object: std.json.ObjectMap,
    key: []const u8,
    problem: *Problem,
) DecodeError!?[]const u8 {
    problem.field = key;
    const value = object.get(key) orelse return null;
    return try stringValue(value);
}

fn rejectUnknown(
    object: std.json.ObjectMap,
    allowed: []const []const u8,
    problem: *Problem,
) DecodeError!void {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (listsField(allowed, entry.key_ptr.*)) continue;
        problem.field = entry.key_ptr.*;
        return error.UnknownField;
    }
}

/// Rejects the fields `action` does not take, except a known subagent field
/// set to an empty string or false: it asks for nothing, so it means the same
/// as leaving it out, as in the shell decoder. Some models fill every
/// advertised field this way. Unknown names and any other value are still
/// rejected, since they can carry intent that ignoring them would lose.
fn rejectOutsideAction(
    request: std.json.ObjectMap,
    allowed: []const []const u8,
    problem: *Problem,
) DecodeError!void {
    var fields = request.iterator();
    while (fields.next()) |entry| {
        const name = entry.key_ptr.*;
        if (listsField(allowed, name)) continue;
        if (listsField(message_fields[1..], name) and tool_args.isEmptyArgumentValue(entry.value_ptr.*)) continue;
        problem.field = name;
        return error.UnknownField;
    }
}

fn listsField(names: []const []const u8, name: []const u8) bool {
    for (names) |listed| {
        if (std.mem.eql(u8, listed, name)) return true;
    }
    return false;
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
        const body = model_contract.encodeResultAlloc(ctx.allocator, .{
            .ok = false,
            .error_code = "host_unavailable",
        }) catch return error.OutOfMemory;
        return .{ .failure = body };
    };
    const request = &erased.as(Input).request;
    debug_trace.logf(
        "subagent",
        "request accepted action={s} agent={s} model_override={s} effort_override={s}",
        .{
            @tagName(request.action()),
            request.agentName() orelse "none",
            request.override().model orelse "none",
            if (request.override().effort) |effort| effort.label() else "none",
        },
    );
    const result = try provider.execute(
        ctx.allocator,
        request,
        ctx.tool_call_id,
    );
    return switch (result.status) {
        .success => .{ .success = result.body },
        .failure => .{ .failure = result.body },
    };
}

/// `wait` and `status` change nothing.
pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return switch (erased.as(Input).request) {
        .wait, .status => true,
        .message, .stop, .close => false,
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
            const needle = try alloc.print("\"error_code\":\"{s}\"", .{code});
            defer alloc.free(needle);
            try std.testing.expect(std.mem.find(u8, message, needle) != null);
        },
    }
}

fn expectRequestTag(
    args_json: []const u8,
    expected: model_contract.Action,
) !void {
    const alloc = std.testing.allocator;
    const result = try decode(.{ .allocator = alloc }, args_json);
    switch (result) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(expected, input.as(Input).request.action());
        },
    }
}

test "call executes a validated managed request through the provider" {
    const Fixture = struct {
        calls: usize = 0,
        request: ?*model_contract.Request = null,
        invocation_id: ?[]const u8 = null,

        fn execute(
            raw_context: ?*anyopaque,
            alloc: Allocator,
            request: *model_contract.Request,
            invocation_id: []const u8,
        ) Allocator.Error!tool_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            self.calls += 1;
            self.request = request;
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
        "{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"review this\"}}",
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
                .rich => return error.TestUnexpectedRichResult,
                .success => |body| try std.testing.expectEqualStrings("{\"ok\":true}", body),
                .failure => return error.TestUnexpectedResult,
            }
            try std.testing.expect(fixture.request.? == &input.as(Input).request);
            try std.testing.expectEqual(model_contract.Action.message, fixture.request.?.action());
            try std.testing.expectEqualStrings("call-1", fixture.invocation_id.?);
        },
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "decode accepts the five actions and nothing else" {
    try expectRequestTag("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"next\"}}", .message);
    try expectRequestTag("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"instructions\":\"Review strictly.\",\"message\":\"next\"}}", .message);
    try expectRequestTag("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"next\",\"model\":\"gpt-5.6-sol-fast\"}}", .message);
    try expectRequestTag("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"next\",\"effort\":\"high\",\"report\":\"never\"}}", .message);
    try expectRequestTag("{\"action\":\"wait\"}", .wait);
    try expectRequestTag("{\"action\":\"status\"}", .status);
    try expectRequestTag("{\"action\":\"status\",\"agent\":\"reviewer\"}", .status);
    try expectRequestTag("{\"action\":\"stop\",\"agent\":\"reviewer\"}", .stop);
    try expectRequestTag("{\"action\":\"close\",\"agent\":\"reviewer\"}", .close);
    try expectDecodeFailure("{\"request\":{\"action\":\"run\",\"task\":\"do it\"}}", "invalid_enum");
    try expectDecodeFailure("{\"request\":{\"action\":\"stop\",\"child_id\":\"01J00000000000000000000000\"}}", "unknown_field");
    try expectDecodeFailure("{\"request\":{\"action\":\"cancel\",\"child_id\":\"01J00000000000000000000000\"}}", "invalid_enum");
}

fn expectCorrection(args_json: []const u8, code: []const u8, correction: []const u8) !void {
    const alloc = std.testing.allocator;
    try expectDecodeFailure(args_json, code);
    const result = try decode(.{ .allocator = alloc }, args_json);
    const body = switch (result) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| message,
    };
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const text = parsed.value.object.get("result").?.string;
    try std.testing.expect(std.mem.find(u8, text, correction) != null);
}

test "decode accepts flat calls and names what a rejected call got wrong" {
    try expectRequestTag("{\"action\":\"message\",\"agent\":\"reviewer\",\"instructions\":\"Review strictly.\",\"message\":\"next\"}", .message);
    try expectCorrection("{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"next\",\"task\":\"x\"}", "unknown_field", "task does not apply to message. message takes agent");
    try expectRequestTag("{\"action\":\"wait\",\"agent\":\"reviewer\"}", .wait);
    try expectCorrection("{\"action\":\"wait\",\"agent\":7}", "invalid_field_type", "agent must be a string.");
    try expectCorrection("{\"action\":\"wait\",\"message\":\"x\"}", "unknown_field", "message does not apply to wait.");
    try expectCorrection("{\"action\":\"stop\"}", "missing_field", "stop needs agent.");
    try expectCorrection("{\"action\":\"close\"}", "missing_field", "close needs agent.");
    try expectCorrection("{\"action\":\"message\",\"agent\":\"reviewer\"}", "missing_field", "message needs agent and message.");
    try expectCorrection("{\"task\":\"x\"}", "missing_field", "action is required");
    try expectCorrection("{\"request\":{\"action\":\"wait\"},\"task\":\"y\"}", "unknown_field", "task cannot sit beside request");
    try expectCorrection("{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":7}", "invalid_field_type", "message must be a string.");
    try expectCorrection("{\"request\":null}", "invalid_field_type", "request must be an object");
    try expectCorrection("[]", "invalid_field_type", "must be a JSON object");
    try expectCorrection("{\"action\":\"run\"}", "invalid_enum", "action must be \"message\", \"wait\", \"status\", \"stop\", or \"close\"");
}

test "decode ignores empty fields the action does not take" {
    try expectRequestTag("{\"action\":\"wait\",\"message\":\"\",\"instructions\":\"\",\"model\":\"\"}", .wait);
    try expectRequestTag("{\"action\":\"stop\",\"agent\":\"reviewer\",\"message\":\"\",\"report\":false}", .stop);
    try expectRequestTag("{\"action\":\"status\",\"profile\":\"\"}", .status);
    // Text, a true flag, or an unknown name still does not belong to the action.
    try expectCorrection("{\"action\":\"wait\",\"message\":\"x\"}", "unknown_field", "message does not apply to wait.");
    try expectCorrection("{\"action\":\"close\",\"agent\":\"reviewer\",\"report\":true}", "unknown_field", "report does not apply to close.");
    try expectCorrection("{\"action\":\"wait\",\"task\":\"\"}", "unknown_field", "task does not apply to wait.");
    // Fields beside a request wrapper are still rejected.
    try expectCorrection("{\"request\":{\"action\":\"wait\"},\"message\":\"\"}", "unknown_field", "message cannot sit beside request");
}

test "decode rejects invalid creation overrides and report rules" {
    try expectDecodeFailure("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"do it\",\"model\":\"\"}}", "invalid_model");
    try expectDecodeFailure("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"do it\",\"effort\":\"not an effort!\"}}", "invalid_effort");
    try expectDecodeFailure("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"next\",\"model\":7}}", "invalid_field_type");
    try expectDecodeFailure("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"do it\",\"provider\":\"gateway\"}}", "unknown_field");
    try expectDecodeFailure("{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"do it\",\"report\":\"often\"}", "invalid_report");
    try expectDecodeFailure("{\"action\":\"message\",\"agent\":\"parent\",\"message\":\"done\",\"report\":\"never\"}", "invalid_parent_message");
}

test "decode rejects manager input cross-action fields and unknown actions" {
    try expectDecodeFailure("{\"command\":{\"create\":{\"name\":\"worker\"}}}", "missing_field");
    try expectDecodeFailure("{\"request\":{\"action\":\"wait\",\"child_id\":\"01J00000000000000000000000\",\"task\":\"wrong\"}}", "unknown_field");
    try expectDecodeFailure("{\"request\":{\"action\":\"inspect\",\"child_id\":\"01J00000000000000000000000\"}}", "invalid_enum");
    try expectDecodeFailure("{\"request\":null}", "invalid_field_type");
}

test "call reports compact host unavailability" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"request\":{\"action\":\"wait\"}}",
    );
    switch (decoded) {
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const result = try call(.{ .allocator = alloc }, input);
            defer result.deinit(alloc);
            switch (result) {
                .rich => return error.TestUnexpectedRichResult,
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

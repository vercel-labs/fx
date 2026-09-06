const std = @import("std");
const model_contract = @import("../../core/subagent/model_contract.zig");
const tool_provider = @import("../../core/subagent/tool_provider.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

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

    const request_input = parseRoot(parsed.value) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return decodeFailure(ctx, decodeErrorCode(err)) catch return error.OutOfMemory;
    };
    const request = model_contract.validateRequest(ctx.allocator, request_input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return decodeFailure(ctx, validationErrorCode(err)) catch return error.OutOfMemory;
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
) !tool_dispatch.DecodeResult {
    return .{ .failure = try model_contract.encodeResultAlloc(ctx.allocator, .{
        .ok = false,
        .error_code = code,
    }) };
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
        error.InvalidTask => "invalid_task",
        error.InvalidAgent => "invalid_agent",
        error.InvalidInstructions => "invalid_instructions",
        error.InvalidMessage => "invalid_message",
    };
}

fn parseRoot(value: std.json.Value) DecodeError!model_contract.RequestInput {
    const root = try objectValue(value);
    const request = if (root.get("request")) |request_value| blk: {
        try rejectUnknown(root, &.{"request"});
        break :blk try objectValue(request_value);
    } else root;
    const action = try requiredString(request, "action");

    if (std.mem.eql(u8, action, "run")) {
        try rejectUnknown(request, &.{ "action", "task" });
        return .{ .run = .{
            .task = try requiredString(request, "task"),
        } };
    }
    if (std.mem.eql(u8, action, "message")) {
        try rejectUnknown(request, &.{ "action", "agent", "instructions", "message" });
        return .{ .message = .{
            .agent = try requiredString(request, "agent"),
            .instructions = try optionalString(request, "instructions"),
            .message = try requiredString(request, "message"),
        } };
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
) DecodeError![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return stringValue(value);
}

fn optionalString(
    object: std.json.ObjectMap,
    key: []const u8,
) DecodeError!?[]const u8 {
    const value = object.get(key) orelse return null;
    return try stringValue(value);
}

fn rejectUnknown(
    object: std.json.ObjectMap,
    allowed: []const []const u8,
) DecodeError!void {
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
        const body = model_contract.encodeResultAlloc(ctx.allocator, .{
            .ok = false,
            .error_code = "host_unavailable",
        }) catch return error.OutOfMemory;
        return .{ .failure = body };
    };
    const result = try provider.execute(
        ctx.allocator,
        &erased.as(Input).request,
        ctx.tool_call_id,
    );
    return switch (result.status) {
        .success => .{ .success = result.body },
        .failure => .{ .failure = result.body },
    };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
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
        "{\"request\":{\"action\":\"run\",\"task\":\"review this\"}}",
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
            try std.testing.expectEqual(model_contract.Action.run, fixture.request.?.action());
            try std.testing.expectEqualStrings("call-1", fixture.invocation_id.?);
        },
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "decode accepts only delegation intents" {
    try expectRequestTag("{\"request\":{\"action\":\"run\",\"task\":\"do it\"}}", .run);
    try expectRequestTag("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"message\":\"next\"}}", .message);
    try expectRequestTag("{\"request\":{\"action\":\"message\",\"agent\":\"reviewer\",\"instructions\":\"Review strictly.\",\"message\":\"next\"}}", .message);
    try expectDecodeFailure("{\"request\":{\"action\":\"wait\",\"child_id\":\"01J00000000000000000000000\"}}", "invalid_enum");
    try expectDecodeFailure("{\"request\":{\"action\":\"stop\",\"child_id\":\"01J00000000000000000000000\"}}", "invalid_enum");
    try expectDecodeFailure("{\"request\":{\"action\":\"cancel\",\"child_id\":\"01J00000000000000000000000\"}}", "invalid_enum");
}

test "decode rejects manager input cross-action fields and unknown actions" {
    try expectDecodeFailure("{\"command\":{\"create\":{\"name\":\"worker\"}}}", "missing_field");
    try expectDecodeFailure("{\"request\":{\"action\":\"wait\",\"child_id\":\"01J00000000000000000000000\",\"task\":\"wrong\"}}", "invalid_enum");
    try expectDecodeFailure("{\"request\":{\"action\":\"inspect\",\"child_id\":\"01J00000000000000000000000\"}}", "invalid_enum");
    try expectDecodeFailure("{\"request\":{\"action\":\"wait\"}}", "invalid_enum");
    try expectDecodeFailure("{\"request\":null}", "invalid_field_type");
}

test "call reports compact host unavailability" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"request\":{\"action\":\"run\",\"task\":\"do it\"}}",
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

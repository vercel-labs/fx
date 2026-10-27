const std = @import("std");
const model_contract = @import("../../core/subagent/model_contract.zig");
const tool_provider = @import("../../core/subagent/tool_provider.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");

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

/// Fields each op takes. The flat model schema for this tool in
/// src/builtins/tools.zig advertises exactly these, which a test there checks.
pub const run_fields = [_][]const u8{ "op", "message", "label", "model", "effort", "schema" };
pub const spawn_fields = [_][]const u8{ "op", "message", "label", "instructions", "model", "effort", "schema" };
pub const send_fields = [_][]const u8{ "op", "id", "message" };
pub const list_fields = [_][]const u8{ "op", "scope" };
pub const id_fields = [_][]const u8{ "op", "id" };
pub const message_fields = [_][]const u8{ "op", "to", "message", "reply_to" };
pub const inbox_fields = [_][]const u8{ "op", "peek" };
pub const ops = [_][]const u8{ "run", "spawn", "send", "message", "list", "inspect", "inbox", "terminate" };

/// Where a rejected call went wrong, so the correction can name it.
const Problem = struct {
    field: []const u8 = "",
    op: []const u8 = "",
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
    const request_input = parseRoot(arena, parsed.value, &problem) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("subagent", "fleet decode rejected code={s} field={s}", .{ decodeErrorCode(err), problem.field });
        const correction = try problemText(arena, err, problem);
        return decodeFailure(ctx, decodeErrorCode(err), correction) catch return error.OutOfMemory;
    };
    const request = model_contract.validateRequest(ctx.allocator, request_input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("subagent", "fleet validation rejected code={s}", .{validationErrorCode(err)});
        return decodeFailure(ctx, validationErrorCode(err), validationText(err)) catch return error.OutOfMemory;
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

const op_fields_text = "run takes message, label, model, effort and schema; spawn takes message, label, instructions, model, effort and schema; send takes id and message; message takes to, message and reply_to; inspect and terminate take id; list takes scope; inbox takes peek.";
const ops_text = "run, spawn, send, message, list, inspect, inbox, terminate";

/// Pure: the correction a model sees for a call that failed to decode.
fn problemText(arena: Allocator, err: DecodeError, problem: Problem) Allocator.Error![]const u8 {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidEnum => if (std.mem.eql(u8, problem.field, "scope"))
            "scope must be owned or visible."
        else
            "op must be one of " ++ ops_text ++ ".",
        error.MissingField => if (std.mem.eql(u8, problem.field, "op"))
            "op is required: one of " ++ ops_text ++ "."
        else
            try arena.print("op \"{s}\" requires {s}.", .{ problem.op, problem.field }),
        error.UnknownField => try arena.print("op \"{s}\" does not accept {s}. " ++ op_fields_text, .{ problem.op, problem.field }),
        error.InvalidFieldType => if (problem.field.len == 0)
            "fleet arguments must be a JSON object."
        else if (std.mem.eql(u8, problem.field, "schema"))
            "schema must be a JSON Schema object."
        else if (std.mem.eql(u8, problem.field, "peek"))
            "peek must be true or false."
        else
            try arena.print("{s} must be a string.", .{problem.field}),
    };
}

fn validationText(err: model_contract.ValidationError) ?[]const u8 {
    return switch (err) {
        error.InvalidAgent => "label must be 1 to 48 ASCII letters, digits, underscores or hyphens.",
        error.InvalidId => "id must name a worker, as fleet op \"list\" shows it; to must name an agent, as fleet op \"list\" scope \"visible\" shows it, or be parent, root or all.",
        else => null,
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
        error.InvalidTask => "invalid_message",
        error.InvalidAgent => "invalid_label",
        error.InvalidInstructions => "invalid_instructions",
        error.InvalidMessage => "invalid_message",
        error.InvalidModel => "invalid_model",
        error.InvalidEffort => "invalid_effort",
        error.InvalidId => "invalid_id",
    };
}

fn parseRoot(arena: Allocator, value: std.json.Value, problem: *Problem) DecodeError!model_contract.RequestInput {
    const root = try objectValue(value);
    const op = try requiredString(root, "op", problem);
    problem.op = op;
    if (std.mem.eql(u8, op, "run")) {
        try rejectUnknown(root, &run_fields, problem);
        const message = try withSchema(arena, try requiredString(root, "message", problem), root, problem);
        const model = try optionalString(root, "model", problem);
        const effort = try optionalString(root, "effort", problem);
        // A labelled run is a turn on that named worker, spawned when new.
        if (try optionalString(root, "label", problem)) |label| return .{ .message = .{
            .agent = label,
            .message = message,
            .model = model,
            .effort = effort,
        } };
        return .{ .run = .{ .task = message, .model = model, .effort = effort } };
    }
    if (std.mem.eql(u8, op, "spawn")) {
        try rejectUnknown(root, &spawn_fields, problem);
        return .{ .spawn = .{
            .message = try withSchema(arena, try requiredString(root, "message", problem), root, problem),
            .label = try optionalString(root, "label", problem),
            .instructions = try optionalString(root, "instructions", problem),
            .model = try optionalString(root, "model", problem),
            .effort = try optionalString(root, "effort", problem),
        } };
    }
    if (std.mem.eql(u8, op, "send")) {
        try rejectUnknown(root, &send_fields, problem);
        return .{ .send = .{
            .id = try requiredString(root, "id", problem),
            .message = try requiredString(root, "message", problem),
        } };
    }
    if (std.mem.eql(u8, op, "list")) {
        try rejectUnknown(root, &list_fields, problem);
        const scope = (try optionalString(root, "scope", problem)) orelse "owned";
        if (std.mem.eql(u8, scope, "visible")) return .peers;
        if (!std.mem.eql(u8, scope, "owned")) return error.InvalidEnum;
        return .list;
    }
    if (std.mem.eql(u8, op, "message")) {
        try rejectUnknown(root, &message_fields, problem);
        return .{ .peer_message = .{
            .to = try requiredString(root, "to", problem),
            .message = try requiredString(root, "message", problem),
            .reply_to = try optionalString(root, "reply_to", problem),
        } };
    }
    if (std.mem.eql(u8, op, "inbox")) {
        try rejectUnknown(root, &inbox_fields, problem);
        problem.field = "peek";
        const peek = root.get("peek") orelse return .{ .inbox = false };
        return switch (peek) {
            .bool => |flag| .{ .inbox = flag },
            .null => .{ .inbox = false },
            else => error.InvalidFieldType,
        };
    }
    if (std.mem.eql(u8, op, "inspect")) {
        try rejectUnknown(root, &id_fields, problem);
        return .{ .inspect = try requiredString(root, "id", problem) };
    }
    if (std.mem.eql(u8, op, "terminate")) {
        try rejectUnknown(root, &id_fields, problem);
        return .{ .terminate = try requiredString(root, "id", problem) };
    }
    return error.InvalidEnum;
}

/// The message with the instruction to answer in JSON matching `schema`,
/// as `harness.agent(schema=)` asks.
fn withSchema(arena: Allocator, message: []const u8, root: std.json.ObjectMap, problem: *Problem) DecodeError![]const u8 {
    const schema = root.get("schema") orelse return message;
    if (schema != .object) {
        problem.field = "schema";
        return error.InvalidFieldType;
    }
    var json: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(schema, .{}, &json.writer) catch return error.OutOfMemory;
    return model_contract.withSchemaAlloc(arena, message, json.written()) catch error.OutOfMemory;
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
    if (value == .null) return null;
    return try stringValue(value);
}

fn rejectUnknown(
    object: std.json.ObjectMap,
    allowed: []const []const u8,
    problem: *Problem,
) DecodeError!void {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (entry.value_ptr.* == .null) continue;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
        } else {
            problem.field = entry.key_ptr.*;
            return error.UnknownField;
        }
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
    const request = &erased.as(Input).request;
    debug_trace.logf(
        "subagent",
        "fleet request accepted op={s} agent={s} model_override={s} effort_override={s}",
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

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return switch (erased.as(Input).request) {
        .list, .inspect, .peers => true,
        .inbox => |peek| peek,
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
            const needle = try alloc.print("\"error_code\":\"{s}\"", .{code});
            defer alloc.free(needle);
            try std.testing.expect(std.mem.find(u8, message, needle) != null);
        },
    }
}

fn expectRequestTag(args_json: []const u8, expected: model_contract.Action) !void {
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

test "fleet decodes every op and names what a rejected call got wrong" {
    try expectRequestTag("{\"op\":\"run\",\"message\":\"do it\",\"effort\":\"high\"}", .run);
    try expectRequestTag("{\"op\":\"run\",\"message\":\"do it\",\"label\":\"reviewer\"}", .message);
    try expectRequestTag("{\"op\":\"spawn\",\"message\":\"fix the lexer\",\"label\":\"Parser_1\",\"instructions\":\"Be terse.\"}", .spawn);
    try expectRequestTag("{\"op\":\"spawn\",\"message\":\"fix it\",\"schema\":{\"type\":\"object\"}}", .spawn);
    try expectRequestTag("{\"op\":\"send\",\"id\":\"01J00000000000000000000001\",\"message\":\"also this\"}", .send);
    try expectRequestTag("{\"op\":\"list\"}", .list);
    try expectRequestTag("{\"op\":\"inspect\",\"id\":\"w\"}", .inspect);
    try expectRequestTag("{\"op\":\"terminate\",\"id\":\"w\"}", .terminate);
    try expectRequestTag("{\"op\":\"message\",\"to\":\"all\",\"message\":\"status?\",\"reply_to\":\"m1\"}", .peer_message);
    try expectRequestTag("{\"op\":\"inbox\",\"peek\":true}", .inbox);
    try expectRequestTag("{\"op\":\"list\",\"scope\":\"visible\"}", .peers);
    try expectRequestTag("{\"op\":\"list\",\"scope\":\"owned\"}", .list);
    try expectCorrection("{\"op\":\"list\",\"scope\":\"everyone\"}", "invalid_enum", "scope must be owned or visible.");
    try expectCorrection("{\"op\":\"message\",\"message\":\"x\"}", "missing_field", "op \"message\" requires to.");
    try expectCorrection("{\"op\":\"inbox\",\"peek\":\"yes\"}", "invalid_field_type", "peek must be true or false.");
    try expectCorrection("{\"op\":\"send\",\"id\":\"w\",\"message\":\"x\",\"label\":\"p\"}", "unknown_field", "op \"send\" does not accept label.");
    try expectCorrection("{\"op\":\"spawn\"}", "missing_field", "op \"spawn\" requires message.");
    try expectCorrection("{\"message\":\"x\"}", "missing_field", "op is required");
    try expectCorrection("{\"op\":\"wait\"}", "invalid_enum", "op must be one of");
    try expectCorrection("{\"op\":\"run\",\"message\":7}", "invalid_field_type", "message must be a string.");
    try expectCorrection("{\"op\":\"spawn\",\"message\":\"x\",\"schema\":\"json\"}", "invalid_field_type", "schema must be a JSON Schema object.");
    try expectCorrection("{\"op\":\"spawn\",\"message\":\"x\",\"label\":\"no spaces\"}", "invalid_label", "label must be 1 to 48");
    try expectCorrection("[]", "invalid_field_type", "must be a JSON object");
    try expectDecodeFailure("{\"op\":\"run\",\"message\":\"do it\",\"model\":\"\"}", "invalid_model");
    try expectDecodeFailure("{\"op\":\"run\",\"message\":\"do it\",\"effort\":\"not an effort!\"}", "invalid_effort");
    try expectDecodeFailure("{\"action\":\"run\",\"task\":\"old shape\"}", "missing_field");
}

test "a schema becomes the turn's instruction to answer in JSON" {
    const alloc = std.testing.allocator;
    const result = try decode(.{ .allocator = alloc }, "{\"op\":\"run\",\"message\":\"count files\",\"schema\":{\"type\":\"integer\"}}");
    switch (result) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const task = input.as(Input).request.run.task;
            try std.testing.expect(std.mem.startsWith(u8, task, "count files\n\n"));
            try std.testing.expect(std.mem.endsWith(u8, task, "{\"type\":\"integer\"}"));
        },
    }
}

test "call executes a validated request through the provider" {
    const Fixture = struct {
        calls: usize = 0,
        invocation_id: ?[]const u8 = null,
        action: ?model_contract.Action = null,

        fn execute(
            raw_context: ?*anyopaque,
            alloc: Allocator,
            request: *model_contract.Request,
            invocation_id: []const u8,
        ) Allocator.Error!tool_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            self.calls += 1;
            self.invocation_id = invocation_id;
            self.action = request.action();
            return .{ .status = .success, .body = try alloc.dupe(u8, "{\"ok\":true}") };
        }
    };
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc, .tool_call_id = "call-1" }, "{\"op\":\"spawn\",\"message\":\"review this\"}");
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
                .subagent_provider = .{ .context = &fixture, .execute_fn = Fixture.execute },
            }, input);
            defer result.deinit(alloc);
            try std.testing.expectEqualStrings("{\"ok\":true}", result.success);
            try std.testing.expectEqualStrings("call-1", fixture.invocation_id.?);
        },
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(model_contract.Action.spawn, fixture.action.?);
}

test "call reports compact host unavailability" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"op\":\"list\"}");
    switch (decoded) {
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const result = try call(.{ .allocator = alloc }, input);
            defer result.deinit(alloc);
            try std.testing.expect(std.mem.find(u8, result.failure, "\"error_code\":\"host_unavailable\"") != null);
        },
    }
}

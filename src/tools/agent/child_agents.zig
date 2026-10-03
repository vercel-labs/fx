//! The subagent tool with sub-engine children (`--subagents-v2`): launch up
//! to ten named fx children, type messages into them, wait for them, read
//! what they did, and stop them. The children runtime does the work; this
//! file only decodes requests and encodes results.

const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const children = @import("../../core/child_agents/runtime.zig");
const labels = @import("../../core/child_agents/labels.zig");
const types = @import("../../core/shared/types.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

pub const max_text_bytes: u32 = 64 * 1024;
pub const max_model_bytes: u32 = 256;
pub const default_wait_ms: u32 = 60_000;
pub const max_wait_ms: u32 = 600_000;
pub const max_name_bytes: u32 = children.max_name_bytes;

const name_rule = std.fmt.comptimePrint("Names are 1 to {d} lowercase letters, digits and hyphens, starting with a letter.", .{max_name_bytes});

pub const Request = union(enum) {
    launch: struct { name: []const u8, task: []const u8, model: ?[]const u8, effort: ?[]const u8 },
    send: struct { name: []const u8, message: []const u8 },
    wait: struct { names: []const []const u8, timeout_ms: u32 },
    read: struct { name: []const u8, what: children.Runtime.ReadKind },
    list,
    stop: struct { name: []const u8 },
};

/// A decoded request. Its strings live in `arena`.
pub const Input = struct {
    arena: std.heap.ArenaAllocator,
    request: Request,
};

const DecodeError = error{
    OutOfMemory,
    InvalidFieldType,
    MissingField,
    UnknownField,
    InvalidEnum,
    InvalidName,
    InvalidText,
    InvalidModel,
    InvalidEffort,
    InvalidTimeout,
    TooManyNames,
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const input = try ctx.allocator.create(Input);
    input.* = .{ .arena = .init(ctx.allocator), .request = undefined };
    var keep = false;
    defer if (!keep) {
        input.arena.deinit();
        ctx.allocator.destroy(input);
    };
    const arena = input.arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return failure(ctx.allocator, "invalid_json", "The arguments are not valid JSON.");
    };
    input.request = parseRequest(arena, parsed) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("child_agents", "request rejected code={s}", .{decodeCode(err)});
        return failure(ctx.allocator, decodeCode(err), decodeMessage(err));
    };
    keep = true;
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.arena.deinit();
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const host = ctx.child_agents orelse
        return failureResult(ctx.allocator, "host_unavailable", "Subagents are not available here.");
    const gpa = ctx.allocator;
    const runtime = host.runtime;
    const cancel = ctx.cancel_flag;
    switch (erased.as(Input).request) {
        .launch => |launch| {
            var settings = host.settings;
            if (launch.model) |model| settings.model = model;
            if (launch.effort) |effort| settings.effort = effort;
            const launched = runtime.launch(gpa, launch.name, launch.task, settings, cancel) catch |err|
                return runtimeFailure(gpa, err);
            defer launched.status.deinit(gpa);
            return success(gpa, .{ .ok = true, .delivery = launched.delivery, .child = statusJson(launched.status) });
        },
        .send => |send| {
            const delivery = runtime.send(send.name, send.message, host.settings.root_context, cancel) catch |err| return runtimeFailure(gpa, err);
            return success(gpa, .{ .ok = true, .name = send.name, .delivery = delivery });
        },
        .wait => |wait| {
            const waited = runtime.wait(gpa, wait.names, wait.timeout_ms, cancel) catch |err| return runtimeFailure(gpa, err);
            defer children.freeStatuses(gpa, waited.children);
            const statuses = try statusesJson(gpa, waited.children);
            defer gpa.free(statuses);
            return success(gpa, .{ .ok = true, .timed_out = waited.timed_out, .children = statuses });
        },
        .read => |read| {
            const result = runtime.read(gpa, read.name, read.what) catch |err| return runtimeFailure(gpa, err);
            defer result.deinit(gpa);
            return switch (result) {
                .final => |final| success(gpa, .{
                    .ok = true,
                    .name = read.name,
                    .final = final.text,
                    .truncated = final.truncated,
                    .turns_ended = final.turns_ended,
                }),
                .messages => |messages| success(gpa, .{ .ok = true, .name = read.name, .messages = messages }),
                .screen => |screen| success(gpa, .{ .ok = true, .name = read.name, .screen = screen }),
            };
        },
        .list => {
            const statuses = try runtime.list(gpa);
            defer children.freeStatuses(gpa, statuses);
            const encoded = try statusesJson(gpa, statuses);
            defer gpa.free(encoded);
            return success(gpa, .{ .ok = true, .children = encoded });
        },
        .stop => |stop| {
            const stopped = runtime.stop(gpa, stop.name) catch |err| return runtimeFailure(gpa, err);
            defer stopped.deinit(gpa);
            return success(gpa, .{ .ok = true, .name = stop.name, .session_id = stopped.session_id, .exit = exitJson(stopped.exit) });
        },
    }
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return switch (erased.as(Input).request) {
        .wait, .read, .list => true,
        .launch, .send, .stop => false,
    };
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn parseRequest(arena: Allocator, value: std.json.Value) DecodeError!Request {
    const root = try objectValue(value);
    const request = if (root.get("request")) |inner| blk: {
        try rejectUnknown(root, &.{"request"});
        break :blk try objectValue(inner);
    } else root;
    const action = std.meta.stringToEnum(std.meta.Tag(Request), try requiredString(request, "action")) orelse
        return error.InvalidEnum;
    switch (action) {
        .launch => {
            try rejectUnknown(request, &.{ "action", "name", "task", "model", "effort" });
            const model = try optionalString(request, "model");
            if (model) |text| if (text.len == 0 or text.len > max_model_bytes) return error.InvalidModel;
            const effort = try optionalString(request, "effort");
            if (effort) |text| if (types.ReasoningEffort.parse(text) == null) return error.InvalidEffort;
            return .{ .launch = .{
                .name = try nameField(request),
                .task = try textField(request, "task"),
                .model = model,
                .effort = effort,
            } };
        },
        .send => {
            try rejectUnknown(request, &.{ "action", "name", "message" });
            return .{ .send = .{ .name = try nameField(request), .message = try textField(request, "message") } };
        },
        .wait => {
            try rejectUnknown(request, &.{ "action", "names", "timeout_ms" });
            var names: std.ArrayList([]const u8) = .empty;
            if (request.get("names")) |list| {
                if (list != .array) return error.InvalidFieldType;
                if (list.array.items.len > children.max_children) return error.TooManyNames;
                for (list.array.items) |item| {
                    const name = try stringValue(item);
                    if (!children.validName(name)) return error.InvalidName;
                    try names.append(arena, name);
                }
            }
            const timeout_ms: u32 = if (request.get("timeout_ms")) |timeout| switch (timeout) {
                .integer => |ms| if (ms >= 0 and ms <= max_wait_ms) @intCast(ms) else return error.InvalidTimeout,
                else => return error.InvalidFieldType,
            } else default_wait_ms;
            return .{ .wait = .{ .names = names.items, .timeout_ms = timeout_ms } };
        },
        .read => {
            try rejectUnknown(request, &.{ "action", "name", "what" });
            const what = std.meta.stringToEnum(children.Runtime.ReadKind, try requiredString(request, "what")) orelse
                return error.InvalidEnum;
            return .{ .read = .{ .name = try nameField(request), .what = what } };
        },
        .list => {
            try rejectUnknown(request, &.{"action"});
            return .list;
        },
        .stop => {
            try rejectUnknown(request, &.{ "action", "name" });
            return .{ .stop = .{ .name = try nameField(request) } };
        },
    }
}

fn nameField(object: std.json.ObjectMap) DecodeError![]const u8 {
    const name = try requiredString(object, "name");
    if (!children.validName(name)) return error.InvalidName;
    return name;
}

fn textField(object: std.json.ObjectMap, key: []const u8) DecodeError![]const u8 {
    const text = try requiredString(object, key);
    if (text.len == 0 or text.len > max_text_bytes) return error.InvalidText;
    return text;
}

fn objectValue(value: std.json.Value) DecodeError!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidFieldType;
}

fn stringValue(value: std.json.Value) DecodeError![]const u8 {
    return if (value == .string) value.string else error.InvalidFieldType;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) DecodeError![]const u8 {
    return stringValue(object.get(key) orelse return error.MissingField);
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) DecodeError!?[]const u8 {
    return try stringValue(object.get(key) orelse return null);
}

fn rejectUnknown(object: std.json.ObjectMap, allowed: []const []const u8) DecodeError!void {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
        } else return error.UnknownField;
    }
}

fn decodeCode(err: DecodeError) []const u8 {
    return switch (err) {
        error.OutOfMemory => unreachable,
        error.InvalidFieldType => "invalid_field_type",
        error.MissingField => "missing_field",
        error.UnknownField => "unknown_field",
        error.InvalidEnum => "invalid_enum",
        error.InvalidName => "invalid_name",
        error.InvalidText => "invalid_text",
        error.InvalidModel => "invalid_model",
        error.InvalidEffort => "invalid_effort",
        error.InvalidTimeout => "invalid_timeout",
        error.TooManyNames => "too_many_names",
    };
}

fn decodeMessage(err: DecodeError) []const u8 {
    return switch (err) {
        error.InvalidName => name_rule,
        error.InvalidText => std.fmt.comptimePrint("Tasks and messages are 1 to {d} bytes.", .{max_text_bytes}),
        error.InvalidTimeout => std.fmt.comptimePrint("timeout_ms is 0 to {d}.", .{max_wait_ms}),
        error.TooManyNames => "Wait on at most 10 names.",
        else => "The request does not match the tool's schema.",
    };
}

/// Every error a runtime call returns.
const RuntimeError = children.LaunchError || children.SendError;

fn runtimeFailure(gpa: Allocator, err: RuntimeError) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const code: []const u8, const message: []const u8 = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => .{ "invalid_name", name_rule },
        error.NameTaken => .{ "name_taken", "A child with that name exists. Use send, or stop it first." },
        error.LimitReached => .{ "limit_reached", "Ten children are running. Stop one first." },
        error.NotFound => .{ "not_found", "No child has that name." },
        error.Exited => .{ "exited", "The child exited. Stop it to free its name." },
        error.Blocked => .{ "blocked", "The child is waiting on a permission or question prompt, which only the user answers. Wait for it, or stop it." },
        error.UnsupportedText => .{ "unsupported_text", "The text has control characters other than tab, newline and carriage return." },
        error.StartFailed => .{ "start_failed", "The child could not start." },
        error.StartTimedOut => .{ "start_timed_out", "The child did not start in time and was stopped." },
        error.Cancelled => .{ "cancelled", "The call was cancelled." },
    };
    return failureResult(gpa, code, message);
}

fn failure(gpa: Allocator, code: []const u8, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try encode(gpa, .{ .ok = false, .error_code = code, .message = message }) };
}

fn failureResult(gpa: Allocator, code: []const u8, message: []const u8) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try encode(gpa, .{ .ok = false, .error_code = code, .message = message }) };
}

fn success(gpa: Allocator, value: anytype) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .success = try encode(gpa, value) };
}

fn encode(gpa: Allocator, value: anytype) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
}

const ExitJson = struct { code: ?u8 = null, signal: ?u8 = null };

fn exitJson(exit: @import("sub_engine").Exit) ExitJson {
    return switch (exit) {
        .code => |code| .{ .code = code },
        .signal => |signal| .{ .signal = signal },
    };
}

const StatusJson = struct {
    name: []const u8,
    state: labels.State,
    blocked_reason: ?labels.BlockedReason,
    exit: ?ExitJson,
    session_id: ?[]const u8,
    turns_ended: u64,
    settled: bool,
    stopped: ?bool,
};

fn statusJson(status: children.Status) StatusJson {
    return .{
        .name = status.name,
        .state = status.state,
        .blocked_reason = status.blocked_reason,
        .exit = if (status.exit) |exit| exitJson(exit) else null,
        .session_id = status.session_id,
        .turns_ended = status.turns_ended,
        .settled = status.settled,
        .stopped = if (status.stopped) true else null,
    };
}

fn statusesJson(gpa: Allocator, statuses: []const children.Status) Allocator.Error![]StatusJson {
    const out = try gpa.alloc(StatusJson, statuses.len);
    for (statuses, out) |status, *item| item.* = statusJson(status);
    return out;
}

const testing = std.testing;

fn decodeForTest(args: []const u8) !union(enum) { input: *Input, code: []u8 } {
    const result = try decode(.{ .allocator = testing.allocator }, args);
    switch (result) {
        .input => |input| return .{ .input = input.as(Input) },
        .failure => |body| return .{ .code = body },
    }
}

fn expectRejected(args: []const u8, code: []const u8) !void {
    const result = try decodeForTest(args);
    switch (result) {
        .input => |input| {
            inputDeinit(input, testing.allocator);
            return error.TestExpectedError;
        },
        .code => |body| {
            defer testing.allocator.free(body);
            try testing.expect(std.mem.find(u8, body, code) != null);
        },
    }
}

test "requests decode into one typed action each" {
    const cases = [_]struct { args: []const u8, action: std.meta.Tag(Request) }{
        .{ .args = "{\"request\":{\"action\":\"launch\",\"name\":\"a1\",\"task\":\"fix it\",\"effort\":\"high\"}}", .action = .launch },
        .{ .args = "{\"action\":\"send\",\"name\":\"a1\",\"message\":\"more\"}", .action = .send },
        .{ .args = "{\"request\":{\"action\":\"wait\",\"names\":[\"a1\",\"b2\"],\"timeout_ms\":500}}", .action = .wait },
        .{ .args = "{\"request\":{\"action\":\"read\",\"name\":\"a1\",\"what\":\"screen\"}}", .action = .read },
        .{ .args = "{\"request\":{\"action\":\"list\"}}", .action = .list },
        .{ .args = "{\"request\":{\"action\":\"stop\",\"name\":\"a1\"}}", .action = .stop },
    };
    for (cases) |case| {
        const result = try decodeForTest(case.args);
        const input = result.input;
        defer inputDeinit(input, testing.allocator);
        try testing.expectEqual(case.action, std.meta.activeTag(input.request));
    }
    const wait = try decodeForTest("{\"request\":{\"action\":\"wait\"}}");
    defer inputDeinit(wait.input, testing.allocator);
    try testing.expectEqual(default_wait_ms, wait.input.request.wait.timeout_ms);
    try testing.expectEqual(@as(usize, 0), wait.input.request.wait.names.len);
}

test "bad requests are rejected with a code the model can act on" {
    try expectRejected("not json", "invalid_json");
    try expectRejected("{\"request\":{\"action\":\"run\",\"task\":\"x\"}}", "invalid_enum");
    try expectRejected("{\"request\":{\"action\":\"launch\",\"name\":\"A1\",\"task\":\"x\"}}", "invalid_name");
    try expectRejected("{\"request\":{\"action\":\"launch\",\"name\":\"a1\"}}", "missing_field");
    try expectRejected("{\"request\":{\"action\":\"launch\",\"name\":\"a1\",\"task\":\"\"}}", "invalid_text");
    try expectRejected("{\"request\":{\"action\":\"launch\",\"name\":\"a1\",\"task\":\"x\",\"effort\":\"bogus effort!\"}}", "invalid_effort");
    try expectRejected("{\"request\":{\"action\":\"send\",\"name\":\"a1\",\"message\":\"x\",\"agent\":\"a1\"}}", "unknown_field");
    try expectRejected("{\"request\":{\"action\":\"wait\",\"timeout_ms\":600001}}", "invalid_timeout");
    try expectRejected("{\"request\":{\"action\":\"wait\",\"names\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\",\"j\",\"k\"]}}", "too_many_names");
    try expectRejected("{\"request\":{\"action\":\"read\",\"name\":\"a1\",\"what\":\"pane\"}}", "invalid_enum");
}

test "a call without a children host says so" {
    const result = try decodeForTest("{\"request\":{\"action\":\"list\"}}");
    defer inputDeinit(result.input, testing.allocator);
    const output = try call(.{ .allocator = testing.allocator }, .{ .ptr = result.input, .deinit_fn = inputDeinit });
    defer output.deinit(testing.allocator);
    try testing.expect(std.mem.find(u8, output.failure, "host_unavailable") != null);
}

test "results never use the old tool's delivery names or error codes" {
    // tool_presentation still parses the old tool's results by name.
    for (std.meta.tags(children.Delivery)) |delivery| {
        try testing.expect(std.meta.stringToEnum(types.SteeringDelivery, @tagName(delivery)) == null);
    }
}

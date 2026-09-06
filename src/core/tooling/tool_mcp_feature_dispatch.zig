const std = @import("std");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const tool_result_errors = @import("tool_result_errors.zig");

const Allocator = std.mem.Allocator;
const max_arguments_json_bytes: usize = 64 * 1024;
const max_context_arguments: usize = 128;
const max_context_bytes: usize = 128 * 1024;
const input_required_failure = "{\"error\":\"McpInputRequired\"}";

pub fn isInputRequiredFailure(body: []const u8) bool {
    return std.mem.eql(u8, body, input_required_failure);
}

const Input = struct {
    request: tool_mcp_runtime.FeatureRequest,
    server_name: []u8,
    identity: []u8,
    argument_name: []u8,
    value: []u8,
    arguments_json: []u8,
    context_arguments: []tool_mcp_runtime.FeatureArgument,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.identity);
        alloc.free(self.argument_name);
        alloc.free(self.value);
        alloc.free(self.arguments_json);
        for (self.context_arguments) |argument| {
            alloc.free(argument.name);
            alloc.free(argument.value);
        }
        alloc.free(self.context_arguments);
        self.* = undefined;
    }
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "Invalid mcp_features arguments."),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return failure(ctx.allocator, "Invalid mcp_features arguments.");
    if (!onlyKnownFields(parsed.value.object)) {
        return failure(ctx.allocator, "mcp_features received an unknown argument field.");
    }

    const action_text = stringField(parsed.value.object, "action") orelse
        return failure(ctx.allocator, "mcp_features requires an action.");
    const action = parseAction(action_text) orelse
        return failure(ctx.allocator, "mcp_features action is not supported.");
    const server_name = stringField(parsed.value.object, "server") orelse
        return failure(ctx.allocator, "mcp_features requires a stable server name.");
    if (server_name.len == 0) {
        return failure(ctx.allocator, "mcp_features requires a stable server name.");
    }

    const identity = switch (action) {
        .resource_list, .resource_templates, .prompt_list => "",
        .resource_read => stringField(parsed.value.object, "uri") orelse
            return failure(ctx.allocator, "resource_read requires uri."),
        .resource_complete => stringField(parsed.value.object, "uri_template") orelse
            return failure(ctx.allocator, "resource_complete requires uri_template."),
        .prompt_get, .prompt_complete => stringField(parsed.value.object, "prompt") orelse
            return failure(ctx.allocator, "prompt actions require prompt."),
    };
    if (actionNeedsIdentity(action) and identity.len == 0) {
        return failure(ctx.allocator, "mcp_features requires a stable feature identity.");
    }
    const argument_name = if (action == .prompt_complete or action == .resource_complete)
        stringField(parsed.value.object, "argument") orelse
            return failure(ctx.allocator, "completion actions require argument.")
    else
        "";
    if ((action == .prompt_complete or action == .resource_complete) and argument_name.len == 0) {
        return failure(ctx.allocator, "completion actions require argument.");
    }
    const value = stringField(parsed.value.object, "value") orelse "";

    const arguments_json = argumentsJson(ctx.allocator, parsed.value.object, action) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "mcp_features arguments are invalid or too large."),
    };
    errdefer ctx.allocator.free(arguments_json);
    const context_arguments = contextArguments(ctx.allocator, parsed.value.object, action) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "mcp_features completion context is invalid or too large."),
    };
    errdefer freeContextArguments(ctx.allocator, context_arguments);
    const owned_server = try ctx.allocator.dupe(u8, server_name);
    errdefer ctx.allocator.free(owned_server);
    const owned_identity = try ctx.allocator.dupe(u8, identity);
    errdefer ctx.allocator.free(owned_identity);
    const owned_argument = try ctx.allocator.dupe(u8, argument_name);
    errdefer ctx.allocator.free(owned_argument);
    const owned_value = try ctx.allocator.dupe(u8, value);
    errdefer ctx.allocator.free(owned_value);
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .request = .{
            .action = action,
            .server_name = owned_server,
            .identity = owned_identity,
            .argument_name = owned_argument,
            .value = owned_value,
            .arguments_json = arguments_json,
            .context_arguments = context_arguments,
        },
        .server_name = owned_server,
        .identity = owned_identity,
        .argument_name = owned_argument,
        .value = owned_value,
        .arguments_json = arguments_json,
        .context_arguments = context_arguments,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
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
    const runtime_context = ctx.mcp_ctx orelse
        return semanticFailure(ctx.allocator, "No MCP runtime is available.");
    const call_feature = ctx.mcp_call_feature orelse
        return semanticFailure(ctx.allocator, "MCP resources and prompts are unavailable.");
    const result = call_feature(runtime_context, ctx.allocator, erased.as(Input).request, .{
        .cancel_flag = ctx.cancel_flag,
        .input_responder = ctx.mcp_input_responder,
        .output_limit_bytes = ctx.max_tool_result_bytes,
        .access = ctx.mcp_access,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.McpInputRequired or
            err == error.UnsupportedMode or
            err == error.UnsupportedInputRequest)
        {
            return .{ .failure = try ctx.allocator.dupe(u8, input_required_failure) };
        }
        return .{ .failure = try tool_result_errors.formatToolExecutionErrorJson(
            ctx.allocator,
            "mcp_features",
            err,
        ) };
    };
    if (result.images.len > 0) return .{ .rich = .{ .text = result.model_output, .images = result.images } };
    return .{ .success = result.model_output };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(raw: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(raw));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn onlyKnownFields(object: std.json.ObjectMap) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!std.mem.eql(u8, name, "action") and
            !std.mem.eql(u8, name, "server") and
            !std.mem.eql(u8, name, "uri") and
            !std.mem.eql(u8, name, "uri_template") and
            !std.mem.eql(u8, name, "prompt") and
            !std.mem.eql(u8, name, "argument") and
            !std.mem.eql(u8, name, "value") and
            !std.mem.eql(u8, name, "arguments") and
            !std.mem.eql(u8, name, "context"))
        {
            return false;
        }
    }
    return true;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn parseAction(value: []const u8) ?tool_mcp_runtime.FeatureAction {
    inline for (std.meta.fields(tool_mcp_runtime.FeatureAction)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn actionNeedsIdentity(action: tool_mcp_runtime.FeatureAction) bool {
    return switch (action) {
        .resource_list, .resource_templates, .prompt_list => false,
        else => true,
    };
}

fn argumentsJson(
    alloc: Allocator,
    object: std.json.ObjectMap,
    action: tool_mcp_runtime.FeatureAction,
) ![]u8 {
    const value = object.get("arguments");
    if (action != .prompt_get) {
        if (value != null) return error.InvalidToolArguments;
        return alloc.dupe(u8, "{}");
    }
    const arguments = value orelse return alloc.dupe(u8, "{}");
    if (arguments != .object) return error.InvalidToolArguments;
    var iterator = arguments.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidToolArguments;
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(arguments, .{}, &out.writer);
    if (out.written().len > max_arguments_json_bytes) return error.InvalidToolArguments;
    return out.toOwnedSlice();
}

fn contextArguments(
    alloc: Allocator,
    object: std.json.ObjectMap,
    action: tool_mcp_runtime.FeatureAction,
) ![]tool_mcp_runtime.FeatureArgument {
    const value = object.get("context");
    const completion = action == .prompt_complete or action == .resource_complete;
    if (!completion) {
        if (value != null) return error.InvalidToolArguments;
        return alloc.alloc(tool_mcp_runtime.FeatureArgument, 0);
    }
    const context = value orelse return alloc.alloc(tool_mcp_runtime.FeatureArgument, 0);
    if (context != .object or context.object.count() > max_context_arguments) {
        return error.InvalidToolArguments;
    }
    const result = try alloc.alloc(tool_mcp_runtime.FeatureArgument, context.object.count());
    var count: usize = 0;
    var total_bytes: usize = 0;
    errdefer {
        for (result[0..count]) |argument| {
            alloc.free(argument.name);
            alloc.free(argument.value);
        }
        alloc.free(result);
    }
    var iterator = context.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidToolArguments;
        total_bytes = std.math.add(usize, total_bytes, entry.key_ptr.*.len) catch
            return error.InvalidToolArguments;
        total_bytes = std.math.add(usize, total_bytes, entry.value_ptr.string.len) catch
            return error.InvalidToolArguments;
        if (total_bytes > max_context_bytes) return error.InvalidToolArguments;
        const name = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(name);
        const argument_value = try alloc.dupe(u8, entry.value_ptr.string);
        result[count] = .{ .name = name, .value = argument_value };
        count += 1;
    }
    return result;
}

fn freeContextArguments(alloc: Allocator, arguments: []tool_mcp_runtime.FeatureArgument) void {
    for (arguments) |argument| {
        alloc.free(argument.name);
        alloc.free(argument.value);
    }
    alloc.free(arguments);
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}

fn semanticFailure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}

test "MCP feature tool decodes stable server-qualified resource and prompt requests" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const decoded = try decode(ctx, "{\"action\":\"prompt_get\",\"server\":\"fixture\",\"prompt\":\"review\",\"arguments\":{\"tone\":\"brief\"}}");
    var input = switch (decoded) {
        .input => |value| value,
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
    };
    defer input.deinit(alloc);
    const typed = input.as(Input).request;
    try std.testing.expectEqual(tool_mcp_runtime.FeatureAction.prompt_get, typed.action);
    try std.testing.expectEqualStrings("fixture", typed.server_name);
    try std.testing.expectEqualStrings("review", typed.identity);
    try std.testing.expectEqualStrings("{\"tone\":\"brief\"}", typed.arguments_json);
}

test "MCP feature tool owned input releases every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const decoded = try decode(.{ .allocator = alloc }, "{\"action\":\"resource_complete\",\"server\":\"fixture\",\"uri_template\":\"custom:///{path}\",\"argument\":\"path\",\"context\":{\"root\":\"src\"}}");
            switch (decoded) {
                .input => |input| input.deinit(alloc),
                .failure => |message| alloc.free(message),
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "MCP feature input-required remains a typed terminal result" {
    const Fixture = struct {
        fn callFeature(
            _: *anyopaque,
            _: Allocator,
            _: tool_mcp_runtime.FeatureRequest,
            _: tool_mcp_runtime.FeatureCallOptions,
        ) anyerror!tool_mcp_runtime.FeatureResult {
            return error.McpInputRequired;
        }
    };
    const alloc = std.testing.allocator;
    var marker: u8 = 0;
    const ctx = tool_dispatch.DispatchContext{
        .allocator = alloc,
        .mcp_ctx = @ptrCast(&marker),
        .mcp_call_feature = Fixture.callFeature,
    };
    const decoded = try decode(ctx, "{\"action\":\"resource_read\",\"server\":\"fixture\",\"uri\":\"custom://item\"}");
    var input = switch (decoded) {
        .input => |value| value,
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
    };
    defer input.deinit(alloc);
    var result = try call(ctx, input);
    defer result.deinit(alloc);
    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .failure => |body| try std.testing.expect(isInputRequiredFailure(body)),
        .success => return error.TestUnexpectedResult,
    }
}

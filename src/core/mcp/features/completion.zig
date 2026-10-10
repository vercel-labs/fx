const std = @import("std");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const common = @import("common.zig");
const json_number = @import("../json_number.zig");

const Allocator = std.mem.Allocator;

pub const Protocol = common.Protocol;

pub const Limits = struct {
    max_values: usize = 100,
    max_total_value_bytes: usize = 64 * 1024,
    max_value_bytes: usize = 4096,
    max_name_bytes: usize = 256,
    max_ref_bytes: usize = 64 * 1024,
    max_context_arguments: usize = 128,
    max_context_bytes: usize = 128 * 1024,
    common: common.Limits = .{},
};

pub const Error = error{
    InvalidReference,
    InvalidArgument,
    InvalidContext,
    InvalidResult,
    CompletionLimitExceeded,
    CompletionByteLimitExceeded,
} || common.Error || Allocator.Error || std.Io.Writer.Error;

pub const Reference = union(enum) {
    prompt: []const u8,
    resource_template: []const u8,
};

pub const Argument = struct {
    name: []const u8,
    value: []const u8,
};

pub const Result = struct {
    values: []const []u8,
    total: ?u64 = null,
    has_more: ?bool = null,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        for (self.values) |value| alloc.free(value);
        alloc.free(self.values);
        self.* = undefined;
    }
};

pub fn parseResult(alloc: Allocator, response: []const u8, protocol: Protocol, limits: Limits) Error!Result {
    var parsed = try common.parseEnvelope(alloc, response, limits.common);
    defer parsed.deinit();
    const result = common.completeResult(parsed.value, protocol) catch |err| return mapCommonResultError(err);
    const completion = result.object.get("completion") orelse return error.InvalidResult;
    if (completion != .object) return error.InvalidResult;
    const values_value = completion.object.get("values") orelse return error.InvalidResult;
    if (values_value != .array or values_value.array.items.len > limits.max_values) {
        return error.CompletionLimitExceeded;
    }
    const values = try alloc.alloc([]u8, values_value.array.items.len);
    var count: usize = 0;
    var total_bytes: usize = 0;
    errdefer {
        for (values[0..count]) |value| alloc.free(value);
        alloc.free(values);
    }
    for (values_value.array.items, 0..) |value, index| {
        if (value != .string or value.string.len > limits.max_value_bytes) {
            return error.CompletionByteLimitExceeded;
        }
        total_bytes = std.math.add(usize, total_bytes, value.string.len) catch
            return error.CompletionByteLimitExceeded;
        if (total_bytes > limits.max_total_value_bytes) return error.CompletionByteLimitExceeded;
        values[index] = try alloc.dupe(u8, value.string);
        count += 1;
    }
    const total = if (completion.object.get("total")) |value|
        (try nonNegativeU64(alloc, value)) orelse return error.InvalidResult
    else
        null;
    const has_more = if (completion.object.get("hasMore")) |value| blk: {
        if (value != .bool) return error.InvalidResult;
        break :blk value.bool;
    } else null;
    return .{ .values = values, .total = total, .has_more = has_more };
}

pub fn buildRequest(
    alloc: Allocator,
    request_id: u64,
    protocol: Protocol,
    reference: Reference,
    argument: Argument,
    context_arguments: []const Argument,
    limits: Limits,
    write_modern_metadata: *const fn (*std.Io.Writer) anyerror!void,
) ![]u8 {
    try validateReference(reference, limits);
    try validateArgument(argument, limits);
    if (context_arguments.len > limits.max_context_arguments) return error.InvalidContext;
    var context_bytes: usize = 0;
    for (context_arguments, 0..) |item, index| {
        try validateArgument(item, limits);
        context_bytes = std.math.add(usize, context_bytes, item.name.len) catch
            return error.InvalidContext;
        context_bytes = std.math.add(usize, context_bytes, item.value.len) catch
            return error.InvalidContext;
        if (context_bytes > limits.max_context_bytes) return error.InvalidContext;
        for (context_arguments[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, item.name)) return error.InvalidContext;
        }
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"completion/complete\",\"params\":{{", .{request_id});
    if (protocol == .modern) {
        try out.writer.writeAll("\"_meta\":");
        try write_modern_metadata(&out.writer);
        try out.writer.writeByte(',');
    }
    try out.writer.writeAll("\"ref\":{");
    switch (reference) {
        .prompt => |name| {
            try out.writer.writeAll("\"type\":\"ref/prompt\",\"name\":");
            try std.json.Stringify.value(name, .{}, &out.writer);
        },
        .resource_template => |uri| {
            try out.writer.writeAll("\"type\":\"ref/resource\",\"uri\":");
            try std.json.Stringify.value(uri, .{}, &out.writer);
        },
    }
    try out.writer.writeAll("},\"argument\":{\"name\":");
    try std.json.Stringify.value(argument.name, .{}, &out.writer);
    try out.writer.writeAll(",\"value\":");
    try std.json.Stringify.value(argument.value, .{}, &out.writer);
    try out.writer.writeAll("}");
    if (context_arguments.len > 0) {
        try out.writer.writeAll(",\"context\":{\"arguments\":{");
        for (context_arguments, 0..) |item, index| {
            if (index > 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(item.name, .{}, &out.writer);
            try out.writer.writeByte(':');
            try std.json.Stringify.value(item.value, .{}, &out.writer);
        }
        try out.writer.writeAll("}}");
    }
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn validateReference(reference: Reference, limits: Limits) Error!void {
    const value = switch (reference) {
        .prompt => |name| name,
        .resource_template => |uri| uri,
    };
    if (value.len == 0 or value.len > limits.max_ref_bytes) return error.InvalidReference;
}

fn validateArgument(argument: Argument, limits: Limits) Error!void {
    if (argument.name.len == 0 or argument.name.len > limits.max_name_bytes or
        argument.value.len > limits.max_value_bytes)
    {
        return error.InvalidArgument;
    }
}

fn mapCommonResultError(err: common.Error) Error {
    return switch (err) {
        error.ProtocolFailure => error.ProtocolFailure,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResult,
    };
}

fn nonNegativeU64(alloc: Allocator, value: std.json.Value) Error!?u64 {
    const parsed = json_number.fromValue(alloc, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed == null) return null;
    var number = parsed.?;
    defer number.deinit(alloc);
    const result = number.toNonNegativeUsize() orelse return null;
    return std.math.cast(u64, result);
}

fn writeMetadata(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"io.modelcontextprotocol/related-task\":{\"taskId\":\"fx-test\"}}");
}

test "completion result enforces count bytes total and hasMore" {
    const alloc = std.testing.allocator;
    var result = try parseResult(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"completion\":{\"values\":[\"alpha\",\"beta\"],\"total\":3,\"hasMore\":true}}}",
        .modern,
        .{},
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), result.values.len);
    try std.testing.expectEqual(@as(?u64, 3), result.total);
    try std.testing.expectEqual(@as(?bool, true), result.has_more);

    try std.testing.expectError(
        error.CompletionLimitExceeded,
        parseResult(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"completion\":{\"values\":[\"a\",\"b\"]}}}",
            .modern,
            .{ .max_values = 1 },
        ),
    );
    try std.testing.expectError(
        error.CompletionByteLimitExceeded,
        parseResult(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"completion\":{\"values\":[\"alpha\",\"beta\"]}}}",
            .modern,
            .{ .max_total_value_bytes = 4 },
        ),
    );
}

test "completion requests encode prompt and resource template references" {
    const alloc = std.testing.allocator;
    const prompt_request = try buildRequest(
        alloc,
        1,
        .modern,
        .{ .prompt = "review" },
        .{ .name = "focus", .value = "sec" },
        &.{.{ .name = "language", .value = "zig" }},
        .{},
        writeMetadata,
    );
    defer alloc.free(prompt_request);
    try std.testing.expect(std.mem.find(u8, prompt_request, "\"type\":\"ref/prompt\"") != null);

    const resource_request = try buildRequest(
        alloc,
        2,
        .modern,
        .{ .resource_template = "db:///{table}/{id}" },
        .{ .name = "table", .value = "us" },
        &.{},
        .{},
        writeMetadata,
    );
    defer alloc.free(resource_request);
    try std.testing.expect(std.mem.find(u8, resource_request, "\"type\":\"ref/resource\"") != null);
    try std.testing.expectError(
        error.InvalidContext,
        buildRequest(
            alloc,
            3,
            .modern,
            .{ .prompt = "review" },
            .{ .name = "focus", .value = "sec" },
            &.{.{ .name = "language", .value = "zig" }},
            .{ .max_context_bytes = 2 },
            writeMetadata,
        ),
    );
}

fn checkCompletionAllocationFailures(alloc: Allocator) !void {
    var result = try parseResult(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"completion\":{\"values\":[\"alpha\",\"beta\",\"gamma\"],\"total\":3,\"hasMore\":false}}}",
        .modern,
        .{},
    );
    defer result.deinit(alloc);
}

test "completion result construction is allocation failure safe" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkCompletionAllocationFailures,
        .{},
    );
}

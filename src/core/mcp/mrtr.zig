//! Multi Round-Trip Requests (MRTR): bounded parsing and validation for
//! stateless client-input requests carried by modern MCP operation results.

const std = @import("std");
const elicitation = @import("elicitation.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_requests: usize = 32,
    max_name_bytes: usize = 256,
    max_json_bytes: usize = 128 * 1024,
    max_string_bytes: usize = 64 * 1024,
    max_collection_items: usize = 256,
    max_depth: usize = 32,
};

pub const Error = error{
    InvalidInputRequired,
    InvalidInputResponses,
    UnsupportedInputRequest,
    MetadataLimitExceeded,
} || Allocator.Error || std.Io.Writer.Error;

const UnsupportedMethod = enum { sampling, roots };
const ElicitationRequest = elicitation.Request;

const RequestPayload = union(enum) {
    unsupported: UnsupportedMethod,
    elicitation_create: ElicitationRequest,

    fn deinit(self: *RequestPayload, alloc: Allocator) void {
        switch (self.*) {
            .unsupported => {},
            .elicitation_create => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }

    pub fn method(self: RequestPayload) []const u8 {
        return switch (self) {
            .unsupported => |method_name| switch (method_name) {
                .sampling => "sampling/createMessage",
                .roots => "roots/list",
            },
            .elicitation_create => "elicitation/create",
        };
    }
};

pub const InputRequest = struct {
    key: []u8,
    payload: RequestPayload,

    pub fn deinit(self: *InputRequest, alloc: Allocator) void {
        alloc.free(self.key);
        self.payload.deinit(alloc);
        self.* = undefined;
    }
};

pub const InputRequired = struct {
    requests: []InputRequest,
    request_state_json: ?[]u8 = null,

    pub fn deinit(self: *InputRequired, alloc: Allocator) void {
        for (self.requests) |*request| request.deinit(alloc);
        alloc.free(self.requests);
        if (self.request_state_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub fn parseInputRequired(
    alloc: Allocator,
    result: std.json.Value,
    limits: Limits,
) Error!InputRequired {
    if (result != .object) return error.InvalidInputRequired;
    try validateJsonBounds(result, limits, 0);
    const requests_value = result.object.get("inputRequests");
    const state_value = result.object.get("requestState");
    if (requests_value == null and state_value == null) return error.InvalidInputRequired;

    const requests = if (requests_value) |value|
        try parseRequestMap(alloc, value, limits, .modern_mcp)
    else
        try alloc.alloc(InputRequest, 0);
    errdefer {
        for (requests) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    const request_state_json = if (state_value) |state|
        try stringifyBounded(alloc, state, limits.max_json_bytes)
    else
        null;
    return .{ .requests = requests, .request_state_json = request_state_json };
}

fn parseRequestJson(
    alloc: Allocator,
    input_requests_json: []const u8,
    limits: Limits,
) Error![]InputRequest {
    return parseRequestJsonForWire(alloc, input_requests_json, .modern_mcp, limits);
}

pub fn parseRequestJsonForWire(
    alloc: Allocator,
    input_requests_json: []const u8,
    wire: elicitation.Wire,
    limits: Limits,
) Error![]InputRequest {
    if (input_requests_json.len > limits.max_json_bytes) return error.MetadataLimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, input_requests_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInputRequired,
    };
    defer parsed.deinit();
    try validateJsonBounds(parsed.value, limits, 0);
    return parseRequestMap(alloc, parsed.value, limits, wire);
}

fn parseRequestMap(
    alloc: Allocator,
    value: std.json.Value,
    limits: Limits,
    wire: elicitation.Wire,
) Error![]InputRequest {
    if (value != .object or value.object.count() > limits.max_requests) {
        return error.InvalidInputRequired;
    }
    const requests = try alloc.alloc(InputRequest, value.object.count());
    var parsed_count: usize = 0;
    errdefer {
        for (requests[0..parsed_count]) |*request| request.deinit(alloc);
        alloc.free(requests);
    }

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.len == 0 or entry.key_ptr.len > limits.max_name_bytes) {
            return error.InvalidInputRequired;
        }
        const request = entry.value_ptr.*;
        if (request != .object) return error.InvalidInputRequired;
        const method = request.object.get("method") orelse return error.InvalidInputRequired;
        if (method != .string) return error.InvalidInputRequired;

        const key = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(key);
        const payload: RequestPayload = if (std.mem.eql(u8, method.string, "sampling/createMessage"))
            .{ .unsupported = .sampling }
        else if (std.mem.eql(u8, method.string, "roots/list"))
            .{ .unsupported = .roots }
        else if (std.mem.eql(u8, method.string, "elicitation/create"))
            try parseElicitationRequest(alloc, request, limits, wire)
        else
            return error.InvalidInputRequired;
        requests[parsed_count] = .{ .key = key, .payload = payload };
        parsed_count += 1;
    }
    return requests;
}

fn parseElicitationRequest(
    alloc: Allocator,
    request: std.json.Value,
    limits: Limits,
    wire: elicitation.Wire,
) Error!RequestPayload {
    const params = request.object.get("params") orelse return error.InvalidInputRequired;
    if (params != .object) return error.InvalidInputRequired;
    const params_json = try stringifyBounded(alloc, params, limits.max_json_bytes);
    defer alloc.free(params_json);
    return .{ .elicitation_create = elicitation.parseRequest(
        alloc,
        wire,
        params_json,
        .{
            .max_request_bytes = limits.max_json_bytes,
            .max_response_bytes = limits.max_json_bytes,
            .max_message_bytes = limits.max_string_bytes,
            .max_schema_bytes = limits.max_json_bytes,
            .max_fields = limits.max_collection_items,
            .max_options = limits.max_collection_items,
            .max_name_bytes = limits.max_name_bytes,
            .max_label_bytes = limits.max_string_bytes,
            .max_string_bytes = limits.max_string_bytes,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => return error.MetadataLimitExceeded,
        else => return error.InvalidInputRequired,
    } };
}

pub fn renderRequests(
    alloc: Allocator,
    requests: []const InputRequest,
) Error![]u8 {
    return renderRequestsFallible(alloc, requests) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

fn renderRequestsFallible(
    alloc: Allocator,
    requests: []const InputRequest,
) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    for (requests, 0..) |request, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(request.key, .{}, &out.writer);
        try out.writer.writeAll(":{\"method\":");
        try std.json.Stringify.value(request.payload.method(), .{}, &out.writer);
        switch (request.payload) {
            .unsupported => {},
            .elicitation_create => |value| {
                try out.writer.writeAll(",\"params\":");
                try out.writer.writeAll(value.raw_params_json);
            },
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

pub fn validateResponses(
    alloc: Allocator,
    requests: []const InputRequest,
    input_responses_json: []const u8,
    limits: Limits,
) Error!void {
    if (input_responses_json.len > limits.max_json_bytes) {
        return error.InvalidInputResponses;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, input_responses_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInputResponses,
    };
    defer parsed.deinit();
    try validateJsonBounds(parsed.value, limits, 0);
    if (parsed.value != .object or parsed.value.object.count() != requests.len) {
        return error.InvalidInputResponses;
    }

    for (requests) |request| {
        const response = parsed.value.object.get(request.key) orelse
            return error.InvalidInputResponses;
        switch (request.payload) {
            .unsupported => return error.UnsupportedInputRequest,
            .elicitation_create => |elicitation_request| try validateElicitationResult(
                alloc,
                elicitation_request,
                response,
                limits,
            ),
        }
    }
}

/// Validates the user response to a 2025-11 URL-required error. Acceptance is
/// browser consent only; completion is decided separately from matching
/// notifications or an explicit local manual retry.
pub fn legacyUrlConsent(
    alloc: Allocator,
    requests: []const InputRequest,
    input_responses_json: []const u8,
    limits: Limits,
) Error!elicitation.LegacyUrlConsent {
    try validateResponses(alloc, requests, input_responses_json, limits);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, input_responses_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidInputResponses,
    };
    defer parsed.deinit();
    var decision: elicitation.LegacyUrlConsent = .accepted;
    for (requests) |request| {
        if (request.payload != .elicitation_create or
            request.payload.elicitation_create.mode != .url)
        {
            return error.InvalidInputResponses;
        }
        const response = parsed.value.object.get(request.key).?;
        const action = elicitation.parseAction(response.object.get("action").?);
        if (action == .cancel) return .cancelled;
        if (action == .decline) decision = .declined;
    }
    return decision;
}

fn validateJsonBounds(value: std.json.Value, limits: Limits, depth: usize) Error!void {
    if (depth > limits.max_depth) return error.MetadataLimitExceeded;
    switch (value) {
        .string, .number_string => |text| {
            if (text.len > limits.max_string_bytes) return error.MetadataLimitExceeded;
        },
        .array => |array| {
            if (array.items.len > limits.max_collection_items) return error.MetadataLimitExceeded;
            for (array.items) |item| try validateJsonBounds(item, limits, depth + 1);
        },
        .object => |object| {
            if (object.count() > limits.max_collection_items) return error.MetadataLimitExceeded;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (entry.key_ptr.len > limits.max_name_bytes) return error.MetadataLimitExceeded;
                try validateJsonBounds(entry.value_ptr.*, limits, depth + 1);
            }
        },
        else => {},
    }
}

fn validateElicitationResult(
    alloc: Allocator,
    request: ElicitationRequest,
    value: std.json.Value,
    limits: Limits,
) Error!void {
    const response_json = try stringifyBounded(alloc, value, limits.max_json_bytes);
    defer alloc.free(response_json);
    _ = elicitation.validateResponse(
        alloc,
        request,
        response_json,
        .{
            .max_request_bytes = limits.max_json_bytes,
            .max_response_bytes = limits.max_json_bytes,
            .max_message_bytes = limits.max_string_bytes,
            .max_schema_bytes = limits.max_json_bytes,
            .max_fields = limits.max_collection_items,
            .max_options = limits.max_collection_items,
            .max_name_bytes = limits.max_name_bytes,
            .max_label_bytes = limits.max_string_bytes,
            .max_string_bytes = limits.max_string_bytes,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => return error.MetadataLimitExceeded,
        else => return error.InvalidInputResponses,
    };
}

fn stringifyBounded(
    alloc: Allocator,
    value: std.json.Value,
    max_bytes: usize,
) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch
        return error.OutOfMemory;
    if (out.written().len > max_bytes) return error.MetadataLimitExceeded;
    return try out.toOwnedSlice();
}

test "MRTR parses the closed request union and rejects unknown methods" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"inputRequests":{"sample":{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":8}},"roots":{"method":"roots/list"},"form":{"method":"elicitation/create","params":{"message":"Continue?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}},"required":["confirmed"]}}}},"requestState":"opaque"}
    ,
        .{},
    );
    defer parsed.deinit();
    var required = try parseInputRequired(alloc, parsed.value, .{});
    defer required.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), required.requests.len);
    try std.testing.expectEqualStrings("\"opaque\"", required.request_state_json.?);

    var invalid = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"inputRequests":{"bad":{"method":"custom/request","params":{}}}}
    ,
        .{},
    );
    defer invalid.deinit();
    try std.testing.expectError(
        error.InvalidInputRequired,
        parseInputRequired(alloc, invalid.value, .{}),
    );
}

test "MRTR validates only supported responses with exact keys" {
    const alloc = std.testing.allocator;
    const requests = try parseRequestJson(alloc,
        \\{"form":{"method":"elicitation/create","params":{"message":"Continue?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}},"required":["confirmed"]}}},"url":{"method":"elicitation/create","params":{"mode":"url","message":"Authenticate","url":"https://example.test/auth"}}}
    , .{});
    defer {
        for (requests) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    try validateResponses(alloc, requests,
        \\{"form":{"action":"accept","content":{"confirmed":true}},"url":{"action":"accept"}}
    , .{});
    const invalid = [_][]const u8{
        \\{"form":{"action":"accept","content":{"confirmed":true}}}
        ,
        \\{"form":{"action":"accept","content":{"confirmed":"yes"}},"url":{"action":"accept"}}
        ,
        \\{"other":{"action":"decline"},"url":{"action":"accept"}}
        ,
    };
    for (invalid) |response| try std.testing.expectError(error.InvalidInputResponses, validateResponses(alloc, requests, response, .{}));
}

test "MRTR recognizes unsupported methods without implementing their semantics" {
    const alloc = std.testing.allocator;
    const requests = try parseRequestJson(alloc,
        \\{"sample":{"method":"sampling/createMessage","params":{"unimplemented":true}}}
    , .{});
    defer {
        for (requests) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    try std.testing.expectEqualStrings("sampling/createMessage", requests[0].payload.method());
    try std.testing.expect(requests[0].payload == .unsupported);
    try std.testing.expectError(error.UnsupportedInputRequest, validateResponses(alloc, requests,
        \\{"sample":{}}
    , .{}));
}

test "MRTR parser and response validation release allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAllocationFailures,
        .{},
    );
}

test "MRTR bounds opaque request state depth before retention" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"inputRequests\":{},\"requestState\":[[[[true]]]]}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        parseInputRequired(alloc, parsed.value, .{ .max_depth = 3 }),
    );
}

fn checkAllocationFailures(alloc: Allocator) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"inputRequests":{"form":{"method":"elicitation/create","params":{"message":"Continue?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}}}}},"requestState":"opaque"}
    ,
        .{},
    );
    defer parsed.deinit();
    var required = try parseInputRequired(alloc, parsed.value, .{});
    defer required.deinit(alloc);
    const rendered = try renderRequests(alloc, required.requests);
    defer alloc.free(rendered);
    try validateResponses(
        alloc,
        required.requests,
        \\{"form":{"action":"accept","content":{"confirmed":true}}}
    ,
        .{},
    );
}

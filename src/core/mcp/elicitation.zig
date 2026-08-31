const std = @import("std");
const json_number = @import("json_number.zig");
const json_schema_pattern = @import("json_schema_pattern.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_request_bytes: usize = 128 * 1024,
    max_response_bytes: usize = 128 * 1024,
    max_message_bytes: usize = 8 * 1024,
    max_schema_bytes: usize = 128 * 1024,
    max_fields: usize = 64,
    max_options: usize = 64,
    max_name_bytes: usize = 256,
    max_label_bytes: usize = 1024,
    max_string_bytes: usize = 64 * 1024,
    max_pattern_bytes: usize = 512,
    max_pattern_depth: usize = 64,
    max_pattern_states: usize = 2048,
    max_pattern_repeat: usize = 1024,
    max_pattern_steps: usize = 100_000,
    max_elicitation_id_bytes: usize = 256,
    max_number_bytes: usize = 4096,
    max_number_exponent_abs: i64 = 1_000_000,
    max_number_expanded_digits: usize = 8192,
};

pub const Error = error{
    InvalidRequest,
    InvalidSchema,
    UnsupportedSchema,
    SecretField,
    InvalidUrl,
    InsecureUrl,
    InvalidResponse,
    LimitExceeded,
    UnsupportedMode,
    UnsupportedAction,
} || Allocator.Error;

pub const Wire = enum {
    modern_mcp,
    legacy_mcp_2025_06,
    legacy_mcp_2025_11,
    acp,

    pub fn isLegacy(self: Wire) bool {
        return self == .legacy_mcp_2025_06 or self == .legacy_mcp_2025_11;
    }
};

pub const Mode = enum {
    form,
    url,
    unknown,
};

pub const HostClassification = enum {
    ordinary,
    punycode,
    non_ascii,
};

/// Pure, deliberately conservative host warning. Punycode labels and any
/// non-ASCII hostname are shown with a warning; no network lookup is needed.
pub fn classifyHost(host: []const u8) HostClassification {
    var label_start: usize = 0;
    while (label_start <= host.len) {
        const label_end = std.mem.findScalarPos(u8, host, label_start, '.') orelse host.len;
        const label = host[label_start..label_end];
        if (label.len >= 4 and std.ascii.eqlIgnoreCase(label[0..4], "xn--")) {
            return .punycode;
        }
        if (label_end == host.len) break;
        label_start = label_end + 1;
    }
    for (host) |byte| if (byte >= 0x80) return .non_ascii;
    return .ordinary;
}

pub const Capabilities = packed struct {
    form: bool = false,
    url: bool = false,

    pub fn supports(self: Capabilities, mode: Mode) bool {
        return switch (mode) {
            .form => self.form,
            .url => self.url,
            .unknown => false,
        };
    }

    pub fn intersect(left: Capabilities, right: Capabilities) Capabilities {
        return .{
            .form = left.form and right.form,
            .url = left.url and right.url,
        };
    }

    pub fn any(self: Capabilities) bool {
        return self.form or self.url;
    }
};

/// ACP deliberately has no empty-object form fallback. A mode is supported
/// only when its property exists and is not JSON null.
pub fn parseAcpCapabilities(client_capabilities: std.json.Value) Capabilities {
    if (client_capabilities != .object) return .{};
    const elicitation = client_capabilities.object.get("elicitation") orelse return .{};
    if (elicitation != .object) return .{};
    const form = elicitation.object.get("form");
    const url = elicitation.object.get("url");
    return .{
        .form = form != null and form.? != .null,
        .url = url != null and url.? != .null,
    };
}

/// Modern MCP retains its compatibility rule: an empty elicitation capability
/// supports form mode. Explicit mode members otherwise use presence/non-null.
fn parseModernMcpCapabilities(client_capabilities: std.json.Value) Capabilities {
    if (client_capabilities != .object) return .{};
    const elicitation = client_capabilities.object.get("elicitation") orelse return .{};
    if (elicitation != .object) return .{};
    if (elicitation.object.count() == 0) return .{ .form = true };
    const form = elicitation.object.get("form");
    const url = elicitation.object.get("url");
    return .{
        .form = form != null and form.? != .null,
        .url = url != null and url.? != .null,
    };
}

pub const Scope = union(enum) {
    operation: Operation,
    acp_session: struct {
        session_id: []const u8,
        tool_call_id: ?[]const u8 = null,
    },
    acp_request: AcpRequestId,
};

const AcpRequestId = union(enum) {
    integer: i64,
    string: []const u8,
};

pub const Operation = union(enum) {
    tools_call: []const u8,
    resources_read: []const u8,
    prompts_get: []const u8,
};

pub const Binding = struct {
    server_name: []const u8,
    scope: Scope,
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    catalog_generation: u64,
    request_generation: u64,
    auth_generation: u64,
    user_identity: ?[]const u8 = null,
    deadline_ms: i64,
};

pub const AnswerBinding = struct {
    server_name: []const u8,
    scope: Scope,
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    catalog_generation: u64,
    request_generation: u64,
    auth_generation: u64,
    user_identity: ?[]const u8 = null,
};

pub const RequestState = enum {
    pending,
    consumed,
    cancelled,
    retired,
};

const Rejection = enum {
    duplicate,
    late,
    removed_server,
    wrong_server,
    wrong_scope,
    wrong_runtime,
    wrong_connection,
    wrong_client_generation,
    wrong_catalog_generation,
    wrong_request_generation,
    changed_auth,
    wrong_user,
    cancelled,
};

pub const Transition = union(enum) {
    consume,
    reject: Rejection,
};

/// Pure exactly-once decision. The effectful owner performs the state mutation
/// only after this returns `.consume` while holding its own short-lived lock.
pub fn decideTransition(
    state: RequestState,
    expected: Binding,
    answer: AnswerBinding,
    now_ms: i64,
    server_present: bool,
) Transition {
    if (state == .consumed) return .{ .reject = .duplicate };
    if (state == .cancelled or state == .retired) return .{ .reject = .cancelled };
    if (now_ms > expected.deadline_ms) return .{ .reject = .late };
    if (!server_present) return .{ .reject = .removed_server };
    if (!std.mem.eql(u8, expected.server_name, answer.server_name)) return .{ .reject = .wrong_server };
    if (!scopeEqual(expected.scope, answer.scope)) return .{ .reject = .wrong_scope };
    if (expected.runtime_generation != answer.runtime_generation) return .{ .reject = .wrong_runtime };
    if (expected.connection_generation != answer.connection_generation) return .{ .reject = .wrong_connection };
    if (expected.client_generation != answer.client_generation) return .{ .reject = .wrong_client_generation };
    if (expected.catalog_generation != answer.catalog_generation) return .{ .reject = .wrong_catalog_generation };
    if (expected.request_generation != answer.request_generation) return .{ .reject = .wrong_request_generation };
    if (expected.auth_generation != answer.auth_generation) return .{ .reject = .changed_auth };
    if (!optionalStringEqual(expected.user_identity, answer.user_identity)) return .{ .reject = .wrong_user };
    return .consume;
}

fn scopeEqual(expected: Scope, answer: Scope) bool {
    return switch (expected) {
        .operation => |operation| switch (answer) {
            .operation => |other| operationEqual(operation, other),
            else => false,
        },
        .acp_session => |session| switch (answer) {
            .acp_session => |other| std.mem.eql(u8, session.session_id, other.session_id) and
                optionalStringEqual(session.tool_call_id, other.tool_call_id),
            else => false,
        },
        .acp_request => |request_id| switch (answer) {
            .acp_request => |other| requestIdEqual(request_id, other),
            else => false,
        },
    };
}

fn operationEqual(expected: Operation, answer: Operation) bool {
    return switch (expected) {
        .tools_call => |name| switch (answer) {
            .tools_call => |other| std.mem.eql(u8, name, other),
            else => false,
        },
        .resources_read => |uri| switch (answer) {
            .resources_read => |other| std.mem.eql(u8, uri, other),
            else => false,
        },
        .prompts_get => |name| switch (answer) {
            .prompts_get => |other| std.mem.eql(u8, name, other),
            else => false,
        },
    };
}

fn requestIdEqual(expected: AcpRequestId, answer: AcpRequestId) bool {
    return switch (expected) {
        .integer => |value| switch (answer) {
            .integer => |other| value == other,
            else => false,
        },
        .string => |value| switch (answer) {
            .string => |other| std.mem.eql(u8, value, other),
            else => false,
        },
    };
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

pub const Action = enum {
    accept,
    decline,
    cancel,
    unknown,
};

pub fn parseAction(value: std.json.Value) Action {
    if (value != .string) return .unknown;
    if (std.mem.eql(u8, value.string, "accept")) return .accept;
    if (std.mem.eql(u8, value.string, "decline")) return .decline;
    if (std.mem.eql(u8, value.string, "cancel")) return .cancel;
    return .unknown;
}

pub const Request = struct {
    wire: Wire,
    mode: Mode,
    message: []u8,
    raw_params_json: []u8,
    requested_schema_json: ?[]u8 = null,
    url: ?[]u8 = null,
    url_host: ?[]u8 = null,
    elicitation_id: ?[]u8 = null,

    pub fn deinit(self: *Request, alloc: Allocator) void {
        alloc.free(self.message);
        alloc.free(self.raw_params_json);
        if (self.requested_schema_json) |value| alloc.free(value);
        if (self.url) |value| alloc.free(value);
        if (self.url_host) |value| alloc.free(value);
        if (self.elicitation_id) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const legacy_url_required_error_code: i64 = -32042;

const LegacyUrlCompletionNotification = struct {
    elicitation_id: []const u8,
};

pub fn classifyLegacyUrlCompletionNotification(
    value: std.json.Value,
    limits: Limits,
) ?LegacyUrlCompletionNotification {
    if (value != .object) return null;
    const jsonrpc = value.object.get("jsonrpc") orelse return null;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) return null;
    const method = value.object.get("method") orelse return null;
    if (method != .string or
        !std.mem.eql(u8, method.string, "notifications/elicitation/complete"))
    {
        return null;
    }
    const params = value.object.get("params") orelse return null;
    if (params != .object) return null;
    const id = params.object.get("elicitationId") orelse return null;
    if (id != .string or id.string.len == 0 or
        id.string.len > limits.max_elicitation_id_bytes)
    {
        return null;
    }
    return .{ .elicitation_id = id.string };
}

const UrlRequired = struct {
    requests: []Request,

    pub fn deinit(self: *UrlRequired, alloc: Allocator) void {
        for (self.requests) |*request| request.deinit(alloc);
        alloc.free(self.requests);
        self.* = undefined;
    }
};

pub const LegacyUrlCompletionIdentity = struct {
    server_name: []const u8,
    elicitation_id: []const u8,
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    catalog_generation: u64,
    auth_generation: u64,
};

const LegacyUrlCompletionRejection = union(enum) {
    unknown_id,
    duplicate,
    binding: Rejection,
};

const LegacyUrlCompletionTransition = union(enum) {
    record: struct {
        index: usize,
        all_complete: bool,
    },
    reject: LegacyUrlCompletionRejection,
};

/// Pure correlation for one legacy URL completion notification. The effectful
/// owner applies `.record` while holding its short-lived waiter lock.
pub fn decideLegacyUrlCompletion(
    expected: Binding,
    ids: []const []const u8,
    completed: []const bool,
    notification: LegacyUrlCompletionIdentity,
    now_ms: i64,
    server_present: bool,
) LegacyUrlCompletionTransition {
    std.debug.assert(ids.len == completed.len);
    const binding_transition = decideTransition(
        .pending,
        expected,
        .{
            .server_name = notification.server_name,
            .scope = expected.scope,
            .runtime_generation = notification.runtime_generation,
            .connection_generation = notification.connection_generation,
            .client_generation = notification.client_generation,
            .catalog_generation = notification.catalog_generation,
            .request_generation = expected.request_generation,
            .auth_generation = notification.auth_generation,
            .user_identity = expected.user_identity,
        },
        now_ms,
        server_present,
    );
    switch (binding_transition) {
        .consume => {},
        .reject => |reason| return .{ .reject = .{ .binding = reason } },
    }

    for (ids, 0..) |id, index| {
        if (!std.mem.eql(u8, id, notification.elicitation_id)) continue;
        if (completed[index]) return .{ .reject = .duplicate };
        var remaining: usize = 0;
        for (completed, 0..) |is_complete, other_index| {
            if (other_index != index and !is_complete) remaining += 1;
        }
        return .{ .record = .{
            .index = index,
            .all_complete = remaining == 0,
        } };
    }
    return .{ .reject = .unknown_id };
}

pub const LegacyUrlConsent = enum {
    accepted,
    declined,
    cancelled,
};

pub const LegacyUrlCompletionProof = enum {
    none,
    notifications,
    manual_retry,
};

pub const LegacyUrlRetryDecision = enum {
    await_completion,
    retry,
    declined,
    cancelled,
};

pub fn decideLegacyUrlRetry(
    consent: LegacyUrlConsent,
    proof: LegacyUrlCompletionProof,
) LegacyUrlRetryDecision {
    return switch (consent) {
        .declined => .declined,
        .cancelled => .cancelled,
        .accepted => switch (proof) {
            .none => .await_completion,
            .notifications, .manual_retry => .retry,
        },
    };
}

pub fn renderLegacyUrlRequiredRequests(
    alloc: Allocator,
    required: UrlRequired,
    limits: Limits,
) Error![]u8 {
    return renderLegacyUrlRequiredRequestsFallible(alloc, required, limits) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
}

fn renderLegacyUrlRequiredRequestsFallible(
    alloc: Allocator,
    required: UrlRequired,
    limits: Limits,
) (Error || std.Io.Writer.Error)![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    for (required.requests, 0..) |request, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(request.elicitation_id.?, .{}, &out.writer);
        try out.writer.writeAll(":{\"method\":\"elicitation/create\",\"params\":");
        try out.writer.writeAll(request.raw_params_json);
        try out.writer.writeByte('}');
        if (out.writer.buffered().len > limits.max_response_bytes) return error.LimitExceeded;
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

/// Parses the `2025-11-25` URL-required error data. Older legacy revisions do
/// not define this error or URL mode and are rejected before any interaction.
pub fn parseLegacyUrlRequired(
    alloc: Allocator,
    wire: Wire,
    data_json: []const u8,
    limits: Limits,
) Error!UrlRequired {
    if (wire != .legacy_mcp_2025_11) return error.UnsupportedMode;
    if (data_json.len > limits.max_response_bytes) return error.LimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, data_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const elicitations = parsed.value.object.get("elicitations") orelse
        return error.InvalidRequest;
    if (elicitations != .array or elicitations.array.items.len == 0 or
        elicitations.array.items.len > limits.max_options)
    {
        return error.InvalidRequest;
    }

    const requests = try alloc.alloc(Request, elicitations.array.items.len);
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(alloc);
    var count: usize = 0;
    errdefer {
        for (requests[0..count]) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    for (elicitations.array.items) |value| {
        if (value != .object) return error.InvalidRequest;
        const params_json = try stringifyBounded(alloc, value, limits.max_request_bytes);
        defer alloc.free(params_json);
        requests[count] = try parseRequest(
            alloc,
            .legacy_mcp_2025_11,
            params_json,
            limits,
        );
        var current_owned = true;
        errdefer if (current_owned) requests[count].deinit(alloc);
        if (requests[count].mode != .url) {
            requests[count].deinit(alloc);
            current_owned = false;
            return error.InvalidRequest;
        }
        const id = requests[count].elicitation_id.?;
        if (ids.contains(id)) {
            requests[count].deinit(alloc);
            current_owned = false;
            return error.InvalidRequest;
        }
        try ids.put(alloc, id, {});
        count += 1;
        current_owned = false;
    }
    return .{ .requests = requests };
}

const AcpProjectionScope = union(enum) {
    session: struct {
        session_id: []const u8,
        tool_call_id: ?[]const u8 = null,
    },
    request: AcpRequestId,
};

/// Projects a validated modern MCP request onto ACP's distinct direct-request
/// wire. ACP requires an explicit mode, excludes MCP's `$schema` and
/// compatibility-only `enumNames`, and owns its own URL elicitation id.
pub fn projectToAcpCreateParams(
    alloc: Allocator,
    request: Request,
    scope: AcpProjectionScope,
    url_elicitation_id: ?[]const u8,
    display_message: ?[]const u8,
    limits: Limits,
) Error![]u8 {
    return projectToAcpCreateParamsFallible(
        alloc,
        request,
        scope,
        url_elicitation_id,
        display_message,
        limits,
    ) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
}

fn projectToAcpCreateParamsFallible(
    alloc: Allocator,
    request: Request,
    scope: AcpProjectionScope,
    url_elicitation_id: ?[]const u8,
    display_message: ?[]const u8,
    limits: Limits,
) (Error || std.Io.Writer.Error)![]u8 {
    if (request.wire != .modern_mcp and !request.wire.isLegacy()) return error.InvalidRequest;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request.raw_params_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    switch (scope) {
        .session => |value| {
            if (value.session_id.len == 0 or value.session_id.len > limits.max_name_bytes) {
                return error.InvalidRequest;
            }
            try out.writer.writeAll("\"sessionId\":");
            try std.json.Stringify.value(value.session_id, .{}, &out.writer);
            if (value.tool_call_id) |tool_call_id| {
                if (tool_call_id.len == 0 or tool_call_id.len > limits.max_name_bytes) {
                    return error.InvalidRequest;
                }
                try out.writer.writeAll(",\"toolCallId\":");
                try std.json.Stringify.value(tool_call_id, .{}, &out.writer);
            }
        },
        .request => |request_id| {
            try out.writer.writeAll("\"requestId\":");
            switch (request_id) {
                .integer => |value| try out.writer.print("{d}", .{value}),
                .string => |value| {
                    if (value.len == 0 or value.len > limits.max_name_bytes) {
                        return error.InvalidRequest;
                    }
                    try std.json.Stringify.value(value, .{}, &out.writer);
                },
            }
        },
    }
    try out.writer.writeAll(",\"mode\":");
    try std.json.Stringify.value(@tagName(request.mode), .{}, &out.writer);
    try out.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(display_message orelse request.message, .{}, &out.writer);
    switch (request.mode) {
        .form => {
            const schema = parsed.value.object.get("requestedSchema") orelse return error.InvalidRequest;
            try out.writer.writeAll(",\"requestedSchema\":");
            var remaining = schemaNodeLimit(limits);
            try writeAcpSchemaValue(&out.writer, schema, &remaining);
        },
        .url => {
            const id = url_elicitation_id orelse return error.InvalidRequest;
            if (id.len == 0 or id.len > limits.max_name_bytes) return error.InvalidRequest;
            try out.writer.writeAll(",\"url\":");
            try std.json.Stringify.value(request.url orelse return error.InvalidRequest, .{}, &out.writer);
            try out.writer.writeAll(",\"elicitationId\":");
            try std.json.Stringify.value(id, .{}, &out.writer);
        },
        .unknown => return error.UnsupportedMode,
    }
    if (parsed.value.object.get("_meta")) |metadata| {
        if (metadata != .object) return error.InvalidRequest;
        try out.writer.writeAll(",\"_meta\":");
        try std.json.Stringify.value(metadata, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    if (out.written().len > limits.max_request_bytes) return error.LimitExceeded;

    const projected = try out.toOwnedSlice();
    errdefer alloc.free(projected);
    var validated = try parseRequest(alloc, .acp, projected, limits);
    validated.deinit(alloc);
    return projected;
}

fn writeAcpSchemaValue(
    writer: *std.Io.Writer,
    schema: std.json.Value,
    remaining: *usize,
) (Error || std.Io.Writer.Error)!void {
    if (remaining.* == 0) return error.LimitExceeded;
    remaining.* -= 1;
    switch (schema) {
        .object => |object| {
            try writer.writeByte('{');
            var wrote = false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "$schema") or
                    std.mem.eql(u8, entry.key_ptr.*, "enumNames")) continue;
                if (wrote) try writer.writeByte(',');
                wrote = true;
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try writeAcpSchemaValue(writer, entry.value_ptr.*, remaining);
            }
            try writer.writeByte('}');
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeAcpSchemaValue(writer, item, remaining);
            }
            try writer.writeByte(']');
        },
        else => try std.json.Stringify.value(schema, .{}, writer),
    }
}

fn containsKeyRecursive(value: std.json.Value, needle: []const u8, max_nodes: usize) bool {
    var remaining = max_nodes;
    return containsKeyRecursiveBounded(value, needle, &remaining);
}

fn containsKeyRecursiveBounded(value: std.json.Value, needle: []const u8, remaining: *usize) bool {
    if (remaining.* == 0) return true;
    remaining.* -= 1;
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, needle) or
                    containsKeyRecursiveBounded(entry.value_ptr.*, needle, remaining)) return true;
            }
        },
        .array => |array| for (array.items) |item| {
            if (containsKeyRecursiveBounded(item, needle, remaining)) return true;
        },
        else => {},
    }
    return false;
}

pub fn parseRequest(
    alloc: Allocator,
    wire: Wire,
    params_json: []const u8,
    limits: Limits,
) Error!Request {
    if (params_json.len > limits.max_request_bytes) return error.LimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, params_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;

    const mode_value = parsed.value.object.get("mode");
    const mode = parseMode(wire, mode_value);
    if (mode == .unknown) return error.UnsupportedMode;

    var request: Request = request: {
        const message_value = parsed.value.object.get("message") orelse return error.InvalidRequest;
        const message = try copyString(alloc, message_value, limits.max_message_bytes, error.InvalidRequest);
        errdefer alloc.free(message);
        const raw_params_json = try alloc.dupe(u8, params_json);
        errdefer alloc.free(raw_params_json);
        break :request .{
            .wire = wire,
            .mode = mode,
            .message = message,
            .raw_params_json = raw_params_json,
        };
    };
    errdefer request.deinit(alloc);

    switch (mode) {
        .form => {
            const schema = parsed.value.object.get("requestedSchema") orelse return error.InvalidRequest;
            const schema_json = try stringifyBounded(alloc, schema, limits.max_schema_bytes);
            request.requested_schema_json = schema_json;
            var form = try parseFormSchemaValue(alloc, wire, schema, limits);
            form.deinit(alloc);
        },
        .url => {
            if (parsed.value.object.get("requestedSchema") != null) return error.InvalidRequest;
            const url_value = parsed.value.object.get("url") orelse return error.InvalidRequest;
            request.url = try copyString(alloc, url_value, limits.max_string_bytes, error.InvalidRequest);
            request.url_host = try classifyUrl(alloc, request.url.?, limits);
            if (wire == .acp or wire == .legacy_mcp_2025_11) {
                const id_value = parsed.value.object.get("elicitationId") orelse return error.InvalidRequest;
                request.elicitation_id = try copyString(
                    alloc,
                    id_value,
                    limits.max_name_bytes,
                    error.InvalidRequest,
                );
            } else if (parsed.value.object.get("elicitationId") != null) {
                return error.InvalidRequest;
            }
        },
        .unknown => unreachable,
    }
    return request;
}

fn parseMode(wire: Wire, mode: ?std.json.Value) Mode {
    if (mode == null) return if (wire == .acp) .unknown else .form;
    if (wire == .legacy_mcp_2025_06) return .unknown;
    if (mode.? != .string) return .unknown;
    if (std.mem.eql(u8, mode.?.string, "form")) return .form;
    if (std.mem.eql(u8, mode.?.string, "url")) return .url;
    return .unknown;
}

fn classifyUrl(alloc: Allocator, url: []const u8, limits: Limits) Error![]u8 {
    if (url.len == 0 or url.len > limits.max_string_bytes or
        !std.mem.eql(u8, url, std.mem.trim(u8, url, " \t\r\n")))
    {
        return error.InvalidUrl;
    }
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (uri.host == null or uri.user != null or uri.password != null) return error.InvalidUrl;

    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.host.?.toRaw(&host_buffer) catch return error.InvalidUrl;
    if (host.len == 0) return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !isLoopbackHttp(uri, host)) {
        return error.InsecureUrl;
    }
    return alloc.dupe(u8, host);
}

fn isLoopbackHttp(uri: std.Uri, host: []const u8) bool {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]");
}

pub const FormSchema = struct {
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    fields: []Field,

    pub fn deinit(self: *FormSchema, alloc: Allocator) void {
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        for (self.fields) |*field| field.deinit(alloc);
        alloc.free(self.fields);
        self.* = undefined;
    }
};

const FieldKind = enum {
    string,
    number,
    integer,
    boolean,
    single_select,
    multi_select,
};

const Format = enum {
    none,
    email,
    uri,
    date,
    date_time,
    unknown,
};

pub const Choice = struct {
    value: []u8,
    title: []u8,
    description: ?[]u8 = null,

    fn deinit(self: *Choice, alloc: Allocator) void {
        alloc.free(self.value);
        alloc.free(self.title);
        if (self.description) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Field = struct {
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    kind: FieldKind,
    required: bool,
    default_json: ?[]u8 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    minimum: ?json_number.Number = null,
    maximum: ?json_number.Number = null,
    multiple_of: ?json_number.Number = null,
    min_items: ?usize = null,
    max_items: ?usize = null,
    format: Format = .none,
    format_name: ?[]u8 = null,
    pattern: ?[]u8 = null,
    choices: []Choice = &.{},

    fn deinit(self: *Field, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        if (self.default_json) |value| alloc.free(value);
        if (self.format_name) |value| alloc.free(value);
        if (self.pattern) |value| alloc.free(value);
        if (self.minimum) |*value| value.deinit(alloc);
        if (self.maximum) |*value| value.deinit(alloc);
        if (self.multiple_of) |*value| value.deinit(alloc);
        for (self.choices) |*choice| choice.deinit(alloc);
        if (self.choices.len > 0) alloc.free(self.choices);
        self.* = undefined;
    }

    pub fn displayName(self: Field) []const u8 {
        return self.title orelse self.name;
    }
};

pub fn parseFormSchema(
    alloc: Allocator,
    wire: Wire,
    schema_json: []const u8,
    limits: Limits,
) Error!FormSchema {
    if (schema_json.len > limits.max_schema_bytes) return error.LimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSchema,
    };
    defer parsed.deinit();
    return parseFormSchemaValue(alloc, wire, parsed.value, limits);
}

fn parseFormSchemaValue(
    alloc: Allocator,
    wire: Wire,
    schema: std.json.Value,
    limits: Limits,
) Error!FormSchema {
    if (schema != .object) return error.InvalidSchema;
    if (wire == .acp and
        (containsKeyRecursive(schema, "$schema", schemaNodeLimit(limits)) or
            containsKeyRecursive(schema, "enumNames", schemaNodeLimit(limits))))
    {
        return error.UnsupportedSchema;
    }
    if (wire != .acp and
        (schema.object.get("title") != null or schema.object.get("description") != null))
    {
        return error.UnsupportedSchema;
    }
    if (schema.object.get("additionalProperties")) |additional| {
        if (additional != .bool or additional.bool) return error.UnsupportedSchema;
    }
    const type_value = schema.object.get("type") orelse return error.InvalidSchema;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "object")) {
        return error.InvalidSchema;
    }
    const properties = schema.object.get("properties") orelse return error.InvalidSchema;
    if (properties != .object or properties.object.count() > limits.max_fields) {
        return error.LimitExceeded;
    }

    var required_names: std.StringHashMapUnmanaged(void) = .empty;
    defer required_names.deinit(alloc);
    if (schema.object.get("required")) |required| {
        if (required != .array or required.array.items.len > limits.max_fields) {
            return error.InvalidSchema;
        }
        for (required.array.items) |name| {
            if (name != .string or name.string.len == 0 or name.string.len > limits.max_name_bytes or
                !properties.object.contains(name.string))
            {
                return error.InvalidSchema;
            }
            if (required_names.contains(name.string)) return error.InvalidSchema;
            try required_names.put(alloc, name.string, {});
        }
    }

    const fields = fields: {
        const owned = try alloc.alloc(Field, properties.object.count());
        var field_count: usize = 0;
        errdefer {
            for (owned[0..field_count]) |*field| field.deinit(alloc);
            alloc.free(owned);
        }

        var iterator = properties.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.len == 0 or entry.key_ptr.len > limits.max_name_bytes) {
                return error.InvalidSchema;
            }
            try parseFieldInto(
                &owned[field_count],
                alloc,
                wire,
                entry.key_ptr.*,
                entry.value_ptr.*,
                required_names.contains(entry.key_ptr.*),
                limits,
            );
            field_count += 1;
        }
        break :fields owned;
    };

    var result: FormSchema = .{ .fields = fields };
    errdefer result.deinit(alloc);
    if (schema.object.get("title")) |title| {
        result.title = try copyString(alloc, title, limits.max_label_bytes, error.InvalidSchema);
    }
    if (schema.object.get("description")) |description| {
        result.description = try copyString(alloc, description, limits.max_label_bytes, error.InvalidSchema);
    }
    return result;
}

fn schemaNodeLimit(limits: Limits) usize {
    return std.math.mul(usize, limits.max_fields, limits.max_options) catch
        std.math.maxInt(usize);
}

fn parseFieldInto(
    out: *Field,
    alloc: Allocator,
    wire: Wire,
    name: []const u8,
    schema: std.json.Value,
    required: bool,
    limits: Limits,
) Error!void {
    if (schema != .object) return error.InvalidSchema;
    if (wire == .acp and schema.object.get("enumNames") != null) {
        return error.UnsupportedSchema;
    }
    const type_value = schema.object.get("type") orelse return error.InvalidSchema;
    if (type_value != .string) return error.UnsupportedSchema;

    var field: Field = .{
        .name = try alloc.dupe(u8, name),
        .kind = .string,
        .required = required,
    };
    errdefer field.deinit(alloc);
    if (schema.object.get("title")) |title| {
        field.title = try copyString(alloc, title, limits.max_label_bytes, error.InvalidSchema);
    }
    if (schema.object.get("description")) |description| {
        field.description = try copyString(alloc, description, limits.max_label_bytes, error.InvalidSchema);
    }
    if (isSecretField(field.name, field.title)) return error.SecretField;

    if (std.mem.eql(u8, type_value.string, "string")) {
        field.kind = .string;
        try parseStringConstraints(alloc, &field, schema, limits, wire);
        if (schema.object.get("oneOf")) |choices| {
            if (wire == .legacy_mcp_2025_06) return error.UnsupportedSchema;
            field.choices = try parseTitledChoices(alloc, choices, limits, wire == .acp);
            field.kind = .single_select;
        } else if (schema.object.get("enum")) |choices| {
            field.choices = try parseEnumChoices(alloc, choices, schema.object.get("enumNames"), limits, wire);
            field.kind = .single_select;
        }
    } else if (std.mem.eql(u8, type_value.string, "number")) {
        field.kind = .number;
        try parseNumberConstraints(alloc, &field, schema, limits);
    } else if (std.mem.eql(u8, type_value.string, "integer")) {
        field.kind = .integer;
        try parseNumberConstraints(alloc, &field, schema, limits);
    } else if (std.mem.eql(u8, type_value.string, "boolean")) {
        field.kind = .boolean;
    } else if (std.mem.eql(u8, type_value.string, "array")) {
        if (wire == .legacy_mcp_2025_06) return error.UnsupportedSchema;
        field.kind = .multi_select;
        try parseMultiSelect(alloc, &field, schema, limits, wire);
    } else {
        return error.UnsupportedSchema;
    }

    if (schema.object.get("default")) |default_value| {
        field.default_json = try stringifyBounded(alloc, default_value, limits.max_string_bytes);
        try validateFieldValue(alloc, field, default_value, limits);
    }
    out.* = field;
}

fn parseStringConstraints(
    alloc: Allocator,
    field: *Field,
    schema: std.json.Value,
    limits: Limits,
    wire: Wire,
) Error!void {
    field.min_length = try optionalUsize(schema.object, "minLength", limits.max_string_bytes);
    field.max_length = try optionalUsize(schema.object, "maxLength", limits.max_string_bytes);
    if (field.min_length != null and field.max_length != null and field.min_length.? > field.max_length.?) {
        return error.InvalidSchema;
    }
    if (schema.object.get("format")) |format_value| {
        field.format_name = try copyString(alloc, format_value, limits.max_name_bytes, error.InvalidSchema);
        field.format = classifyFormat(field.format_name.?);
        if (field.format == .unknown and wire != .acp) return error.UnsupportedSchema;
    }
    if (schema.object.get("pattern")) |pattern_value| {
        if (wire == .legacy_mcp_2025_06) return error.UnsupportedSchema;
        if (pattern_value != .string or pattern_value.string.len > limits.max_pattern_bytes) {
            return error.LimitExceeded;
        }
        try validatePattern(alloc, pattern_value.string, limits);
        field.pattern = try alloc.dupe(u8, pattern_value.string);
    }
}

fn parseNumberConstraints(
    alloc: Allocator,
    field: *Field,
    schema: std.json.Value,
    limits: Limits,
) Error!void {
    field.minimum = try optionalExactNumber(alloc, schema.object, "minimum", limits);
    field.maximum = try optionalExactNumber(alloc, schema.object, "maximum", limits);
    field.multiple_of = try optionalExactNumber(alloc, schema.object, "multipleOf", limits);
    if (field.minimum != null and field.maximum != null and
        field.minimum.?.order(field.maximum.?) == .gt)
    {
        return error.InvalidSchema;
    }
    if (field.multiple_of) |multiple| {
        if (multiple.negative or multiple.isZero()) return error.InvalidSchema;
    }
}

fn parseMultiSelect(
    alloc: Allocator,
    field: *Field,
    schema: std.json.Value,
    limits: Limits,
    wire: Wire,
) Error!void {
    field.min_items = try optionalUsize(schema.object, "minItems", limits.max_options);
    field.max_items = try optionalUsize(schema.object, "maxItems", limits.max_options);
    if (field.min_items != null and field.max_items != null and field.min_items.? > field.max_items.?) {
        return error.InvalidSchema;
    }
    const items = schema.object.get("items") orelse return error.InvalidSchema;
    if (items != .object) return error.InvalidSchema;
    if (items.object.get("anyOf")) |choices| {
        if (items.object.get("type")) |item_type| {
            if (item_type != .string or !std.mem.eql(u8, item_type.string, "string")) {
                return error.UnsupportedSchema;
            }
        }
        field.choices = try parseTitledChoices(alloc, choices, limits, wire == .acp);
    } else if (items.object.get("enum")) |choices| {
        const item_type = items.object.get("type") orelse return error.InvalidSchema;
        if (item_type != .string or !std.mem.eql(u8, item_type.string, "string")) {
            return error.UnsupportedSchema;
        }
        field.choices = try parseEnumChoices(alloc, choices, items.object.get("enumNames"), limits, wire);
    } else {
        return error.InvalidSchema;
    }
    if (field.choices.len == 0) return error.InvalidSchema;
}

fn parseTitledChoices(
    alloc: Allocator,
    value: std.json.Value,
    limits: Limits,
    allow_description: bool,
) Error![]Choice {
    if (value != .array or value.array.items.len == 0 or value.array.items.len > limits.max_options) {
        return error.InvalidSchema;
    }
    const choices = try alloc.alloc(Choice, value.array.items.len);
    var count: usize = 0;
    errdefer {
        for (choices[0..count]) |*choice| choice.deinit(alloc);
        alloc.free(choices);
    }
    for (value.array.items) |item| {
        if (item != .object) return error.InvalidSchema;
        const const_value = item.object.get("const") orelse return error.InvalidSchema;
        const title = item.object.get("title") orelse return error.InvalidSchema;
        if (const_value != .string) return error.UnsupportedSchema;
        choices[count] = choice: {
            const choice_value = try alloc.dupe(u8, const_value.string);
            errdefer alloc.free(choice_value);
            const choice_title = try copyString(alloc, title, limits.max_label_bytes, error.InvalidSchema);
            errdefer alloc.free(choice_title);
            break :choice .{
                .value = choice_value,
                .title = choice_title,
            };
        };
        for (choices[0..count]) |prior| {
            if (std.mem.eql(u8, prior.value, choices[count].value)) {
                choices[count].deinit(alloc);
                return error.InvalidSchema;
            }
        }
        if (item.object.get("description")) |description| {
            if (!allow_description) {
                choices[count].deinit(alloc);
                return error.UnsupportedSchema;
            }
            choices[count].description = copyString(
                alloc,
                description,
                limits.max_label_bytes,
                error.InvalidSchema,
            ) catch |err| {
                choices[count].deinit(alloc);
                return err;
            };
        }
        count += 1;
    }
    return choices;
}

fn parseEnumChoices(
    alloc: Allocator,
    value: std.json.Value,
    enum_names: ?std.json.Value,
    limits: Limits,
    wire: Wire,
) Error![]Choice {
    if (value != .array or value.array.items.len == 0 or value.array.items.len > limits.max_options) {
        return error.InvalidSchema;
    }
    if (wire == .acp and enum_names != null) return error.UnsupportedSchema;
    if (enum_names) |names| if (names != .array or names.array.items.len != value.array.items.len) {
        return error.InvalidSchema;
    };
    const choices = try alloc.alloc(Choice, value.array.items.len);
    var count: usize = 0;
    errdefer {
        for (choices[0..count]) |*choice| choice.deinit(alloc);
        alloc.free(choices);
    }
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.UnsupportedSchema;
        const title_value = if (enum_names) |names| names.array.items[index] else item;
        choices[count] = choice: {
            const choice_value = try alloc.dupe(u8, item.string);
            errdefer alloc.free(choice_value);
            const choice_title = try copyString(alloc, title_value, limits.max_label_bytes, error.InvalidSchema);
            errdefer alloc.free(choice_title);
            break :choice .{
                .value = choice_value,
                .title = choice_title,
            };
        };
        for (choices[0..count]) |prior| {
            if (std.mem.eql(u8, prior.value, choices[count].value)) {
                choices[count].deinit(alloc);
                return error.InvalidSchema;
            }
        }
        count += 1;
    }
    return choices;
}

pub fn validateResponse(
    alloc: Allocator,
    request: Request,
    response_json: []const u8,
    limits: Limits,
) Error!Action {
    if (response_json.len > limits.max_response_bytes) return error.LimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const action_value = parsed.value.object.get("action") orelse return error.InvalidResponse;
    const action = parseAction(action_value);
    if (action == .unknown) return error.UnsupportedAction;
    const content = parsed.value.object.get("content");
    if (action != .accept) return action;
    switch (request.mode) {
        .url => if (content != null) return error.InvalidResponse,
        .form => {
            const value = content orelse return error.InvalidResponse;
            const schema_json = request.requested_schema_json orelse return error.InvalidRequest;
            var form = try parseFormSchema(alloc, request.wire, schema_json, limits);
            defer form.deinit(alloc);
            try validateFormContent(alloc, form, value, limits);
        },
        .unknown => return error.UnsupportedMode,
    }
    return action;
}

/// Produces the smallest response safe to place on the originating MCP wire.
/// In particular, ignored ACP fields and content attached to decline/cancel or
/// URL consent are never forwarded to the MCP server.
pub fn canonicalResponse(
    alloc: Allocator,
    request: Request,
    response_json: []const u8,
    limits: Limits,
) Error![]u8 {
    const action = try validateResponse(alloc, request, response_json, limits);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("{\"action\":") catch return error.OutOfMemory;
    std.json.Stringify.value(@tagName(action), .{}, &out.writer) catch return error.OutOfMemory;
    if (action == .accept and request.mode == .form) {
        const content = parsed.value.object.get("content") orelse return error.InvalidResponse;
        out.writer.writeAll(",\"content\":") catch return error.OutOfMemory;
        std.json.Stringify.value(content, .{}, &out.writer) catch return error.OutOfMemory;
    }
    out.writer.writeByte('}') catch return error.OutOfMemory;
    if (out.written().len > limits.max_response_bytes) return error.LimitExceeded;
    return out.toOwnedSlice();
}

fn validateFormContent(
    alloc: Allocator,
    form: FormSchema,
    content: std.json.Value,
    limits: Limits,
) Error!void {
    if (content != .object or content.object.count() > form.fields.len) return error.InvalidResponse;
    for (form.fields) |field| {
        const value = content.object.get(field.name);
        if (value == null) {
            if (field.required) return error.InvalidResponse;
            continue;
        }
        try validateFieldValue(alloc, field, value.?, limits);
    }
    var iterator = content.object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (form.fields) |field| {
            if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidResponse;
    }
}

/// Validates one already-encoded field value without exposing it in an error.
/// UI adapters use this before advancing to the next field so constraint
/// failures can be reported while the value remains confined to the adapter.
pub fn validateFieldJson(
    alloc: Allocator,
    field: Field,
    value_json: []const u8,
    limits: Limits,
) Error!void {
    if (value_json.len > limits.max_response_bytes) return error.LimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, value_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    try validateFieldValue(alloc, field, parsed.value, limits);
}

fn validateFieldValue(
    alloc: Allocator,
    field: Field,
    value: std.json.Value,
    limits: Limits,
) Error!void {
    switch (field.kind) {
        .string => {
            if (value != .string or value.string.len > limits.max_string_bytes) return error.InvalidResponse;
            const rune_count = std.unicode.utf8CountCodepoints(value.string) catch return error.InvalidResponse;
            if (field.min_length) |minimum| if (rune_count < minimum) return error.InvalidResponse;
            if (field.max_length) |maximum| if (rune_count > maximum) return error.InvalidResponse;
            if (field.pattern) |pattern| if (!try patternMatches(alloc, pattern, value.string, limits)) {
                return error.InvalidResponse;
            };
            if (!validFormat(field.format, value.string)) return error.InvalidResponse;
        },
        .number, .integer => {
            const parsed_number = json_number.fromValue(
                alloc,
                value,
                exactNumberLimits(limits),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidResponse,
            };
            if (parsed_number == null) return error.InvalidResponse;
            var number = parsed_number.?;
            defer number.deinit(alloc);
            if (field.kind == .integer and !number.isInteger()) return error.InvalidResponse;
            if (field.minimum) |minimum| if (number.order(minimum) == .lt) {
                return error.InvalidResponse;
            };
            if (field.maximum) |maximum| if (number.order(maximum) == .gt) {
                return error.InvalidResponse;
            };
            if (field.multiple_of) |multiple| {
                const is_multiple = number.isMultipleOf(
                    alloc,
                    multiple,
                    exactNumberLimits(limits),
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidResponse,
                };
                if (!is_multiple) return error.InvalidResponse;
            }
        },
        .boolean => if (value != .bool) return error.InvalidResponse,
        .single_select => {
            if (value != .string or !choiceContains(field.choices, value.string)) return error.InvalidResponse;
        },
        .multi_select => {
            if (value != .array or value.array.items.len > field.choices.len) return error.InvalidResponse;
            if (field.min_items) |minimum| if (value.array.items.len < minimum) return error.InvalidResponse;
            if (field.max_items) |maximum| if (value.array.items.len > maximum) return error.InvalidResponse;
            for (value.array.items, 0..) |item, index| {
                if (item != .string or !choiceContains(field.choices, item.string)) return error.InvalidResponse;
                for (value.array.items[0..index]) |prior| {
                    if (prior == .string and std.mem.eql(u8, prior.string, item.string)) return error.InvalidResponse;
                }
            }
        },
    }
}

fn choiceContains(choices: []const Choice, value: []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, choice.value, value)) return true;
    return false;
}

fn isSecretField(name: []const u8, title: ?[]const u8) bool {
    if (containsSecretTerm(name)) return true;
    if (title) |value| if (containsSecretTerm(value)) return true;
    return false;
}

fn containsSecretTerm(value: []const u8) bool {
    const single_terms = [_][]const u8{
        "token",          "secret",            "credential",
        "credentials",    "password",          "passcode",
        "passphrase",     "otp",               "pin",
        "apikey",         "apitoken",          "accesstoken",
        "refreshtoken",   "authtoken",         "bearertoken",
        "privatekey",     "secretkey",         "signingkey",
        "sshkey",         "clientsecret",      "authorizationcode",
        "recoverycode",   "backupcode",        "seedphrase",
        "recoveryphrase", "creditcard",        "cardnumber",
        "securitycode",   "paymentcredential", "paymentcredentials",
        "bankaccount",    "socialsecurity",    "cvv",
        "cvc",            "paymentcard",       "paymenttoken",
    };
    const two_word_terms = [_][2][]const u8{
        .{ "api", "key" },
        .{ "api", "token" },
        .{ "access", "token" },
        .{ "refresh", "token" },
        .{ "auth", "token" },
        .{ "bearer", "token" },
        .{ "private", "key" },
        .{ "secret", "key" },
        .{ "signing", "key" },
        .{ "ssh", "key" },
        .{ "client", "secret" },
        .{ "authorization", "code" },
        .{ "recovery", "code" },
        .{ "backup", "code" },
        .{ "seed", "phrase" },
        .{ "recovery", "phrase" },
        .{ "credit", "card" },
        .{ "card", "number" },
        .{ "security", "code" },
        .{ "payment", "credential" },
        .{ "payment", "credentials" },
        .{ "payment", "card" },
        .{ "payment", "token" },
        .{ "bank", "account" },
        .{ "social", "security" },
    };

    var cursor: usize = 0;
    var previous: ?[]const u8 = null;
    while (nextNormalizedWord(value, &cursor)) |word| {
        for (single_terms) |term| {
            if (std.ascii.eqlIgnoreCase(word, term)) return true;
        }
        if (previous) |prior| {
            for (two_word_terms) |term| {
                if (std.ascii.eqlIgnoreCase(prior, term[0]) and
                    std.ascii.eqlIgnoreCase(word, term[1])) return true;
            }
        }
        previous = word;
    }
    return false;
}

fn nextNormalizedWord(value: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < value.len and !std.ascii.isAlphanumeric(value[cursor.*])) {
        cursor.* += 1;
    }
    if (cursor.* == value.len) return null;

    const start = cursor.*;
    var index = start + 1;
    while (index < value.len and std.ascii.isAlphanumeric(value[index])) : (index += 1) {
        const current = value[index];
        const previous = value[index - 1];
        if (std.ascii.isUpper(current) and
            (std.ascii.isLower(previous) or std.ascii.isDigit(previous)))
        {
            cursor.* = index;
            return value[start..index];
        }
        if (std.ascii.isLower(current) and std.ascii.isUpper(previous) and
            index > start + 1 and std.ascii.isUpper(value[index - 2]))
        {
            cursor.* = index - 1;
            return value[start .. index - 1];
        }
    }
    cursor.* = index;
    return value[start..index];
}

fn optionalUsize(object: std.json.ObjectMap, name: []const u8, maximum: usize) Error!?usize {
    const value = object.get(name) orelse return null;
    const integer = switch (value) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return error.InvalidSchema,
        else => return error.InvalidSchema,
    };
    if (integer < 0) return error.InvalidSchema;
    const converted = std.math.cast(usize, integer) orelse return error.LimitExceeded;
    if (converted > maximum) return error.LimitExceeded;
    return converted;
}

fn optionalExactNumber(
    alloc: Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
    limits: Limits,
) Error!?json_number.Number {
    const value = object.get(name) orelse return null;
    return (json_number.fromValue(alloc, value, exactNumberLimits(limits)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NumberLimitExceeded => return error.LimitExceeded,
        error.InvalidNumber => return error.InvalidSchema,
    }) orelse error.InvalidSchema;
}

fn exactNumberLimits(limits: Limits) json_number.Limits {
    return .{
        .max_lexeme_bytes = limits.max_number_bytes,
        .max_exponent_abs = limits.max_number_exponent_abs,
        .max_expanded_digits = limits.max_number_expanded_digits,
    };
}

fn classifyFormat(value: []const u8) Format {
    if (std.mem.eql(u8, value, "email")) return .email;
    if (std.mem.eql(u8, value, "uri")) return .uri;
    if (std.mem.eql(u8, value, "date")) return .date;
    if (std.mem.eql(u8, value, "date-time")) return .date_time;
    return .unknown;
}

fn validFormat(format: Format, value: []const u8) bool {
    return switch (format) {
        .none, .unknown => true,
        .email => simpleEmail(value),
        .uri => std.Uri.parse(value) catch null != null,
        .date => validDate(value),
        .date_time => validDateTime(value),
    };
}

fn simpleEmail(value: []const u8) bool {
    const at = std.mem.findScalar(u8, value, '@') orelse return false;
    if (at == 0 or at + 1 >= value.len) return false;
    if (std.mem.findScalar(u8, value[at + 1 ..], '@') != null) return false;
    return std.mem.findScalar(u8, value[at + 1 ..], '.') != null;
}

fn validDate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    if (year == 0 or month == 0 or month > 12 or day == 0) return false;
    const days = [_]u8{ 31, if (isLeapYear(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day <= days[month - 1];
}

fn validDateTime(value: []const u8) bool {
    if (value.len < 20 or !validDate(value[0..10]) or
        (value[10] != 'T' and value[10] != 't') or
        value[13] != ':' or value[16] != ':') return false;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return false;
    if (hour > 23 or minute > 59 or second > 60) return false;

    var index: usize = 19;
    if (index < value.len and value[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
        if (index == fraction_start) return false;
    }
    if (index + 1 == value.len and (value[index] == 'Z' or value[index] == 'z')) return true;
    if (index + 6 != value.len or (value[index] != '+' and value[index] != '-') or
        value[index + 3] != ':') return false;
    const offset_hour = std.fmt.parseInt(u8, value[index + 1 .. index + 3], 10) catch return false;
    const offset_minute = std.fmt.parseInt(u8, value[index + 4 .. index + 6], 10) catch return false;
    return offset_hour <= 23 and offset_minute <= 59;
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn patternLimits(limits: Limits) json_schema_pattern.Limits {
    return .{
        .max_depth = limits.max_pattern_depth,
        .max_states = limits.max_pattern_states,
        .max_repeat = limits.max_pattern_repeat,
        .max_steps = limits.max_pattern_steps,
    };
}

fn validatePattern(alloc: Allocator, pattern: []const u8, limits: Limits) Error!void {
    json_schema_pattern.validate(alloc, pattern, patternLimits(limits)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPattern, error.InvalidUtf8 => return error.InvalidSchema,
        error.PatternLimitExceeded => return error.LimitExceeded,
    };
}

fn patternMatches(
    alloc: Allocator,
    pattern: []const u8,
    input: []const u8,
    limits: Limits,
) Error!bool {
    var steps: usize = 0;
    return json_schema_pattern.matches(
        alloc,
        pattern,
        input,
        patternLimits(limits),
        &steps,
    ) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPattern => error.InvalidSchema,
        error.InvalidUtf8 => error.InvalidResponse,
        error.PatternLimitExceeded => error.LimitExceeded,
    };
}

fn copyString(
    alloc: Allocator,
    value: std.json.Value,
    max_bytes: usize,
    invalid: Error,
) Error![]u8 {
    if (value != .string or value.string.len > max_bytes) return invalid;
    return alloc.dupe(u8, value.string);
}

fn stringifyBounded(alloc: Allocator, value: std.json.Value, max_bytes: usize) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    if (out.written().len > max_bytes) return error.LimitExceeded;
    return out.toOwnedSlice();
}

test "ACP and modern MCP capability fallbacks stay distinct" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        json: []const u8,
        acp: Capabilities,
        mcp: Capabilities,
    }{
        .{ .json = "{}", .acp = .{}, .mcp = .{} },
        .{ .json = "{\"elicitation\":null}", .acp = .{}, .mcp = .{} },
        .{ .json = "{\"elicitation\":{}}", .acp = .{}, .mcp = .{ .form = true } },
        .{ .json = "{\"elicitation\":{\"form\":null,\"url\":null}}", .acp = .{}, .mcp = .{} },
        .{ .json = "{\"elicitation\":{\"form\":{},\"url\":{}}}", .acp = .{ .form = true, .url = true }, .mcp = .{ .form = true, .url = true } },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.acp, parseAcpCapabilities(parsed.value));
        try std.testing.expectEqual(case.mcp, parseModernMcpCapabilities(parsed.value));
    }
}

test "form schemas parse every supported field kind and validate content" {
    const alloc = std.testing.allocator;
    const schema =
        \\{"type":"object","title":"Profile","additionalProperties":false,"properties":{"name":{"type":"string","minLength":2,"maxLength":20,"pattern":"^[A-Za-z]+$"},"age":{"type":"integer","minimum":18,"maximum":120},"ratio":{"type":"number","minimum":0,"maximum":1},"enabled":{"type":"boolean","default":true},"color":{"type":"string","oneOf":[{"const":"red","title":"Red"},{"const":"blue","title":"Blue"}]},"tags":{"type":"array","items":{"anyOf":[{"const":"a","title":"A"},{"const":"b","title":"B"}]},"minItems":1}},"required":["name","age"]}
    ;
    var form = try parseFormSchema(alloc, .acp, schema, .{});
    defer form.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 6), form.fields.len);

    var valid = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"name\":\"Alice\",\"age\":42,\"ratio\":0.5,\"enabled\":false,\"color\":\"red\",\"tags\":[\"a\",\"b\"]}",
        .{ .parse_numbers = false },
    );
    defer valid.deinit();
    try validateFormContent(alloc, form, valid.value, .{});

    var invalid = try std.json.parseFromSlice(std.json.Value, alloc, "{\"name\":\"A1\",\"age\":17}", .{ .parse_numbers = false });
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidResponse, validateFormContent(alloc, form, invalid.value, .{}));
}

test "secret fields are rejected before a form is published" {
    const schemas = [_][]const u8{
        "{\"type\":\"object\",\"properties\":{\"api_key\":{\"type\":\"string\"}}}",
        "{\"type\":\"object\",\"properties\":{\"accessToken\":{\"type\":\"string\"}}}",
        "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\",\"title\":\"PrivateKey\"}}}",
    };
    for (schemas) |schema| {
        try std.testing.expectError(
            error.SecretField,
            parseFormSchema(std.testing.allocator, .modern_mcp, schema, .{}),
        );
    }

    var guidance = try parseFormSchema(
        std.testing.allocator,
        .modern_mcp,
        "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\",\"description\":\"Do not give us your phone number, pin, or other sensitive info\"}}}",
        .{},
    );
    guidance.deinit(std.testing.allocator);
}

test "secret classification covers normalized forms without truncation bypasses" {
    const secret_names = [_][]const u8{
        "token",
        "client_secret",
        "paymentCredential",
        "PASSWORD",
        "user-passcode",
        "otp",
        "userPin",
        "api key",
        "APIKey",
        "access.token",
        "privateKey",
        "credit-card",
    };
    for (secret_names) |name| {
        try std.testing.expect(isSecretField(name, null));
    }
    try std.testing.expect(!isSecretField("shipping_address", "Shipping address"));

    var long_name: [1536]u8 = undefined;
    @memset(&long_name, 'a');
    @memcpy(long_name[long_name.len - "AccessToken".len ..], "AccessToken");
    try std.testing.expect(isSecretField(&long_name, null));

    const description = try std.testing.allocator.alloc(u8, 1500);
    defer std.testing.allocator.free(description);
    @memset(description, 'a');
    @memcpy(description[description.len - " private key".len ..], " private key");
    const schema = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"type\":\"object\",\"properties\":{{\"value\":{{\"type\":\"string\",\"description\":\"{s}\"}}}}}}",
        .{description},
    );
    defer std.testing.allocator.free(schema);
    var form = try parseFormSchema(
        std.testing.allocator,
        .acp,
        schema,
        .{ .max_label_bytes = 2048 },
    );
    form.deinit(std.testing.allocator);
}

test "legacy schemas are explicitly scoped to their negotiated revision" {
    const alloc = std.testing.allocator;
    const legacy_06 =
        "{\"message\":\"Choose\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"choice\":{\"type\":\"string\",\"enum\":[\"a\"],\"enumNames\":[\"A\"]}}}}";
    var request_06 = try parseRequest(alloc, .legacy_mcp_2025_06, legacy_06, .{});
    defer request_06.deinit(alloc);
    try std.testing.expectEqual(Mode.form, request_06.mode);
    try std.testing.expectError(
        error.UnsupportedMode,
        parseRequest(
            alloc,
            .legacy_mcp_2025_06,
            "{\"mode\":\"form\",\"message\":\"No explicit mode\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}",
            .{},
        ),
    );
    try std.testing.expectError(
        error.UnsupportedSchema,
        parseRequest(
            alloc,
            .legacy_mcp_2025_06,
            "{\"message\":\"No pattern\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\",\"pattern\":\"^[a-z]+$\"}}}}",
            .{},
        ),
    );

    var request_11 = try parseRequest(
        alloc,
        .legacy_mcp_2025_11,
        "{\"mode\":\"form\",\"message\":\"Pattern\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\",\"pattern\":\"^[a-z]+$\"}}}}",
        .{},
    );
    defer request_11.deinit(alloc);
    try std.testing.expectEqual(Mode.form, request_11.mode);
    var request_11_enum_names = try parseRequest(
        alloc,
        .legacy_mcp_2025_11,
        legacy_06,
        .{},
    );
    defer request_11_enum_names.deinit(alloc);
    var parsed_11_form = try parseFormSchema(
        alloc,
        .legacy_mcp_2025_11,
        request_11_enum_names.requested_schema_json.?,
        .{},
    );
    defer parsed_11_form.deinit(alloc);
    try std.testing.expectEqualStrings("A", parsed_11_form.fields[0].choices[0].title);

    try std.testing.expectError(
        error.UnsupportedSchema,
        parseFormSchema(
            alloc,
            .acp,
            "{\"type\":\"object\",\"properties\":{\"choice\":{\"type\":\"string\",\"enum\":[\"a\"],\"enumNames\":[\"A\"]}}}",
            .{},
        ),
    );
}

test "exact numeric constraints retain large integer and fractional lexemes" {
    const alloc = std.testing.allocator;
    var form = try parseFormSchema(
        alloc,
        .acp,
        "{\"type\":\"object\",\"properties\":{\"large\":{\"type\":\"integer\",\"minimum\":9007199254740993,\"maximum\":9007199254740995,\"default\":9007199254740994},\"fraction\":{\"type\":\"number\",\"minimum\":0.1,\"maximum\":0.3,\"multipleOf\":0.1,\"default\":0.3}},\"required\":[\"large\",\"fraction\"]}",
        .{},
    );
    defer form.deinit(alloc);

    var valid = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"large\":9007199254740994,\"fraction\":0.300000000000000000000000000000}",
        .{ .parse_numbers = false },
    );
    defer valid.deinit();
    try validateFormContent(alloc, form, valid.value, .{});

    var rounded_down = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"large\":9007199254740992,\"fraction\":0.3}",
        .{ .parse_numbers = false },
    );
    defer rounded_down.deinit();
    try std.testing.expectError(error.InvalidResponse, validateFormContent(alloc, form, rounded_down.value, .{}));

    var not_multiple = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"large\":9007199254740994,\"fraction\":0.300000000000000000000000000001}",
        .{ .parse_numbers = false },
    );
    defer not_multiple.deinit();
    try std.testing.expectError(error.InvalidResponse, validateFormContent(alloc, form, not_multiple.value, .{}));
}

test "2025-11 URL-required errors parse only on their negotiated wire" {
    const alloc = std.testing.allocator;
    const data =
        "{\"elicitations\":[{\"mode\":\"url\",\"message\":\"Authorize\",\"url\":\"https://example.test/connect\",\"elicitationId\":\"url-1\"}]}";
    var required = try parseLegacyUrlRequired(alloc, .legacy_mcp_2025_11, data, .{});
    defer required.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), required.requests.len);
    try std.testing.expectEqualStrings("url-1", required.requests[0].elicitation_id.?);
    const rendered = try renderLegacyUrlRequiredRequests(alloc, required, .{});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"url-1\":{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"url\",\"message\":\"Authorize\",\"url\":\"https://example.test/connect\",\"elicitationId\":\"url-1\"}}}",
        rendered,
    );
    try std.testing.expectError(
        error.UnsupportedMode,
        parseLegacyUrlRequired(alloc, .legacy_mcp_2025_06, data, .{}),
    );
    try std.testing.expectError(
        error.InvalidRequest,
        parseLegacyUrlRequired(
            alloc,
            .legacy_mcp_2025_11,
            "{\"elicitations\":[{\"mode\":\"form\",\"message\":\"No\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{}}}]}",
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidRequest,
        parseLegacyUrlRequired(
            alloc,
            .legacy_mcp_2025_11,
            "{\"elicitations\":[{\"mode\":\"url\",\"message\":\"One\",\"url\":\"https://example.test/one\",\"elicitationId\":\"same\"},{\"mode\":\"url\",\"message\":\"Two\",\"url\":\"https://example.test/two\",\"elicitationId\":\"same\"}]}",
            .{},
        ),
    );
}

test "ambiguous schemas are rejected before interaction" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidSchema,
        parseFormSchema(
            alloc,
            .acp,
            "{\"type\":\"object\",\"properties\":{\"color\":{\"type\":\"string\",\"enum\":[\"red\",\"red\"]}}}",
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidSchema,
        parseFormSchema(
            alloc,
            .acp,
            "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\",\"name\"]}",
            .{},
        ),
    );
    try std.testing.expectError(
        error.UnsupportedSchema,
        parseFormSchema(
            alloc,
            .acp,
            "{\"type\":\"object\",\"additionalProperties\":true,\"properties\":{}}",
            .{},
        ),
    );
}

test "unknown formats remain ACP annotations but are not widened onto MCP" {
    const alloc = std.testing.allocator;
    const schema =
        "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\",\"format\":\"future-format\"}}}";
    var acp = try parseFormSchema(alloc, .acp, schema, .{});
    defer acp.deinit(alloc);
    try std.testing.expectEqual(Format.unknown, acp.fields[0].format);
    try std.testing.expectEqualStrings("future-format", acp.fields[0].format_name.?);
    try std.testing.expectError(
        error.UnsupportedSchema,
        parseFormSchema(alloc, .modern_mcp, schema, .{}),
    );
}

test "known formats use bounded structural validation" {
    try std.testing.expect(validFormat(.email, "user@example.test"));
    try std.testing.expect(!validFormat(.email, "not-an-email"));
    try std.testing.expect(validFormat(.date, "2024-02-29"));
    try std.testing.expect(!validFormat(.date, "2023-02-29"));
    try std.testing.expect(validFormat(.date_time, "2026-08-02T12:34:56.123-04:00"));
    try std.testing.expect(!validFormat(.date_time, "2026-08-02T99:34:56Z"));
}

test "elicitation patterns use bounded codepoint semantics" {
    const alloc = std.testing.allocator;
    var valid = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"glyph\":\"\\u03c0\",\"space\":\"\\u00a0\"}",
        .{},
    );
    defer valid.deinit();

    var too_many_codepoints = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"glyph\":\"\\u03c0a\",\"space\":\"\\u00a0\"}",
        .{},
    );
    defer too_many_codepoints.deinit();

    for ([_]Wire{ .modern_mcp, .legacy_mcp_2025_11, .acp }) |wire| {
        var form = try parseFormSchema(
            alloc,
            wire,
            "{\"type\":\"object\",\"properties\":{\"glyph\":{\"type\":\"string\",\"pattern\":\"^.{1}$\"},\"space\":{\"type\":\"string\",\"pattern\":\"^\\\\s$\"}},\"required\":[\"glyph\",\"space\"]}",
            .{},
        );
        defer form.deinit(alloc);
        try validateFormContent(alloc, form, valid.value, .{});
        try std.testing.expectError(
            error.InvalidResponse,
            validateFormContent(alloc, form, too_many_codepoints.value, .{}),
        );
    }

    try std.testing.expectError(
        error.InvalidSchema,
        parseFormSchema(
            alloc,
            .modern_mcp,
            "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\",\"pattern\":\"(?=x)\"}}}",
            .{},
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        parseFormSchema(
            alloc,
            .modern_mcp,
            "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\",\"pattern\":\"^a$\"}}}",
            .{ .max_pattern_states = 1 },
        ),
    );
}

test "duplicate titled alternatives remain valid distinct schema choices" {
    var schema = try parseFormSchema(
        std.testing.allocator,
        .modern_mcp,
        "{\"type\":\"object\",\"properties\":{\"choice\":{\"type\":\"string\",\"oneOf\":[{\"const\":\"first\",\"title\":\"Duplicate\"},{\"const\":\"second\",\"title\":\"Duplicate\"}]}},\"required\":[\"choice\"]}",
        .{},
    );
    defer schema.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), schema.fields.len);
    try std.testing.expectEqual(@as(usize, 2), schema.fields[0].choices.len);
    try std.testing.expectEqualStrings("Duplicate", schema.fields[0].choices[0].title);
    try std.testing.expectEqualStrings("Duplicate", schema.fields[0].choices[1].title);
}

test "URL classification permits secure and loopback URLs only" {
    const alloc = std.testing.allocator;
    const host = try classifyUrl(alloc, "https://example.test/full/path?state=opaque", .{});
    defer alloc.free(host);
    try std.testing.expectEqualStrings("example.test", host);
    const loopback = try classifyUrl(alloc, "http://localhost:4321/callback", .{});
    defer alloc.free(loopback);
    try std.testing.expectEqualStrings("localhost", loopback);
    try std.testing.expectError(error.InsecureUrl, classifyUrl(alloc, "http://example.test", .{}));
    try std.testing.expectError(error.InvalidUrl, classifyUrl(alloc, "https://user@example.test", .{}));
}

test "host classification warns for punycode and non-ASCII without I/O" {
    try std.testing.expectEqual(HostClassification.ordinary, classifyHost("example.test"));
    try std.testing.expectEqual(HostClassification.punycode, classifyHost("XN--e1awd7f.test"));
    try std.testing.expectEqual(HostClassification.punycode, classifyHost("login.xn--pple-43d.test"));
    try std.testing.expectEqual(HostClassification.non_ascii, classifyHost("ex\xc3\xa4mple.test"));
}

test "legacy URL completion notification classification validates the full bounded envelope" {
    const alloc = std.testing.allocator;
    const malformed = [_][]const u8{
        "null",
        "{}",
        "{\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"id\"}}",
        "{\"jsonrpc\":\"1.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"id\"}}",
        "{\"jsonrpc\":2,\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"id\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/completed\",\"params\":{\"elicitationId\":\"id\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":[]}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":7}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"\"}}",
    };
    for (malformed) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expect(classifyLegacyUrlCompletionNotification(parsed.value, .{}) == null);
    }

    const oversized_id = try alloc.alloc(u8, (Limits{}).max_elicitation_id_bytes + 1);
    defer alloc.free(oversized_id);
    @memset(oversized_id, 'x');
    const oversized_json = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{{\"elicitationId\":\"{s}\"}}}}",
        .{oversized_id},
    );
    defer alloc.free(oversized_json);
    var oversized = try std.json.parseFromSlice(std.json.Value, alloc, oversized_json, .{});
    defer oversized.deinit();
    try std.testing.expect(classifyLegacyUrlCompletionNotification(oversized.value, .{}) == null);

    var valid = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"matching-id\"}}",
        .{},
    );
    defer valid.deinit();
    const notification = classifyLegacyUrlCompletionNotification(valid.value, .{}).?;
    try std.testing.expectEqualStrings("matching-id", notification.elicitation_id);
}

test "legacy URL completion correlation requires every bound unique ID" {
    const binding = Binding{
        .server_name = "server-a",
        .scope = .{ .operation = .{ .tools_call = "authorize" } },
        .connection_generation = 4,
        .client_generation = 5,
        .catalog_generation = 6,
        .request_generation = 7,
        .auth_generation = 8,
        .deadline_ms = 100,
    };
    const ids = [_][]const u8{ "one", "two" };
    var completed = [_]bool{ false, false };
    const first = decideLegacyUrlCompletion(
        binding,
        &ids,
        &completed,
        .{
            .server_name = "server-a",
            .elicitation_id = "one",
            .connection_generation = 4,
            .client_generation = 5,
            .catalog_generation = 6,
            .auth_generation = 8,
        },
        99,
        true,
    );
    try std.testing.expectEqual(@as(usize, 0), first.record.index);
    try std.testing.expect(!first.record.all_complete);
    completed[0] = true;

    const duplicate = decideLegacyUrlCompletion(
        binding,
        &ids,
        &completed,
        .{
            .server_name = "server-a",
            .elicitation_id = "one",
            .connection_generation = 4,
            .client_generation = 5,
            .catalog_generation = 6,
            .auth_generation = 8,
        },
        99,
        true,
    );
    try std.testing.expectEqual(LegacyUrlCompletionRejection.duplicate, duplicate.reject);

    const unknown = decideLegacyUrlCompletion(
        binding,
        &ids,
        &completed,
        .{
            .server_name = "server-a",
            .elicitation_id = "wrong",
            .connection_generation = 4,
            .client_generation = 5,
            .catalog_generation = 6,
            .auth_generation = 8,
        },
        99,
        true,
    );
    try std.testing.expectEqual(LegacyUrlCompletionRejection.unknown_id, unknown.reject);

    const wrong_generation = decideLegacyUrlCompletion(
        binding,
        &ids,
        &completed,
        .{
            .server_name = "server-a",
            .elicitation_id = "two",
            .connection_generation = 9,
            .client_generation = 5,
            .catalog_generation = 6,
            .auth_generation = 8,
        },
        99,
        true,
    );
    try std.testing.expectEqual(
        Rejection.wrong_connection,
        wrong_generation.reject.binding,
    );

    const late = decideLegacyUrlCompletion(
        binding,
        &ids,
        &completed,
        .{
            .server_name = "server-a",
            .elicitation_id = "two",
            .connection_generation = 4,
            .client_generation = 5,
            .catalog_generation = 6,
            .auth_generation = 8,
        },
        101,
        true,
    );
    try std.testing.expectEqual(Rejection.late, late.reject.binding);

    const last = decideLegacyUrlCompletion(
        binding,
        &ids,
        &completed,
        .{
            .server_name = "server-a",
            .elicitation_id = "two",
            .connection_generation = 4,
            .client_generation = 5,
            .catalog_generation = 6,
            .auth_generation = 8,
        },
        99,
        true,
    );
    try std.testing.expectEqual(@as(usize, 1), last.record.index);
    try std.testing.expect(last.record.all_complete);
    try std.testing.expectEqual(
        LegacyUrlRetryDecision.await_completion,
        decideLegacyUrlRetry(.accepted, .none),
    );
    try std.testing.expectEqual(
        LegacyUrlRetryDecision.retry,
        decideLegacyUrlRetry(.accepted, .notifications),
    );
    try std.testing.expectEqual(
        LegacyUrlRetryDecision.retry,
        decideLegacyUrlRetry(.accepted, .manual_retry),
    );
    try std.testing.expectEqual(
        LegacyUrlRetryDecision.declined,
        decideLegacyUrlRetry(.declined, .notifications),
    );
}

test "continuation decisions reject stale cross-owner and duplicate answers" {
    const expected: Binding = .{
        .server_name = "alpha",
        .scope = .{ .operation = .{ .tools_call = "lookup" } },
        .runtime_generation = 1,
        .connection_generation = 2,
        .client_generation = 3,
        .catalog_generation = 4,
        .request_generation = 5,
        .auth_generation = 6,
        .user_identity = "user-a",
        .deadline_ms = 100,
    };
    const answer: AnswerBinding = .{
        .server_name = "alpha",
        .scope = .{ .operation = .{ .tools_call = "lookup" } },
        .runtime_generation = 1,
        .connection_generation = 2,
        .client_generation = 3,
        .catalog_generation = 4,
        .request_generation = 5,
        .auth_generation = 6,
        .user_identity = "user-a",
    };
    try std.testing.expectEqual(Transition.consume, decideTransition(.pending, expected, answer, 99, true));
    try std.testing.expectEqual(Rejection.duplicate, decideTransition(.consumed, expected, answer, 99, true).reject);
    var wrong = answer;
    wrong.server_name = "beta";
    try std.testing.expectEqual(Rejection.wrong_server, decideTransition(.pending, expected, wrong, 99, true).reject);
    wrong = answer;
    wrong.runtime_generation += 1;
    try std.testing.expectEqual(Rejection.wrong_runtime, decideTransition(.pending, expected, wrong, 99, true).reject);
    wrong = answer;
    wrong.auth_generation += 1;
    try std.testing.expectEqual(Rejection.changed_auth, decideTransition(.pending, expected, wrong, 99, true).reject);
    wrong = answer;
    wrong.scope = .{ .operation = .{ .resources_read = "memory://lookup" } };
    try std.testing.expectEqual(Rejection.wrong_scope, decideTransition(.pending, expected, wrong, 99, true).reject);
    try std.testing.expectEqual(Rejection.late, decideTransition(.pending, expected, answer, 101, true).reject);
}

test "request parsing and validation release every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllocationFailures, .{});
}

test "ACP projection keeps the wire distinctions from modern and legacy MCP" {
    const alloc = std.testing.allocator;
    var modern = try parseRequest(
        alloc,
        .modern_mcp,
        "{\"message\":\"Profile\",\"requestedSchema\":{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}},\"_meta\":{\"fixture\":true}}",
        .{},
    );
    defer modern.deinit(alloc);
    const projected = try projectToAcpCreateParams(
        alloc,
        modern,
        .{ .session = .{ .session_id = "session", .tool_call_id = "tool" } },
        null,
        null,
        .{},
    );
    defer alloc.free(projected);
    try std.testing.expect(std.mem.find(u8, projected, "\"mode\":\"form\"") != null);
    try std.testing.expect(std.mem.find(u8, projected, "\"$schema\"") == null);
    try std.testing.expect(std.mem.find(u8, projected, "\"_meta\":{\"fixture\":true}") != null);

    var legacy_url = try parseRequest(
        alloc,
        .legacy_mcp_2025_11,
        "{\"mode\":\"url\",\"message\":\"Authorize\",\"url\":\"https://example.test/connect\",\"elicitationId\":\"legacy-id\"}",
        .{},
    );
    defer legacy_url.deinit(alloc);
    try std.testing.expectEqualStrings("legacy-id", legacy_url.elicitation_id.?);

    var with_enum_names = try parseRequest(
        alloc,
        .legacy_mcp_2025_06,
        "{\"message\":\"Choose\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"choice\":{\"type\":\"string\",\"enum\":[\"a\"],\"enumNames\":[\"A\"]}}}}",
        .{},
    );
    defer with_enum_names.deinit(alloc);
    const projected_enum_names = try projectToAcpCreateParams(
        alloc,
        with_enum_names,
        .{ .request = .{ .string = "request" } },
        null,
        null,
        .{},
    );
    defer alloc.free(projected_enum_names);
    try std.testing.expect(std.mem.find(u8, projected_enum_names, "enumNames") == null);
    try std.testing.expect(std.mem.find(u8, projected_enum_names, "\"enum\":[\"a\"]") != null);
}

test "canonical responses discard ignored content and unknown fields" {
    const alloc = std.testing.allocator;
    var request = try parseRequest(
        alloc,
        .acp,
        "{\"mode\":\"url\",\"message\":\"Authorize\",\"url\":\"https://example.test/connect\",\"elicitationId\":\"id\"}",
        .{},
    );
    defer request.deinit(alloc);
    const canonical = try canonicalResponse(
        alloc,
        request,
        "{\"action\":\"decline\",\"content\":{\"ignored\":\"private\"},\"future\":true}",
        .{},
    );
    defer alloc.free(canonical);
    try std.testing.expectEqualStrings("{\"action\":\"decline\"}", canonical);
}

fn checkAllocationFailures(alloc: Allocator) !void {
    var request = try parseRequest(
        alloc,
        .acp,
        "{\"mode\":\"form\",\"message\":\"Choose\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"choice\":{\"type\":\"string\",\"enum\":[\"a\",\"b\"]}},\"required\":[\"choice\"]}}",
        .{},
    );
    defer request.deinit(alloc);
    _ = try validateResponse(alloc, request, "{\"action\":\"accept\",\"content\":{\"choice\":\"a\"}}", .{});

    var modern = try parseRequest(
        alloc,
        .modern_mcp,
        "{\"message\":\"Profile\",\"requestedSchema\":{\"$schema\":\"draft\",\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}}",
        .{},
    );
    defer modern.deinit(alloc);
    const projected = try projectToAcpCreateParams(
        alloc,
        modern,
        .{ .session = .{ .session_id = "session" } },
        null,
        null,
        .{},
    );
    alloc.free(projected);

    var url_required = try parseLegacyUrlRequired(
        alloc,
        .legacy_mcp_2025_11,
        "{\"elicitations\":[{\"mode\":\"url\",\"message\":\"Authorize\",\"url\":\"https://example.test/connect\",\"elicitationId\":\"id\"}]}",
        .{},
    );
    defer url_required.deinit(alloc);
    const url_requests = try renderLegacyUrlRequiredRequests(alloc, url_required, .{});
    alloc.free(url_requests);
}

fn fuzzElicitationJson(_: void, smith: *std.testing.Smith) !void {
    var buffer: [2048]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, '{', 4),
        .value(u8, '}', 4),
        .value(u8, '[', 3),
        .value(u8, ']', 3),
        .value(u8, '"', 4),
        .value(u8, ':', 3),
        .value(u8, ',', 3),
    });
    const bytes = buffer[0..len];
    var parsed_json = std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        bytes,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (parsed_json) |*parsed| {
        defer parsed.deinit();
        _ = classifyLegacyUrlCompletionNotification(parsed.value, .{});
    }
    for ([_]Wire{ .modern_mcp, .legacy_mcp_2025_06, .legacy_mcp_2025_11, .acp }) |wire| {
        var request = parseRequest(std.testing.allocator, wire, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer request.deinit(std.testing.allocator);
        const response = canonicalResponse(std.testing.allocator, request, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        std.testing.allocator.free(response);
    }
}

test "elicitation request and response parsers stay bounded under fuzzed bytes" {
    try std.testing.fuzz({}, fuzzElicitationJson, .{
        .corpus = &.{
            "{}",
            "{\"mode\":\"form\",\"requestedSchema\":{}}",
            "{\"action\":\"accept\",\"content\":{}}",
            "{\"mode\":\"url\",\"url\":\"https://example.test\"}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"id\"}}",
        },
    });
}

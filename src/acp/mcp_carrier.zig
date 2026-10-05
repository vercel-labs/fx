//! MCP over ACP: serves `type: "acp"` MCP servers through the ACP connection,
//! following the stateless MCP-over-ACP RFD. Each MCP request becomes one
//! outbound `mcp/message` request carrying the server ID, a fresh logical
//! request ID, and the flattened MCP method and params. The client's
//! `{result}` or `{error}` carrier becomes the JSON-RPC response frame that the
//! modern MCP runtime already parses.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const server = @import("server.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const message_carrier = @import("../core/mcp/message_carrier.zig");
const streamable_http = @import("../core/mcp/streamable_http.zig");

const Allocator = std.mem.Allocator;

/// Binding errors the client reports outside the MCP outcome carrier.
const BindingError = struct {
    const invalid_params: i64 = -32602;
    const cancelled: i64 = -32800;
    const resource_limit: i64 = -33000;
    const server_unavailable: i64 = -33001;
    const backend_failed: i64 = -33002;
};

pub fn carrier(state: *server.ServerState) message_carrier.Carrier {
    return .{ .context = @ptrCast(state), .exchange_fn = exchange };
}

fn exchange(raw_state: *anyopaque, alloc: Allocator, request: message_carrier.Request) anyerror![]u8 {
    const state: *server.ServerState = @ptrCast(@alignCast(raw_state));
    const frame = std.json.parseFromSlice(std.json.Value, alloc, request.frame, .{}) catch
        return error.McpInvalidJson;
    defer frame.deinit();
    if (frame.value != .object) return error.McpInvalidJson;
    const inner_id = frame.value.object.get("id") orelse return error.McpInvalidJson;
    const method = frame.value.object.get("method") orelse return error.McpInvalidJson;
    if (method != .string) return error.McpInvalidJson;

    const logical_id = state.next_mcp_message_id.fetchAdd(1, .monotonic);
    const params = try messageParams(alloc, request.server_id, logical_id, method.string, frame.value.object.get("params"));
    defer alloc.free(params);

    const outbound_id = (try server.beginOutboundRequest(state, .mcp_message)) orelse {
        debug_trace.logf("acp", "mcp/message rejected reason=outbound_limit server_id_bytes={d}", .{request.server_id.len});
        return error.McpTransportUnavailable;
    };
    var phase: enum { unsent, sent, settled } = .unsent;
    errdefer switch (phase) {
        // The client never saw this request, so there is nothing to cancel.
        .unsent => server.discardOutboundRequest(state, outbound_id),
        .sent => abandon(state, outbound_id),
        .settled => {},
    };

    if (request.precommit) |precommit| try precommit.acquire();
    defer if (request.precommit) |precommit| precommit.release();
    try state.writer.writeRequest(alloc, .{ .integer = @intCast(outbound_id) }, "mcp/message", params);
    phase = .sent;
    if (request.precommit) |precommit| precommit.release();

    const outcome = try awaitResponse(state, outbound_id, request.control);
    phase = .settled;
    var response = switch (outcome) {
        .response => |value| value,
        .cancelled => return error.Cancelled,
        .timed_out => return error.McpRequestTimedOut,
    };
    defer response.deinit(state.alloc);
    if (response.cancelled) return error.Cancelled;
    if (response.error_json) |error_json| return bindingFailure(alloc, error_json);
    const result_json = response.result_json orelse return error.McpInvalidResult;
    if (result_json.len > request.max_response_bytes) return error.McpResponseFrameTooLarge;
    return responseFrame(alloc, inner_id, result_json);
}

/// Builds `mcp/message` params. The logical request ID is fresh for every
/// operation on this connection, including MRTR retries.
fn messageParams(
    alloc: Allocator,
    server_id: []const u8,
    logical_id: u64,
    method: []const u8,
    inner_params: ?std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"serverId\":");
    try jsonrpc.writeJsonStr(server_id, &out.writer);
    try out.writer.print(",\"requestId\":\"fx-mcp-{d}\",\"method\":", .{logical_id});
    try jsonrpc.writeJsonStr(method, &out.writer);
    if (inner_params) |value| {
        if (value != .null) {
            try out.writer.writeAll(",\"params\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

/// Converts a successful outer response into the inner JSON-RPC frame. The
/// carrier holds exactly one of `result` or `error`; an inner error stays an
/// MCP error and is never treated as an ACP error.
fn responseFrame(alloc: Allocator, inner_id: std.json.Value, result_json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, result_json, .{}) catch
        return error.McpInvalidResult;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidResult;
    const result = parsed.value.object.get("result");
    const inner_error = parsed.value.object.get("error");
    if ((result == null) == (inner_error == null)) return error.McpInvalidResult;
    if (inner_error) |value| {
        if (value != .object) return error.McpInvalidResult;
        const code = value.object.get("code") orelse return error.McpInvalidResult;
        const message = value.object.get("message") orelse return error.McpInvalidResult;
        if (code != .integer or message != .string) return error.McpInvalidResult;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(inner_id, .{}, &out.writer);
    if (result) |value| {
        try out.writer.writeAll(",\"result\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    } else {
        try out.writer.writeAll(",\"error\":");
        try std.json.Stringify.value(inner_error.?, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn bindingFailure(alloc: Allocator, error_json: []const u8) anyerror {
    const code: ?i64 = code: {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, error_json, .{}) catch break :code null;
        defer parsed.deinit();
        if (parsed.value != .object) break :code null;
        const value = parsed.value.object.get("code") orelse break :code null;
        break :code if (value == .integer) value.integer else null;
    };
    debug_trace.logf("acp", "mcp/message binding failure code={?d}", .{code});
    return switch (code orelse return error.McpProtocolError) {
        BindingError.cancelled => error.Cancelled,
        BindingError.server_unavailable => error.McpServerNotFound,
        BindingError.resource_limit => error.McpTransportUnavailable,
        BindingError.backend_failed => error.McpConnectionClosed,
        BindingError.invalid_params => error.McpProtocolError,
        else => error.McpProtocolError,
    };
}

const Outcome = union(enum) {
    response: server.OutboundResponse,
    cancelled,
    timed_out,
};

const Wait = union(enum) {
    response: ?server.OutboundResponse,
    deadline: anyerror!void,
    cancelled: anyerror!void,
};

/// Waits for the client's reply, the MCP deadline, or cancellation. When the
/// deadline or cancellation wins, the client receives `$/cancel_request` for
/// the outer request. The pending request is always retired on return.
fn awaitResponse(state: *server.ServerState, id: u64, control: streamable_http.Control) !Outcome {
    const Cleanup = struct {
        fn drain(state_alloc: Allocator, select: *std.Io.Select(Wait)) void {
            while (select.cancel()) |item| switch (item) {
                .response => |maybe_response| if (maybe_response) |owned| {
                    var response = owned;
                    response.deinit(state_alloc);
                },
                .deadline, .cancelled => {},
            };
        }
    };

    var select_buffer: [3]Wait = undefined;
    var select: std.Io.Select(Wait) = .init(io_mod.getIo(), &select_buffer);
    try select.concurrent(.response, server.awaitOutboundResponse, .{ state, id, server.OutboundKind.mcp_message });
    select.concurrent(.deadline, waitForDeadline, .{control.deadline}) catch |err| {
        server.cancelOutboundRequest(state, id);
        Cleanup.drain(state.alloc, &select);
        return err;
    };
    select.concurrent(.cancelled, waitForCancellation, .{control}) catch |err| {
        server.cancelOutboundRequest(state, id);
        Cleanup.drain(state.alloc, &select);
        return err;
    };
    const event = select.await() catch |err| {
        server.cancelOutboundRequest(state, id);
        Cleanup.drain(state.alloc, &select);
        return err;
    };
    switch (event) {
        .response => |response| {
            Cleanup.drain(state.alloc, &select);
            return if (response) |value| .{ .response = value } else .cancelled;
        },
        .deadline, .cancelled => {
            server.cancelOutboundRequest(state, id);
            Cleanup.drain(state.alloc, &select);
            return if (event == .deadline and !control.cancellation().cancelled()) .timed_out else .cancelled;
        },
    }
}

fn waitForDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    const io = io_mod.getIo();
    while (std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io, .awake), .lt, deadline)) {
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

fn waitForCancellation(control: streamable_http.Control) anyerror!void {
    const cancellation = control.cancellation();
    while (!cancellation.cancelled()) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

/// Retires a request that failed before its reply was awaited.
fn abandon(state: *server.ServerState, id: u64) void {
    server.cancelOutboundRequest(state, id);
    if (server.awaitOutboundResponse(state, id, .mcp_message)) |owned| {
        var response = owned;
        response.deinit(state.alloc);
    }
}

test "MCP over ACP frames flatten the request and keep inner errors in MCP" {
    const alloc = std.testing.allocator;
    const params = try messageParams(alloc, "tools:7a72", 3, "tools/call", .{ .string = "ignored" });
    defer alloc.free(params);
    try std.testing.expectEqualStrings(
        "{\"serverId\":\"tools:7a72\",\"requestId\":\"fx-mcp-3\",\"method\":\"tools/call\",\"params\":\"ignored\"}",
        params,
    );
    const without_params = try messageParams(alloc, "tools:7a72", 4, "server/discover", .null);
    defer alloc.free(without_params);
    try std.testing.expect(std.mem.find(u8, without_params, "params") == null);

    const result = try responseFrame(alloc, .{ .integer = 7 }, "{\"result\":{\"resultType\":\"complete\",\"content\":[],\"extra\":1}}");
    defer alloc.free(result);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"content\":[],\"extra\":1}}",
        result,
    );
    const inner_error = try responseFrame(alloc, .{ .integer = 8 }, "{\"error\":{\"code\":-32000,\"message\":\"inner\",\"data\":null}}");
    defer alloc.free(inner_error);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32000,\"message\":\"inner\",\"data\":null}}",
        inner_error,
    );
    const null_result = try responseFrame(alloc, .{ .integer = 9 }, "{\"result\":null}");
    defer alloc.free(null_result);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":null}", null_result);

    try std.testing.expectError(error.McpInvalidResult, responseFrame(alloc, .{ .integer = 1 }, "{}"));
    try std.testing.expectError(error.McpInvalidResult, responseFrame(alloc, .{ .integer = 1 }, "{\"result\":1,\"error\":{\"code\":1,\"message\":\"x\"}}"));
    try std.testing.expectError(error.McpInvalidResult, responseFrame(alloc, .{ .integer = 1 }, "{\"error\":{\"message\":\"x\"}}"));
}

test "MCP over ACP binding errors map outside the MCP outcome" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(error.Cancelled, bindingFailure(alloc, "{\"code\":-32800,\"message\":\"cancelled\"}"));
    try std.testing.expectEqual(error.McpServerNotFound, bindingFailure(alloc, "{\"code\":-33001,\"message\":\"gone\"}"));
    try std.testing.expectEqual(error.McpTransportUnavailable, bindingFailure(alloc, "{\"code\":-33000,\"message\":\"busy\"}"));
    try std.testing.expectEqual(error.McpConnectionClosed, bindingFailure(alloc, "{\"code\":-33002,\"message\":\"backend\"}"));
    try std.testing.expectEqual(error.McpProtocolError, bindingFailure(alloc, "not json"));
}

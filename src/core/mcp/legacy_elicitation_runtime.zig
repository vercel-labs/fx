const server_connection = @import("server_connection.zig");
const tool_snapshot = @import("tool_snapshot.zig");
const feature_snapshot = @import("feature_snapshot.zig");
const FeatureIdentitySnapshot = feature_snapshot.Snapshot;
const ToolCallSnapshot = tool_snapshot.Snapshot;
const mrtr = @import("mrtr.zig");
const controlled_lock = @import("controlled_lock.zig");
const checkOperationControl = controlled_lock.checkOperation;
const LegacyUrlWaiter = legacy_url_completion.Waiter;

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const mcp_contract = @import("mcp_contract.zig");
const elicitation = @import("elicitation.zig");
const legacy_url_completion = @import("legacy_url_completion.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const stdio_dispatcher = @import("stdio_dispatcher.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const tool_subscription = @import("tool_subscription.zig");
const operation_control = @import("operation_control.zig");
const lockRwSharedUntil = @import("controlled_lock.zig").rwSharedUntil;
const McpServer = @import("server_connection.zig").Server;
const Allocator = std.mem.Allocator;

pub const Context = struct {
    catalog_mutex: *std.Io.RwLock,
    completions: *legacy_url_completion.State,
    server: *McpServer,
    transport: union(enum) {
        stdio: *stdio_dispatcher.StdioDispatcher,
        http: *legacy_streamable_http.Client,
    },
    wire: elicitation.Wire,
    responder: ?tool_mcp_runtime.InputResponder,
    capabilities: elicitation.Capabilities,
    operation: elicitation.Operation,
    deadline: std.Io.Clock.Timestamp,
    deadline_gate: operation_control.DeadlineGate = .init(0),
    cancel_flag: ?*std.atomic.Value(bool),
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    catalog_generation: u64,
    auth_generation: u64,
    requests_seen: std.atomic.Value(usize) = .init(0),
    completion_window_generation: ?u64 = null,

    pub fn initHttp(
        catalog_mutex: *std.Io.RwLock,
        completions: *legacy_url_completion.State,
        server: *McpServer,
        client: *legacy_streamable_http.Client,
        wire: elicitation.Wire,
        responder: ?tool_mcp_runtime.InputResponder,
        operation: elicitation.Operation,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) Context {
        return initCommon(
            catalog_mutex,
            completions,
            server,
            .{ .http = client },
            wire,
            responder,
            operation,
            deadline,
            cancel_flag,
        );
    }

    pub fn initStdio(
        catalog_mutex: *std.Io.RwLock,
        completions: *legacy_url_completion.State,
        server: *McpServer,
        dispatcher: *stdio_dispatcher.StdioDispatcher,
        wire: elicitation.Wire,
        responder: ?tool_mcp_runtime.InputResponder,
        operation: elicitation.Operation,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) Context {
        return initCommon(
            catalog_mutex,
            completions,
            server,
            .{ .stdio = dispatcher },
            wire,
            responder,
            operation,
            deadline,
            cancel_flag,
        );
    }

    fn initCommon(
        catalog_mutex: *std.Io.RwLock,
        completions: *legacy_url_completion.State,
        server: *McpServer,
        transport: @FieldType(Context, "transport"),
        wire: elicitation.Wire,
        responder: ?tool_mcp_runtime.InputResponder,
        operation: elicitation.Operation,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) Context {
        const runtime_capabilities = server.elicitation_capabilities;
        return .{
            .catalog_mutex = catalog_mutex,
            .completions = completions,
            .server = server,
            .transport = transport,
            .wire = wire,
            .responder = responder,
            .capabilities = elicitation.Capabilities.intersect(
                runtime_capabilities,
                if (responder) |value| value.capabilities else .{},
            ),
            .operation = operation,
            .deadline = deadline,
            .deadline_gate = .init(operation_control.timestampMillis(deadline)),
            .cancel_flag = cancel_flag,
            .runtime_generation = completions.runtime_generation,
            .connection_generation = server.connection_generation,
            .client_generation = switch (transport) {
                .stdio => |dispatcher| dispatcher.connectionGeneration(),
                .http => server.connection_generation,
            },
            .catalog_generation = server.catalog_generation,
            .auth_generation = server.auth_generation.load(.acquire),
        };
    }

    pub fn sink(self: *Context) ?mcp_contract.ServerRequestSink {
        if (!self.wire.isLegacy() or !self.capabilities.any()) return null;
        return .{
            .context = @ptrCast(self),
            .prepare_callback = prepareLegacyServerRequest,
            .callback = handleLegacyServerRequest,
        };
    }

    pub fn responseObserver(self: *Context) ?mcp_contract.ResponseObserver {
        if (self.wire != .legacy_mcp_2025_11 or
            !self.capabilities.url)
        {
            return null;
        }
        return .{ .context = @ptrCast(self), .callback = observeLegacyResponse };
    }

    pub fn completionSink(self: *Context) ?mcp_contract.NotificationSink {
        if (self.wire != .legacy_mcp_2025_11 or self.transport != .http or
            !self.capabilities.url)
        {
            return null;
        }
        return .{
            .context = @ptrCast(self),
            .callback = handleLegacyOperationCompletionNotification,
        };
    }

    fn source(self: *const Context) tool_subscription.NotificationSource {
        return .{
            .server_name = self.server.config.name,
            .connection_generation = self.connection_generation,
            .client_generation = self.client_generation,
            .auth_generation = self.auth_generation,
        };
    }

    fn sourceStateLocked(self: *const Context) legacy_url_completion.SourceState {
        if (self.completions.runtime_generation != self.runtime_generation) return .stale;
        return self.server.legacySourceState(self.connection_generation, self.client_generation, self.auth_generation);
    }

    fn registerCandidates(self: *Context, ids: []const []const u8) !void {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        return self.completions.registerCandidatesLocked(self.source(), self.runtime_generation, self.completion_window_generation, ids, self.sourceStateLocked(), operation_control.awakeMillis(io_mod.getIo()));
    }

    pub fn beginCompletionWindow(self: *Context) !void {
        if (self.transport != .http or self.responseObserver() == null) return;
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        if (self.sourceStateLocked() != .current) return error.Cancelled;
        self.completion_window_generation = try self.completions.beginWindowLocked(self.source(), self.runtime_generation);
    }

    pub fn endCompletionWindow(self: *Context) void {
        const generation = self.completion_window_generation orelse return;
        self.completion_window_generation = null;
        self.completions.endLegacyUrlCompletionWindow(
            self.source(),
            self.runtime_generation,
            generation,
        );
    }

    fn sendFrame(self: *Context, alloc: Allocator, frame: []const u8) !void {
        const deadline = self.deadlineTimestamp();
        return switch (self.transport) {
            .stdio => |dispatcher| dispatcher.sendNotificationWithLifecycleControl(
                frame,
                self.server.config.operation_timeout_ms,
                deadline,
                self.cancel_flag,
                self.server.cancellation(),
            ),
            .http => |client| client.sendNotification(
                alloc,
                frame,
                .{
                    .deadline = deadline,
                    .cancel_flag = self.cancel_flag,
                    .lifecycle_cancel_flag = self.server.cancellation(),
                },
            ),
        };
    }

    fn bindingCurrent(self: *const Context) !bool {
        const deadline = self.deadlineTimestamp();
        try lockRwSharedUntil(
            &self.server.connection_lock,
            deadline,
            self.cancel_flag,
        );
        defer self.server.connection_lock.unlockShared(io_mod.getIo());
        if (self.server.lifetime.retiring.load(.acquire)) return false;
        try lockRwSharedUntil(self.catalog_mutex, deadline, self.cancel_flag);
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        if (self.completions.runtime_generation != self.runtime_generation) return false;
        return self.server.connection_generation == self.connection_generation and
            self.server.catalog_generation == self.catalog_generation and
            self.server.auth_generation.load(.acquire) == self.auth_generation and
            self.server.legacyWire() == self.wire;
    }

    pub fn inputOrigin(self: *const Context) tool_mcp_runtime.InputOrigin {
        return .{
            .wire = self.wire,
            .server_name = self.server.config.name,
            .operation = self.operation,
            .runtime_generation = self.runtime_generation,
            .connection_generation = self.connection_generation,
            .client_generation = self.client_generation,
            .catalog_generation = self.catalog_generation,
            .request_generation = 1,
            .auth_generation = self.auth_generation,
            .deadline_ms = self.deadline_gate.currentDeadlineMs(),
            .lifecycle_cancel_flag = self.server.cancellation(),
        };
    }

    fn beginInputWait(self: *Context) void {
        self.deadline_gate.pauseUntil(operation_control.timestampMillis(operation_control.elicitationDeadline(io_mod.getIo())));
    }

    fn endInputWait(self: *Context) void {
        self.deadline_gate.resumeAt(operation_control.awakeMillis(io_mod.getIo()), self.server.config.operation_timeout_ms);
    }

    fn deadlineTimestamp(self: *const Context) std.Io.Clock.Timestamp {
        return .{
            .clock = .awake,
            .raw = std.Io.Timestamp.fromNanoseconds(
                @as(i96, self.deadline_gate.currentDeadlineMs()) * std.time.ns_per_ms,
            ),
        };
    }

    pub fn directTerminal(self: *const Context) ?tool_mcp_runtime.InputCompletion {
        if (self.requests_seen.load(.acquire) == 0) return null;
        const responder = self.responder orelse return null;
        if (responder.continuation_terminal == null) return null;
        return .{ .responder = responder, .origin = self.inputOrigin() };
    }
};

fn prepareLegacyServerRequest(
    raw_context: *anyopaque,
    alloc: Allocator,
    request_json: []const u8,
) anyerror!void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    if (context.wire != .legacy_mcp_2025_11 or !context.capabilities.url) return;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const jsonrpc = parsed.value.object.get("jsonrpc") orelse return;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) return;
    const request_id = parsed.value.object.get("id") orelse return;
    if (!validLegacyServerRequestId(request_id)) return;
    const method = parsed.value.object.get("method") orelse return;
    if (method != .string or !std.mem.eql(u8, method.string, "elicitation/create")) return;
    const params = parsed.value.object.get("params") orelse return;
    const params_json = stringifyMcpValue(alloc, params) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer alloc.free(params_json);
    var request = elicitation.parseRequest(alloc, context.wire, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer request.deinit(alloc);
    if (request.mode != .url) return;
    const ids = [_][]const u8{request.elicitation_id.?};
    try context.registerCandidates(
        &ids,
    );
}

fn observeLegacyResponse(
    raw_context: *anyopaque,
    alloc: Allocator,
    value: std.json.Value,
) anyerror!void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    if (value != .object) return;
    const error_value = value.object.get("error") orelse return;
    if (error_value != .object) return;
    const code = error_value.object.get("code") orelse return;
    const code_value = switch (code) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return,
        else => return,
    };
    if (code_value != elicitation.legacy_url_required_error_code) return;
    const data = error_value.object.get("data") orelse return;
    const data_json = stringifyMcpValue(alloc, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer alloc.free(data_json);
    var required = elicitation.parseLegacyUrlRequired(
        alloc,
        context.wire,
        data_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer required.deinit(alloc);
    const ids = try alloc.alloc([]const u8, required.requests.len);
    defer alloc.free(ids);
    for (required.requests, ids) |request, *id| id.* = request.elicitation_id.?;
    try context.registerCandidates(
        ids,
    );
}

fn handleLegacyOperationCompletionNotification(
    raw_context: *anyopaque,
    value: std.json.Value,
) void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    const handler = context.server.legacy_notifications orelse return;
    handler.callback(handler.context, context.source(), value);
}

fn handleLegacyServerRequest(
    raw_context: *anyopaque,
    alloc: Allocator,
    request_json: []const u8,
) anyerror!void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    if (request_json.len > 128 * 1024) return error.McpResponseFrameTooLarge;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.McpInvalidJson,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidJson;
    const id = parsed.value.object.get("id") orelse return error.McpInvalidJson;
    if (!validLegacyServerRequestId(id)) {
        return sendLegacyServerRequestError(context, alloc, .null, -32600, "Invalid request id");
    }
    if (context.requests_seen.fetchAdd(1, .monotonic) >= 32) {
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Elicitation request limit exceeded");
    }
    const method = parsed.value.object.get("method") orelse return error.McpInvalidJson;
    if (method != .string or !std.mem.eql(u8, method.string, "elicitation/create")) {
        return sendLegacyServerRequestError(context, alloc, id, -32601, "Method not found");
    }
    const params = parsed.value.object.get("params") orelse
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Invalid params");
    const params_json = stringifyMcpValue(alloc, params) catch
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Invalid params");
    defer alloc.free(params_json);
    var request = elicitation.parseRequest(alloc, context.wire, params_json, .{}) catch
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Invalid params");
    defer request.deinit(alloc);
    if (!context.capabilities.supports(request.mode)) {
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Unsupported elicitation mode");
    }
    const responder = context.responder orelse
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Elicitation unavailable");
    context.beginInputWait();
    defer context.endInputWait();
    const binding_current = context.bindingCurrent() catch |err| {
        return sendLegacyServerRequestError(context, alloc, id, -32603, @errorName(err));
    };
    if (!binding_current) {
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Elicitation owner changed");
    }

    var input_requests: std.Io.Writer.Allocating = .init(alloc);
    defer input_requests.deinit();
    try input_requests.writer.writeAll("{\"legacy\":{\"method\":\"elicitation/create\",\"params\":");
    try input_requests.writer.writeAll(params_json);
    try input_requests.writer.writeAll("}}");
    const origin = context.inputOrigin();
    const responses_json = responder.callback(
        responder.context,
        alloc,
        origin,
        .{ .input_requests_json = input_requests.writer.buffered() },
    ) catch |err| {
        return sendLegacyServerRequestError(context, alloc, id, -32603, @errorName(err));
    };
    defer alloc.free(responses_json);
    const response_binding_current = context.bindingCurrent() catch |err| {
        return sendLegacyServerRequestError(context, alloc, id, -32603, @errorName(err));
    };
    if (!response_binding_current) {
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Elicitation owner changed");
    }
    var responses = std.json.parseFromSlice(std.json.Value, alloc, responses_json, .{
        .parse_numbers = false,
    }) catch return sendLegacyServerRequestError(context, alloc, id, -32603, "Invalid elicitation response");
    defer responses.deinit();
    if (responses.value != .object or responses.value.object.count() != 1) {
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Invalid elicitation response");
    }
    const response = responses.value.object.get("legacy") orelse
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Invalid elicitation response");
    const response_json = try stringifyMcpValue(alloc, response);
    defer alloc.free(response_json);
    _ = elicitation.validateResponse(alloc, request, response_json, .{}) catch
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Invalid elicitation response");

    var frame: std.Io.Writer.Allocating = .init(alloc);
    defer frame.deinit();
    try frame.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &frame.writer);
    try frame.writer.writeAll(",\"result\":");
    try frame.writer.writeAll(response_json);
    try frame.writer.writeByte('}');
    try context.sendFrame(alloc, frame.writer.buffered());
}

fn validLegacyServerRequestId(value: std.json.Value) bool {
    return switch (value) {
        .integer => true,
        .number_string => |text| blk: {
            _ = std.fmt.parseInt(i64, text, 10) catch break :blk false;
            break :blk true;
        },
        .string => |text| text.len <= 256,
        else => false,
    };
}

fn sendLegacyServerRequestError(
    context: *Context,
    alloc: Allocator,
    id: std.json.Value,
    code: i64,
    message: []const u8,
) !void {
    var frame: std.Io.Writer.Allocating = .init(alloc);
    defer frame.deinit();
    try frame.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &frame.writer);
    try frame.writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try std.json.Stringify.value(message, .{}, &frame.writer);
    try frame.writer.writeAll("}}");
    try context.sendFrame(alloc, frame.writer.buffered());
}

fn stringifyMcpValue(alloc: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub const CatalogGuard = union(enum) {
    tool: *const ToolCallSnapshot,
    feature: *const FeatureIdentitySnapshot,
};

pub const Coordination = struct {
    catalog_mutex: *std.Io.RwLock,
    completions: *legacy_url_completion.State,

    pub fn registerWaiter(
        self: Coordination,
        server: *McpServer,
        waiter: *LegacyUrlWaiter,
    ) !void {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.completions.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.completions.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        const source_state: legacy_url_completion.SourceState = if (self.completions.runtime_generation != waiter.binding.runtime_generation or !std.mem.eql(u8, server.config.name, waiter.binding.server_name)) .stale else server.legacySourceState(waiter.binding.connection_generation, waiter.binding.client_generation, waiter.binding.auth_generation);
        switch (source_state) {
            .stale => return error.Cancelled,
            .logout_fenced => if (!self.completions.legacyUrlWaiterAdmittedLocked(waiter)) {
                return error.Cancelled;
            },
            .current => {},
        }
        try self.completions.registerLegacyUrlWaiterLocked(waiter);
        if (source_state == .current) {
            self.completions.replayEarlyLegacyUrlCompletionsLocked(waiter);
        } else {
            self.completions.fenceEarlyLegacyUrlCompletionsLocked(waiter);
        }
    }

    pub fn interact(
        self: Coordination,
        alloc: Allocator,
        server: *McpServer,
        origin: tool_mcp_runtime.InputOrigin,
        requests: []const mrtr.InputRequest,
        requests_json: []const u8,
        responder: tool_mcp_runtime.InputResponder,
        catalog_guard: CatalogGuard,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !elicitation.LegacyUrlRetryDecision {
        const ids = try alloc.alloc([]const u8, requests.len);
        defer alloc.free(ids);
        for (requests, 0..) |request, index| {
            if (request.payload != .elicitation_create or
                request.payload.elicitation_create.mode != .url)
            {
                return error.McpInvalidInputRequired;
            }
            ids[index] = request.payload.elicitation_create.elicitation_id orelse
                return error.McpInvalidInputRequired;
        }
        const completed = try alloc.alloc(bool, ids.len);
        defer alloc.free(completed);
        @memset(completed, false);
        var waiter = LegacyUrlWaiter{
            .binding = .{
                .server_name = origin.server_name,
                .scope = .{ .operation = origin.operation },
                .runtime_generation = origin.runtime_generation,
                .connection_generation = origin.connection_generation,
                .client_generation = origin.client_generation,
                .catalog_generation = origin.catalog_generation,
                .request_generation = origin.request_generation,
                .auth_generation = origin.auth_generation,
                .deadline_ms = origin.deadline_ms,
            },
            .ids = ids,
            .completed = completed,
        };
        try self.registerWaiter(server, &waiter);
        defer self.completions.unregisterLegacyUrlWaiter(&waiter);

        const consent_responses = try responder.callback(
            responder.context,
            alloc,
            origin,
            .{
                .input_requests_json = requests_json,
                .legacy_retry_without_responses = true,
                .legacy_url_phase = .consent,
            },
        );
        defer alloc.free(consent_responses);
        const consent = mrtr.legacyUrlConsent(alloc, requests, consent_responses, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.McpInvalidInputResponses,
        };
        const consent_decision = elicitation.decideLegacyUrlRetry(consent, .none);
        if (consent_decision != .await_completion) return consent_decision;

        if (waiter.signal.status.load(.acquire) == .completed) {
            if (!try self.bindingCurrent(server, waiter.binding, catalog_guard, deadline, cancel_flag)) {
                return .cancelled;
            }
            return .retry;
        }

        if (responder.legacy_url_manual_completion) {
            const completion_responses = try responder.callback(
                responder.context,
                alloc,
                origin,
                .{
                    .input_requests_json = requests_json,
                    .legacy_retry_without_responses = true,
                    .legacy_url_phase = .await_completion,
                    .legacy_url_completion_signal = &waiter.signal,
                },
            );
            defer alloc.free(completion_responses);
            const completion_consent = mrtr.legacyUrlConsent(
                alloc,
                requests,
                completion_responses,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.McpInvalidInputResponses,
            };
            const proof: elicitation.LegacyUrlCompletionProof = if (waiter.signal.status.load(.acquire) == .completed) .notifications else .manual_retry;
            const decision = elicitation.decideLegacyUrlRetry(completion_consent, proof);
            if (decision != .retry) return decision;
        } else {
            while (true) {
                switch (waiter.signal.status.load(.acquire)) {
                    .completed => break,
                    .cancelled => return .cancelled,
                    .pending => {},
                }
                try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
                if (server.lifetime.retiring.load(.acquire)) return error.Cancelled;
                try io_mod.getIo().sleep(.fromMilliseconds(10), .awake);
            }
        }

        if (!try self.bindingCurrent(server, waiter.binding, catalog_guard, deadline, cancel_flag)) {
            return .cancelled;
        }
        return .retry;
    }

    pub fn bindingCurrent(
        self: Coordination,
        server: *McpServer,
        binding: elicitation.Binding,
        catalog_guard: CatalogGuard,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !bool {
        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        defer server.connection_lock.unlockShared(io_mod.getIo());
        try lockRwSharedUntil(self.catalog_mutex, deadline, cancel_flag);
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        const client_generation = if (server.dispatcher) |dispatcher|
            dispatcher.connectionGeneration()
        else
            server.connection_generation;
        return !server.lifetime.retiring.load(.acquire) and
            std.mem.eql(u8, server.config.name, binding.server_name) and
            self.completions.runtime_generation == binding.runtime_generation and
            server.connection_generation == binding.connection_generation and
            client_generation == binding.client_generation and
            server.auth_generation.load(.acquire) == binding.auth_generation and
            server.legacyWire() == .legacy_mcp_2025_11 and
            switch (catalog_guard) {
                .tool => |snapshot| tool_snapshot.current(server, snapshot),
                .feature => |snapshot| feature_snapshot.featureSnapshotCurrent(server, snapshot),
            };
    }
};

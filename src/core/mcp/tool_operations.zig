const legacy_elicitation_runtime = @import("legacy_elicitation_runtime.zig");
const catalog_refresh = @import("catalog_refresh.zig");
const std = @import("std");
const server_connection = @import("server_connection.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mcp_contract = @import("mcp_contract.zig");
const server_auth = @import("server_auth.zig");
const server_lifecycle = @import("server_lifecycle.zig");
const tool_snapshot = @import("tool_snapshot.zig");
const ToolCallSnapshot = tool_snapshot.Snapshot;
const ToolPrecommit = tool_snapshot.CommitGuard;
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const elicitation = @import("elicitation.zig");
const legacy_url_completion = @import("legacy_url_completion.zig");
const mrtr = @import("mrtr.zig");
const operation_control = @import("operation_control.zig");
const controlled_lock = @import("controlled_lock.zig");
const protocol_negotiation = @import("protocol_negotiation.zig");
const protocol_messages = @import("protocol_messages.zig");
const buildToolCallRequestForProtocol = protocol_messages.buildToolCallRequestForProtocol;
const buildCancellationNotification = protocol_messages.buildCancellationNotification;
const featureProtocol = protocol_messages.featureProtocol;
const stdio_dispatcher = @import("stdio_dispatcher.zig");
const tool_result = @import("tool_result.zig");
const Allocator = std.mem.Allocator;
const mcp_response_frame_overhead_bytes: usize = 16 * 1024;
const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const checkOperationControl = controlled_lock.checkOperation;
const StdioProtocol = protocol_negotiation.Protocol;
const operation_authority = @import("operation_authority.zig");
const LegacyDirectTerminal = tool_mcp_runtime.InputCompletion;
const StdioServerRequestWait = server_connection.StdioRequestWait;
const ServerAccessPrecommit = operation_authority.SendGuard;
const McpServer = server_connection.Server;

pub const Operations = struct {
    lifecycle: server_lifecycle.Operations,
    generation: u64,
    completions: *legacy_url_completion.State,

    fn catalogRefresh(self: Operations) catalog_refresh.Context {
        return .{ .lifecycle = self.lifecycle, .generation = self.generation };
    }

    fn legacyInputs(self: Operations) legacy_elicitation_runtime.Coordination {
        return .{ .catalog_mutex = self.lifecycle.catalog_mutex, .completions = self.completions };
    }

    pub fn callToolFromSnapshot(
        self: Operations,
        arena: Allocator,
        server: *McpServer,
        snapshot: *ToolCallSnapshot,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
        continuation_round: u8,
        continuation_deadline: ?std.Io.Clock.Timestamp,
    ) !tool_mcp_runtime.CallResult {
        if (server.lifetime.retiring.load(.acquire)) return error.Cancelled;
        const operation_started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (continuation_deadline) |deadline| {
            try checkOperationControl(io_mod.getIo(), deadline, options.cancel_flag);
        }
        const catalog_deadline = continuation_deadline orelse
            operation_started.addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(server.config.operation_timeout_ms) });
        _ = try self.catalogRefresh().refresh(
            server,
            catalog_deadline,
            options.cancel_flag,
            options.access,
        );
        try lockRwSharedUntil(self.lifecycle.catalog_mutex, catalog_deadline, options.cancel_flag);
        if (!tool_snapshot.current(server, snapshot)) {
            self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());
            return error.McpToolCatalogChanged;
        }
        const connection_locked = server.config.transport == .stdio;
        const operation_deadline = continuation_deadline orelse if (connection_locked or
            server.config.transport == .http or
            server.config.transport == .sse)
            operation_started.addDuration(.{
                .clock = .awake,
                .raw = .fromMilliseconds(server.config.operation_timeout_ms),
            })
        else
            null;
        if (operation_deadline) |deadline| {
            checkOperationControl(io_mod.getIo(), deadline, options.cancel_flag) catch |err| {
                self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());
                return err;
            };
        }
        self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());
        try (operation_authority.EffectAccess{ .alloc = self.lifecycle.alloc, .runtime_generation = self.generation, .access = options.access, .target = .{ .tool = snapshot.prefixed_name } }).authorize();
        if (connection_locked) {
            lockRwSharedUntil(
                &server.connection_lock,
                operation_deadline.?,
                options.cancel_flag,
            ) catch |err| {
                return err;
            };
            const dispatcher = server.dispatcher orelse {
                server.connection_lock.unlockShared(io_mod.getIo());
                return error.McpToolCatalogChanged;
            };
            if (snapshot.stdio_generation == null or
                dispatcher.connectionGeneration() != snapshot.stdio_generation.?)
            {
                server.connection_lock.unlockShared(io_mod.getIo());
                return error.McpToolCatalogChanged;
            }
        }

        const result = try self.callTool(
            arena,
            server,
            snapshot,
            arguments_json,
            max_tool_result_bytes,
            options,
            connection_locked,
            operation_deadline,
        );
        if (result.status != .input_required or options.input_responder == null) return result;
        var owned_result = result;
        var result_owned = true;
        defer if (result_owned) owned_result.deinit(arena);
        const required = owned_result.input_required orelse
            return error.McpInvalidInputRequired;
        if (continuation_round >= 8) {
            return .{
                .model_output = try tool_result_limits.prepareModelOutput(
                    arena,
                    snapshot.prefixed_name,
                    "MCP protocol failure: input-required continuation limit exceeded",
                    max_tool_result_bytes,
                ),
                .status = .protocol_failure,
            };
        }
        const input_wire: elicitation.Wire = if (required.legacy_retry_without_responses)
            server.legacyWire() orelse return error.McpInvalidInputRequired
        else
            .modern_mcp;
        const requests = mrtr.parseRequestJsonForWire(
            arena,
            required.input_requests_json,
            input_wire,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.McpInvalidInputRequired,
        };
        defer {
            for (requests) |*request| request.deinit(arena);
            arena.free(requests);
        }
        const responder = options.input_responder.?;
        const interaction_deadline = operation_control.elicitationDeadline(io_mod.getIo());
        const origin = tool_mcp_runtime.InputOrigin{
            .wire = input_wire,
            .server_name = snapshot.server_name,
            .operation = .{ .tools_call = snapshot.original_name },
            .runtime_generation = self.completions.runtime_generation,
            .connection_generation = snapshot.connection_generation,
            .client_generation = snapshot.stdio_generation orelse snapshot.connection_generation,
            .catalog_generation = snapshot.catalog_generation,
            .request_generation = continuation_round + 1,
            .auth_generation = server.auth_generation.load(.acquire),
            .deadline_ms = operation_control.timestampMillis(interaction_deadline),
            .lifecycle_cancel_flag = server.cancellation(),
        };
        var next_options = options;
        var owned_input_responses: ?[]const u8 = null;
        defer if (owned_input_responses) |responses| arena.free(responses);
        if (required.legacy_retry_without_responses) {
            const decision = self.legacyInputs().interact(
                arena,
                server,
                origin,
                requests,
                required.input_requests_json,
                responder,
                .{ .tool = snapshot },
                interaction_deadline,
                options.cancel_flag,
            ) catch |err| switch (err) {
                error.McpInputRequired, error.UnsupportedMode, error.UnsupportedInputRequest => {
                    result_owned = false;
                    return owned_result;
                },
                else => |other| return other,
            };
            if (decision != .retry) {
                const message = if (decision == .declined)
                    "MCP URL elicitation was declined"
                else
                    "MCP URL elicitation was cancelled";
                responder.finish(arena, origin, .abandoned);
                return .{
                    .model_output = try tool_result_limits.prepareModelOutput(
                        arena,
                        snapshot.prefixed_name,
                        message,
                        max_tool_result_bytes,
                    ),
                    .status = .tool_failure,
                };
            }
            next_options.continuation = null;
        } else {
            const input_responses_json = responder.callback(
                responder.context,
                arena,
                origin,
                required,
            ) catch |err| switch (err) {
                error.McpInputRequired, error.UnsupportedMode, error.UnsupportedInputRequest => {
                    result_owned = false;
                    return owned_result;
                },
                else => |other| return other,
            };
            owned_input_responses = input_responses_json;
            mrtr.validateResponses(
                arena,
                requests,
                input_responses_json,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.McpInvalidInputResponses,
            };
            next_options.continuation = .{
                .input_responses_json = input_responses_json,
                .request_state_json = required.request_state_json,
            };
        }
        const continued = self.callToolFromSnapshot(
            arena,
            server,
            snapshot,
            arguments_json,
            max_tool_result_bytes,
            next_options,
            continuation_round + 1,
            null,
        ) catch |err| {
            responder.finish(arena, origin, .abandoned);
            return err;
        };
        responder.finish(
            arena,
            origin,
            if (continued.status == .success or continued.status == .tool_failure)
                .completed
            else
                .abandoned,
        );
        return continued;
    }

    fn callTool(
        self: Operations,
        arena: Allocator,
        server: *McpServer,
        snapshot: *ToolCallSnapshot,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
        connection_locked: bool,
        operation_deadline: ?std.Io.Clock.Timestamp,
    ) !tool_mcp_runtime.CallResult {
        if (server.config.transport == .sse) {
            std.debug.assert(!connection_locked);
            return try callToolSse(
                self,
                arena,
                server,
                snapshot,
                arguments_json,
                max_tool_result_bytes,
                options,
                operation_deadline.?,
            );
        }
        if (server.config.transport == .http) {
            std.debug.assert(!connection_locked);
            return try callToolHttp(
                self,
                arena,
                server,
                snapshot,
                arguments_json,
                max_tool_result_bytes,
                options,
                operation_deadline.?,
            );
        }
        std.debug.assert(connection_locked);

        const raw_frame_cap = mcpResponseFrameCap(max_tool_result_bytes);
        var lease_active = true;
        var retried_unsent_call = false;
        errdefer if (lease_active) {
            server.connection_lock.unlockShared(io_mod.getIo());
        };
        while (true) {
            const dispatcher = server.dispatcher orelse return error.McpConnectionClosed;
            dispatcher.retainPublished();
            var outcome = outcome: {
                defer dispatcher.releaseUse();
                break :outcome try callStdioToolOnce(
                    self,
                    arena,
                    server,
                    dispatcher,
                    snapshot,
                    arguments_json,
                    raw_frame_cap,
                    options,
                    operation_deadline.?,
                );
            };
            if (!outcome.connection_lease_released) {
                server.connection_lock.unlockShared(io_mod.getIo());
            }
            lease_active = false;
            const response = outcome.response orelse {
                outcome.finishLegacy(arena, .abandoned);
                const err = outcome.failure.?;
                if (err == error.Cancelled or server.lifetime.retiring.load(.acquire)) {
                    return error.Cancelled;
                }
                if (!outcome.connection_running and !outcome.request_started and !retried_unsent_call) {
                    try self.recoverServerForToolCall(
                        server,
                        snapshot,
                        outcome.generation,
                        operation_deadline.?,
                        options,
                    );
                    try lockRwSharedUntil(
                        &server.connection_lock,
                        operation_deadline.?,
                        options.cancel_flag,
                    );
                    lease_active = true;
                    const recovered_dispatcher = server.dispatcher orelse {
                        server.connection_lock.unlockShared(io_mod.getIo());
                        lease_active = false;
                        return error.McpToolCatalogChanged;
                    };
                    const snapshot_current = if (options.continuation == null)
                        try self.refreshSnapshotAfterUnsentRecovery(
                            server,
                            snapshot,
                            recovered_dispatcher.connectionGeneration(),
                            operation_deadline.?,
                            options.cancel_flag,
                        )
                    else
                        try self.toolSnapshotMatchesCurrent(
                            server,
                            snapshot,
                            recovered_dispatcher.connectionGeneration(),
                            operation_deadline.?,
                            options.cancel_flag,
                        );
                    if (!snapshot_current) {
                        server.connection_lock.unlockShared(io_mod.getIo());
                        lease_active = false;
                        return error.McpToolCatalogChanged;
                    }
                    retried_unsent_call = true;
                    continue;
                }

                switch (err) {
                    error.McpResponseFrameTooLarge => {
                        const result = try handleMcpResponseFrameTooLarge(
                            arena,
                            server,
                            snapshot.prefixed_name,
                            raw_frame_cap,
                        );
                        self.recoverServerForToolCall(
                            server,
                            snapshot,
                            outcome.generation,
                            operation_deadline.?,
                            options,
                        ) catch |recovery_err| {
                            debug_trace.logf(
                                "mcp",
                                "stdio server recovery failed server={s} generation={d} err={s}",
                                .{ server.config.name, outcome.generation, @errorName(recovery_err) },
                            );
                            if (recovery_err == error.McpAccessDenied or
                                recovery_err == error.McpAuthorityChanged)
                            {
                                return recovery_err;
                            }
                        };
                        return result;
                    },
                    error.Cancelled, error.McpRequestTimedOut => return err,
                    else => {
                        if (!outcome.connection_running) {
                            self.recoverServerForToolCall(
                                server,
                                snapshot,
                                outcome.generation,
                                operation_deadline.?,
                                options,
                            ) catch |recovery_err| {
                                debug_trace.logf(
                                    "mcp",
                                    "stdio server recovery failed server={s} generation={d} err={s}",
                                    .{ server.config.name, outcome.generation, @errorName(recovery_err) },
                                );
                                if (recovery_err == error.McpAccessDenied or
                                    recovery_err == error.McpAuthorityChanged)
                                {
                                    return recovery_err;
                                }
                            };
                        }
                        return err;
                    },
                }
            };
            defer arena.free(response);

            const result = tool_result.extract(arena, .{
                .server_name = server.config.name,
                .tool_name = snapshot.prefixed_name,
                .response = response,
                .max_tool_result_bytes = max_tool_result_bytes,
                .protocol = featureProtocol(outcome.protocol),
                .output_schema_json = snapshot.output_schema_json,
                .legacy_wire = server.legacyWire(),
            }) catch |err| {
                outcome.finishLegacy(arena, .abandoned);
                return err;
            };
            outcome.finishLegacy(arena, terminalOutcomeForCallStatus(result.status));
            return result;
        }
    }

    fn recoverServerForToolCall(
        self: Operations,
        server: *McpServer,
        snapshot: *const ToolCallSnapshot,
        failed_generation: u64,
        deadline: std.Io.Clock.Timestamp,
        options: tool_mcp_runtime.CallOptions,
    ) !void {
        var guard = ServerAccessPrecommit{
            .authority = .{ .alloc = self.lifecycle.alloc, .runtime_generation = self.generation, .access = options.access, .target = .{ .tool = snapshot.prefixed_name } },
            .cancel_flag = server.cancellation(),
        };
        var precommit = guard.transport();
        return self.lifecycle.recoverServer(
            server,
            failed_generation,
            deadline,
            options.cancel_flag,
            &precommit,
        );
    }

    fn toolSnapshotMatchesCurrent(
        self: Operations,
        server: *McpServer,
        snapshot: *const ToolCallSnapshot,
        generation: u64,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !bool {
        try lockRwSharedUntil(self.lifecycle.catalog_mutex, deadline, cancel_flag);
        defer self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());

        const dispatcher = server.dispatcher orelse return false;
        if (dispatcher.connectionGeneration() != generation or
            snapshot.stdio_generation == null or
            generation != snapshot.stdio_generation.?) return false;
        return tool_snapshot.current(server, snapshot);
    }

    fn refreshSnapshotAfterUnsentRecovery(
        self: Operations,
        server: *McpServer,
        snapshot: *ToolCallSnapshot,
        generation: u64,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !bool {
        try lockRwSharedUntil(self.lifecycle.catalog_mutex, deadline, cancel_flag);
        defer self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());

        const dispatcher = server.dispatcher orelse return false;
        if ((server.lifetime.retiring.load(.acquire) or !std.mem.eql(u8, server.config.name, snapshot.server_name)) or
            dispatcher.connectionGeneration() != generation)
        {
            return false;
        }
        return tool_snapshot.refreshGenerations(
            server,
            snapshot,
            generation,
        );
    }

    const StdioCallOutcome = struct {
        generation: u64,
        protocol: StdioProtocol,
        response: ?[]u8 = null,
        failure: ?anyerror = null,
        legacy_terminal: ?LegacyDirectTerminal = null,
        connection_running: bool,
        request_started: bool,
        connection_lease_released: bool = false,

        fn finishLegacy(self: *StdioCallOutcome, alloc: Allocator, outcome: tool_mcp_runtime.ContinuationTerminal) void {
            const terminal = self.legacy_terminal orelse return;
            self.legacy_terminal = null;
            terminal.finish(alloc, outcome);
        }
    };

    fn callStdioToolOnce(
        runtime: Operations,
        alloc: Allocator,
        server: *McpServer,
        dispatcher: *stdio_dispatcher.StdioDispatcher,
        snapshot: *const ToolCallSnapshot,
        arguments_json: []const u8,
        max_frame_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
        deadline: std.Io.Clock.Timestamp,
    ) !StdioCallOutcome {
        const generation = dispatcher.connectionGeneration();
        const protocol = server.stdio_protocol;
        const request_id = dispatcher.reserveRequestId() catch |err| return .{
            .generation = generation,
            .protocol = protocol,
            .failure = err,
            .connection_running = dispatcher.isRunning(),
            .request_started = false,
        };
        const request_body = try buildToolCallRequestForProtocol(
            alloc,
            request_id,
            snapshot.original_name,
            arguments_json,
            protocol,
            if (options.progress != null)
                request_id
            else
                null,
            options.continuation,
            responderCapabilities(options.input_responder),
        );
        defer alloc.free(request_body);

        var tool_precommit = ToolPrecommit{
            .alloc = runtime.lifecycle.alloc,
            .runtime_generation = runtime.generation,
            .catalog_mutex = runtime.lifecycle.catalog_mutex,
            .server = server,
            .snapshot = snapshot,
            .deadline = deadline,
            .cancel_flag = options.cancel_flag,
            .access = options.access,
        };
        var transport_precommit = tool_precommit.transport();
        var request_started = false;
        var legacy_context: ?LegacyElicitationContext = if (protocol == .legacy)
            if (server.legacyWire()) |wire|
                LegacyElicitationContext.initStdio(
                    runtime.lifecycle.catalog_mutex,
                    runtime.completions,
                    server,
                    dispatcher,
                    wire,
                    options.input_responder,
                    .{ .tools_call = snapshot.original_name },
                    deadline,
                    options.cancel_flag,
                )
            else
                null
        else
            null;
        var server_request_wait = StdioServerRequestWait{ .server = server };
        const server_request_sink = if (legacy_context) |*context| context.sink() else null;
        const response = dispatcher.request(
            alloc,
            request_id,
            request_body,
            max_frame_bytes,
            .{
                .timeout_ms = server.config.operation_timeout_ms,
                .deadline = deadline,
                .cancel_flag = options.cancel_flag,
                .lifecycle_cancel_flag = server.cancellation(),
                .progress = options.progress,
                .response_observer = if (legacy_context) |*context| context.responseObserver() else null,
                .server_requests = server_request_sink,
                .deadline_gate = if (legacy_context) |*context| &context.deadline_gate else null,
                .server_request_wait = if (server_request_sink != null)
                    .{ .context = &server_request_wait, .callback = StdioServerRequestWait.begin }
                else
                    null,
                .request_started = &request_started,
                .precommit = &transport_precommit,
            },
        ) catch |err| return .{
            .generation = generation,
            .protocol = protocol,
            .failure = err,
            .legacy_terminal = if (legacy_context) |*context| context.directTerminal() else null,
            .connection_running = dispatcher.isRunning(),
            .request_started = request_started,
            .connection_lease_released = server_request_wait.released,
        };
        return .{
            .generation = generation,
            .protocol = protocol,
            .response = response,
            .legacy_terminal = if (legacy_context) |*context| context.directTerminal() else null,
            .connection_running = true,
            .request_started = true,
            .connection_lease_released = server_request_wait.released,
        };
    }

    pub fn mcpResponseFrameCap(max_tool_result_bytes: usize) usize {
        // JSON-RPC and MCP content wrappers add bytes around the model-facing result.
        // Keep the transport cap close to the configured result cap while allowing
        // normal envelope overhead before the model-facing truncation pass runs.
        return @max(@import("../images/image_data.zig").max_result_frame_bytes, std.math.add(usize, max_tool_result_bytes, mcp_response_frame_overhead_bytes) catch std.math.maxInt(usize));
    }

    pub fn terminalOutcomeForCallStatus(status: tool_mcp_runtime.CallStatus) tool_mcp_runtime.ContinuationTerminal {
        return switch (status) {
            .success, .tool_failure => .completed,
            .protocol_failure, .input_required => .abandoned,
        };
    }

    pub fn handleMcpResponseFrameTooLarge(arena: Allocator, server: *McpServer, tool_name: []const u8, cap_bytes: usize) !tool_mcp_runtime.CallResult {
        const server_name = server.config.name;
        debug_trace.logf("mcp", "server {s} exceeded response frame cap_bytes={d}", .{ server_name, cap_bytes });
        return .{
            .model_output = try tool_result.frame_too_large_result(
                arena,
                server_name,
                tool_name,
                cap_bytes,
            ),
            .status = .protocol_failure,
        };
    }

    fn responderCapabilities(responder: ?tool_mcp_runtime.InputResponder) elicitation.Capabilities {
        return if (responder) |value| value.capabilities else .{};
    }

    fn callToolHttp(
        self: Operations,
        alloc: Allocator,
        server: *McpServer,
        snapshot: *ToolCallSnapshot,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
        deadline: std.Io.Clock.Timestamp,
    ) !tool_mcp_runtime.CallResult {
        try lockRwSharedUntil(
            &server.connection_lock,
            deadline,
            options.cancel_flag,
        );
        var connection_locked = true;
        var reconnected_for_credentials = false;
        defer if (connection_locked) {
            server.connection_lock.unlockShared(io_mod.getIo());
        };
        if (server.legacy_http != null and try server_auth.legacyConnectionNeedsCredentialUpdate(
            self.lifecycle.alloc,
            server,
            deadline,
            options.cancel_flag,
        )) {
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            try (operation_authority.EffectAccess{ .alloc = self.lifecycle.alloc, .runtime_generation = self.generation, .access = options.access, .target = .{ .tool = snapshot.prefixed_name } }).authorize();
            switch (options.access) {
                .unrestricted => {},
                .disabled, .scoped => return error.McpAuthenticationRequired,
            }
            try self.lifecycle.reconnectRemote(server, deadline, options.cancel_flag, .credentials);
            try lockRwSharedUntil(
                &server.connection_lock,
                deadline,
                options.cancel_flag,
            );
            connection_locked = true;
            reconnected_for_credentials = true;
        }
        const snapshot_current = if (reconnected_for_credentials and options.continuation == null)
            try refreshRemoteSnapshotAfterReconnect(
                self,
                server,
                snapshot,
                deadline,
                options.cancel_flag,
            )
        else
            try httpToolSnapshotMatchesCurrent(
                self,
                server,
                snapshot,
                deadline,
                options.cancel_flag,
            );
        if (!snapshot_current) return error.McpToolCatalogChanged;

        var tool_precommit = ToolPrecommit{
            .alloc = self.lifecycle.alloc,
            .runtime_generation = self.generation,
            .catalog_mutex = self.lifecycle.catalog_mutex,
            .server = server,
            .snapshot = snapshot,
            .deadline = deadline,
            .cancel_flag = options.cancel_flag,
            .access = options.access,
        };
        var transport_precommit = tool_precommit.transport();
        const request_id = try server.reserveRequestId();
        if (server.legacy_http) |client| {
            if (!client.acquireUse()) return error.McpConnectionClosed;
            const client_version = client.version;
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            const result = callToolLegacyHttp(
                self,
                alloc,
                server,
                client,
                request_id,
                snapshot.original_name,
                snapshot.prefixed_name,
                snapshot.output_schema_json,
                arguments_json,
                max_tool_result_bytes,
                options,
                deadline,
                &transport_precommit,
            ) catch |err| {
                client.releaseUse();
                if (err == error.McpSessionExpired) {
                    switch (options.access) {
                        .unrestricted => {},
                        .disabled, .scoped => return err,
                    }
                    (operation_authority.EffectAccess{ .alloc = self.lifecycle.alloc, .runtime_generation = self.generation, .access = options.access, .target = .{ .tool = snapshot.prefixed_name } }).authorize() catch |access_err| {
                        debug_trace.logf(
                            "mcp",
                            "legacy HTTP session recovery denied server={s} err={s}",
                            .{ server.config.name, @errorName(access_err) },
                        );
                        return err;
                    };
                    self.lifecycle.recoverLegacyHttpSession(
                        server,
                        client,
                        client_version,
                        deadline,
                        options.cancel_flag,
                    ) catch |recovery_err| {
                        debug_trace.logf(
                            "mcp",
                            "legacy HTTP session recovery failed server={s} version={s} err={s}",
                            .{
                                server.config.name,
                                client_version.string(),
                                @errorName(recovery_err),
                            },
                        );
                    };
                }
                return err;
            };
            client.releaseUse();
            return result;
        }
        const request_body = try buildToolCallRequestForProtocol(
            alloc,
            request_id,
            snapshot.original_name,
            arguments_json,
            .modern,
            if (options.progress != null) request_id else null,
            options.continuation,
            responderCapabilities(options.input_responder),
        );
        defer alloc.free(request_body);

        const raw_frame_cap = mcpResponseFrameCap(max_tool_result_bytes);
        var response = server_auth.authenticatedPost(alloc, self.lifecycle.alloc, server, .{
            .url = try server.config.remoteUrl(),
            .static_headers = server.resolved_headers,
            .request_body = request_body,
            .input_schema_json = snapshot.input_schema_json,
            .max_response_bytes = raw_frame_cap,
            .max_event_bytes = raw_frame_cap,
            .progress = options.progress,
            .precommit = &transport_precommit,
            .control = .{
                .deadline = deadline,
                .cancel_flag = options.cancel_flag,
                .lifecycle_cancel_flag = server.cancellation(),
            },
        }, .{
            .alloc = self.lifecycle.alloc,
            .runtime_generation = self.generation,
            .access = options.access,
            .target = .{ .tool = snapshot.prefixed_name },
        }, .never, null) catch |err| switch (err) {
            error.ResponseTooLarge, error.SseEventTooLarge => {
                return handleMcpResponseFrameTooLarge(
                    alloc,
                    server,
                    snapshot.prefixed_name,
                    raw_frame_cap,
                );
            },
            else => |e| return e,
        };
        errdefer response.deinit(alloc);
        const result = try tool_result.extract(alloc, .{
            .server_name = server.config.name,
            .tool_name = snapshot.prefixed_name,
            .response = response.body,
            .max_tool_result_bytes = max_tool_result_bytes,
            .protocol = .modern,
            .output_schema_json = snapshot.output_schema_json,
        });
        response.deinit(alloc);
        return result;
    }

    fn httpToolSnapshotMatchesCurrent(
        self: Operations,
        server: *McpServer,
        snapshot: *const ToolCallSnapshot,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !bool {
        try lockRwSharedUntil(self.lifecycle.catalog_mutex, deadline, cancel_flag);
        defer self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());

        return tool_snapshot.current(server, snapshot);
    }

    fn refreshRemoteSnapshotAfterReconnect(
        self: Operations,
        server: *McpServer,
        snapshot: *ToolCallSnapshot,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !bool {
        try lockRwSharedUntil(self.lifecycle.catalog_mutex, deadline, cancel_flag);
        defer self.lifecycle.catalog_mutex.unlockShared(io_mod.getIo());
        if ((server.lifetime.retiring.load(.acquire) or !std.mem.eql(u8, server.config.name, snapshot.server_name))) return false;
        return tool_snapshot.refreshGenerations(server, snapshot, null);
    }

    fn callToolLegacyHttp(
        self: Operations,
        alloc: Allocator,
        server: *McpServer,
        client: *legacy_streamable_http.Client,
        request_id: u64,
        original_name: []const u8,
        prefixed_name: []const u8,
        output_schema_json: ?[]const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
        deadline: std.Io.Clock.Timestamp,
        precommit: *mcp_contract.TransportPrecommit,
    ) !tool_mcp_runtime.CallResult {
        const request_body = try buildToolCallRequestForProtocol(
            alloc,
            request_id,
            original_name,
            arguments_json,
            .legacy,
            if (options.progress != null) request_id else null,
            options.continuation,
            .{},
        );
        defer alloc.free(request_body);

        const raw_frame_cap = mcpResponseFrameCap(max_tool_result_bytes);
        var committed = std.atomic.Value(bool).init(false);
        var elicitation_context: ?LegacyElicitationContext = if (server_connection.legacyWireForHttpVersion(client.version)) |wire|
            LegacyElicitationContext.initHttp(
                self.lifecycle.catalog_mutex,
                self.completions,
                server,
                client,
                wire,
                options.input_responder,
                .{ .tools_call = original_name },
                deadline,
                options.cancel_flag,
            )
        else
            null;
        if (elicitation_context) |*context| try context.beginCompletionWindow();
        defer if (elicitation_context) |*context| context.endCompletionWindow();
        var direct_request_completed = false;
        defer if (!direct_request_completed) {
            if (elicitation_context) |*context| {
                if (context.directTerminal()) |terminal| terminal.finish(alloc, .abandoned);
            }
        };
        const response = client.request(alloc, .{
            .request_id = request_id,
            .request_body = request_body,
            .max_response_bytes = raw_frame_cap,
            .max_event_bytes = raw_frame_cap,
            .progress = options.progress,
            .response_observer = if (elicitation_context) |*context| context.responseObserver() else null,
            .server_requests = if (elicitation_context) |*context| context.sink() else null,
            .notifications = if (elicitation_context) |*context| context.completionSink() else null,
            .control = .{
                .deadline = deadline,
                .deadline_gate = if (elicitation_context) |*context| &context.deadline_gate else null,
                .cancel_flag = options.cancel_flag,
                .lifecycle_cancel_flag = server.cancellation(),
            },
            .committed = &committed,
            .precommit = precommit,
        }) catch |err| switch (err) {
            error.Cancelled, error.McpRequestTimedOut => {
                if (committed.load(.acquire)) {
                    sendLegacyHttpCancellation(
                        alloc,
                        server,
                        client,
                        request_id,
                        @errorName(err),
                    );
                }
                return err;
            },
            error.ResponseTooLarge, error.SseEventTooLarge => {
                return handleMcpResponseFrameTooLarge(
                    alloc,
                    server,
                    prefixed_name,
                    raw_frame_cap,
                );
            },
            error.McpAuthenticationRequired => {
                try server_auth.captureLegacyStreamableAuth(
                    self.lifecycle.alloc,
                    server,
                    client,
                    .{
                        .deadline = deadline,
                        .cancel_flag = options.cancel_flag,
                    },
                );
                return error.McpAuthenticationRequired;
            },
            else => |request_err| return request_err,
        };
        defer alloc.free(response);

        const result = try tool_result.extract(alloc, .{
            .server_name = server.config.name,
            .tool_name = prefixed_name,
            .response = response,
            .max_tool_result_bytes = max_tool_result_bytes,
            .protocol = .legacy,
            .output_schema_json = output_schema_json,
            .legacy_wire = server_connection.legacyWireForHttpVersion(client.version),
        });
        direct_request_completed = true;
        if (elicitation_context) |*context| {
            if (context.directTerminal()) |terminal| {
                terminal.finish(alloc, terminalOutcomeForCallStatus(result.status));
            }
        }
        return result;
    }

    const LegacyElicitationContext = @import("legacy_elicitation_runtime.zig").Context;

    fn sendLegacyHttpCancellation(
        alloc: Allocator,
        server: *McpServer,
        client: *legacy_streamable_http.Client,
        request_id: u64,
        reason: []const u8,
    ) void {
        const body = buildCancellationNotification(
            alloc,
            request_id,
            reason,
        ) catch |err| {
            debug_trace.logf(
                "mcp",
                "failed to build legacy HTTP cancellation server={s} request_id={d} err={s}",
                .{ server.config.name, request_id, @errorName(err) },
            );
            return;
        };
        defer alloc.free(body);
        const deadline = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)
            .addDuration(.{
            .clock = .awake,
            .raw = .fromMilliseconds(100),
        });
        client.sendNotification(alloc, body, .{ .deadline = deadline }) catch |err| {
            debug_trace.logf(
                "mcp",
                "failed to send legacy HTTP cancellation server={s} request_id={d} err={s}",
                .{ server.config.name, request_id, @errorName(err) },
            );
        };
    }

    fn callToolSse(
        self: Operations,
        alloc: Allocator,
        server: *McpServer,
        snapshot: *ToolCallSnapshot,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
        deadline: std.Io.Clock.Timestamp,
    ) !tool_mcp_runtime.CallResult {
        try lockRwSharedUntil(
            &server.connection_lock,
            deadline,
            options.cancel_flag,
        );
        var connection_locked = true;
        var reconnected_for_credentials = false;
        defer if (connection_locked) {
            server.connection_lock.unlockShared(io_mod.getIo());
        };
        if (server.legacy_sse != null and try server_auth.legacyConnectionNeedsCredentialUpdate(
            self.lifecycle.alloc,
            server,
            deadline,
            options.cancel_flag,
        )) {
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            try (operation_authority.EffectAccess{ .alloc = self.lifecycle.alloc, .runtime_generation = self.generation, .access = options.access, .target = .{ .tool = snapshot.prefixed_name } }).authorize();
            switch (options.access) {
                .unrestricted => {},
                .disabled, .scoped => return error.McpAuthenticationRequired,
            }
            try self.lifecycle.reconnectRemote(server, deadline, options.cancel_flag, .credentials);
            try lockRwSharedUntil(
                &server.connection_lock,
                deadline,
                options.cancel_flag,
            );
            connection_locked = true;
            reconnected_for_credentials = true;
        }
        const snapshot_current = if (reconnected_for_credentials and options.continuation == null)
            try refreshRemoteSnapshotAfterReconnect(
                self,
                server,
                snapshot,
                deadline,
                options.cancel_flag,
            )
        else
            try httpToolSnapshotMatchesCurrent(
                self,
                server,
                snapshot,
                deadline,
                options.cancel_flag,
            );
        if (!snapshot_current) return error.McpToolCatalogChanged;

        const client = server.legacy_sse orelse return error.McpConnectionClosed;
        const request_id = try server.reserveRequestId();
        const request_body = try buildToolCallRequestForProtocol(
            alloc,
            request_id,
            snapshot.original_name,
            arguments_json,
            .legacy,
            null,
            options.continuation,
            .{},
        );
        defer alloc.free(request_body);
        const raw_frame_cap = mcpResponseFrameCap(max_tool_result_bytes);
        var tool_precommit = ToolPrecommit{
            .alloc = self.lifecycle.alloc,
            .runtime_generation = self.generation,
            .catalog_mutex = self.lifecycle.catalog_mutex,
            .server = server,
            .snapshot = snapshot,
            .deadline = deadline,
            .cancel_flag = options.cancel_flag,
            .access = options.access,
        };
        var transport_precommit = tool_precommit.transport();
        const response = client.request(
            alloc,
            request_id,
            request_body,
            raw_frame_cap,
            .{
                .deadline = deadline,
                .cancel_flag = options.cancel_flag,
                .lifecycle_cancel_flag = server.cancellation(),
                .precommit = &transport_precommit,
            },
        ) catch |err| switch (err) {
            error.McpResponseFrameTooLarge, error.SseEventTooLarge => {
                return handleMcpResponseFrameTooLarge(
                    alloc,
                    server,
                    snapshot.prefixed_name,
                    raw_frame_cap,
                );
            },
            error.McpAuthenticationRequired => {
                try server_auth.captureLegacySseAuth(
                    self.lifecycle.alloc,
                    server,
                    client,
                    .{
                        .deadline = deadline,
                        .cancel_flag = options.cancel_flag,
                        .lifecycle_cancel_flag = server.cancellation(),
                    },
                );
                return error.McpAuthenticationRequired;
            },
            else => |request_err| return request_err,
        };
        defer alloc.free(response);
        return tool_result.extract(alloc, .{
            .server_name = server.config.name,
            .tool_name = snapshot.prefixed_name,
            .response = response,
            .max_tool_result_bytes = max_tool_result_bytes,
            .protocol = .legacy,
            .output_schema_json = snapshot.output_schema_json,
        });
    }
};

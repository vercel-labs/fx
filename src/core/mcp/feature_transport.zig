const std = @import("std");
const server_connection = @import("server_connection.zig");
const io_mod = @import("../shared/io.zig");
const mcp_contract = @import("mcp_contract.zig");
const server_auth = @import("server_auth.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const elicitation = @import("elicitation.zig");
const legacy_url_completion = @import("legacy_url_completion.zig");
const controlled_lock = @import("controlled_lock.zig");
const catalog_freshness = @import("catalog_freshness.zig");
const Allocator = std.mem.Allocator;
const mcp_feature_response_frame_cap_bytes: usize = 4 * 1024 * 1024;
const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const LegacyDirectTerminal = tool_mcp_runtime.InputCompletion;
const StdioServerRequestWait = server_connection.StdioRequestWait;
const McpServer = server_connection.Server;
const LegacyElicitationContext = @import("legacy_elicitation_runtime.zig").Context;

pub const Response = struct {
    body: []u8,
    auth_identity: ?catalog_freshness.Digest = null,
    legacy_terminal: ?LegacyDirectTerminal = null,

    pub fn finishLegacy(self: *Response, alloc: Allocator, outcome: tool_mcp_runtime.ContinuationTerminal) void {
        const terminal = self.legacy_terminal orelse return;
        self.legacy_terminal = null;
        terminal.finish(alloc, outcome);
    }

    pub fn deinit(self: *Response, alloc: Allocator) void {
        self.finishLegacy(alloc, .abandoned);
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const LegacyElicitationSpec = struct {
    responder: ?tool_mcp_runtime.InputResponder,
    operation: elicitation.Operation,
};

pub const Operations = struct {
    alloc: Allocator,
    generation: u64,
    catalog_mutex: *std.Io.RwLock,
    completions: *legacy_url_completion.State,

    pub fn send(
        self: Operations,
        server: *McpServer,
        request_id: u64,
        request: []const u8,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
        precommit: ?*mcp_contract.TransportPrecommit,
        legacy_elicitation: ?LegacyElicitationSpec,
    ) !Response {
        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        var connection_locked = true;
        defer if (connection_locked) server.connection_lock.unlockShared(io_mod.getIo());
        return switch (server.config.transport) {
            .stdio => stdio: {
                const dispatcher = server.dispatcher orelse return error.McpConnectionClosed;
                dispatcher.retainPublished();
                defer dispatcher.releaseUse();
                var legacy_context: ?LegacyElicitationContext = if (legacy_elicitation) |spec|
                    if (server.legacyWire()) |wire|
                        LegacyElicitationContext.initStdio(
                            self.catalog_mutex,
                            self.completions,
                            server,
                            dispatcher,
                            wire,
                            spec.responder,
                            spec.operation,
                            deadline,
                            cancel_flag,
                        )
                    else
                        null
                else
                    null;
                var server_request_wait = StdioServerRequestWait{ .server = server };
                defer {
                    if (server_request_wait.released) connection_locked = false;
                }
                const server_request_sink = if (legacy_context) |*context| context.sink() else null;
                var request_finished = false;
                defer if (!request_finished) {
                    if (legacy_context) |*context| {
                        if (context.directTerminal()) |terminal| terminal.finish(self.alloc, .abandoned);
                    }
                };
                const body = try dispatcher.request(
                    self.alloc,
                    request_id,
                    request,
                    mcp_feature_response_frame_cap_bytes,
                    .{
                        .timeout_ms = server.config.operation_timeout_ms,
                        .deadline = deadline,
                        .cancel_flag = cancel_flag,
                        .lifecycle_cancel_flag = server.cancellation(),
                        .precommit = precommit,
                        .response_observer = if (legacy_context) |*context| context.responseObserver() else null,
                        .server_requests = server_request_sink,
                        .deadline_gate = if (legacy_context) |*context| &context.deadline_gate else null,
                        .server_request_wait = if (server_request_sink != null)
                            .{ .context = &server_request_wait, .callback = StdioServerRequestWait.begin }
                        else
                            null,
                    },
                );
                request_finished = true;
                break :stdio .{
                    .body = body,
                    .legacy_terminal = if (legacy_context) |*context| context.directTerminal() else null,
                };
            },
            .http => if (server.legacy_http) |client| legacy: {
                if (!client.acquireUse()) return error.McpConnectionClosed;
                server.connection_lock.unlockShared(io_mod.getIo());
                connection_locked = false;
                defer client.releaseUse();
                var legacy_context: ?LegacyElicitationContext = if (legacy_elicitation) |spec|
                    if (server_connection.legacyWireForHttpVersion(client.version)) |wire|
                        LegacyElicitationContext.initHttp(
                            self.catalog_mutex,
                            self.completions,
                            server,
                            client,
                            wire,
                            spec.responder,
                            spec.operation,
                            deadline,
                            cancel_flag,
                        )
                    else
                        null
                else
                    null;
                if (legacy_context) |*context| try context.beginCompletionWindow();
                defer if (legacy_context) |*context| context.endCompletionWindow();
                const auth_identity = try server_auth.authIdentityForHeaders(self.alloc, client.static_headers);
                var request_finished = false;
                defer if (!request_finished) {
                    if (legacy_context) |*context| {
                        if (context.directTerminal()) |terminal| terminal.finish(self.alloc, .abandoned);
                    }
                };
                const body = try client.request(self.alloc, .{
                    .request_id = request_id,
                    .request_body = request,
                    .max_response_bytes = mcp_feature_response_frame_cap_bytes,
                    .max_event_bytes = mcp_feature_response_frame_cap_bytes,
                    .response_observer = if (legacy_context) |*context| context.responseObserver() else null,
                    .server_requests = if (legacy_context) |*context| context.sink() else null,
                    .notifications = if (legacy_context) |*context| context.completionSink() else null,
                    .control = .{
                        .deadline = deadline,
                        .deadline_gate = if (legacy_context) |*context| &context.deadline_gate else null,
                        .cancel_flag = cancel_flag,
                        .lifecycle_cancel_flag = server.cancellation(),
                    },
                    .precommit = precommit,
                });
                request_finished = true;
                break :legacy .{
                    .body = body,
                    .auth_identity = auth_identity,
                    .legacy_terminal = if (legacy_context) |*context| context.directTerminal() else null,
                };
            } else modern: {
                var identity: catalog_freshness.Digest = undefined;
                var response = try server_auth.authenticatedPost(self.alloc, self.alloc, server, .{
                    .url = try server.config.remoteUrl(),
                    .request_body = request,
                    .max_response_bytes = mcp_feature_response_frame_cap_bytes,
                    .max_event_bytes = mcp_feature_response_frame_cap_bytes,
                    .precommit = precommit,
                    .control = .{
                        .deadline = deadline,
                        .cancel_flag = cancel_flag,
                        .lifecycle_cancel_flag = server.cancellation(),
                    },
                }, .{
                    .alloc = self.alloc,
                    .runtime_generation = self.generation,
                    .access = access,
                    .target = .{ .feature_server = server.config.name },
                }, .safe, &identity);
                defer response.deinit(self.alloc);
                break :modern .{ .body = try self.alloc.dupe(u8, response.body), .auth_identity = identity };
            },
            .sse => if (server.legacy_sse) |client| legacy: {
                const body = try client.request(
                    self.alloc,
                    request_id,
                    request,
                    mcp_feature_response_frame_cap_bytes,
                    .{
                        .deadline = deadline,
                        .cancel_flag = cancel_flag,
                        .lifecycle_cancel_flag = server.cancellation(),
                        .precommit = precommit,
                    },
                );
                break :legacy .{
                    .body = body,
                    .auth_identity = try server_auth.authIdentityForHeaders(self.alloc, client.static_headers),
                };
            } else error.McpConnectionClosed,
        };
    }
};

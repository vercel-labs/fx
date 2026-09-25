//! Foreground ownership of server-directed tasks. The original tool is sent
//! once; all subsequent traffic uses its task handle and original authority.
const std = @import("std");
const tasks = @import("tasks.zig");
const io_mod = @import("../shared/io.zig");
const server_connection = @import("server_connection.zig");
const server_auth = @import("server_auth.zig");
const tool_snapshot = @import("tool_snapshot.zig");
const tool_result = @import("tool_result.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const controlled_lock = @import("controlled_lock.zig");
const operation_control = @import("operation_control.zig");
const mrtr = @import("mrtr.zig");

const Allocator = std.mem.Allocator;
const max_answered_inputs = 256;

pub const Context = struct {
    runtime_alloc: Allocator,
    runtime_generation: u64,
    catalog_mutex: *std.Io.RwLock,
    server: *server_connection.Server,
    snapshot: *const tool_snapshot.Snapshot,
    options: tool_mcp_runtime.CallOptions,
    max_frame_bytes: usize,
    max_tool_result_bytes: usize,

    /// Returns null for a non-task response. Caller owns the returned result.
    pub fn follow(
        self: Context,
        result_alloc: Allocator,
        response: []const u8,
        initial_deadline: std.Io.Clock.Timestamp,
    ) !?tool_mcp_runtime.CallResult {
        // Polling scratch must be released between requests, even when the
        // caller's result allocator is a turn arena.
        const alloc = self.runtime_alloc;
        var seed = std.json.parseFromSlice(std.json.Value, alloc, response, .{ .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null, // Ordinary tool extraction diagnoses malformed JSON.
        };
        defer seed.deinit();
        const initial = (try tasks.creation(seed.value)) orelse return null;
        const task_id = initial.id;
        var terminal = false;
        var input_outcome: tool_mcp_runtime.ContinuationTerminal = .abandoned;
        defer if (!terminal) self.cancel(alloc, task_id);

        var answered = std.StringHashMap(void).init(alloc);
        defer {
            var keys = answered.keyIterator();
            while (keys.next()) |key| alloc.free(key.*);
            answered.deinit();
        }
        var inputs: std.ArrayList(tool_mcp_runtime.InputOrigin) = .empty;
        defer {
            if (self.options.input_responder) |responder| {
                for (inputs.items) |origin| responder.finish(alloc, origin, input_outcome);
            }
            inputs.deinit(alloc);
        }
        var deadline = initial_deadline;
        // Creation carries Task, not DetailedTask, even if already terminal.
        var interval = switch (initial.status) {
            .working, .input_required => initial.poll_interval_ms,
            .completed, .failed, .cancelled => 0,
        };
        while (true) {
            try self.wait(interval, deadline);
            const body = try self.send(alloc, .get, task_id, null, deadline, self.options.cancel_flag);
            defer alloc.free(body);
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{ .parse_numbers = false });
            defer parsed.deinit();
            // Preserve JSON-RPC error details, including expired/unknown tasks.
            if (parsed.value == .object and parsed.value.object.contains("error")) {
                return try self.extract(result_alloc, body);
            }
            const task = try tasks.get(parsed.value, task_id);
            interval = task.poll_interval_ms;
            switch (task.status) {
                .working => {},
                .cancelled => {
                    terminal = true;
                    return .{
                        .model_output = try tool_result_limits.prepareModelOutput(result_alloc, self.snapshot.prefixed_name, "MCP task was cancelled by the server", self.max_tool_result_bytes),
                        .status = .tool_failure,
                    };
                },
                .completed, .failed => {
                    terminal = true;
                    var out: std.Io.Writer.Allocating = .init(alloc);
                    defer out.deinit();
                    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":0,");
                    if (task.status == .completed) {
                        try out.writer.writeAll("\"result\":");
                        var result = task.payload.object.get("result").?;
                        // Embedded CallToolResult examples omit the envelope discriminator.
                        if (!result.object.contains("resultType")) {
                            try result.object.put(parsed.arena.allocator(), "resultType", .{ .string = "complete" });
                        }
                        try std.json.Stringify.value(result, .{}, &out.writer);
                    } else {
                        try out.writer.writeAll("\"error\":");
                        try std.json.Stringify.value(task.payload.object.get("error").?, .{}, &out.writer);
                    }
                    try out.writer.writeByte('}');
                    const result = try self.extract(result_alloc, out.written());
                    if (result.status == .success or result.status == .tool_failure) input_outcome = .completed;
                    return result;
                },
                .input_required => {
                    const responder = self.options.input_responder orelse return error.McpInputRequired;
                    var required = try mrtr.parseInputRequired(alloc, task.payload, .{});
                    defer required.deinit(alloc);
                    var pending: std.ArrayList(mrtr.InputRequest) = .empty;
                    defer pending.deinit(alloc);
                    for (required.requests) |request| {
                        if (!answered.contains(request.key)) try pending.append(alloc, request);
                    }
                    if (pending.items.len == 0) continue;
                    if (answered.count() + pending.items.len > max_answered_inputs) return error.McpTaskInputLimitExceeded;
                    const requests_json = try mrtr.renderRequests(alloc, pending.items);
                    defer alloc.free(requests_json);
                    try self.check(deadline);
                    const interaction_deadline = operation_control.elicitationDeadline(io_mod.getIo());
                    const origin = tool_mcp_runtime.InputOrigin{
                        .wire = .modern_mcp,
                        .server_name = self.snapshot.server_name,
                        .operation = .{ .tools_call = self.snapshot.original_name },
                        .runtime_generation = self.runtime_generation,
                        .connection_generation = self.snapshot.connection_generation,
                        .client_generation = self.snapshot.stdio_generation orelse self.snapshot.connection_generation,
                        .catalog_generation = self.snapshot.catalog_generation,
                        // Keep task input identities distinct from any MRTR
                        // rounds that preceded creation of this task.
                        .request_generation = mrtr.max_tool_rounds + inputs.items.len + 1,
                        .auth_generation = self.server.auth_generation.load(.acquire),
                        .deadline_ms = operation_control.timestampMillis(interaction_deadline),
                        .lifecycle_cancel_flag = self.server.cancellation(),
                    };
                    try inputs.append(alloc, origin);
                    const responses = try responder.callback(responder.context, alloc, origin, .{ .input_requests_json = requests_json });
                    defer alloc.free(responses);
                    try mrtr.validateResponses(alloc, pending.items, responses, .{});
                    // User interaction has its own budget, as in synchronous MRTR.
                    deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                        .clock = .awake,
                        .raw = .fromMilliseconds(self.server.config.operation_timeout_ms),
                    });
                    const ack_body = try self.send(alloc, .update, task_id, responses, deadline, self.options.cancel_flag);
                    defer alloc.free(ack_body);
                    var ack = try std.json.parseFromSlice(std.json.Value, alloc, ack_body, .{});
                    defer ack.deinit();
                    if (ack.value == .object and ack.value.object.contains("error")) return try self.extract(result_alloc, ack_body);
                    try tasks.acknowledgement(ack.value);
                    for (pending.items) |request| {
                        const key = try alloc.dupe(u8, request.key);
                        errdefer alloc.free(key);
                        try answered.put(key, {});
                    }
                },
            }
        }
    }

    fn extract(self: Context, alloc: Allocator, response: []const u8) !tool_mcp_runtime.CallResult {
        return tool_result.extract(alloc, .{
            .server_name = self.snapshot.server_name,
            .tool_name = self.snapshot.prefixed_name,
            .response = response,
            .max_tool_result_bytes = self.max_tool_result_bytes,
            .protocol = .modern,
            .output_schema_json = self.snapshot.output_schema_json,
        });
    }

    fn check(self: Context, deadline: std.Io.Clock.Timestamp) !void {
        if (self.server.cancellation().load(.acquire)) return error.Cancelled;
        try controlled_lock.checkOperation(io_mod.getIo(), deadline, self.options.cancel_flag);
    }

    fn wait(self: Context, interval_ms: u64, deadline: std.Io.Clock.Timestamp) !void {
        const start = operation_control.monotonicMillis(io_mod.getIo());
        // Avoid a busy loop if a server suggests zero. Poll waits remain cancellable.
        const delay = @max(interval_ms, 10);
        while (true) {
            try self.check(deadline);
            const elapsed = operation_control.monotonicMillis(io_mod.getIo()) -| start;
            if (elapsed >= delay) return;
            io_mod.sleep(@as(u64, @min(delay - elapsed, 25)) * std.time.ns_per_ms);
        }
    }

    fn cancel(self: Context, alloc: Allocator, task_id: []const u8) void {
        // Cancellation is cooperative. Bound cleanup independently of the
        // expired call deadline, but retain its server, identity and authority.
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(1000),
        });
        const body = self.send(alloc, .cancel, task_id, null, deadline, null) catch return;
        alloc.free(body);
    }

    fn send(
        self: Context,
        alloc: Allocator,
        method: tasks.Method,
        task_id: []const u8,
        responses: ?[]const u8,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) ![]u8 {
        try controlled_lock.rwSharedUntil(&self.server.connection_lock, deadline, cancel_flag);
        defer self.server.connection_lock.unlockShared(io_mod.getIo());
        const request_id = try server_connection.featureRequestId(self.server);
        const body = try tasks.request(alloc, request_id, method, task_id, responses, if (self.options.input_responder) |responder| responder.capabilities else .{});
        defer alloc.free(body);
        var guard = tool_snapshot.CommitGuard{
            .alloc = self.runtime_alloc,
            .runtime_generation = self.runtime_generation,
            .catalog_mutex = self.catalog_mutex,
            .server = self.server,
            .snapshot = self.snapshot,
            .deadline = deadline,
            .cancel_flag = cancel_flag,
            .access = self.options.access,
        };
        var precommit = guard.transport();
        switch (self.server.config.transport) {
            .stdio => {
                const dispatcher = self.server.dispatcher orelse return error.McpConnectionClosed;
                if (self.snapshot.stdio_generation != dispatcher.connectionGeneration()) return error.McpToolCatalogChanged;
                dispatcher.retainPublished();
                defer dispatcher.releaseUse();
                return dispatcher.request(alloc, request_id, body, self.max_frame_bytes, .{
                    .timeout_ms = self.server.config.operation_timeout_ms,
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = self.server.cancellation(),
                    .precommit = &precommit,
                    .send_cancellation = false,
                });
            },
            .http => {
                if (self.server.legacy_http != null) return error.McpToolCatalogChanged;
                var response = try server_auth.authenticatedPost(alloc, self.runtime_alloc, self.server, .{
                    .url = try self.server.config.remoteUrl(),
                    .request_body = body,
                    .max_response_bytes = self.max_frame_bytes,
                    .max_event_bytes = self.max_frame_bytes,
                    .precommit = &precommit,
                    .control = .{
                        .deadline = deadline,
                        .cancel_flag = cancel_flag,
                        .lifecycle_cancel_flag = self.server.cancellation(),
                    },
                }, .{
                    .alloc = self.runtime_alloc,
                    .runtime_generation = self.runtime_generation,
                    .access = self.options.access,
                    .target = .{ .tool = self.snapshot.prefixed_name },
                }, .never, null);
                defer response.deinit(alloc);
                return alloc.dupe(u8, response.body);
            },
            .sse => return error.McpInvalidTask,
        }
    }
};

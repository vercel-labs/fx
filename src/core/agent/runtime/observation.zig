//! Semantic execution facts for host-owned instrumentation. No trace schema,
//! exporter, or durable state lives here. All event payloads are borrowed for
//! the synchronous callback; a retaining sink must copy them and be thread safe.
const std = @import("std");
const types = @import("../../shared/types.zig");
const provider = @import("../stream_provider.zig");

pub const ModelPurpose = enum { agent, compaction, vision, title, permission_review, auxiliary };
pub const TurnOutcome = enum { completed, interrupted, failed, paused, yielded, cancelled, fenced };
pub const WaitKind = enum { approval, question, mcp_form, mcp_url };
pub const WaitOutcome = enum { accepted, denied, cancelled, failed, timed_out };
pub const McpStatus = enum { success, failure, cancelled, input_required, unavailable, unknown };
pub const WaitRequest = struct {
    kind: WaitKind,
    call_id: ?[]const u8 = null,
    external_id: ?u64 = null,
    prompt: ?[]const u8 = null,
    schema_json: ?[]const u8 = null,
    questions: []const types.QuestionBatchEntry = &.{},
    server_name: ?[]const u8 = null,
};
pub const McpIdentity = struct { call_id: ?[]const u8, server: []const u8, tool: []const u8, transport: ?[]const u8 };

pub const Event = union(enum) {
    turn_start: struct { input: []const u8, resumed: bool },
    turn_end: struct { outcome: TurnOutcome, error_name: ?[]const u8 = null },
    step_start: void,
    step_end: void,
    model_start: struct { id: usize, purpose: ModelPurpose, request: provider.RequestData, parent_call_id: ?[]const u8 = null, tools_json: ?[]const u8 = null },
    model_admitted: usize,
    model_output_start: usize,
    model_end: struct {
        id: usize,
        completion: ?types.ModelCompletion = null,
        error_name: ?[]const u8 = null,
        cancelled: bool = false,
    },
    tool_start: struct { call: types.ToolCall, rerun: bool = false },
    tool_end: struct {
        call: types.ToolCall,
        output: ?[]const u8 = null,
        status: []const u8,
        error_name: ?[]const u8 = null,
        usage: ?types.ToolUsage = null,
    },
    /// Accepted into the engine's conversation, not a durable-write receipt.
    tool_result: struct { call: types.ToolCall, output: []const u8, status: types.PersistedToolStatus },
    /// The whole permission evaluation, not necessarily a human wait.
    permission_start: types.ToolCall,
    permission_end: struct { call: types.ToolCall, decision: ?types.ToolPermissionDecision = null, error_name: ?[]const u8 = null },
    wait_start: struct { id: usize, request: WaitRequest },
    wait_end: struct { id: usize, outcome: WaitOutcome, answers: []const []const u8 = &.{}, error_name: ?[]const u8 = null },
    mcp_start: struct { id: usize, identity: McpIdentity },
    mcp_request: struct { id: usize, request_id: u64, kind: enum { jsonrpc, engine } = .jsonrpc },
    mcp_end: struct { id: usize, status: McpStatus, error_name: ?[]const u8 = null },
    delegation: struct {
        call_id: []const u8,
        child_id: []const u8,
        work_id: []const u8,
        operation_id: ?[]const u8 = null,
        phase: enum { dispatched, completed, yielded, replayed, failed, cancelled, feedback_queued, feedback_applied, feedback_not_applied },
    },
};

pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, usize, Event) void,
};

pub const Observer = struct {
    // One observer per worker execution, including a resumed execution.
    sink: Sink,
    /// Execution-local ordinals, never debug counters or durable operation IDs.
    step_index: std.atomic.Value(usize) = .init(0),
    next_model: std.atomic.Value(usize) = .init(1),
    next_operation: std.atomic.Value(usize) = .init(1),
    turn_started: bool = false,
    turn_ended: bool = false,

    pub fn beginTurn(self: *Observer, input: []const u8, resumed: bool) void {
        if (self.turn_started) return;
        self.turn_started = true;
        self.emit(.{ .turn_start = .{ .input = input, .resumed = resumed } });
    }

    pub fn endTurn(self: *Observer, outcome: TurnOutcome, error_name: ?[]const u8) void {
        if (!self.turn_started or self.turn_ended) return;
        self.turn_ended = true;
        self.emit(.{ .turn_end = .{ .outcome = outcome, .error_name = error_name } });
    }

    pub fn emit(self: *Observer, event: Event) void {
        self.sink.emit_fn(self.sink.context, self.step_index.load(.acquire), event);
    }

    pub fn beginStep(self: *Observer, index: usize) void {
        self.step_index.store(index, .release);
        self.emit(.step_start);
    }

    pub fn endStep(self: *Observer) void {
        self.emit(.step_end);
        self.step_index.store(0, .release);
    }

    pub fn beginModel(self: *Observer, request: provider.RequestData, purpose: ModelPurpose) ModelCall {
        return self.beginModelForTool(request, purpose, null);
    }

    pub fn beginModelForTool(self: *Observer, request: provider.RequestData, purpose: ModelPurpose, parent_call_id: ?[]const u8) ModelCall {
        return self.beginModelWithSchemas(request, purpose, parent_call_id, null);
    }

    pub fn beginModelWithSchemas(self: *Observer, request: provider.RequestData, purpose: ModelPurpose, parent_call_id: ?[]const u8, tools_json: ?[]const u8) ModelCall {
        const call = ModelCall{ .observer = self, .id = self.next_model.fetchAdd(1, .monotonic), .step = self.step_index.load(.acquire) };
        call.emit(.{ .model_start = .{ .id = call.id, .purpose = purpose, .request = request, .parent_call_id = parent_call_id, .tools_json = tools_json } });
        return call;
    }

    pub fn beginWait(self: *Observer, request: WaitRequest) Wait {
        const wait = Wait{ .observer = self, .id = self.next_operation.fetchAdd(1, .monotonic), .step = self.step_index.load(.acquire) };
        self.sink.emit_fn(self.sink.context, wait.step, .{ .wait_start = .{ .id = wait.id, .request = request } });
        return wait;
    }

    pub fn beginMcp(self: *Observer, identity: McpIdentity) McpCall {
        const call = McpCall{ .observer = self, .id = self.next_operation.fetchAdd(1, .monotonic), .step = self.step_index.load(.acquire) };
        self.sink.emit_fn(self.sink.context, call.step, .{ .mcp_start = .{ .id = call.id, .identity = identity } });
        return call;
    }
};

pub const Wait = struct {
    observer: *Observer,
    id: usize,
    step: usize,
    pub fn end(self: Wait, outcome: WaitOutcome, answers: []const []const u8, error_name: ?[]const u8) void {
        self.observer.sink.emit_fn(self.observer.sink.context, self.step, .{ .wait_end = .{ .id = self.id, .outcome = outcome, .answers = answers, .error_name = error_name } });
    }
};

pub const McpCall = struct {
    observer: *Observer,
    id: usize,
    step: usize,
    pub fn request(self: McpCall, request_id: u64) void {
        self.observer.sink.emit_fn(self.observer.sink.context, self.step, .{ .mcp_request = .{ .id = self.id, .request_id = request_id } });
    }
    pub fn engineRequest(self: McpCall, request_id: u64) void {
        self.observer.sink.emit_fn(self.observer.sink.context, self.step, .{ .mcp_request = .{ .id = self.id, .request_id = request_id, .kind = .engine } });
    }
    pub fn end(self: McpCall, status: McpStatus, error_name: ?[]const u8) void {
        self.observer.sink.emit_fn(self.observer.sink.context, self.step, .{ .mcp_end = .{ .id = self.id, .status = status, .error_name = error_name } });
    }
};

pub const ModelCall = struct {
    observer: *Observer,
    id: usize,
    step: usize,
    output_started: bool = false,

    pub fn emit(self: ModelCall, event: Event) void {
        self.observer.sink.emit_fn(self.observer.sink.context, self.step, event);
    }

    pub fn output(self: *ModelCall) void {
        if (self.output_started) return;
        self.output_started = true;
        self.emit(.{ .model_output_start = self.id });
    }
};

test "semantic observer model identities are independent of debug IDs and capture their step" {
    const Capture = struct {
        steps: [4]usize = undefined,
        len: usize = 0,
        fn emit(raw: *anyopaque, step: usize, _: Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.steps[self.len] = step;
            self.len += 1;
        }
    };
    var capture: Capture = .{};
    var observer = Observer{ .sink = .{ .context = &capture, .emit_fn = Capture.emit } };
    observer.beginStep(1);
    const data = provider.RequestData{ .model = "fixture", .messages = &.{}, .tool_choice = .none, .provider_options = .{} };
    var call = observer.beginModel(data, .agent);
    try std.testing.expectEqual(@as(usize, 1), call.id);
    observer.beginStep(2);
    call.output();
    call.output();
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 2, 1 }, &capture.steps);
}

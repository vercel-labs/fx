//! A JSON-lines shell around the real `fx tool ask` path, for the Bun driver
//! in tests/tla/drivers/tool_bridge/ask-*.ts.
//!
//! The driver copies this file to the root of a work folder that holds a copy
//! of src/ and build.zig, so each import below is a real file of this tree.
//! Each bash call runs through `tool_runtime.executeToolCallAuthorized` on a
//! `bash_session` tool, which creates the real `McpCallBridgeState`, registers
//! the real bridge (`tool_bridge.register`), and runs `managed.startCaptured`
//! with the real `&registration.hold` and steering yield. Each `fx tool ask`
//! client connects over a real Unix socket to the bridge, passes through
//! `bridge.zig`'s `holds_prompt` lock and `authorizeGated`, runs `runBridgeAsk`
//! and `QuestionWatch`, and blocks on the real `WorkerRuntime` question slot.
//!
//! One gate on `permission_prompter` holds a queued second request right after
//! the first unlocks `bridge.prompt` (on `answer` or `esc` or `gone`), so the
//! model's `Show(2)` and `GiveUp(2)` remain distinct steps without touching
//! `bridge.zig`. That gate is never armed during `send`, so `admission-lock-only`
//! reaches the real `std.debug.assert` in `worker_runtime.zig`.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("src/core/shared/io.zig");
const managed = @import("src/core/execution/managed_execution.zig");
const command_runner = @import("src/core/execution/command_runner.zig");
const contract = @import("src/core/execution/managed_execution_contract.zig");
const command_admission = @import("src/core/permissions/command_admission.zig");
const permission_prompter = @import("src/core/permissions/permission_prompter.zig");
const permission_request = @import("src/core/permissions/permission_request.zig");
const tool_runtime = @import("src/core/tooling/tool_runtime.zig");
const tool_dispatch = @import("src/core/tooling/tool_dispatch.zig");
const tool_contracts = @import("src/core/agent/runtime/tool_contracts.zig");
const tool_bridge = @import("src/core/tool_bridge/tool_bridge.zig");
const worker_runtime = @import("src/core/agent/worker_runtime.zig");
const session_runtime = @import("src/core/session/session.zig");
const context_contract = @import("src/core/workspace/context_contract.zig");
const types = @import("src/core/shared/types.zig");
const builtin_tools = @import("src/builtins/tools.zig");

comptime {
    _ = @import("session_manager");
}

const Allocator = std.mem.Allocator;

const max_programs = 2;
const req_count = 2;
const answer_window_ms: i64 = 1500;
const still_waiting_probe_ms: i64 = 50;
const held_yield_probe_ms: i64 = 400;
const shutdown_limit_ms: i64 = 5000;
const admit_limit_ms: i64 = 2000;
const register_limit_ms: i64 = 2000;
const program_command = "sleep 30";

const Prog = enum { none, running, gone };
const Stage = enum { none, queued, shown, done };
const Told = enum { none, answer, esc, withdrawn, gave_up, no_ui, unavailable, other };

fn toldName(told: Told) []const u8 {
    return switch (told) {
        .gave_up => "gave-up",
        .no_ui => "no-ui",
        else => @tagName(told),
    };
}

const Input = struct { event: []const u8, i: ?u32 = null };

const Run = struct {
    harness: *Harness,
    id: []const u8,
    registered: std.atomic.Value(bool) = .init(false),
    captured_done: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    unregister_mutex: std.Io.Mutex = .init,
    unregister_cond: std.Io.Condition = .init,
    unregister_release: bool = false,
    registration: ?*tool_bridge.Registration = null,
    socket_path: []const u8 = "",
    token: tool_bridge.core.Token = @splat(0),
    prepared: ?managed.PreparedSnapshot = null,
    err: ?anyerror = null,

    fn releaseUnregister(self: *Run) void {
        const io = io_mod.getIo();
        self.unregister_mutex.lockUncancelable(io);
        self.unregister_release = true;
        self.unregister_cond.broadcast(io);
        self.unregister_mutex.unlock(io);
    }

    fn waitUnregister(self: *Run) void {
        const io = io_mod.getIo();
        self.unregister_mutex.lockUncancelable(io);
        while (!self.unregister_release) self.unregister_cond.waitUncancelable(io, &self.unregister_mutex);
        self.unregister_mutex.unlock(io);
    }
};

const AskCall = struct {
    index: usize,
    socket_path: []const u8,
    token: tool_bridge.core.Token,
    question: []const u8,
    stream_mutex: std.Io.Mutex = .init,
    stream: ?std.Io.net.Stream = null,
    sent: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    shut_down: std.atomic.Value(bool) = .init(false),
    was_queued: std.atomic.Value(bool) = .init(false),
    told: Told = .other,

    fn shutdownWrite(self: *AskCall) void {
        const io = io_mod.getIo();
        self.shut_down.store(true, .release);
        self.stream_mutex.lockUncancelable(io);
        if (self.stream) |stream| stream.shutdown(io, .send) catch {};
        self.stream_mutex.unlock(io);
    }
};

const ReqSlot = struct {
    stage: Stage = .none,
    told: Told = .none,
    call: ?*AskCall = null,
};

fn waitDone(flag: *std.atomic.Value(bool), limit_ms: i64) bool {
    const started = io_mod.milliTimestamp();
    while (!flag.load(.seq_cst)) {
        if (io_mod.milliTimestamp() - started >= limit_ms) return false;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return true;
}

fn gatherNoopContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopStatic(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransient(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

const harness_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "harness.ask_wait",
    .gather_project_context_fn = gatherNoopContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStatic,
    .append_transient_fn = appendNoopTransient,
} };

fn noopOutput(_: *anyopaque, _: ?types.ToolLifecycleId, _: @import("src/core/execution/command_contract.zig").CommandOutputStream, _: []const u8) !void {}

const BashInput = struct {};

fn decodeHarnessBash(ctx: tool_dispatch.DispatchContext, _: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const ptr = try ctx.allocator.create(BashInput);
    ptr.* = .{};
    return .{ .input = .{ .ptr = ptr, .deinit_fn = deinitHarnessBash } };
}

fn deinitHarnessBash(ptr: *anyopaque, alloc: Allocator) void {
    const input: *BashInput = @ptrCast(@alignCast(ptr));
    alloc.destroy(input);
}

fn readsOnlyFalse(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn irreversibleFalse(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn authorityFor(input: managed.StartCapturedInput) command_admission.CommandExecutionAuthority {
    const ctx = command_admission.CommandContext{
        .command = input.command,
        .resolved_cwd = input.cwd,
        .target_os = builtin.target.os.tag,
        .environment = input.environment,
    };
    return .{ .shell_allowed = .{ .fingerprint = .init(ctx), .source = .yolo } };
}

fn callHarnessBash(ctx: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const run: *Run = @ptrCast(@alignCast(ctx.output_chunk_ctx));
    const self = run.harness;
    const capability = ctx.mcp_call_capability orelse return .{ .failure = try ctx.allocator.dupe(u8, "bridge capability missing") };
    const registration = tool_bridge.register(capability) catch |err| {
        run.err = err;
        run.registered.store(true, .release);
        return .{ .failure = try ctx.allocator.print("register failed: {s}", .{@errorName(err)}) };
    };
    errdefer tool_bridge.unregister(registration);
    const variables = registration.environment();
    run.registration = registration;
    run.socket_path = self.alloc.dupe(u8, variables[0].value) catch return error.OutOfMemory;
    run.token = tool_bridge.wire.parseToken(variables[1].value) orelse return error.OutOfMemory;
    run.registered.store(true, .release);

    var input = managed.StartCapturedInput{
        .execution_id = run.id,
        .command = program_command,
        .cwd = self.root,
        .environment = .legacy,
        .authority = undefined,
        .extra_environment = variables,
        .yield_hold = &registration.hold,
        .max_output_bytes = 4096,
        .timeout_ms = 60_000,
        .command_artifact_dir = null,
        .yield_time_ms = contract.max_yield_time_ms,
        .tool_yield_flag = &self.steer,
        .cancel_flag = &run.cancel,
    };
    input.authority = authorityFor(input);
    run.prepared = self.managed.startCaptured(self.alloc, input) catch |err| blk: {
        run.err = err;
        break :blk null;
    };
    run.captured_done.store(true, .seq_cst);
    run.waitUnregister();
    tool_bridge.unregister(registration);
    return .{ .success = try ctx.allocator.dupe(u8, "ok") };
}

const harness_bash_tool = tool_dispatch.Tool{
    .name = "bash",
    .description = "harness bash",
    .model_schema = .{ .name = "bash", .description = "harness bash" },
    .executor_kind = .terminal,
    .activity_kind = .command,
    .requires_approval = true,
    .captured_command_host = .bash_session,
    .captured_command_action = "run",
    .decode = decodeHarnessBash,
    .call = callHarnessBash,
    .reads_only_fn = readsOnlyFalse,
    .irreversible_fn = irreversibleFalse,
};

const harness_tools = [_]tool_dispatch.Tool{harness_bash_tool};
const harness_registry = tool_dispatch.Registry{ .tools = &harness_tools };

fn firstMain(self: *Harness, run: *Run) void {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("ask_user_question"),
        .pattern = @constCast("**"),
        .action = .ask,
    }};
    const ctx = tool_runtime.Context{
        .workspace_root = self.root,
        .ignored_list_entries = &.{},
        .max_list_entries = 100,
        .max_read_file_bytes = 64 * 1024,
        .max_read_file_lines = 400,
        .max_read_file_line_len = 2000,
        .max_command_output_bytes = 64 * 1024,
        .api_key = "",
        .model = "test",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .agent_step_limit = 0,
        .tool_registry = harness_registry,
        .nested_tool_registry = builtin_tools.registry,
        .permission_mode = .ask,
        .permission_grants = &.{},
        .permission_rules = .{ .rules = &rules },
        .worker = self.worker,
        .permission_prompter = self.prompter(),
        .cancel_flag = &run.cancel,
        .session = self.session,
        .session_allocator = self.alloc,
        .context_registry = harness_context_registry,
        .output_chunk_ctx = @ptrCast(run),
        .on_output_chunk = noopOutput,
        .managed_executions = self.managed,
        .interactive = self.ui,
    };
    _ = tool_runtime.executeToolCallAuthorized(ctx, .{
        .call_allocator = arena,
        .result_allocator = arena,
        .call = .{ .id = run.id, .name = "bash", .arguments_json = "{}" },
        .authority = .ordinary,
        .session_grants = &.{},
        .advertised_dynamic_tool_names = &.{},
        .max_tool_result_bytes = 64 * 1024,
        .classification_complete = true,
    }) catch |err| {
        if (run.err == null) run.err = err;
    };
    run.done.store(true, .seq_cst);
}

fn clientMain(call: *AskCall) void {
    const io = io_mod.getIo();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const options = [_][]const u8{ "A", "B" };
    const encoded = tool_bridge.client.encodeRequest(arena, call.token, .{ .ask = .{
        .question = call.question,
        .options = &options,
    } }) catch {
        call.told = .other;
        call.sent.store(true, .release);
        call.done.store(true, .seq_cst);
        return;
    };
    const address = std.Io.net.UnixAddress.init(call.socket_path) catch {
        call.told = .unavailable;
        call.sent.store(true, .release);
        call.done.store(true, .seq_cst);
        return;
    };
    const stream = address.connect(io) catch {
        call.told = .unavailable;
        call.sent.store(true, .release);
        call.done.store(true, .seq_cst);
        return;
    };
    defer {
        call.stream_mutex.lockUncancelable(io);
        call.stream = null;
        call.stream_mutex.unlock(io);
        stream.close(io);
    }
    call.stream_mutex.lockUncancelable(io);
    call.stream = stream;
    call.stream_mutex.unlock(io);

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(encoded) catch {
        call.told = .unavailable;
        call.sent.store(true, .release);
        call.done.store(true, .seq_cst);
        return;
    };
    writer.interface.flush() catch {
        call.told = .unavailable;
        call.sent.store(true, .release);
        call.done.store(true, .seq_cst);
        return;
    };
    call.sent.store(true, .release);

    var read_buf: [tool_bridge.wire.max_header_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const line = (reader.interface.takeDelimiter('\n') catch {
        call.told = classifyDisconnect(call);
        call.done.store(true, .seq_cst);
        return;
    }) orelse {
        call.told = classifyDisconnect(call);
        call.done.store(true, .seq_cst);
        return;
    };
    const header = tool_bridge.wire.parseHeader(arena, line) catch {
        call.told = .other;
        call.done.store(true, .seq_cst);
        return;
    };
    const bytes = reader.interface.readAllocAll(arena, @intCast(header.bytes)) catch {
        call.told = classifyDisconnect(call);
        call.done.store(true, .seq_cst);
        return;
    };
    call.told = classifyReply(header.status, bytes);
    call.done.store(true, .seq_cst);
}

fn classifyDisconnect(call: *const AskCall) Told {
    if (!call.shut_down.load(.acquire)) return .unavailable;
    return if (call.was_queued.load(.acquire)) .gave_up else .withdrawn;
}

fn classifyReply(status: tool_bridge.wire.Status, bytes: []const u8) Told {
    return switch (status) {
        .ok => if (std.mem.eql(u8, bytes, "A") or std.mem.eql(u8, bytes, "A\n")) .answer else .other,
        .tool_error => if (std.mem.find(u8, bytes, "no question UI") != null) .no_ui else .other,
        .denied => if (std.mem.find(u8, bytes, "left before its permission check") != null) .gave_up else .other,
        .failed => if (std.mem.find(u8, bytes, "Cancelled.") != null) .esc else .other,
        .refused => .unavailable,
    };
}

const Harness = struct {
    alloc: Allocator,
    root: []const u8,
    ui: bool,
    managed: *managed.Runtime,
    worker: *worker_runtime.WorkerRuntime,
    session: *session_runtime.SessionRuntime,
    steer: std.atomic.Value(bool) = .init(false),
    gate_mutex: std.Io.Mutex = .init,
    gate_cond: std.Io.Condition = .init,
    gate_queued_ask: bool = false,
    first: ?*Run = null,
    last_socket_path: ?[]const u8 = null,
    last_token: tool_bridge.core.Token = @splat(0),
    prog: Prog = .none,
    execution_id: []const u8 = "",
    programs: u32 = 0,
    asked: u32 = 0,
    reqs: [req_count]ReqSlot = .{ .{}, .{} },
    serial: u32 = 0,
    notes: std.ArrayList([]const u8) = .empty,

    fn create(alloc: Allocator, root: []const u8, ui: bool) !*Harness {
        const managed_runtime = try alloc.create(managed.Runtime);
        managed_runtime.* = managed.Runtime.init(alloc);
        const worker = try alloc.create(worker_runtime.WorkerRuntime);
        worker.* = .{};
        const session = try alloc.create(session_runtime.SessionRuntime);
        session.* = .{ .max_history_turns = 8 };
        const self = try alloc.create(Harness);
        self.* = .{
            .alloc = alloc,
            .root = root,
            .ui = ui,
            .managed = managed_runtime,
            .worker = worker,
            .session = session,
        };
        return self;
    }

    fn prompter(self: *Harness) permission_prompter.Prompter {
        return .{ .context = @ptrCast(self), .request_fn = requestPermission };
    }

    fn requestPermission(
        raw: *anyopaque,
        alloc: Allocator,
        _: permission_request.PermissionRequest,
        _: types.ToolCall,
        _: ?*const @import("src/core/output/diff.zig").FileReview,
        _: ?[]const types.PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse {
        const self: *Harness = @ptrCast(@alignCast(raw));
        const io = io_mod.getIo();
        self.gate_mutex.lockUncancelable(io);
        while (self.gate_queued_ask) self.gate_cond.waitUncancelable(io, &self.gate_mutex);
        self.gate_mutex.unlock(io);
        return permission_request.OwnedPermissionResponse.init(alloc, .once, null);
    }

    fn armQueuedGate(self: *Harness, armed: bool) void {
        const io = io_mod.getIo();
        self.gate_mutex.lockUncancelable(io);
        self.gate_queued_ask = armed;
        if (!armed) self.gate_cond.broadcast(io);
        self.gate_mutex.unlock(io);
    }

    fn slot(self: *Harness) u32 {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const snap = self.worker.snapshotPendingQuestionBatch(arena_state.allocator()) catch return 0;
        const batch = snap orelse return 0;
        defer batch.deinit(arena_state.allocator());
        if (batch.entries.len == 0) return 0;
        if (std.mem.eql(u8, batch.entries[0].question, "Question 1?")) return 1;
        if (std.mem.eql(u8, batch.entries[0].question, "Question 2?")) return 2;
        return 0;
    }

    fn anyOpen(self: *const Harness) bool {
        for (self.reqs) |item| {
            if (item.stage == .queued or item.stage == .shown) return true;
        }
        return false;
    }

    fn bash(self: *const Harness) []const u8 {
        const run = self.first orelse return "idle";
        if (run.done.load(.seq_cst)) {
            if (run.prepared) |prepared| {
                if (prepared.snapshot.state == .running) return "yielded";
            }
        }
        return "first";
    }

    fn refuse(self: *Harness, event: []const u8) !void {
        try self.notes.append(self.alloc, try self.alloc.print("refused: {s}", .{event}));
    }

    fn note(self: *Harness, text: []const u8) !void {
        try self.notes.append(self.alloc, text);
    }

    fn awaitAdmitted(self: *Harness, id: []const u8) !bool {
        const started = io_mod.milliTimestamp();
        while (io_mod.milliTimestamp() - started < admit_limit_ms) {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const items = try self.managed.list(arena.allocator());
            for (items) |item| {
                if (std.mem.eql(u8, item.execution_id, id)) return true;
            }
            io_mod.sleep(std.time.ns_per_ms);
        }
        return false;
    }

    fn doRun(self: *Harness) !void {
        if (!std.mem.eql(u8, self.bash(), "idle") or self.prog == .running or self.programs >= max_programs) {
            return self.refuse("run");
        }
        self.serial += 1;
        const id = try self.alloc.print("ask-program-{d}", .{self.serial});
        const run = try self.alloc.create(Run);
        run.* = .{ .harness = self, .id = id };
        self.first = run;
        self.execution_id = id;
        self.prog = .running;
        self.programs += 1;
        self.asked = 0;
        self.reqs = .{ .{}, .{} };
        const thread = try std.Thread.spawn(.{}, firstMain, .{ self, run });
        thread.detach();
        if (!waitDone(&run.registered, register_limit_ms)) try self.note("bridge did not register");
        if (run.socket_path.len > 0) {
            self.last_socket_path = run.socket_path;
            self.last_token = run.token;
        }
        if (!try self.awaitAdmitted(id)) try self.note("program was not admitted");
    }

    fn doYield(self: *Harness) !void {
        if (!std.mem.eql(u8, self.bash(), "first") or self.prog != .running) return self.refuse("yield");
        const run = self.first orelse return self.refuse("yield");
        const window: i64 = if (self.anyOpen()) held_yield_probe_ms else answer_window_ms;
        self.steer.store(true, .seq_cst);
        _ = waitDone(&run.captured_done, window);
        self.steer.store(false, .seq_cst);
        if (run.captured_done.load(.seq_cst)) {
            if (run.prepared) |prepared| {
                if (prepared.snapshot.state == .running) {
                    self.managed.commitDelivery(self.execution_id, prepared.reservation_id) catch |err| {
                        try self.note(try self.alloc.print("commit failed: {s}", .{@errorName(err)}));
                    };
                }
            }
            run.releaseUnregister();
            _ = waitDone(&run.done, answer_window_ms);
        }
    }

    fn doReturn(self: *Harness) !void {
        const run = self.first orelse return self.refuse("return");
        if (self.prog != .gone or self.anyOpen()) return self.refuse("return");
        if (std.mem.eql(u8, self.bash(), "first")) {
            if (!run.captured_done.load(.seq_cst)) {
                run.cancel.store(true, .seq_cst);
                _ = waitDone(&run.captured_done, answer_window_ms);
            }
            run.releaseUnregister();
            if (!waitDone(&run.done, answer_window_ms)) return self.refuse("return");
        }
        self.first = null;
    }

    fn stopRunningProgram(self: *Harness) !void {
        const run = self.first orelse return;
        for (&self.reqs) |*item| {
            if (item.stage == .queued) {
                self.armQueuedGate(true);
                if (item.call) |call| call.shutdownWrite();
            }
        }
        if (std.mem.eql(u8, self.bash(), "first")) {
            run.cancel.store(true, .seq_cst);
            _ = waitDone(&run.captured_done, answer_window_ms);
        } else {
            const stopped = self.managed.stop(self.alloc, self.execution_id, true) catch |err| {
                return self.note(try self.alloc.print("stop failed: {s}", .{@errorName(err)}));
            };
            if (stopped.snapshot.state == .running) return self.note("program still running after stop");
        }
        if (self.hasQueued()) io_mod.sleep(15 * std.time.ns_per_ms);
        self.prog = .gone;
    }

    fn hasQueued(self: *const Harness) bool {
        for (self.reqs) |item| if (item.stage == .queued) return true;
        return false;
    }

    fn doGone(self: *Harness) !void {
        if (self.prog != .running) return self.refuse("gone");
        try self.stopRunningProgram();
    }

    fn doSend(self: *Harness, k: usize) !void {
        if (self.prog != .running or self.reqs[k].stage != .none) return self.refuse("send");
        const socket_path = if (std.mem.eql(u8, self.bash(), "first"))
            self.first.?.socket_path
        else
            (self.last_socket_path orelse "");
        const token = if (std.mem.eql(u8, self.bash(), "first"))
            self.first.?.token
        else
            self.last_token;
        const call = try self.alloc.create(AskCall);
        call.* = .{
            .index = k,
            .socket_path = socket_path,
            .token = token,
            .question = if (k == 0) "Question 1?" else "Question 2?",
        };
        self.reqs[k].call = call;
        const thread = try std.Thread.spawn(.{}, clientMain, .{call});
        thread.detach();
        _ = waitDone(&call.sent, answer_window_ms);

        if (!std.mem.eql(u8, self.bash(), "first") or !self.ui) {
            if (!waitDone(&call.done, answer_window_ms)) {
                try self.note("send refusal timed out");
                return;
            }
            self.reqs[k].stage = .done;
            self.reqs[k].told = call.told;
            return;
        }

        const expected_id: u32 = @intCast(k + 1);
        const slot_before = self.slot();
        if (slot_before == 0) {
            const started = io_mod.milliTimestamp();
            while (self.slot() != expected_id and !call.done.load(.seq_cst)) {
                if (io_mod.milliTimestamp() - started >= answer_window_ms) break;
                io_mod.sleep(std.time.ns_per_ms);
            }
            if (self.slot() == expected_id) {
                self.reqs[k].stage = .shown;
                self.asked += 1;
                return;
            }
            if (call.done.load(.seq_cst)) {
                self.reqs[k].stage = .done;
                self.reqs[k].told = call.told;
                return;
            }
        } else {
            io_mod.sleep(still_waiting_probe_ms);
            if (self.slot() == expected_id) {
                self.reqs[k].stage = .shown;
                self.asked += 1;
                return;
            }
        }
        call.was_queued.store(true, .release);
        self.reqs[k].stage = .queued;
    }

    fn doShow(self: *Harness, k: usize) !void {
        if (self.reqs[k].stage != .queued or self.prog != .running or self.slot() != 0) {
            return self.refuse("show");
        }
        const call = self.reqs[k].call orelse return self.refuse("show");
        call.was_queued.store(false, .release);
        self.armQueuedGate(false);
        const expected_id: u32 = @intCast(k + 1);
        const started = io_mod.milliTimestamp();
        while (self.slot() != expected_id and !call.done.load(.seq_cst)) {
            if (io_mod.milliTimestamp() - started >= answer_window_ms) break;
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (self.slot() == expected_id) {
            self.reqs[k].stage = .shown;
            self.asked += 1;
            return;
        }
        try self.note("queued ask did not show");
    }

    fn doGiveUp(self: *Harness, k: usize) !void {
        if (self.reqs[k].stage != .queued or self.prog != .gone or self.slot() != 0) {
            return self.refuse("give_up");
        }
        const call = self.reqs[k].call orelse return self.refuse("give_up");
        self.armQueuedGate(false);
        if (!waitDone(&call.done, answer_window_ms)) {
            try self.note("queued ask did not give up");
            return;
        }
        self.reqs[k].stage = .done;
        self.reqs[k].told = .gave_up;
    }

    fn doAnswer(self: *Harness, k: usize) !void {
        if (self.reqs[k].stage != .shown) return self.refuse("answer");
        const call = self.reqs[k].call orelse return self.refuse("answer");
        const other = 1 - k;
        if (self.reqs[other].stage == .queued) self.armQueuedGate(true);
        try self.worker.submitQuestionBatchAnswer(std.heap.c_allocator, &.{"A"}, null);
        if (!waitDone(&call.done, answer_window_ms)) {
            try self.note("answer did not complete ask");
            return;
        }
        self.reqs[k].stage = .done;
        self.reqs[k].told = call.told;
    }

    fn doEsc(self: *Harness, k: usize) !void {
        if (self.reqs[k].stage != .shown) return self.refuse("esc");
        const call = self.reqs[k].call orelse return self.refuse("esc");
        const other = 1 - k;
        if (self.reqs[other].stage == .queued) self.armQueuedGate(true);
        if (self.prog == .running) try self.stopRunningProgram();
        try self.worker.submitQuestionBatchAnswer(std.heap.c_allocator, null, null);
        if (!waitDone(&call.done, answer_window_ms)) {
            try self.note("esc did not complete ask");
            return;
        }
        self.reqs[k].stage = .done;
        self.reqs[k].told = call.told;
    }

    fn doWithdraw(self: *Harness, k: usize) !void {
        if (self.reqs[k].stage != .shown or self.prog != .gone) return self.refuse("withdraw");
        const call = self.reqs[k].call orelse return self.refuse("withdraw");
        const other = 1 - k;
        if (self.reqs[other].stage == .queued) self.armQueuedGate(true);
        call.shutdownWrite();
        if (!waitDone(&call.done, answer_window_ms)) {
            // watch-off leaves the question open in the slot without ending the call.
            return;
        }
        self.reqs[k].stage = .done;
        self.reqs[k].told = call.told;
    }

    fn perform(self: *Harness, input: Input) !void {
        const event = input.event;
        if (std.mem.eql(u8, event, "run")) return self.doRun();
        if (std.mem.eql(u8, event, "yield")) return self.doYield();
        if (std.mem.eql(u8, event, "return")) return self.doReturn();
        if (std.mem.eql(u8, event, "gone")) return self.doGone();
        const k = try reqIndex(input.i);
        if (std.mem.eql(u8, event, "send")) return self.doSend(k);
        if (std.mem.eql(u8, event, "show")) return self.doShow(k);
        if (std.mem.eql(u8, event, "give_up")) return self.doGiveUp(k);
        if (std.mem.eql(u8, event, "answer")) return self.doAnswer(k);
        if (std.mem.eql(u8, event, "esc")) return self.doEsc(k);
        if (std.mem.eql(u8, event, "withdraw")) return self.doWithdraw(k);
        try self.note(try self.alloc.print("unknown event: {s}", .{event}));
    }

    fn shutdown(self: *Harness) void {
        self.armQueuedGate(false);
        _ = self.worker.cancelPendingQuestionBatch();
        for (&self.reqs) |*item| {
            if (item.call) |call| call.shutdownWrite();
        }
        if (self.first) |run| {
            run.cancel.store(true, .seq_cst);
            if (self.prog == .running) {
                _ = self.managed.stop(self.alloc, self.execution_id, true) catch {};
            }
            run.releaseUnregister();
            _ = waitDone(&run.done, shutdown_limit_ms);
        }
    }

    fn writeState(self: *Harness, out: *std.Io.Writer) !void {
        const slot_now = self.slot();
        try out.print(
            "{{\"state\":{{\"prog\":\"{s}\",\"programs\":{d},\"ui\":{},\"bash\":\"{s}\",\"req\":[\"{s}\",\"{s}\"],\"lock\":{d},\"slot\":{d},\"crashed\":false,\"asked\":{d},\"told\":[\"{s}\",\"{s}\"]}},\"out\":[",
            .{
                @tagName(self.prog),
                self.programs,
                self.ui,
                self.bash(),
                @tagName(self.reqs[0].stage),
                @tagName(self.reqs[1].stage),
                slot_now,
                slot_now,
                self.asked,
                toldName(self.reqs[0].told),
                toldName(self.reqs[1].told),
            },
        );
        for (self.notes.items, 0..) |text, index| {
            if (index > 0) try out.writeAll(",");
            try out.print("\"{s}\"", .{text});
        }
        try out.writeAll("]}\n");
    }
};

fn reqIndex(value: ?u32) !usize {
    const id = value orelse return error.MissingRequestId;
    if (id < 1 or id > req_count) return error.BadRequestId;
    return id - 1;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    io_mod.setIo(io);
    io_mod.setEnvironMap(init.environ_map);
    const alloc = std.heap.smp_allocator;
    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());
    if (command_runner.isForegroundSessionInvocation(args[1..])) {
        return command_runner.runForegroundSessionBootstrap(args[1..]);
    }
    if (args.len != 5 or !std.mem.eql(u8, args[1], "--root") or !std.mem.eql(u8, args[3], "--ui")) return error.Usage;
    const ui = if (std.mem.eql(u8, args[4], "true"))
        true
    else if (std.mem.eql(u8, args[4], "false"))
        false
    else
        return error.Usage;

    const self = try Harness.create(alloc, args[2], ui);
    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    try self.writeState(&stdout.interface);
    try stdout.interface.flush();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    while (try stdin.interface.takeDelimiter('\n')) |raw| {
        const text = std.mem.trim(u8, raw, " \r\t");
        if (text.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Input, arena_state.allocator(), text, .{ .ignore_unknown_fields = true });
        self.notes.clearRetainingCapacity();
        try self.perform(parsed.value);
        try self.writeState(&stdout.interface);
        try stdout.interface.flush();
        _ = arena_state.reset(.retain_capacity);
    }
    self.shutdown();
    std.process.exit(0);
}

const std = @import("std");
const builtin = @import("builtin");

const types = @import("../shared/types.zig");
const stream_provider = @import("../agent/stream_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const runtime_gateway_step = @import("../agent/runtime/gateway_step.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum {
    btw,
    recap,
};

pub const StartOptions = struct {
    kind: Kind,
    question: []const u8,
    messages: []const types.ChatMessage,
    credential: types.CredentialLease,
    model: []const u8,
    provider: stream_provider.Provider,
    provider_options: model_capabilities.ResolvedProviderOptions,
    trace_ctx: debug_trace.TraceContext,
    max_output_tokens: ?u32 = null,
};

pub const Completion = struct {
    kind: Kind,
    answer: ?[]u8 = null,
    error_message: ?[]u8 = null,
    alloc: Allocator,

    pub fn deinit(self: *Completion) void {
        if (self.answer) |ans| self.alloc.free(ans);
        if (self.error_message) |err_msg| self.alloc.free(err_msg);
        self.* = undefined;
    }
};

const default_side_question_max_tokens: u32 = 4096;

const btw_system_instruction =
    "You are answering a concise, non-interrupting side question (/btw) for the user about the ongoing session. " ++
    "Provide a direct, focused answer based on context when relevant. Do not execute any tools, call functions, or produce tool invocations.";

const recap_system_instruction =
    "You are providing a concise, read-only recap (/recap) of the session for the user. " ++
    "Structure your response strictly grounded in the supplied conversation snapshot: clearly highlight what is done, " ++
    "what remains or is next, and any critical context. Do not execute any tools, call functions, or produce tool invocations.";

pub const Runtime = struct {
    arena: ?std.heap.ArenaAllocator = null,
    thread: ?std.Thread = null,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    completion: ?Completion = null,

    pub fn init() Runtime {
        return .{};
    }

    pub fn isActive(self: *const Runtime) bool {
        return self.thread != null and !self.done.load(.seq_cst);
    }

    pub fn takeCompleted(self: *Runtime) ?Completion {
        if (self.thread) |thread| {
            if (self.done.load(.seq_cst)) {
                thread.join();
                self.thread = null;
                const comp = self.completion;
                self.completion = null;
                if (self.arena) |*arena| {
                    arena.deinit();
                    self.arena = null;
                }
                return comp;
            }
        }
        return null;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.thread) |thread| {
            self.cancel_flag.store(true, .seq_cst);
            thread.join();
            self.thread = null;
        }
        if (self.completion) |*comp| {
            comp.deinit();
            self.completion = null;
        }
        if (self.arena) |*arena| {
            arena.deinit();
            self.arena = null;
        }
        self.* = .{};
    }

    pub fn start(self: *Runtime, alloc: Allocator, options: StartOptions) !void {
        if (comptime builtin.single_threaded) {
            return error.UnsupportedPlatform;
        }

        if (self.isActive()) {
            return error.SideQuestionBusy;
        }

        // A completed run may have been observed but its answer not rendered yet.
        // Discarding takeCompleted's owned result would leak its answer/error buffer.
        if (self.thread != null) {
            if (self.takeCompleted()) |completion| {
                var owned_completion = completion;
                owned_completion.deinit();
            }
        }

        var task_arena = std.heap.ArenaAllocator.init(alloc);
        errdefer task_arena.deinit();
        const arena_alloc = task_arena.allocator();

        // Deep-own all borrowed request inputs
        const question_copy = try arena_alloc.dupe(u8, options.question);
        const model_copy = try arena_alloc.dupe(u8, options.model);
        const credential_copy = try deepCopyCredential(arena_alloc, options.credential);
        const messages_copy = try deepCopyMessages(arena_alloc, options.messages);

        self.cancel_flag.store(false, .seq_cst);
        self.done.store(false, .seq_cst);
        self.completion = null;
        self.arena = task_arena;

        const worker_ctx = WorkerContext{
            .runtime = self,
            .result_alloc = alloc,
            .kind = options.kind,
            .question = question_copy,
            .messages = messages_copy,
            .credential = credential_copy,
            .model = model_copy,
            .provider = options.provider,
            .provider_options = options.provider_options,
            .trace_ctx = options.trace_ctx,
            .max_output_tokens = options.max_output_tokens orelse default_side_question_max_tokens,
        };

        const thread = std.Thread.spawn(.{}, workerThreadMain, .{worker_ctx}) catch |err| {
            self.done.store(true, .seq_cst);
            if (self.arena) |*a| {
                a.deinit();
                self.arena = null;
            }
            return err;
        };
        self.thread = thread;
    }

    const WorkerContext = struct {
        runtime: *Runtime,
        result_alloc: Allocator,
        kind: Kind,
        question: []const u8,
        messages: []const types.ChatMessage,
        credential: types.CredentialLease,
        model: []const u8,
        provider: stream_provider.Provider,
        provider_options: model_capabilities.ResolvedProviderOptions,
        trace_ctx: debug_trace.TraceContext,
        max_output_tokens: u32,
    };

    fn workerThreadMain(ctx: WorkerContext) void {
        const result = runWorker(ctx);
        ctx.runtime.completion = result;
        ctx.runtime.done.store(true, .seq_cst);
    }

    fn runWorker(ctx: WorkerContext) Completion {
        var text_acc: std.Io.Writer.Allocating = .init(ctx.result_alloc);
        defer text_acc.deinit();

        var capture = StreamCapture{
            .alloc = ctx.result_alloc,
            .text_acc = &text_acc,
            .cancel_flag = &ctx.runtime.cancel_flag,
            .saw_tool_call = false,
        };

        const sys_instruction_text = switch (ctx.kind) {
            .btw => btw_system_instruction,
            .recap => recap_system_instruction,
        };

        const instructions = [_]types.ChatMessage{.{
            .role = .system,
            .content = sys_instruction_text,
        }};

        var filtered_messages_count: usize = 0;
        for (ctx.messages) |msg| {
            if (msg.role != .system) filtered_messages_count += 1;
        }

        const need_extra_user = ctx.question.len > 0 or filtered_messages_count == 0;
        const total_msgs = filtered_messages_count + (if (need_extra_user) @as(usize, 1) else 0);

        var final_messages = ctx.result_alloc.alloc(types.ChatMessage, total_msgs) catch {
            return makeError(ctx.result_alloc, ctx.kind, "Out of memory");
        };
        defer ctx.result_alloc.free(final_messages);

        var idx: usize = 0;
        for (ctx.messages) |msg| {
            if (msg.role != .system) {
                final_messages[idx] = msg;
                idx += 1;
            }
        }
        if (need_extra_user) {
            final_messages[idx] = .{
                .role = .user,
                .content = if (ctx.question.len > 0) ctx.question else "Please recap the session so far.",
            };
        }

        var delivery = stream_provider.DeliveryCertainty.init();
        var attempt_evidence: stream_provider.AttemptEvidence = .{};

        const model_req = stream_provider.ModelRequest{
            .credential = ctx.credential,
            .model = ctx.model,
            .retry_count = 0,
            .instructions = &instructions,
            .messages = final_messages,
            .tools = .{},
            .tool_choice = .auto,
            .provider_options = ctx.provider_options,
            .max_output_tokens = ctx.max_output_tokens,
            .trace_ctx = ctx.trace_ctx,
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &capture, .emit_fn = StreamCapture.emit },
            .admission = .{},
            .cancel_flag = &ctx.runtime.cancel_flag,
            .provider_attempt_owner = .agent,
        };

        var stream_result = runtime_gateway_step.streamModelCompletion(
            ctx.provider,
            ctx.result_alloc,
            model_req,
            null,
            ctx.result_alloc,
        ) catch |err| {
            return makeError(ctx.result_alloc, ctx.kind, @errorName(err));
        };
        defer stream_result.deinit(ctx.result_alloc);

        if (ctx.runtime.cancel_flag.load(.seq_cst)) {
            return makeError(ctx.result_alloc, ctx.kind, "Cancelled");
        }

        if (capture.saw_tool_call) {
            return makeError(ctx.result_alloc, ctx.kind, "Tool call rejected: side questions do not support tools");
        }

        switch (stream_result) {
            .failed => |failure| {
                if (failure.detail) |detail| {
                    const msg = ctx.result_alloc.dupe(u8, detail) catch return makeError(ctx.result_alloc, ctx.kind, @tagName(failure.kind));
                    return .{
                        .kind = ctx.kind,
                        .answer = null,
                        .error_message = msg,
                        .alloc = ctx.result_alloc,
                    };
                }
                return makeError(ctx.result_alloc, ctx.kind, @tagName(failure.kind));
            },
            .completed => |completed| {
                if (completed.completion.tool_calls.len > 0) {
                    return makeError(ctx.result_alloc, ctx.kind, "Tool call rejected: side questions do not support tools");
                }

                // If text was accumulated via streaming events, prefer that; otherwise take completion.content
                if (text_acc.written().len > 0) {
                    const ans = text_acc.toOwnedSlice() catch {
                        return makeError(ctx.result_alloc, ctx.kind, "Out of memory");
                    };
                    return .{
                        .kind = ctx.kind,
                        .answer = ans,
                        .error_message = null,
                        .alloc = ctx.result_alloc,
                    };
                } else if (completed.completion.content) |content| {
                    const ans = ctx.result_alloc.dupe(u8, content) catch {
                        return makeError(ctx.result_alloc, ctx.kind, "Out of memory");
                    };
                    return .{
                        .kind = ctx.kind,
                        .answer = ans,
                        .error_message = null,
                        .alloc = ctx.result_alloc,
                    };
                } else {
                    const empty_ans = ctx.result_alloc.dupe(u8, "") catch {
                        return makeError(ctx.result_alloc, ctx.kind, "Out of memory");
                    };
                    return .{
                        .kind = ctx.kind,
                        .answer = empty_ans,
                        .error_message = null,
                        .alloc = ctx.result_alloc,
                    };
                }
            },
        }
    }

    fn makeError(alloc: Allocator, kind: Kind, message: []const u8) Completion {
        const err_copy = alloc.dupe(u8, message) catch null;
        return .{
            .kind = kind,
            .answer = null,
            .error_message = err_copy,
            .alloc = alloc,
        };
    }

    const StreamCapture = struct {
        alloc: Allocator,
        text_acc: *std.Io.Writer.Allocating,
        cancel_flag: *std.atomic.Value(bool),
        saw_tool_call: bool,

        fn emit(raw: *anyopaque, event: stream_provider.Event) void {
            const self: *StreamCapture = @ptrCast(@alignCast(raw));
            if (self.cancel_flag.load(.seq_cst)) return;
            switch (event) {
                .content_delta => |chunk| {
                    self.text_acc.writer.writeAll(chunk) catch {};
                },
                .reasoning_delta => {},
                .tool_started => {
                    self.saw_tool_call = true;
                },
                .tool_input_delta => {
                    self.saw_tool_call = true;
                },
            }
        }
    };
};

fn deepCopyCredential(arena: Allocator, lease: types.CredentialLease) !types.CredentialLease {
    return switch (lease) {
        .host_managed => .host_managed,
        .direct => |direct| .{
            .direct = .{
                .secret_bytes = try arena.dupe(u8, direct.secret_bytes),
                .source = direct.source,
                .account_id = if (direct.account_id) |acc| try arena.dupe(u8, acc) else null,
                .tenant_context = if (direct.tenant_context) |tc| try arena.dupe(u8, tc) else null,
            },
        },
    };
}

fn deepCopyMessages(arena: Allocator, messages: []const types.ChatMessage) ![]types.ChatMessage {
    if (messages.len == 0) return &.{};
    const copy = try arena.alloc(types.ChatMessage, messages.len);
    for (messages, 0..) |msg, i| {
        copy[i] = .{
            .role = msg.role,
            .content = if (msg.content) |c| try arena.dupe(u8, c) else null,
            .images = try types.dupeImageAttachmentSlice(arena, msg.images),
            .tool_call_id = if (msg.tool_call_id) |id| try arena.dupe(u8, id) else null,
            .tool_name = if (msg.tool_name) |name| try arena.dupe(u8, name) else null,
            .tool_calls = try types.dupeToolCallSlice(arena, msg.tool_calls),
            .provider_replay = if (msg.provider_replay) |pr| try types.dupeProviderReplay(arena, pr) else null,
            .tool_result_status = msg.tool_result_status,
            .tool_result_memory = if (msg.tool_result_memory) |trm| try deepCopyToolResultMemory(arena, trm) else null,
            .permission_feedback = msg.permission_feedback,
            .standalone_response = msg.standalone_response,
        };
    }
    return copy;
}

fn deepCopyToolResultMemory(arena: Allocator, memory: types.ToolResultMemory) !types.ToolResultMemory {
    const tool_images = try types.dupeToolImages(arena, memory.tool_images);
    const tool_image_handle = if (memory.tool_image_handle) |handle| try arena.dupe(u8, handle) else null;
    const output_handle = if (memory.output_handle) |handle| try arena.dupe(u8, handle) else null;
    const preview = if (memory.preview) |p| try arena.dupe(u8, p) else null;
    const committed_file_presentation = if (memory.committed_file_presentation) |presentation|
        try types.dupeCommittedFilePresentation(arena, presentation)
    else
        null;
    const replay = if (memory.command_output_replay) |r| try types.dupeCommandOutputReplay(arena, r) else null;
    return .{
        .tool_images = tool_images,
        .tool_image_handle = tool_image_handle,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = memory.output_bytes,
        .stored_output_bytes = memory.stored_output_bytes,
        .truncated = memory.truncated,
        .model_view_covers_full_file = memory.model_view_covers_full_file,
        .committed_file_presentation = committed_file_presentation,
        .command_output_replay = replay,
        .command_process_presentation = memory.command_process_presentation,
        .terminal_action_presentation = memory.terminal_action_presentation,
    };
}

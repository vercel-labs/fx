const std = @import("std");
const definitions = @import("definitions.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const HookEvent = definitions.HookKind;

const RegisteredHook = struct {
    event: HookEvent,
    name: []u8,
    ctx: *anyopaque,
};

const RegisteredPreToolUseHandler = struct {
    hook: RegisteredHook,
    run: *const fn (
        ctx: *anyopaque,
        input: definitions.PreToolUseInput,
    ) definitions.HandlerError!definitions.PreToolUseAction,
    release_action: ?*const fn (*anyopaque, definitions.PreToolUseAction) void,
};

const RegisteredStopHandler = struct {
    hook: RegisteredHook,
    run: *const fn (
        ctx: *anyopaque,
        input: definitions.StopInput,
    ) definitions.HandlerError!definitions.StopAction,
    release_action: ?*const fn (*anyopaque, definitions.StopAction) void,
};

fn RegisteredSideEffectHandler(comptime Input: type) type {
    return struct {
        hook: RegisteredHook,
        run: *const fn (*anyopaque, Input) definitions.HandlerError!void,
    };
}

const RegisteredPostTurnEndHandler = RegisteredSideEffectHandler(definitions.PostTurnEndInput);
const RegisteredAttentionRequiredHandler = RegisteredSideEffectHandler(definitions.AttentionRequiredInput);

pub const Runtime = struct {
    alloc: Allocator,
    pre_tool_use_handlers: std.ArrayList(RegisteredPreToolUseHandler) = .empty,
    stop_handlers: std.ArrayList(RegisteredStopHandler) = .empty,
    post_turn_end_handlers: std.ArrayList(RegisteredPostTurnEndHandler) = .empty,
    attention_required_handlers: std.ArrayList(RegisteredAttentionRequiredHandler) = .empty,
    frozen: bool = false,

    pub fn init(alloc: Allocator) Runtime {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Runtime) void {
        deinitRegisteredHooks(self.alloc, self.pre_tool_use_handlers.items);
        self.pre_tool_use_handlers.deinit(self.alloc);
        deinitRegisteredHooks(self.alloc, self.stop_handlers.items);
        self.stop_handlers.deinit(self.alloc);
        deinitRegisteredHooks(self.alloc, self.post_turn_end_handlers.items);
        self.post_turn_end_handlers.deinit(self.alloc);
        deinitRegisteredHooks(self.alloc, self.attention_required_handlers.items);
        self.attention_required_handlers.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn registerPreToolUse(
        self: *Runtime,
        handler: definitions.PreToolUseHandler,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.validateRegistration(
            .pre_tool_use,
            handler.name,
            self.pre_tool_use_handlers.items,
        );

        const hook = try self.copyHook(.pre_tool_use, handler.name, handler.ctx);
        errdefer self.alloc.free(hook.name);
        try self.pre_tool_use_handlers.append(self.alloc, .{
            .hook = hook,
            .run = handler.run,
            .release_action = handler.release_action,
        });
    }

    pub fn registerStop(
        self: *Runtime,
        handler: definitions.StopHandler,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.validateRegistration(
            .stop,
            handler.name,
            self.stop_handlers.items,
        );

        const hook = try self.copyHook(.stop, handler.name, handler.ctx);
        errdefer self.alloc.free(hook.name);
        try self.stop_handlers.append(self.alloc, .{
            .hook = hook,
            .run = handler.run,
            .release_action = handler.release_action,
        });
    }

    pub fn registerPostTurnEnd(
        self: *Runtime,
        handler: definitions.PostTurnEndHandler,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.registerSideEffect(
            .post_turn_end,
            handler,
            &self.post_turn_end_handlers,
        );
    }

    pub fn registerAttentionRequired(
        self: *Runtime,
        handler: definitions.AttentionRequiredHandler,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.registerSideEffect(
            .attention_required,
            handler,
            &self.attention_required_handlers,
        );
    }

    fn registerSideEffect(
        self: *Runtime,
        event: HookEvent,
        handler: anytype,
        registered_handlers: anytype,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.validateRegistration(event, handler.name, registered_handlers.items);
        const hook = try self.copyHook(event, handler.name, handler.ctx);
        errdefer self.alloc.free(hook.name);
        try registered_handlers.append(self.alloc, .{
            .hook = hook,
            .run = handler.run,
        });
    }

    pub fn freeze(self: *Runtime) RuntimeView {
        self.frozen = true;
        return self.currentView();
    }

    pub fn view(self: *const Runtime) definitions.ViewError!RuntimeView {
        if (!self.frozen) return error.RuntimeNotFrozen;
        return self.currentView();
    }

    fn currentView(self: *const Runtime) RuntimeView {
        return .{
            .pre_tool_use_handlers = self.pre_tool_use_handlers.items,
            .stop_handlers = self.stop_handlers.items,
            .post_turn_end_handlers = self.post_turn_end_handlers.items,
            .attention_required_handlers = self.attention_required_handlers.items,
        };
    }

    fn validateRegistration(
        self: *const Runtime,
        event: HookEvent,
        name: []const u8,
        registered_handlers: anytype,
    ) definitions.RegistrationError!void {
        if (self.frozen) return error.RuntimeFrozen;
        try validateHandlerName(name);
        for (registered_handlers) |registered| {
            std.debug.assert(registered.hook.event == event);
            if (std.mem.eql(u8, registered.hook.name, name)) return error.DuplicateHandlerName;
        }
    }

    fn copyHook(
        self: *Runtime,
        event: HookEvent,
        name: []const u8,
        ctx: *anyopaque,
    ) Allocator.Error!RegisteredHook {
        return .{
            .event = event,
            .name = try self.alloc.dupe(u8, name),
            .ctx = ctx,
        };
    }
};

pub const RuntimeView = struct {
    pre_tool_use_handlers: []const RegisteredPreToolUseHandler,
    stop_handlers: []const RegisteredStopHandler,
    post_turn_end_handlers: []const RegisteredPostTurnEndHandler,
    attention_required_handlers: []const RegisteredAttentionRequiredHandler,

    pub fn empty() RuntimeView {
        return .{
            .pre_tool_use_handlers = &.{},
            .stop_handlers = &.{},
            .post_turn_end_handlers = &.{},
            .attention_required_handlers = &.{},
        };
    }

    pub fn hasPreToolUse(self: RuntimeView) bool {
        return self.pre_tool_use_handlers.len != 0;
    }

    pub fn runPreToolUse(
        self: RuntimeView,
        alloc: Allocator,
        input: definitions.PreToolUseInput,
    ) definitions.MutationDispatchError!definitions.PreToolUseOutcome {
        if (self.pre_tool_use_handlers.len == 0) return .unchanged;

        var dispatch = PreToolUseDispatch{
            .alloc = alloc,
            .input = input,
        };
        errdefer dispatch.deinit();
        return try dispatch.run(self.pre_tool_use_handlers);
    }

    pub fn hasStop(self: RuntimeView) bool {
        return self.stop_handlers.len != 0;
    }

    pub fn runStop(
        self: RuntimeView,
        alloc: Allocator,
        input: definitions.StopInput,
    ) definitions.StopOutcome {
        if (self.stop_handlers.len == 0) return .allow;

        const dispatch = StopDispatch{
            .alloc = alloc,
            .input = input,
        };
        return dispatch.run(self.stop_handlers);
    }

    pub fn hasPostTurnEnd(self: RuntimeView) bool {
        return self.post_turn_end_handlers.len != 0;
    }

    pub fn runPostTurnEnd(
        self: RuntimeView,
        input: definitions.PostTurnEndInput,
    ) void {
        runSideEffectHandlers(input, self.post_turn_end_handlers);
    }

    pub fn hasAttentionRequired(self: RuntimeView) bool {
        return self.attention_required_handlers.len != 0;
    }

    pub fn runAttentionRequired(
        self: RuntimeView,
        input: definitions.AttentionRequiredInput,
    ) void {
        runSideEffectHandlers(input, self.attention_required_handlers);
    }
};

const PreToolUseDispatch = struct {
    alloc: Allocator,
    input: definitions.PreToolUseInput,
    current_arguments: ?[]u8 = null,

    fn deinit(self: *PreToolUseDispatch) void {
        if (self.current_arguments) |arguments_json| self.alloc.free(arguments_json);
        self.current_arguments = null;
    }

    fn run(
        self: *PreToolUseDispatch,
        handlers: []const RegisteredPreToolUseHandler,
    ) definitions.MutationDispatchError!definitions.PreToolUseOutcome {
        for (handlers) |handler| {
            switch (try self.runHandler(handler)) {
                .next => {},
                .blocked => |reason| return .{ .blocked = reason },
            }
        }

        return self.takeOutcome();
    }

    fn runHandler(
        self: *PreToolUseDispatch,
        handler: RegisteredPreToolUseHandler,
    ) definitions.MutationDispatchError!PreToolUseActionResult {
        const trace = HandlerTrace.start(
            handler.hook,
            self.input.invocation,
            self.input.call_id,
        );
        const action = handler.run(handler.hook.ctx, self.handlerInput()) catch |err| {
            trace.fail(err);
            return switch (err) {
                error.Failed => error.HandlerFailed,
                error.Cancelled => error.Cancelled,
            };
        };
        defer if (handler.release_action) |release| release(handler.hook.ctx, action);
        return applyPreToolUseAction(
            self.alloc,
            action,
            &self.current_arguments,
            trace,
        );
    }

    fn takeOutcome(self: *PreToolUseDispatch) definitions.PreToolUseOutcome {
        if (self.current_arguments) |arguments_json| {
            self.current_arguments = null;
            return .{ .rewritten = arguments_json };
        }
        return .unchanged;
    }

    fn handlerInput(self: PreToolUseDispatch) definitions.PreToolUseInput {
        var input = self.input;
        if (self.current_arguments) |arguments_json| input.arguments_json = arguments_json;
        return input;
    }
};

const PreToolUseActionResult = union(enum) {
    next,
    blocked: []u8,
};

fn applyPreToolUseAction(
    alloc: Allocator,
    action: definitions.PreToolUseAction,
    current_arguments: *?[]u8,
    trace: HandlerTrace,
) definitions.MutationDispatchError!PreToolUseActionResult {
    switch (action) {
        .continue_ => {
            trace.finish("continue");
            return .next;
        },
        .rewrite_arguments => |borrowed| {
            if (borrowed.len > definitions.Limits.arguments_json_bytes) {
                trace.finish("rewrite_too_large");
                return error.HandlerOutputTooLarge;
            }

            const copied = alloc.dupe(u8, borrowed) catch {
                trace.finish("copy_failed");
                return error.OutOfMemory;
            };
            validateJsonObject(alloc, copied) catch |err| {
                alloc.free(copied);
                trace.fail(err);
                return err;
            };

            if (current_arguments.*) |previous| alloc.free(previous);
            current_arguments.* = copied;
            trace.finish("rewrite");
            return .next;
        },
        .block => |borrowed| {
            if (borrowed.len == 0 or !std.unicode.utf8ValidateSlice(borrowed)) {
                trace.finish("invalid_block");
                return error.InvalidHandlerOutput;
            }
            if (borrowed.len > definitions.Limits.reason_bytes) {
                trace.finish("block_too_large");
                return error.HandlerOutputTooLarge;
            }

            const reason = alloc.dupe(u8, borrowed) catch {
                trace.finish("copy_failed");
                return error.OutOfMemory;
            };
            if (current_arguments.*) |previous| {
                alloc.free(previous);
                current_arguments.* = null;
            }
            trace.finish("block");
            return .{ .blocked = reason };
        },
    }
}

const StopActionResult = union(enum) {
    next,
    done: definitions.StopOutcome,
};

const StopDispatch = struct {
    alloc: Allocator,
    input: definitions.StopInput,

    fn run(
        self: StopDispatch,
        handlers: []const RegisteredStopHandler,
    ) definitions.StopOutcome {
        for (handlers) |handler| {
            switch (self.runHandler(handler)) {
                .next => {},
                .done => |outcome| return outcome,
            }
        }
        return .allow;
    }

    fn runHandler(
        self: StopDispatch,
        handler: RegisteredStopHandler,
    ) StopActionResult {
        const trace = HandlerTrace.start(
            handler.hook,
            self.input.invocation,
            null,
        );
        const action = handler.run(handler.hook.ctx, self.input) catch |err| {
            trace.fail(err);
            return .{ .done = .allow };
        };
        defer if (handler.release_action) |release| release(handler.hook.ctx, action);
        return applyStopAction(
            self.alloc,
            action,
            self.input.can_continue,
            trace,
        );
    }
};

fn applyStopAction(
    alloc: Allocator,
    action: definitions.StopAction,
    can_continue: bool,
    trace: HandlerTrace,
) StopActionResult {
    switch (action) {
        .allow => {
            trace.finish("allow");
            return .next;
        },
        .continue_once => |borrowed| {
            if (!can_continue) {
                trace.finish("continue_not_allowed");
                return .{ .done = .allow };
            }
            if (borrowed.len > definitions.Limits.context_bytes or
                !std.unicode.utf8ValidateSlice(borrowed))
            {
                trace.finish("invalid_continue");
                return .{ .done = .allow };
            }

            const context = alloc.dupe(u8, borrowed) catch {
                trace.finish("copy_failed");
                return .{ .done = .allow };
            };
            trace.finish("continue_once");
            return .{ .done = .{ .continue_once = context } };
        },
    }
}

fn runSideEffectHandlers(input: anytype, handlers: anytype) void {
    for (handlers) |handler| {
        const trace = HandlerTrace.start(
            handler.hook,
            input.invocation,
            null,
        );
        handler.run(handler.hook.ctx, input) catch |err| {
            trace.fail(err);
            continue;
        };
        trace.finish("ok");
    }
}

fn deinitRegisteredHooks(alloc: Allocator, registered_handlers: anytype) void {
    for (registered_handlers) |handler| alloc.free(handler.hook.name);
}

fn validateHandlerName(name: []const u8) definitions.RegistrationError!void {
    if (name.len == 0) return error.EmptyHandlerName;
    if (name.len > definitions.Limits.handler_name_bytes) return error.HandlerNameTooLong;
    for (name) |byte| {
        const valid = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        if (!valid) return error.InvalidHandlerName;
    }
}

fn validateJsonObject(
    alloc: Allocator,
    arguments_json: []const u8,
) definitions.MutationDispatchError!void {
    if (!std.unicode.utf8ValidateSlice(arguments_json)) return error.InvalidHandlerOutput;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidHandlerOutput;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHandlerOutput;
}

const HandlerTrace = struct {
    event: HookEvent,
    handler_name: []const u8,
    invocation: definitions.Invocation,
    call_id: ?[]const u8,
    started_ms: i64,

    fn start(
        hook: RegisteredHook,
        invocation: definitions.Invocation,
        call_id: ?[]const u8,
    ) HandlerTrace {
        const trace: HandlerTrace = .{
            .event = hook.event,
            .handler_name = hook.name,
            .invocation = invocation,
            .call_id = call_id,
            .started_ms = io_mod.milliTimestamp(),
        };
        trace.emitStart();
        return trace;
    }

    fn finish(self: HandlerTrace, outcome: []const u8) void {
        const duration_ms = self.durationMs();
        const trace_ctx = traceContext(self.invocation);
        if (self.call_id) |id| {
            debug_trace.eventf(
                "hooks",
                "handler_finish",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} call_id={s} duration_ms={d} outcome={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), id, duration_ms, outcome },
            );
        } else {
            debug_trace.eventf(
                "hooks",
                "handler_finish",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} duration_ms={d} outcome={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), duration_ms, outcome },
            );
        }
    }

    fn fail(self: HandlerTrace, err: anyerror) void {
        const duration_ms = self.durationMs();
        const trace_ctx = traceContext(self.invocation);
        if (self.call_id) |id| {
            debug_trace.eventf(
                "hooks",
                "handler_finish",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} call_id={s} duration_ms={d} outcome=error error={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), id, duration_ms, @errorName(err) },
            );
        } else {
            debug_trace.eventf(
                "hooks",
                "handler_finish",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} duration_ms={d} outcome=error error={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), duration_ms, @errorName(err) },
            );
        }
    }

    fn emitStart(self: HandlerTrace) void {
        const trace_ctx = traceContext(self.invocation);
        if (self.call_id) |id| {
            debug_trace.eventf(
                "hooks",
                "handler_start",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} call_id={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), id },
            );
        } else {
            debug_trace.eventf(
                "hooks",
                "handler_start",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind) },
            );
        }
    }

    fn durationMs(self: HandlerTrace) i64 {
        return @max(io_mod.milliTimestamp() - self.started_ms, 0);
    }
};

fn traceContext(invocation: definitions.Invocation) debug_trace.TraceContext {
    return .{
        .turn_id = invocation.turn_id orelse 0,
        .subagent_id = invocation.scope.subagent_id orelse 0,
    };
}

fn testInvocation() definitions.Invocation {
    return .{
        .scope = .{
            .kind = .interactive,
            .workspace_root = "/tmp/workspace",
            .session_id = "session",
        },
        .turn_id = 42,
    };
}

const TestHandler = struct {
    fn continueTool(_: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        return .continue_;
    }

    fn allowStop(_: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        return .allow;
    }

    fn notePostTurnEnd(_: *anyopaque, _: definitions.PostTurnEndInput) definitions.HandlerError!void {}

    fn noteAttentionRequired(_: *anyopaque, _: definitions.AttentionRequiredInput) definitions.HandlerError!void {}
};

test "runtime validates names owns copies freezes and exposes lifecycle events" {
    const alloc = std.testing.allocator;
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();

    try std.testing.expectError(error.RuntimeNotFrozen, runtime.view());
    try std.testing.expectError(error.EmptyHandlerName, runtime.registerPreToolUse(.{
        .name = "",
        .ctx = undefined,
        .run = TestHandler.continueTool,
    }));
    try std.testing.expectError(error.InvalidHandlerName, runtime.registerPreToolUse(.{
        .name = "bad name",
        .ctx = undefined,
        .run = TestHandler.continueTool,
    }));

    var long_name: [definitions.Limits.handler_name_bytes + 1]u8 = undefined;
    @memset(&long_name, 'a');
    try std.testing.expectError(error.HandlerNameTooLong, runtime.registerPreToolUse(.{
        .name = &long_name,
        .ctx = undefined,
        .run = TestHandler.continueTool,
    }));

    var mutable_name = [_]u8{ 'a', 'l', 'p', 'h', 'a' };
    try runtime.registerPreToolUse(.{
        .name = &mutable_name,
        .ctx = undefined,
        .run = TestHandler.continueTool,
    });
    mutable_name[0] = 'x';
    try std.testing.expectError(error.DuplicateHandlerName, runtime.registerPreToolUse(.{
        .name = "alpha",
        .ctx = undefined,
        .run = TestHandler.continueTool,
    }));
    try runtime.registerStop(.{
        .name = "alpha",
        .ctx = undefined,
        .run = TestHandler.allowStop,
    });
    try runtime.registerPostTurnEnd(.{
        .name = "alpha",
        .ctx = undefined,
        .run = TestHandler.notePostTurnEnd,
    });
    try std.testing.expectError(error.DuplicateHandlerName, runtime.registerPostTurnEnd(.{
        .name = "alpha",
        .ctx = undefined,
        .run = TestHandler.notePostTurnEnd,
    }));
    try runtime.registerAttentionRequired(.{
        .name = "alpha",
        .ctx = undefined,
        .run = TestHandler.noteAttentionRequired,
    });
    try std.testing.expectError(error.DuplicateHandlerName, runtime.registerAttentionRequired(.{
        .name = "alpha",
        .ctx = undefined,
        .run = TestHandler.noteAttentionRequired,
    }));

    const view = runtime.freeze();
    const second_view = runtime.freeze();
    try std.testing.expect(view.hasPreToolUse());
    try std.testing.expect(view.hasStop());
    try std.testing.expect(view.hasPostTurnEnd());
    try std.testing.expect(view.hasAttentionRequired());
    try std.testing.expect(second_view.hasPreToolUse());
    try std.testing.expect(second_view.hasStop());
    try std.testing.expect(second_view.hasPostTurnEnd());
    try std.testing.expect(second_view.hasAttentionRequired());
    try std.testing.expectError(error.RuntimeFrozen, runtime.registerStop(.{
        .name = "late",
        .ctx = undefined,
        .run = TestHandler.allowStop,
    }));
    try std.testing.expectError(error.RuntimeFrozen, runtime.registerPostTurnEnd(.{
        .name = "late",
        .ctx = undefined,
        .run = TestHandler.notePostTurnEnd,
    }));
    try std.testing.expectError(error.RuntimeFrozen, runtime.registerAttentionRequired(.{
        .name = "late",
        .ctx = undefined,
        .run = TestHandler.noteAttentionRequired,
    }));

    try std.testing.expect(!@hasDecl(Runtime, "registerSessionStart"));
    try std.testing.expect(!@hasDecl(Runtime, "registerUserPromptSubmit"));
    try std.testing.expect(!@hasDecl(Runtime, "registerPermissionRequest"));
    try std.testing.expect(!@hasDecl(Runtime, "registerPostToolUse"));
    try std.testing.expect(!@hasDecl(Runtime, "registerPostToolFailure"));
}

test "empty views dispatch without allocation" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const views = [_]RuntimeView{ runtime.freeze(), RuntimeView.empty() };

    for (views) |view| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expect(!view.hasPreToolUse());
        try std.testing.expect(!view.hasStop());
        try std.testing.expect(!view.hasPostTurnEnd());
        try std.testing.expect(!view.hasAttentionRequired());

        var pre = try view.runPreToolUse(failing.allocator(), .{
            .invocation = testInvocation(),
            .step_index = 1,
            .call_id = "call",
            .tool_name = "read_file",
            .arguments_json = "{}",
        });
        defer pre.deinit(failing.allocator());
        try std.testing.expect(pre == .unchanged);

        var stop = view.runStop(failing.allocator(), .{
            .invocation = testInvocation(),
            .step_index = 1,
            .assistant_text = "done",
            .provider_disposition = .completed,
            .can_continue = true,
        });
        defer stop.deinit(failing.allocator());
        try std.testing.expect(stop == .allow);

        view.runPostTurnEnd(.{
            .invocation = testInvocation(),
            .outcome = .completed,
            .provider_disposition = .completed,
        });
        view.runAttentionRequired(.{
            .invocation = testInvocation(),
            .kind = .permission,
        });
        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    }
}

const RewriteCapture = struct {
    order: [4]u8 = undefined,
    count: usize = 0,
    second_saw_first: bool = false,
    third_called: bool = false,
    mutable_rewrite: [7]u8 = .{ '{', '"', 'a', '"', ':', '1', '}' },

    fn note(self: *RewriteCapture, value: u8) void {
        self.order[self.count] = value;
        self.count += 1;
    }

    fn first(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *RewriteCapture = @ptrCast(@alignCast(raw));
        self.note(1);
        return .{ .rewrite_arguments = &self.mutable_rewrite };
    }

    fn second(raw: *anyopaque, input: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *RewriteCapture = @ptrCast(@alignCast(raw));
        self.note(2);
        self.second_saw_first = std.mem.eql(u8, input.arguments_json, "{\"a\":1}");
        return .{ .rewrite_arguments = "{\"b\":2}" };
    }

    fn block(raw: *anyopaque, input: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *RewriteCapture = @ptrCast(@alignCast(raw));
        self.note(3);
        if (!std.mem.eql(u8, input.arguments_json, "{\"b\":2}")) return error.Failed;
        return .{ .block = "blocked by policy" };
    }

    fn third(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *RewriteCapture = @ptrCast(@alignCast(raw));
        self.third_called = true;
        return .continue_;
    }
};

test "PreToolUse chains rewrites in registration order and first block wins" {
    const alloc = std.testing.allocator;
    var capture = RewriteCapture{};
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerPreToolUse(.{ .name = "first", .ctx = &capture, .run = RewriteCapture.first });
    try runtime.registerPreToolUse(.{ .name = "second", .ctx = &capture, .run = RewriteCapture.second });
    try runtime.registerPreToolUse(.{ .name = "block", .ctx = &capture, .run = RewriteCapture.block });
    try runtime.registerPreToolUse(.{ .name = "never", .ctx = &capture, .run = RewriteCapture.third });
    var outcome = try runtime.freeze().runPreToolUse(alloc, .{
        .invocation = testInvocation(),
        .step_index = 2,
        .call_id = "call-1",
        .tool_name = "read_file",
        .arguments_json = "{\"original\":true}",
    });
    defer outcome.deinit(alloc);

    try std.testing.expect(outcome == .blocked);
    try std.testing.expectEqualStrings("blocked by policy", outcome.blocked);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, capture.order[0..capture.count]);
    try std.testing.expect(capture.second_saw_first);
    try std.testing.expect(!capture.third_called);
}

const OutputHandler = struct {
    output: []const u8,
    action: enum { rewrite, block, stop } = .rewrite,

    fn runTool(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *OutputHandler = @ptrCast(@alignCast(raw));
        return switch (self.action) {
            .rewrite => .{ .rewrite_arguments = self.output },
            .block => .{ .block = self.output },
            .stop => .continue_,
        };
    }

    fn runStop(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *OutputHandler = @ptrCast(@alignCast(raw));
        return .{ .continue_once = self.output };
    }
};

test "PreToolUse returns an owned final rewrite" {
    const alloc = std.testing.allocator;
    var source = [_]u8{ '{', '"', 'x', '"', ':', '1', '}' };
    var handler = OutputHandler{ .output = &source };
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerPreToolUse(.{ .name = "rewrite", .ctx = &handler, .run = OutputHandler.runTool });
    var outcome = try runtime.freeze().runPreToolUse(alloc, .{
        .invocation = testInvocation(),
        .step_index = 1,
        .call_id = "call",
        .tool_name = "tool",
        .arguments_json = "{}",
    });
    defer outcome.deinit(alloc);
    source[5] = '9';

    try std.testing.expect(outcome == .rewritten);
    try std.testing.expectEqualStrings("{\"x\":1}", outcome.rewritten);
}

test "PreToolUse rejects non-object malformed trailing and oversized rewrites" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "[]",
        "1",
        "null",
        "{",
        "{} trailing",
    };

    for (cases) |output| {
        var handler = OutputHandler{ .output = output };
        var runtime = Runtime.init(alloc);
        defer runtime.deinit();
        try runtime.registerPreToolUse(.{ .name = "invalid", .ctx = &handler, .run = OutputHandler.runTool });
        try std.testing.expectError(error.InvalidHandlerOutput, runtime.freeze().runPreToolUse(alloc, .{
            .invocation = testInvocation(),
            .step_index = 1,
            .call_id = "call",
            .tool_name = "tool",
            .arguments_json = "{}",
        }));
    }

    const oversized = try alloc.alloc(u8, definitions.Limits.arguments_json_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, ' ');
    var handler = OutputHandler{ .output = oversized };
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerPreToolUse(.{ .name = "oversized", .ctx = &handler, .run = OutputHandler.runTool });
    try std.testing.expectError(error.HandlerOutputTooLarge, runtime.freeze().runPreToolUse(alloc, .{
        .invocation = testInvocation(),
        .step_index = 1,
        .call_id = "call",
        .tool_name = "tool",
        .arguments_json = "{}",
    }));
}

const ErrorHandler = struct {
    cancelled: bool,

    fn runTool(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *ErrorHandler = @ptrCast(@alignCast(raw));
        if (self.cancelled) return error.Cancelled;
        return error.Failed;
    }

    fn runStop(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *ErrorHandler = @ptrCast(@alignCast(raw));
        if (self.cancelled) return error.Cancelled;
        return error.Failed;
    }
};

test "PreToolUse maps handler errors and allocation failure without leaking prior rewrites" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |cancelled| {
        var handler = ErrorHandler{ .cancelled = cancelled };
        var runtime = Runtime.init(alloc);
        defer runtime.deinit();
        try runtime.registerPreToolUse(.{ .name = "error", .ctx = &handler, .run = ErrorHandler.runTool });
        const result = runtime.freeze().runPreToolUse(alloc, .{
            .invocation = testInvocation(),
            .step_index = 1,
            .call_id = "call",
            .tool_name = "tool",
            .arguments_json = "{}",
        });
        if (cancelled) {
            try std.testing.expectError(error.Cancelled, result);
        } else {
            try std.testing.expectError(error.HandlerFailed, result);
        }
    }

    var rewrite_handler = OutputHandler{ .output = "{\"ok\":true}" };
    var error_handler = ErrorHandler{ .cancelled = false };
    var chained_runtime = Runtime.init(alloc);
    defer chained_runtime.deinit();
    try chained_runtime.registerPreToolUse(.{ .name = "rewrite", .ctx = &rewrite_handler, .run = OutputHandler.runTool });
    try chained_runtime.registerPreToolUse(.{ .name = "error", .ctx = &error_handler, .run = ErrorHandler.runTool });
    try std.testing.expectError(error.HandlerFailed, chained_runtime.freeze().runPreToolUse(alloc, .{
        .invocation = testInvocation(),
        .step_index = 1,
        .call_id = "call",
        .tool_name = "tool",
        .arguments_json = "{}",
    }));

    var handler = OutputHandler{ .output = "{\"ok\":true}" };
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerPreToolUse(.{ .name = "rewrite", .ctx = &handler, .run = OutputHandler.runTool });
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, runtime.freeze().runPreToolUse(failing.allocator(), .{
        .invocation = testInvocation(),
        .step_index = 1,
        .call_id = "call",
        .tool_name = "tool",
        .arguments_json = "{}",
    }));
}

const StopCapture = struct {
    calls: usize = 0,
    third_called: bool = false,
    mutable_context: [8]u8 = .{ 'c', 'o', 'n', 't', 'i', 'n', 'u', 'e' },

    fn allow(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *StopCapture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .allow;
    }

    fn continueOnce(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *StopCapture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .continue_once = &self.mutable_context };
    }

    fn third(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *StopCapture = @ptrCast(@alignCast(raw));
        self.third_called = true;
        return .allow;
    }
};

test "Stop returns the first owned continuation and honors can_continue" {
    const alloc = std.testing.allocator;
    var capture = StopCapture{};
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerStop(.{ .name = "allow", .ctx = &capture, .run = StopCapture.allow });
    try runtime.registerStop(.{ .name = "continue", .ctx = &capture, .run = StopCapture.continueOnce });
    try runtime.registerStop(.{ .name = "never", .ctx = &capture, .run = StopCapture.third });
    const view = runtime.freeze();

    var outcome = view.runStop(alloc, .{
        .invocation = testInvocation(),
        .step_index = 3,
        .assistant_text = "candidate",
        .provider_disposition = .completed,
        .can_continue = true,
    });
    defer outcome.deinit(alloc);
    capture.mutable_context[0] = 'X';
    try std.testing.expect(outcome == .continue_once);
    try std.testing.expectEqualStrings("continue", outcome.continue_once);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect(!capture.third_called);

    var normalized = view.runStop(alloc, .{
        .invocation = testInvocation(),
        .step_index = 3,
        .assistant_text = "candidate",
        .provider_disposition = .length_limited,
        .can_continue = false,
    });
    defer normalized.deinit(alloc);
    try std.testing.expect(normalized == .allow);
}

test "Stop fails open on handler errors, output limits, and copy failures" {
    const alloc = std.testing.allocator;

    for ([_]bool{ false, true }) |cancelled| {
        var error_handler = ErrorHandler{ .cancelled = cancelled };
        var error_runtime = Runtime.init(alloc);
        defer error_runtime.deinit();
        try error_runtime.registerStop(.{ .name = "error", .ctx = &error_handler, .run = ErrorHandler.runStop });
        var handler_failed = error_runtime.freeze().runStop(alloc, .{
            .invocation = testInvocation(),
            .step_index = 1,
            .assistant_text = "done",
            .provider_disposition = .completed,
            .can_continue = true,
        });
        defer handler_failed.deinit(alloc);
        try std.testing.expect(handler_failed == .allow);
    }

    const oversized = try alloc.alloc(u8, definitions.Limits.context_bytes + 1);
    defer alloc.free(oversized);
    var output_handler = OutputHandler{ .output = oversized };
    var output_runtime = Runtime.init(alloc);
    defer output_runtime.deinit();
    try output_runtime.registerStop(.{ .name = "oversized", .ctx = &output_handler, .run = OutputHandler.runStop });
    const view = output_runtime.freeze();
    var oversized_outcome = view.runStop(alloc, .{
        .invocation = testInvocation(),
        .step_index = 1,
        .assistant_text = "done",
        .provider_disposition = .completed,
        .can_continue = true,
    });
    defer oversized_outcome.deinit(alloc);
    try std.testing.expect(oversized_outcome == .allow);

    output_handler.output = "continue";
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var allocation_failed = view.runStop(failing.allocator(), .{
        .invocation = testInvocation(),
        .step_index = 1,
        .assistant_text = "done",
        .provider_disposition = .completed,
        .can_continue = true,
    });
    defer allocation_failed.deinit(failing.allocator());
    try std.testing.expect(allocation_failed == .allow);
}

const PostTurnEndCapture = struct {
    order: [4]u8 = undefined,
    count: usize = 0,
    saw_scope: bool = false,
    saw_turn_id: bool = false,
    saw_outcome: bool = false,
    saw_disposition: bool = false,

    fn note(self: *PostTurnEndCapture, value: u8) void {
        self.order[self.count] = value;
        self.count += 1;
    }

    fn first(raw: *anyopaque, input: definitions.PostTurnEndInput) definitions.HandlerError!void {
        const self: *PostTurnEndCapture = @ptrCast(@alignCast(raw));
        self.note(1);
        self.saw_scope = input.invocation.scope.kind == .interactive and
            std.mem.eql(u8, input.invocation.scope.workspace_root, "/tmp/workspace") and
            std.mem.eql(u8, input.invocation.scope.session_id orelse "", "session");
        self.saw_turn_id = input.invocation.turn_id == 42;
        self.saw_outcome = input.outcome == .completed;
        self.saw_disposition = input.provider_disposition == .length_limited;
    }

    fn failing(raw: *anyopaque, _: definitions.PostTurnEndInput) definitions.HandlerError!void {
        const self: *PostTurnEndCapture = @ptrCast(@alignCast(raw));
        self.note(2);
        return error.Failed;
    }

    fn cancelled(raw: *anyopaque, _: definitions.PostTurnEndInput) definitions.HandlerError!void {
        const self: *PostTurnEndCapture = @ptrCast(@alignCast(raw));
        self.note(3);
        return error.Cancelled;
    }

    fn fourth(raw: *anyopaque, _: definitions.PostTurnEndInput) definitions.HandlerError!void {
        const self: *PostTurnEndCapture = @ptrCast(@alignCast(raw));
        self.note(4);
    }
};

test "PostTurnEnd runs side-effect handlers in order and fails open on handler errors" {
    const alloc = std.testing.allocator;
    var capture = PostTurnEndCapture{};
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();

    try runtime.registerPostTurnEnd(.{ .name = "first", .ctx = &capture, .run = PostTurnEndCapture.first });
    try runtime.registerPostTurnEnd(.{ .name = "failing", .ctx = &capture, .run = PostTurnEndCapture.failing });
    try runtime.registerPostTurnEnd(.{ .name = "cancelled", .ctx = &capture, .run = PostTurnEndCapture.cancelled });
    try runtime.registerPostTurnEnd(.{ .name = "fourth", .ctx = &capture, .run = PostTurnEndCapture.fourth });

    runtime.freeze().runPostTurnEnd(.{
        .invocation = testInvocation(),
        .outcome = .completed,
        .provider_disposition = .length_limited,
    });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, capture.order[0..capture.count]);
    try std.testing.expect(capture.saw_scope);
    try std.testing.expect(capture.saw_turn_id);
    try std.testing.expect(capture.saw_outcome);
    try std.testing.expect(capture.saw_disposition);
}

const AttentionRequiredCapture = struct {
    order: [4]u8 = undefined,
    count: usize = 0,
    saw_input: bool = false,

    fn note(self: *AttentionRequiredCapture, value: u8) void {
        self.order[self.count] = value;
        self.count += 1;
    }

    fn first(raw: *anyopaque, input: definitions.AttentionRequiredInput) definitions.HandlerError!void {
        const self: *AttentionRequiredCapture = @ptrCast(@alignCast(raw));
        self.note(1);
        self.saw_input = input.invocation.scope.kind == .interactive and
            input.invocation.turn_id == 42 and
            input.kind == .route_recovery;
    }

    fn failing(raw: *anyopaque, _: definitions.AttentionRequiredInput) definitions.HandlerError!void {
        const self: *AttentionRequiredCapture = @ptrCast(@alignCast(raw));
        self.note(2);
        return error.Failed;
    }

    fn cancelled(raw: *anyopaque, _: definitions.AttentionRequiredInput) definitions.HandlerError!void {
        const self: *AttentionRequiredCapture = @ptrCast(@alignCast(raw));
        self.note(3);
        return error.Cancelled;
    }

    fn fourth(raw: *anyopaque, _: definitions.AttentionRequiredInput) definitions.HandlerError!void {
        const self: *AttentionRequiredCapture = @ptrCast(@alignCast(raw));
        self.note(4);
    }
};

test "AttentionRequired runs in order propagates input and fails open" {
    var capture = AttentionRequiredCapture{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();

    try runtime.registerAttentionRequired(.{ .name = "first", .ctx = &capture, .run = AttentionRequiredCapture.first });
    try runtime.registerAttentionRequired(.{ .name = "failing", .ctx = &capture, .run = AttentionRequiredCapture.failing });
    try runtime.registerAttentionRequired(.{ .name = "cancelled", .ctx = &capture, .run = AttentionRequiredCapture.cancelled });
    try runtime.registerAttentionRequired(.{ .name = "fourth", .ctx = &capture, .run = AttentionRequiredCapture.fourth });

    runtime.freeze().runAttentionRequired(.{
        .invocation = testInvocation(),
        .kind = .route_recovery,
    });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, capture.order[0..capture.count]);
    try std.testing.expect(capture.saw_input);
}

const ConcurrentHandler = struct {
    calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn run(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *ConcurrentHandler = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .seq_cst);
        return .continue_;
    }
};

const ConcurrentRun = struct {
    view: RuntimeView,
    failed: *std.atomic.Value(bool),

    fn run(self: ConcurrentRun) void {
        var outcome = self.view.runPreToolUse(std.heap.page_allocator, .{
            .invocation = testInvocation(),
            .step_index = 1,
            .call_id = "call",
            .tool_name = "tool",
            .arguments_json = "{}",
        }) catch {
            self.failed.store(true, .seq_cst);
            return;
        };
        outcome.deinit(std.heap.page_allocator);
    }
};

test "a frozen view is safe to copy across concurrent invocations" {
    var handler = ConcurrentHandler{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.registerPreToolUse(.{ .name = "concurrent", .ctx = &handler, .run = ConcurrentHandler.run });
    const view = runtime.freeze();
    var failed = std.atomic.Value(bool).init(false);

    const first = try std.Thread.spawn(.{}, ConcurrentRun.run, .{ConcurrentRun{ .view = view, .failed = &failed }});
    const second = try std.Thread.spawn(.{}, ConcurrentRun.run, .{ConcurrentRun{ .view = view, .failed = &failed }});
    first.join();
    second.join();

    try std.testing.expect(!failed.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), handler.calls.load(.seq_cst));
}

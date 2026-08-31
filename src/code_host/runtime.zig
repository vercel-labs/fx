const std = @import("std");
const c = @cImport({
    @cInclude("quickjs.h");
});

pub const Options = struct {
    io: std.Io,
    memory_limit_bytes: usize,
    stack_limit_bytes: usize,
    execution_limit_ns: u64 = 10_000_000_000,
};

pub const ToolRequest = struct {
    id: u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const ToolResponse = union(enum) {
    success: []const u8,
    failure: []const u8,
};

pub const DispatchError = error{
    OutOfMemory,
    DispatchFailed,
};

pub const Dispatcher = struct {
    context: *anyopaque,
    dispatch: *const fn (
        context: *anyopaque,
        requests: []const ToolRequest,
        responses: []ToolResponse,
    ) DispatchError!void,
};

const PendingCall = struct {
    request: ToolRequest,
    resolving: [2]c.JSValue,

    fn deinit(self: PendingCall, runtime: *Runtime) void {
        runtime.allocator.free(@constCast(self.request.name));
        runtime.allocator.free(@constCast(self.request.arguments_json));
        c.JS_FreeValue(runtime.context, self.resolving[0]);
        c.JS_FreeValue(runtime.context, self.resolving[1]);
    }
};

pub const RuntimeError = error{
    JavaScriptException,
    InvalidProgramResult,
    InvalidToolResponse,
    ProgramStalled,
    PendingJobFailed,
    TooManyToolCalls,
    TooManyActiveToolCalls,
    SourceTooLarge,
    WriteFailed,
    ExecutionLimitExceeded,
} || std.mem.Allocator.Error || DispatchError;

const InterruptState = struct {
    io: std.Io,
    limit_ns: u64,
    remaining_ns: u64,
    segment_started_ns: u64 = 0,
    active: bool = false,
    exceeded: bool = false,

    fn reset(self: *InterruptState) void {
        self.remaining_ns = self.limit_ns;
        self.segment_started_ns = 0;
        self.active = false;
        self.exceeded = false;
    }

    fn begin(self: *InterruptState) void {
        self.segment_started_ns = monotonicNs(self.io);
        self.active = true;
    }

    fn end(self: *InterruptState) void {
        if (!self.active) return;
        const now = monotonicNs(self.io);
        const elapsed = now -| self.segment_started_ns;
        self.remaining_ns -|= elapsed;
        if (self.remaining_ns == 0) self.exceeded = true;
        self.active = false;
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    runtime: *c.JSRuntime,
    context: *c.JSContext,
    interrupt: *InterruptState,
    pending: std.ArrayList(PendingCall) = .empty,
    next_call_id: u8 = 0,
    call_limit_exceeded: bool = false,
    failure_message: [1024]u8 = undefined,
    failure_message_len: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        options: Options,
    ) error{ OutOfMemory, SandboxInitializationFailed }!Runtime {
        const runtime = c.JS_NewRuntime() orelse return error.OutOfMemory;
        errdefer c.JS_FreeRuntime(runtime);
        const interrupt = try allocator.create(InterruptState);
        errdefer allocator.destroy(interrupt);
        interrupt.* = .{
            .io = options.io,
            .limit_ns = options.execution_limit_ns,
            .remaining_ns = options.execution_limit_ns,
        };
        c.JS_SetInterruptHandler(runtime, interruptHandler, interrupt);
        c.JS_SetMemoryLimit(runtime, options.memory_limit_bytes);
        c.JS_SetMaxStackSize(runtime, options.stack_limit_bytes);
        const context = newRestrictedContext(runtime) orelse
            return error.OutOfMemory;
        errdefer c.JS_FreeContext(context);
        try installToolApi(context);
        try removeGlobal(context, "eval");
        try removeGlobal(context, "Function");
        return .{
            .allocator = allocator,
            .runtime = runtime,
            .context = context,
            .interrupt = interrupt,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.clearPending();
        self.pending.deinit(self.allocator);
        c.JS_SetContextOpaque(self.context, null);
        c.JS_FreeContext(self.context);
        c.JS_FreeRuntime(self.runtime);
        self.allocator.destroy(self.interrupt);
        self.* = undefined;
    }

    fn evaluate(
        self: *Runtime,
        alloc: std.mem.Allocator,
        source: []const u8,
    ) (std.mem.Allocator.Error || error{JavaScriptException})![]u8 {
        const value = c.JS_Eval(
            self.context,
            source.ptr,
            source.len,
            "code.js",
            c.JS_EVAL_TYPE_GLOBAL,
        );
        defer c.JS_FreeValue(self.context, value);
        if (c.JS_IsException(value)) return error.JavaScriptException;

        var len: usize = 0;
        const bytes = c.JS_ToCStringLen(self.context, &len, value) orelse
            return error.JavaScriptException;
        defer c.JS_FreeCString(self.context, bytes);
        return alloc.dupe(u8, bytes[0..len]);
    }

    pub fn runProgram(
        self: *Runtime,
        alloc: std.mem.Allocator,
        source: []const u8,
        dispatcher: Dispatcher,
    ) RuntimeError![]u8 {
        if (source.len > 64 * 1024) return error.SourceTooLarge;
        if (self.pending.items.len != 0) return error.ProgramStalled;
        self.next_call_id = 0;
        self.call_limit_exceeded = false;
        self.failure_message_len = 0;
        self.interrupt.reset();
        c.JS_SetContextOpaque(self.context, self);
        defer c.JS_SetContextOpaque(self.context, null);
        defer self.clearPending();

        const wrapped = try std.fmt.allocPrint(
            self.allocator,
            "(async () => {{\n{s}\n}})()",
            .{source},
        );
        defer self.allocator.free(wrapped);
        self.interrupt.begin();
        const root = c.JS_Eval(
            self.context,
            wrapped.ptr,
            wrapped.len,
            "program.js",
            c.JS_EVAL_TYPE_GLOBAL,
        );
        self.interrupt.end();
        defer c.JS_FreeValue(self.context, root);
        if (self.interrupt.exceeded) return error.ExecutionLimitExceeded;
        if (self.call_limit_exceeded) return error.TooManyToolCalls;
        if (c.JS_IsException(root)) {
            self.captureCurrentException();
            return error.JavaScriptException;
        }
        if (!c.JS_IsPromise(root)) {
            return error.JavaScriptException;
        }

        while (true) {
            self.interrupt.begin();
            self.drainJobs() catch |err| {
                self.interrupt.end();
                if (self.interrupt.exceeded) return error.ExecutionLimitExceeded;
                return err;
            };
            self.interrupt.end();
            if (self.interrupt.exceeded) return error.ExecutionLimitExceeded;
            if (self.call_limit_exceeded) return error.TooManyToolCalls;
            switch (c.JS_PromiseState(self.context, root)) {
                c.JS_PROMISE_FULFILLED => return self.stringifyPromiseResult(
                    alloc,
                    root,
                ),
                c.JS_PROMISE_REJECTED => {
                    const reason = c.JS_PromiseResult(self.context, root);
                    defer c.JS_FreeValue(self.context, reason);
                    self.captureFailureValue(reason);
                    return error.JavaScriptException;
                },
                c.JS_PROMISE_PENDING => {},
                else => return error.InvalidProgramResult,
            }
            if (self.pending.items.len == 0) return error.ProgramStalled;
            if (self.pending.items.len > 8) {
                return error.TooManyActiveToolCalls;
            }
            try self.dispatchPending(dispatcher);
        }
    }

    fn dispatchPending(
        self: *Runtime,
        dispatcher: Dispatcher,
    ) RuntimeError!void {
        const count = self.pending.items.len;
        const requests = try self.allocator.alloc(ToolRequest, count);
        defer self.allocator.free(requests);
        const responses = try self.allocator.alloc(ToolResponse, count);
        defer self.allocator.free(responses);
        for (self.pending.items, requests) |pending, *request| {
            request.* = pending.request;
        }
        try dispatcher.dispatch(dispatcher.context, requests, responses);

        for (self.pending.items, responses) |pending, response| {
            const argument = try self.toolResponseValue(response);
            defer c.JS_FreeValue(self.context, argument);
            const call_result = c.JS_Call(
                self.context,
                switch (response) {
                    .success => pending.resolving[0],
                    .failure => pending.resolving[1],
                },
                undefinedValue(),
                1,
                @constCast(&argument),
            );
            defer c.JS_FreeValue(self.context, call_result);
            if (c.JS_IsException(call_result)) return error.JavaScriptException;
        }
        self.clearPending();
    }

    fn toolResponseValue(
        self: *Runtime,
        response: ToolResponse,
    ) RuntimeError!c.JSValue {
        var json: std.Io.Writer.Allocating = .init(self.allocator);
        defer json.deinit();
        switch (response) {
            .success => |value| try json.writer.writeAll(value),
            .failure => |message| try std.json.Stringify.value(
                message,
                .{},
                &json.writer,
            ),
        }
        const terminated = try self.allocator.allocSentinel(
            u8,
            json.written().len,
            0,
        );
        defer self.allocator.free(terminated);
        @memcpy(terminated, json.written());
        const value = c.JS_ParseJSON(
            self.context,
            terminated.ptr,
            terminated.len,
            "tool-result.json",
        );
        if (c.JS_IsException(value)) return error.InvalidToolResponse;
        return value;
    }

    fn stringifyPromiseResult(
        self: *Runtime,
        alloc: std.mem.Allocator,
        promise: c.JSValueConst,
    ) RuntimeError![]u8 {
        const result = c.JS_PromiseResult(self.context, promise);
        defer c.JS_FreeValue(self.context, result);
        const json = c.JS_JSONStringify(
            self.context,
            result,
            undefinedValue(),
            undefinedValue(),
        );
        defer c.JS_FreeValue(self.context, json);
        if (c.JS_IsException(json)) return error.JavaScriptException;
        var len: usize = 0;
        const bytes = c.JS_ToCStringLen(self.context, &len, json) orelse
            return error.InvalidProgramResult;
        defer c.JS_FreeCString(self.context, bytes);
        return alloc.dupe(u8, bytes[0..len]);
    }

    fn drainJobs(self: *Runtime) RuntimeError!void {
        while (true) {
            var job_context: ?*c.JSContext = null;
            const result = c.JS_ExecutePendingJob(self.runtime, &job_context);
            if (result < 0) {
                self.captureCurrentException();
                return error.PendingJobFailed;
            }
            if (result == 0) return;
        }
    }

    pub fn failureMessage(self: *const Runtime, fallback: []const u8) []const u8 {
        if (self.failure_message_len == 0) return fallback;
        return self.failure_message[0..self.failure_message_len];
    }

    pub fn failureIsSyntax(self: *const Runtime) bool {
        return std.mem.startsWith(
            u8,
            self.failure_message[0..self.failure_message_len],
            "SyntaxError",
        );
    }

    fn captureCurrentException(self: *Runtime) void {
        const exception = c.JS_GetException(self.context);
        defer c.JS_FreeValue(self.context, exception);
        self.captureFailureValue(exception);
    }

    fn captureFailureValue(self: *Runtime, value: c.JSValueConst) void {
        var len: usize = 0;
        const bytes = c.JS_ToCStringLen(self.context, &len, value) orelse return;
        defer c.JS_FreeCString(self.context, bytes);
        self.failure_message_len = @min(len, self.failure_message.len);
        @memcpy(
            self.failure_message[0..self.failure_message_len],
            bytes[0..self.failure_message_len],
        );
    }

    fn clearPending(self: *Runtime) void {
        for (self.pending.items) |pending| pending.deinit(self);
        self.pending.clearRetainingCapacity();
    }
};

fn newRestrictedContext(runtime: *c.JSRuntime) ?*c.JSContext {
    const context = c.JS_NewContextRaw(runtime) orelse return null;
    if (c.JS_AddIntrinsicBaseObjects(context) != 0 or
        c.JS_AddIntrinsicEval(context) != 0 or
        c.JS_AddIntrinsicRegExp(context) != 0 or
        c.JS_AddIntrinsicJSON(context) != 0 or
        c.JS_AddIntrinsicProxy(context) != 0 or
        c.JS_AddIntrinsicMapSet(context) != 0 or
        c.JS_AddIntrinsicPromise(context) != 0)
    {
        c.JS_FreeContext(context);
        return null;
    }
    return context;
}

fn installToolApi(
    context: *c.JSContext,
) error{ OutOfMemory, SandboxInitializationFailed }!void {
    const global = c.JS_GetGlobalObject(context);
    defer c.JS_FreeValue(context, global);
    if (c.JS_IsException(global)) return error.SandboxInitializationFailed;
    const call = c.JS_NewCFunction(context, toolCall, "__fx_call", 2);
    if (c.JS_IsException(call)) return error.OutOfMemory;
    if (c.JS_SetPropertyStr(context, global, "__fx_call", call) < 0) {
        return error.SandboxInitializationFailed;
    }
    const bootstrap =
        \\const __fx_call_captured = globalThis.__fx_call;
        \\globalThis.tools = new Proxy(Object.create(null), {
        \\  get(_target, name) {
        \\    if (typeof name !== "string") return undefined;
        \\    return (argumentsValue = {}) => __fx_call_captured(name, argumentsValue);
        \\  },
        \\});
        \\delete globalThis.__fx_call;
    ;
    const result = c.JS_Eval(
        context,
        bootstrap.ptr,
        bootstrap.len,
        "bootstrap.js",
        c.JS_EVAL_TYPE_GLOBAL,
    );
    defer c.JS_FreeValue(context, result);
    if (c.JS_IsException(result)) return error.SandboxInitializationFailed;
}

fn toolCall(
    maybe_context: ?*c.JSContext,
    _: c.JSValueConst,
    argc: c_int,
    argv: [*c]c.JSValueConst,
) callconv(.c) c.JSValue {
    const context = maybe_context orelse @panic("QuickJS callback without context");
    if (argc != 2) return c.JS_ThrowTypeError(
        context,
        "tool call expects name and arguments",
    );
    const raw_runtime = c.JS_GetContextOpaque(context) orelse
        return c.JS_ThrowInternalError(context, "program runtime unavailable");
    const runtime: *Runtime = @ptrCast(@alignCast(raw_runtime));
    if (runtime.next_call_id >= 32) {
        runtime.call_limit_exceeded = true;
        return c.JS_ThrowRangeError(context, "too many tool calls");
    }

    var name_len: usize = 0;
    const raw_name = c.JS_ToCStringLen(context, &name_len, argv[0]) orelse
        return c.JS_ThrowTypeError(context, "tool name must be a string");
    defer c.JS_FreeCString(context, raw_name);
    const name = runtime.allocator.dupe(u8, raw_name[0..name_len]) catch
        return c.JS_ThrowOutOfMemory(context);

    const json = c.JS_JSONStringify(
        context,
        argv[1],
        undefinedValue(),
        undefinedValue(),
    );
    defer c.JS_FreeValue(context, json);
    if (c.JS_IsException(json)) {
        runtime.allocator.free(name);
        return json;
    }
    var arguments_len: usize = 0;
    const raw_arguments = c.JS_ToCStringLen(
        context,
        &arguments_len,
        json,
    ) orelse {
        runtime.allocator.free(name);
        return c.JS_ThrowTypeError(context, "tool arguments are not serializable");
    };
    defer c.JS_FreeCString(context, raw_arguments);
    const arguments_json = runtime.allocator.dupe(
        u8,
        raw_arguments[0..arguments_len],
    ) catch {
        runtime.allocator.free(name);
        return c.JS_ThrowOutOfMemory(context);
    };

    var resolving: [2]c.JSValue = undefined;
    const promise = c.JS_NewPromiseCapability(context, &resolving);
    if (c.JS_IsException(promise)) {
        runtime.allocator.free(name);
        runtime.allocator.free(arguments_json);
        return promise;
    }
    runtime.pending.append(runtime.allocator, .{
        .request = .{
            .id = runtime.next_call_id,
            .name = name,
            .arguments_json = arguments_json,
        },
        .resolving = resolving,
    }) catch {
        runtime.allocator.free(name);
        runtime.allocator.free(arguments_json);
        c.JS_FreeValue(context, resolving[0]);
        c.JS_FreeValue(context, resolving[1]);
        c.JS_FreeValue(context, promise);
        return c.JS_ThrowOutOfMemory(context);
    };
    runtime.next_call_id += 1;
    return promise;
}

fn undefinedValue() c.JSValue {
    return .{
        .u = .{ .int32 = 0 },
        .tag = c.JS_TAG_UNDEFINED,
    };
}

fn interruptHandler(
    _: ?*c.JSRuntime,
    maybe_opaque: ?*anyopaque,
) callconv(.c) c_int {
    const raw = maybe_opaque orelse return 1;
    const state: *InterruptState = @ptrCast(@alignCast(raw));
    if (!state.active) return 0;
    const elapsed = monotonicNs(state.io) -| state.segment_started_ns;
    if (elapsed < state.remaining_ns) return 0;
    state.exceeded = true;
    return 1;
}

fn monotonicNs(io: std.Io) u64 {
    const now = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    return std.math.cast(u64, now) orelse 0;
}

fn removeGlobal(
    context: *c.JSContext,
    name: [*:0]const u8,
) error{SandboxInitializationFailed}!void {
    const global = c.JS_GetGlobalObject(context);
    defer c.JS_FreeValue(context, global);
    if (c.JS_IsException(global)) return error.SandboxInitializationFailed;
    const atom = c.JS_NewAtom(context, name);
    if (atom == c.JS_ATOM_NULL) return error.SandboxInitializationFailed;
    defer c.JS_FreeAtom(context, atom);
    if (c.JS_DeleteProperty(context, global, atom, 0) != 1) {
        return error.SandboxInitializationFailed;
    }
}

test "runtime evaluates JavaScript without ambient operating system globals" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .io = std.testing.io,
        .memory_limit_bytes = 16 * 1024 * 1024,
        .stack_limit_bytes = 512 * 1024,
    });
    defer runtime.deinit();

    const result = try runtime.evaluate(std.testing.allocator,
        \\JSON.stringify({
        \\  value: 1 + 2,
        \\  process: typeof process,
        \\  require: typeof require,
        \\  fetch: typeof fetch,
        \\  std: typeof std,
        \\  os: typeof os,
        \\  eval: typeof eval,
        \\  Function: typeof Function,
        \\  Uint8Array: typeof Uint8Array,
        \\  Atomics: typeof Atomics,
        \\  SharedArrayBuffer: typeof SharedArrayBuffer,
        \\  WeakRef: typeof WeakRef,
        \\  atob: typeof atob,
        \\  performance: typeof performance,
        \\  Date: typeof Date,
        \\})
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        "{\"value\":3,\"process\":\"undefined\",\"require\":\"undefined\",\"fetch\":\"undefined\",\"std\":\"undefined\",\"os\":\"undefined\",\"eval\":\"undefined\",\"Function\":\"undefined\",\"Uint8Array\":\"undefined\",\"Atomics\":\"undefined\",\"SharedArrayBuffer\":\"undefined\",\"WeakRef\":\"undefined\",\"atob\":\"undefined\",\"performance\":\"undefined\",\"Date\":\"undefined\"}",
        result,
    );
}

test "Promise all presents independent tool calls as one batch" {
    const Capture = struct {
        batch_size: usize = 0,

        fn dispatch(
            raw: *anyopaque,
            requests: []const ToolRequest,
            responses: []ToolResponse,
        ) DispatchError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.batch_size = requests.len;
            for (requests, responses) |request, *response| {
                if (std.mem.eql(u8, request.name, "read_file") and
                    std.mem.find(u8, request.arguments_json, "alpha") != null)
                {
                    response.* = .{ .success = "{\"path\":\"alpha\"}" };
                } else {
                    response.* = .{ .success = "{\"path\":\"beta\"}" };
                }
            }
        }
    };

    var capture: Capture = .{};
    var runtime = try Runtime.init(std.testing.allocator, .{
        .io = std.testing.io,
        .memory_limit_bytes = 16 * 1024 * 1024,
        .stack_limit_bytes = 512 * 1024,
    });
    defer runtime.deinit();

    const result = try runtime.runProgram(
        std.testing.allocator,
        \\const [alpha, beta] = await Promise.all([
        \\  tools.read_file({ path: "alpha" }),
        \\  tools.read_file({ path: "beta" }),
        \\]);
        \\return [alpha.path, beta.path];
    ,
        .{
            .context = &capture,
            .dispatch = Capture.dispatch,
        },
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), capture.batch_size);
    try std.testing.expectEqualStrings("[\"alpha\",\"beta\"]", result);
}

test "failed nested tool rejects the awaiting program" {
    const Reject = struct {
        fn dispatch(
            _: *anyopaque,
            _: []const ToolRequest,
            responses: []ToolResponse,
        ) DispatchError!void {
            responses[0] = .{ .failure = "read failed" };
        }
    };
    var runtime = try Runtime.init(std.testing.allocator, .{
        .io = std.testing.io,
        .memory_limit_bytes = 16 * 1024 * 1024,
        .stack_limit_bytes = 512 * 1024,
    });
    defer runtime.deinit();
    var context: u8 = 0;

    try std.testing.expectError(
        error.JavaScriptException,
        runtime.runProgram(
            std.testing.allocator,
            "return await tools.read_file({ path: 'missing' });",
            .{
                .context = &context,
                .dispatch = Reject.dispatch,
            },
        ),
    );
    try std.testing.expectEqualStrings(
        "read failed",
        runtime.failureMessage("fallback"),
    );
}

test "syntax failure retains a bounded diagnostic" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .io = std.testing.io,
        .memory_limit_bytes = 16 * 1024 * 1024,
        .stack_limit_bytes = 512 * 1024,
    });
    defer runtime.deinit();

    try std.testing.expectError(
        error.JavaScriptException,
        runtime.runProgram(
            std.testing.allocator,
            "return (;",
            .{
                .context = undefined,
                .dispatch = undefined,
            },
        ),
    );
    try std.testing.expect(runtime.failureIsSyntax());
    try std.testing.expect(std.mem.find(
        u8,
        runtime.failureMessage("fallback"),
        "SyntaxError",
    ) != null);
}

test "runtime interrupt stops an infinite JavaScript loop" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .io = std.testing.io,
        .memory_limit_bytes = 16 * 1024 * 1024,
        .stack_limit_bytes = 512 * 1024,
        .execution_limit_ns = 1,
    });
    defer runtime.deinit();

    try std.testing.expectError(
        error.ExecutionLimitExceeded,
        runtime.runProgram(
            std.testing.allocator,
            "while (true) {}",
            .{
                .context = undefined,
                .dispatch = undefined,
            },
        ),
    );
}

test "runtime rejects more than eight concurrently active tool calls" {
    var runtime = try Runtime.init(std.testing.allocator, .{
        .io = std.testing.io,
        .memory_limit_bytes = 16 * 1024 * 1024,
        .stack_limit_bytes = 512 * 1024,
    });
    defer runtime.deinit();

    try std.testing.expectError(
        error.TooManyActiveToolCalls,
        runtime.runProgram(
            std.testing.allocator,
            \\return Promise.all([
            \\  tools.read_file({ path: "0" }),
            \\  tools.read_file({ path: "1" }),
            \\  tools.read_file({ path: "2" }),
            \\  tools.read_file({ path: "3" }),
            \\  tools.read_file({ path: "4" }),
            \\  tools.read_file({ path: "5" }),
            \\  tools.read_file({ path: "6" }),
            \\  tools.read_file({ path: "7" }),
            \\  tools.read_file({ path: "8" }),
            \\]);
        ,
            .{
                .context = undefined,
                .dispatch = undefined,
            },
        ),
    );
}

test "runtime rejects a thirty-third total tool call" {
    const Respond = struct {
        fn dispatch(
            _: *anyopaque,
            requests: []const ToolRequest,
            responses: []ToolResponse,
        ) DispatchError!void {
            for (requests, responses) |_, *response| {
                response.* = .{ .success = "null" };
            }
        }
    };
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..33) |index| {
        try source.writer.print(
            "await tools.read_file({{ path: \"{d}\" }});\n",
            .{index},
        );
    }
    try source.writer.writeAll("return null;");

    var runtime = try Runtime.init(std.testing.allocator, .{
        .io = std.testing.io,
        .memory_limit_bytes = 16 * 1024 * 1024,
        .stack_limit_bytes = 512 * 1024,
    });
    defer runtime.deinit();
    var context: u8 = 0;
    try std.testing.expectError(
        error.TooManyToolCalls,
        runtime.runProgram(
            std.testing.allocator,
            source.written(),
            .{
                .context = &context,
                .dispatch = Respond.dispatch,
            },
        ),
    );
}

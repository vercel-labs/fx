//! The embedded JavaScript engine. `run` executes one short program in a
//! fresh QuickJS runtime with limits on its heap, its time, and the native
//! stack it may use, and returns what the program produced.
//!
//! The engine is fx's fork of quickjs-ng in `quickjs/`; `quickjs/FORK.md`
//! records where it came from and what fx changed. Programs get only the
//! ECMAScript built-ins: no `std` or `os` module, files, network, processes,
//! or timers. `newContext` also leaves out the built-ins code mode doesn't
//! need. A `Host` gives a program `tools` and `console`, and nothing else
//! reaches outside the engine. Outside code imports only this file, and the
//! module imports only the standard library and its own files.

const std = @import("std");
const builtin = @import("builtin");
const qjs = @import("quickjs.zig");
const CappedHeap = @import("capped_heap.zig").CappedHeap;

pub const Limits = struct {
    /// Bytes the program's values may hold, as QuickJS counts them. Past it
    /// the program stops with `InternalError: out of memory`. QuickJS lets no
    /// program catch an `InternalError`, so a program can't swallow the
    /// limit and keep allocating.
    heap_bytes: usize = 64 * 1024 * 1024,
    /// Native stack the engine may use below the caller of `run`. The calling
    /// thread needs at least this much free stack. Deeper recursion gets a
    /// catchable `RangeError`.
    stack_bytes: usize = default_stack_bytes,
    /// JavaScript time the run may take, including promise jobs. Time spent
    /// in `Host.call_fn` doesn't count. Past it the program is stopped, and
    /// nothing it does can catch that.
    time_ms: u32 = 30_000,
    /// Tool calls one program may make. Past it each call throws a
    /// catchable `RangeError`.
    max_calls: u32 = 256,
};

/// What a program's `tools` and `console` reach. A program run without one
/// has neither.
pub const Host = struct {
    context: *anyopaque,
    /// Runs one tool call, `await tools.<name>(args)`. Any name reaches it,
    /// so the host answers an unknown one. `args_json` is the program's
    /// argument as JSON.
    call_fn: *const fn (context: *anyopaque, name: []const u8, args_json: []const u8) CallError!CallResult,
    /// Receives one `console` line.
    log_fn: *const fn (context: *anyopaque, line: []const u8) void,
};

/// A tool call's output, borrowed until the host's next call. The program
/// receives `text`, or, when `ok` is false, an `Error` whose message is
/// `text`.
pub const CallResult = struct { ok: bool, text: []const u8 };

/// `Stopped` ends the program with an error it cannot catch, such as when
/// the run is cancelled.
pub const CallError = error{ OutOfMemory, Stopped };

/// What a program produced. Text is owned by the allocator passed to `run`.
pub const Outcome = union(enum) {
    /// The program finished. The JSON text of its return value, or null
    /// when the value has no JSON form, such as `undefined`.
    returned: ?[]u8,
    /// The program threw, ran out of heap, or returned a value that could not
    /// become JSON. The text names the error and where it happened, so a
    /// model can fix the program.
    threw: []u8,
    /// The program ran past `Limits.time_ms` and was stopped.
    timed_out,
    /// The program waits on a promise that nothing left can settle.
    unsettled,

    pub fn deinit(outcome: Outcome, gpa: std.mem.Allocator) void {
        switch (outcome) {
            .returned => |json| if (json) |text| gpa.free(text),
            .threw => |text| gpa.free(text),
            .timed_out, .unsettled => {},
        }
    }
};

pub const RunError = error{OutOfMemory};

/// About 880 nested JavaScript calls in a release build. A Debug build
/// compiles the engine's C unoptimized with full checks, and each call there
/// takes about 75 times the stack, so the limit is larger to leave room for
/// the built-ins that call back into JavaScript, such as `String.match`.
const default_stack_bytes: usize = if (builtin.optimize == .debug) 4 * 1024 * 1024 else 1024 * 1024;

/// Runs `source` as the body of an async function, so it may `await` and
/// `return`, and waits for every promise job it queues. The engine's heap
/// comes from `gpa` and is gone when `run` returns; `io` is used only to
/// read the clock. Fails only when the engine cannot start or the outcome's
/// text cannot be copied.
pub fn run(gpa: std.mem.Allocator, io: std.Io, source: []const u8, limits: Limits, host: ?Host) RunError!Outcome {
    // QuickJS reads 0 as no limit at all.
    std.debug.assert(limits.heap_bytes > 0);
    std.debug.assert(limits.stack_bytes > 0);

    const program = try wrapProgram(gpa, source);
    defer gpa.free(program);

    // QuickJS's limit counts only what it hands out, so the arenas it carves
    // small blocks from need room beyond it.
    var heap: CappedHeap = .{
        .backing = gpa,
        .limit_bytes = std.math.mul(usize, limits.heap_bytes, 2) catch std.math.maxInt(usize),
    };
    const rt = qjs.JS_NewRuntime2(&CappedHeap.functions, &heap) orelse return error.OutOfMemory;
    defer qjs.JS_FreeRuntime(rt);
    qjs.JS_SetMemoryLimit(rt, limits.heap_bytes);
    qjs.JS_UpdateStackTop(rt);
    qjs.JS_SetMaxStackSize(rt, limits.stack_bytes);

    qjs.JS_SetModuleLoaderFunc(rt, null, refuseImport, null);

    var deadline: Deadline = .start(io, limits.time_ms);
    qjs.JS_SetInterruptHandler(rt, Deadline.onInterrupt, &deadline);

    const ctx = try newContext(rt);
    defer qjs.JS_FreeContext(ctx);
    var bridge: Bridge = undefined;
    if (host) |connected| {
        bridge = .{ .host = connected, .deadline = &deadline, .calls_left = limits.max_calls, .max_calls = limits.max_calls };
        try installHost(rt, ctx, &bridge);
    }

    const completion = qjs.JS_Eval(ctx, program.ptr, program.len, "<program>", qjs.eval_type_global);
    defer qjs.JS_FreeValue(ctx, completion);
    const outcome = try settle(gpa, rt, ctx, completion, &deadline);
    // Turning the result or the error into text runs the program's own
    // `toJSON` or `toString`, which the deadline stops too.
    if (deadline.hit and outcome != .timed_out) {
        outcome.deinit(gpa);
        return .timed_out;
    }
    return outcome;
}

/// Runs the program's promise jobs and reports how its completion settled.
fn settle(gpa: std.mem.Allocator, rt: *qjs.Runtime, ctx: *qjs.Context, completion: qjs.Value, deadline: *Deadline) RunError!Outcome {
    if (deadline.hit) return .timed_out;
    if (completion.isException()) return .{ .threw = try thrownText(gpa, ctx) };

    while (qjs.JS_IsJobPending(rt)) {
        if (deadline.expired()) return .timed_out;
        var job_ctx: ?*qjs.Context = null;
        if (qjs.JS_ExecutePendingJob(rt, &job_ctx) < 0) {
            if (deadline.hit) return .timed_out;
            return .{ .threw = try thrownText(gpa, job_ctx orelse ctx) };
        }
    }
    if (deadline.hit) return .timed_out;

    return switch (qjs.JS_PromiseState(ctx, completion)) {
        .pending => .unsettled,
        .fulfilled, .rejected => |state| settled: {
            const result = qjs.JS_PromiseResult(ctx, completion);
            defer qjs.JS_FreeValue(ctx, result);
            break :settled if (state == .rejected)
                .{ .threw = try describeThrown(gpa, ctx, result) }
            else
                try returnedJson(gpa, ctx, result);
        },
        // The program closed the wrapper's function itself, so the script's
        // last value is whatever it left there.
        else => try returnedJson(gpa, ctx, completion),
    };
}

/// A context with the built-ins code mode keeps. It leaves out Proxy,
/// WeakRef and FinalizationRegistry, and the typed arrays along with
/// ArrayBuffer, SharedArrayBuffer, Atomics, and DataView, none of which the
/// models' programs used. `cut_prelude` then makes those names throw an
/// error that says so, and swaps in stand-ins for `eval` and the Function
/// constructors that throw when called.
fn newContext(rt: *qjs.Runtime) error{OutOfMemory}!*qjs.Context {
    const ctx = qjs.JS_NewContextRaw(rt) orelse return error.OutOfMemory;
    errdefer qjs.JS_FreeContext(ctx);
    const groups = [_]*const fn (*qjs.Context) callconv(.c) c_int{
        qjs.JS_AddIntrinsicBaseObjects,
        qjs.JS_AddIntrinsicDate,
        // The compiler every program needs, not the global `eval`.
        qjs.JS_AddIntrinsicEval,
        qjs.JS_AddIntrinsicRegExp,
        qjs.JS_AddIntrinsicJSON,
        qjs.JS_AddIntrinsicMapSet,
        qjs.JS_AddIntrinsicPromise,
        qjs.JS_AddIntrinsicAToB,
        qjs.JS_AddPerformance,
    };
    for (groups) |add| if (add(ctx) != 0) return error.OutOfMemory;

    const done = qjs.JS_Eval(ctx, cut_prelude, cut_prelude.len, "<code mode>", qjs.eval_type_global);
    defer qjs.JS_FreeValue(ctx, done);
    if (done.isException()) {
        // The prelude throws nothing of its own, so only memory can fail it.
        qjs.JS_FreeValue(ctx, qjs.JS_GetException(ctx));
        return error.OutOfMemory;
    }
    return ctx;
}

/// Every `import()` fails: code mode has no modules to load.
fn refuseImport(ctx: ?*qjs.Context, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) ?*qjs.ModuleDef {
    _ = qjs.JS_ThrowTypeError(ctx.?, "import() is not available in code mode");
    return null;
}

/// Runs before each program. Reading a cut name throws. `eval` and each
/// Function constructor become stand-ins, so a program can still use
/// `instanceof Function`, `typeof eval`, or `fn.constructor.name`, but calling
/// one throws instead of compiling code. A program can't undo it: the
/// properties it defines are neither writable nor configurable, and no other
/// path reaches the real constructors. Direct `eval(...)` compiles code only
/// when the callee is the real `eval`, which QuickJS keeps out of reach.
const cut_prelude =
    \\(() => {
    \\  "use strict";
    \\  const fixed = (value) => ({ value, writable: false, enumerable: false, configurable: false });
    \\  const functionPrototypes = [
    \\    Function.prototype,
    \\    Object.getPrototypeOf(async function () {}),
    \\    Object.getPrototypeOf(function* () {}),
    \\    Object.getPrototypeOf(async function* () {}),
    \\  ];
    \\  for (const prototype of functionPrototypes) {
    \\    const name = prototype.constructor.name;
    \\    const standIn = {
    \\      [name]: function (body) {
    \\        throw new TypeError("The " + name + " constructor is not available in code mode");
    \\      },
    \\    }[name];
    \\    Object.defineProperty(standIn, "prototype", fixed(prototype));
    \\    Object.defineProperty(prototype, "constructor", fixed(standIn));
    \\  }
    \\  Object.defineProperty(globalThis, "Function", fixed(Function.prototype.constructor));
    \\  const evalStandIn = {
    \\    eval(code) { throw new TypeError("eval is not available in code mode"); },
    \\  }.eval;
    \\  Object.defineProperty(globalThis, "eval", fixed(evalStandIn));
    \\  const unavailable = (name) => ({
    \\    get() { throw new TypeError(name + " is not available in code mode"); },
    \\    enumerable: false,
    \\    configurable: false,
    \\  });
    \\  const names = [
    \\    "Proxy", "WeakRef", "FinalizationRegistry",
    \\    "ArrayBuffer", "SharedArrayBuffer", "Atomics", "DataView",
    \\    "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array",
    \\    "Int32Array", "Uint32Array", "Float16Array", "Float32Array", "Float64Array",
    \\    "BigInt64Array", "BigUint64Array",
    \\  ];
    \\  for (const name of names) Object.defineProperty(globalThis, name, unavailable(name));
    \\})();
;

/// What the native functions behind `tools` and `console` need, reached
/// through the context's opaque pointer.
const Bridge = struct {
    host: Host,
    deadline: *Deadline,
    calls_left: u32,
    max_calls: u32,
};

/// Takes the two host objects from the global object, where `installHost`
/// leaves them, and gives the program `tools` and `console`. Both names end
/// up neither writable nor configurable, and no program can add to `tools`.
const host_prelude =
    \\(() => {
    \\  "use strict";
    \\  const tools = globalThis.__fx_tools;
    \\  const log = globalThis.__fx_log;
    \\  delete globalThis.__fx_tools;
    \\  delete globalThis.__fx_log;
    \\  Object.preventExtensions(tools);
    \\  const text = (value) => {
    \\    if (typeof value === "string") return value;
    \\    try {
    \\      const json = JSON.stringify(value);
    \\      if (json !== undefined) return json;
    \\      return String(value);
    \\    } catch {
    \\      return "[a value that cannot be turned into text]";
    \\    }
    \\  };
    \\  const line = (...values) => log(values.map(text).join(" "));
    \\  const console = Object.freeze({ log: line, info: line, warn: line, error: line, debug: line });
    \\  Object.defineProperty(globalThis, "tools", { value: tools });
    \\  Object.defineProperty(globalThis, "console", { value: console });
    \\})();
;

/// `tools` answers every property name with a function that calls that
/// tool, so a program can reach any tool, including an MCP tool the model
/// hasn't loaded, without the engine knowing the names. It has no prototype.
const tools_class: qjs.ClassDef = .{ .class_name = "Tools", .exotic = &tools_methods };
const tools_methods: qjs.ClassExoticMethods = .{ .get_property = toolFunction };

/// Names the language itself looks up, as `await`, `JSON.stringify`, and
/// string conversion do. They read as missing, so none of those calls a tool.
const protocol_names = [_][]const u8{ "then", "toJSON", "toString", "valueOf", "constructor" };

fn installHost(rt: *qjs.Runtime, ctx: *qjs.Context, bridge: *Bridge) error{OutOfMemory}!void {
    qjs.JS_SetContextOpaque(ctx, bridge);
    var class_id: qjs.ClassId = 0;
    _ = qjs.JS_NewClassID(rt, &class_id);
    if (qjs.JS_NewClass(rt, class_id, &tools_class) != 0) return error.OutOfMemory;

    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs.JS_FreeValue(ctx, global);
    if (qjs.JS_SetPropertyStr(ctx, global, "__fx_tools", qjs.JS_NewObjectClass(ctx, class_id)) < 0 or
        qjs.JS_SetPropertyStr(ctx, global, "__fx_log", qjs.JS_NewCFunction2(ctx, logLine, "log", 1, qjs.cfunc_generic, 0)) < 0)
    {
        qjs.JS_FreeValue(ctx, qjs.JS_GetException(ctx));
        return error.OutOfMemory;
    }
    const done = qjs.JS_Eval(ctx, host_prelude, host_prelude.len, "<code mode host>", qjs.eval_type_global);
    defer qjs.JS_FreeValue(ctx, done);
    if (done.isException()) {
        // The prelude throws nothing of its own, so only memory can fail it.
        qjs.JS_FreeValue(ctx, qjs.JS_GetException(ctx));
        return error.OutOfMemory;
    }
}

/// `tools.<name>`: a function bound to the name, or undefined for a symbol
/// or one of `protocol_names`.
fn toolFunction(ctx_arg: ?*qjs.Context, _: qjs.Value, atom: qjs.Atom, _: qjs.Value) callconv(.c) qjs.Value {
    const ctx = ctx_arg.?;
    const key = qjs.JS_AtomToValue(ctx, atom);
    defer qjs.JS_FreeValue(ctx, key);
    if (key.isException()) return key;
    if (key.isSymbol()) return qjs.undefined_value;
    const name = jsText(ctx, key) orelse return qjs.exception_value;
    defer qjs.JS_FreeCString(ctx, name.ptr);
    for (protocol_names) |protocol| {
        if (std.mem.eql(u8, name, protocol)) return qjs.undefined_value;
    }
    const data = [_]qjs.Value{key};
    return qjs.JS_NewCFunctionData(ctx, callTool, 1, 0, data.len, &data);
}

fn bridgeOf(ctx: *qjs.Context) *Bridge {
    return @ptrCast(@alignCast(qjs.JS_GetContextOpaque(ctx).?));
}

/// A `tools.<name>(args)` call: `func_data[0]` is the name.
fn callTool(ctx_arg: ?*qjs.Context, _: qjs.Value, argc: c_int, argv: ?[*]const qjs.Value, _: c_int, func_data: ?[*]const qjs.Value) callconv(.c) qjs.Value {
    const ctx = ctx_arg.?;
    const bridge = bridgeOf(ctx);
    if (bridge.calls_left == 0) {
        return qjs.JS_ThrowRangeError(ctx, "This program reached its limit of %u tool calls.", @as(c_uint, bridge.max_calls));
    }
    const name = jsText(ctx, func_data.?[0]) orelse return qjs.exception_value;
    defer qjs.JS_FreeCString(ctx, name.ptr);

    const argument = if (argc > 0) argv.?[0] else qjs.undefined_value;
    const json = if (argument.isUndefined())
        qjs.JS_NewStringLen(ctx, "{}", 2)
    else
        qjs.JS_JSONStringify(ctx, argument, qjs.undefined_value, qjs.undefined_value);
    defer qjs.JS_FreeValue(ctx, json);
    if (json.isException()) return json;
    if (json.isUndefined()) return qjs.JS_ThrowTypeError(ctx, "A tool's arguments must be a value JSON can hold, such as an object.");
    const args = jsText(ctx, json) orelse return qjs.exception_value;
    defer qjs.JS_FreeCString(ctx, args.ptr);

    bridge.calls_left -= 1;
    const started = bridge.deadline.nowNs();
    const result = bridge.host.call_fn(bridge.host.context, name, args);
    bridge.deadline.excludeSince(started);
    const output = result catch |err| return switch (err) {
        error.Stopped => qjs.JS_ThrowInternalError(ctx, "the program was stopped"),
        error.OutOfMemory => qjs.JS_ThrowInternalError(ctx, "out of memory"),
    };

    const text = qjs.JS_NewStringLen(ctx, output.text.ptr, output.text.len);
    if (text.isException() or output.ok) return text;
    // Set the message directly: QuickJS's formatted throws keep only the
    // first 255 bytes, and a tool's error is often longer.
    const thrown = qjs.JS_NewError(ctx);
    if (thrown.isException()) {
        qjs.JS_FreeValue(ctx, text);
        return thrown;
    }
    if (qjs.JS_SetPropertyStr(ctx, thrown, "message", text) < 0) {
        qjs.JS_FreeValue(ctx, thrown);
        return qjs.exception_value;
    }
    return qjs.JS_Throw(ctx, thrown);
}

/// `log(line)`: hands one `console` line to the host.
fn logLine(ctx_arg: ?*qjs.Context, _: qjs.Value, argc: c_int, argv: ?[*]const qjs.Value) callconv(.c) qjs.Value {
    const ctx = ctx_arg.?;
    if (argc < 1) return qjs.undefined_value;
    const line = jsText(ctx, argv.?[0]) orelse return qjs.exception_value;
    defer qjs.JS_FreeCString(ctx, line.ptr);
    const bridge = bridgeOf(ctx);
    bridge.host.log_fn(bridge.host.context, line);
    return qjs.undefined_value;
}

/// The program as the body of an async arrow function, NUL-terminated as
/// `JS_Eval` requires. The body starts on the first line, so error positions
/// keep the program's own line numbers; columns on that line include the
/// wrapper's prefix. Owned by the caller.
fn wrapProgram(gpa: std.mem.Allocator, source: []const u8) error{OutOfMemory}![:0]u8 {
    return gpa.printSentinel("(async () => {{{s}\n}})()", .{source}, 0);
}

const Deadline = struct {
    io: std.Io,
    at_ns: i96,
    /// Set once the deadline passes; every later check fails too.
    hit: bool = false,

    fn start(io: std.Io, time_ms: u32) Deadline {
        const now = std.Io.Clock.awake.now(io).toNanoseconds();
        return .{ .io = io, .at_ns = now + @as(i96, time_ms) * std.time.ns_per_ms };
    }

    /// Moves the deadline later by the time since `since_ns`, so time spent
    /// outside JavaScript doesn't count.
    fn excludeSince(deadline: *Deadline, since_ns: i96) void {
        deadline.at_ns += std.Io.Clock.awake.now(deadline.io).toNanoseconds() - since_ns;
    }

    fn nowNs(deadline: *const Deadline) i96 {
        return std.Io.Clock.awake.now(deadline.io).toNanoseconds();
    }

    fn expired(deadline: *Deadline) bool {
        if (!deadline.hit and std.Io.Clock.awake.now(deadline.io).toNanoseconds() >= deadline.at_ns) {
            deadline.hit = true;
        }
        return deadline.hit;
    }

    /// QuickJS calls this every few thousand instructions and while a
    /// regular expression runs.
    fn onInterrupt(_: ?*qjs.Context, @"opaque": ?*anyopaque) callconv(.c) c_int {
        const deadline: *Deadline = @ptrCast(@alignCast(@"opaque".?));
        return @intFromBool(deadline.expired());
    }
};

fn returnedJson(gpa: std.mem.Allocator, ctx: *qjs.Context, value: qjs.Value) RunError!Outcome {
    const json = qjs.JS_JSONStringify(ctx, value, qjs.undefined_value, qjs.undefined_value);
    defer qjs.JS_FreeValue(ctx, json);
    if (json.isException()) return .{ .threw = try thrownText(gpa, ctx) };
    if (json.isUndefined()) return .{ .returned = null };
    const text = jsText(ctx, json) orelse return .{ .threw = try thrownText(gpa, ctx) };
    defer qjs.JS_FreeCString(ctx, text.ptr);
    return .{ .returned = try gpa.dupe(u8, text) };
}

/// Takes the context's pending exception and describes it.
fn thrownText(gpa: std.mem.Allocator, ctx: *qjs.Context) error{OutOfMemory}![]u8 {
    const thrown = qjs.JS_GetException(ctx);
    defer qjs.JS_FreeValue(ctx, thrown);
    return describeThrown(gpa, ctx, thrown);
}

/// `String(thrown)`, followed by the stack trace when `thrown` is an Error.
/// Owned by the caller.
fn describeThrown(gpa: std.mem.Allocator, ctx: *qjs.Context, thrown: qjs.Value) error{OutOfMemory}![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);

    if (jsText(ctx, thrown)) |message| {
        defer qjs.JS_FreeCString(ctx, message.ptr);
        try appendValidUtf8(gpa, &text, message);
    } else {
        // Its toString threw or ran out of memory; drop that second error.
        qjs.JS_FreeValue(ctx, qjs.JS_GetException(ctx));
        try text.appendSlice(gpa, "a thrown value that cannot be turned into text");
    }

    if (qjs.JS_IsError(thrown)) try appendStack(gpa, ctx, thrown, &text);
    return text.toOwnedSlice(gpa);
}

/// Appends an Error's stack trace on a new line. A `stack` that throws or
/// isn't a string adds nothing.
fn appendStack(gpa: std.mem.Allocator, ctx: *qjs.Context, thrown: qjs.Value, text: *std.ArrayList(u8)) error{OutOfMemory}!void {
    const stack = qjs.JS_GetPropertyStr(ctx, thrown, "stack");
    defer qjs.JS_FreeValue(ctx, stack);
    if (stack.isException()) {
        qjs.JS_FreeValue(ctx, qjs.JS_GetException(ctx));
        return;
    }
    if (!stack.isString()) return;
    const trace = jsText(ctx, stack) orelse {
        qjs.JS_FreeValue(ctx, qjs.JS_GetException(ctx));
        return;
    };
    defer qjs.JS_FreeCString(ctx, trace.ptr);
    const trimmed = std.mem.trimEnd(u8, trace, "\n");
    if (trimmed.len == 0) return;
    try text.append(gpa, '\n');
    try appendValidUtf8(gpa, text, trimmed);
}

/// QuickJS writes a lone surrogate, which a JavaScript string may hold, as
/// bytes that aren't UTF-8. Each such sequence becomes U+FFFD, so the text
/// stays valid for whoever reads it.
fn appendValidUtf8(gpa: std.mem.Allocator, text: *std.ArrayList(u8), bytes: []const u8) error{OutOfMemory}!void {
    try text.print(gpa, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

/// The value converted to UTF-8, borrowed until `JS_FreeCString`, or null
/// with an exception pending when the conversion fails.
fn jsText(ctx: *qjs.Context, value: qjs.Value) ?[]const u8 {
    var len: usize = 0;
    const ptr = qjs.JS_ToCStringLen2(ctx, &len, value, false) orelse return null;
    return ptr[0..len];
}

const testing = std.testing;

fn expectReturned(expected_json: ?[]const u8, source: []const u8, limits: Limits) !void {
    const outcome = try run(testing.allocator, testing.io, source, limits, null);
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .returned => |json| if (expected_json) |want| {
            try testing.expectEqualStrings(want, json orelse return error.TestExpectedJson);
        } else {
            try testing.expect(json == null);
        },
        else => {
            std.debug.print("expected a return, got {s}\n", .{@tagName(outcome)});
            if (outcome == .threw) std.debug.print("{s}\n", .{outcome.threw});
            return error.TestUnexpectedResult;
        },
    }
}

/// Runs `source` and expects it to throw text that contains `needle`.
fn expectThrew(needle: []const u8, source: []const u8, limits: Limits) !void {
    const outcome = try run(testing.allocator, testing.io, source, limits, null);
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .threw => |text| if (std.mem.find(u8, text, needle) == null) {
            std.debug.print("thrown text lacks \"{s}\":\n{s}\n", .{ needle, text });
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("expected a throw, got {s}\n", .{@tagName(outcome)});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectOutcome(expected: std.meta.Tag(Outcome), source: []const u8, limits: Limits) !void {
    const outcome = try run(testing.allocator, testing.io, source, limits, null);
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(expected, std.meta.activeTag(outcome));
}

test "a program returns its value as JSON" {
    try expectReturned("2", "return 1 + 1;", .{});
    try expectReturned("{\"a\":[1,\"x\",null]}", "return { a: [1, 'x', null] };", .{});
    try expectReturned("\"caf\u{e9} \u{1d11e}\"", "return 'caf\u{e9} \u{1d11e}';", .{});
    try expectReturned(null, "const x = 1;", .{});
    try expectReturned(null, "return undefined;", .{});
}

test "a program can await its own promises" {
    try expectReturned("[2,4,6]",
        \\const doubled = await Promise.all([1, 2, 3].map(async (n) => n * 2));
        \\return doubled;
    , .{});
    try expectReturned("\"done\"",
        \\let order = [];
        \\await null;
        \\queueMicrotask(() => order.push('job'));
        \\await Promise.resolve();
        \\return order.length === 1 ? 'done' : 'missing job';
    , .{});
}

test "a thrown error names what went wrong and where" {
    try expectThrew("TypeError: bad input", "throw new TypeError('bad input');", .{});
    try expectThrew("<program>:2", "const a = 1;\nnull.x;", .{});
    try expectThrew("plain text", "throw 'plain text';", .{});
    try expectThrew("SyntaxError", "return (;", .{});
    try expectThrew("rejected later", "await Promise.reject(new Error('rejected later'));", .{});
    try expectThrew("cannot be turned into text", "throw { toString() { throw 1; } };", .{});
}

test "thrown text stays valid UTF-8 when the program throws a lone surrogate" {
    for ([_][]const u8{ "throw '\\ud800';", "throw new Error('half \\udc00 a pair');" }) |source| {
        const outcome = try run(testing.allocator, testing.io, source, .{}, null);
        defer outcome.deinit(testing.allocator);
        try testing.expect(outcome == .threw);
        try testing.expect(std.unicode.utf8ValidateSlice(outcome.threw));
        try testing.expect(std.mem.find(u8, outcome.threw, "\u{fffd}") != null);
    }
}

test "a return value JSON cannot hold is reported as thrown" {
    try expectThrew("TypeError", "const a = {}; a.self = a; return a;", .{});
    try expectThrew("TypeError", "return 10n;", .{});
}

test "a program gets no host modules, files, timers, or network" {
    try expectReturned("[\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\"]",
        \\return [typeof std, typeof os, typeof require, typeof setTimeout, typeof fetch];
    , .{});
}

test "a program that never settles is reported" {
    try expectOutcome(.unsettled, "await new Promise(() => {});", .{});
}

test "the deadline stops loops, runaway regular expressions, and endless jobs" {
    const quick: Limits = .{ .time_ms = 100 };
    try expectOutcome(.timed_out, "while (true) {}", quick);
    try expectOutcome(.timed_out, "try { while (true) {} } catch (e) { return 'caught'; }", quick);
    try expectOutcome(.timed_out, "return /^(a+)+$/.test('a'.repeat(40) + 'b');", quick);
    try expectOutcome(.timed_out, "for (;;) await null;", quick);
    // Turning the result or the error into text runs the program's code too.
    try expectOutcome(.timed_out, "return { toJSON() { for (;;) {} } };", quick);
    try expectOutcome(.timed_out, "throw { toString() { for (;;) {} } };", quick);
}

test "the deadline stops built-ins that loop over a huge length" {
    // Each loop neither allocates nor calls back into JavaScript, so only
    // the deadline ends it. Without it, each runs for seconds.
    const quick: Limits = .{ .time_ms = 100 };
    const programs = [_][]const u8{
        "return Array.prototype.join.call({ length: 2 ** 27 }, '');",
        "return Array.prototype.reverse.call({ length: 2 ** 27 });",
        "return Array.prototype.shift.call({ length: 2 ** 27 });",
        "return Array.prototype.slice.call({ length: 2 ** 27 }).length;",
        "return [].concat({ length: 2 ** 27, [Symbol.isConcatSpreadable]: true }).length;",
        "return Array.prototype.flat.call({ length: 2 ** 27 }).length;",
        "return Array.prototype.sort.call({ length: 2 ** 27 }).length;",
        "const a = []; a.length = 2 ** 27; return JSON.stringify(a).length;",
        "const r = []; r.length = 2 ** 27; return JSON.stringify({ a: 1 }, r);",
        "return String.raw({ raw: { length: 2 ** 27 } }).length;",
    };
    for (programs) |source| try expectOutcome(.timed_out, source, quick);
}

test "the heap limit stops the program, and the program cannot catch it" {
    const small: Limits = .{ .heap_bytes = 16 * 1024 * 1024 };
    try expectThrew("InternalError: out of memory",
        \\const kept = [];
        \\while (true) kept.push('x'.repeat(1 << 20) + kept.length);
    , small);
    try expectThrew("InternalError: out of memory",
        \\let kept = [];
        \\try {
        \\  while (true) kept.push(new Array(1 << 16).fill(kept.length));
        \\} catch (e) {
        \\  kept = null;
        \\  return 'caught';
        \\}
    , small);
    try expectThrew("InternalError: out of memory",
        \\try { new Array(2 ** 28).fill(0); } finally { return 'finally ran'; }
    , .{});
    // Ordinary errors stay catchable.
    try expectReturned("\"caught RangeError\"",
        \\try { 'x'.repeat(-1); } catch (e) { return 'caught ' + e.name; }
    , .{});
}

test "deep recursion and deep nesting throw instead of overflowing the stack" {
    const depth = 200_000;
    try expectThrew("RangeError", "function f(n) { return f(n + 1) + 1; } return f(0);", .{});
    try expectThrew("Error", std.fmt.comptimePrint("return JSON.parse('['.repeat({d}));", .{depth}), .{});
    try expectThrew("Error", std.fmt.comptimePrint(
        \\let v = 0; for (let i = 0; i < {d}; i++) v = [v];
        \\return JSON.stringify(v).length;
    , .{depth}), .{});
    try expectThrew("Error", std.fmt.comptimePrint("return new RegExp('('.repeat({d}) + 'a' + ')'.repeat({d})).test('a');", .{ depth, depth }), .{});
    // Code mode has no `eval`, so the nesting goes in the program's own text.
    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(testing.allocator);
    try nested.appendSlice(testing.allocator, "return ");
    try nested.appendNTimes(testing.allocator, '(', depth);
    try nested.append(testing.allocator, '1');
    try nested.appendNTimes(testing.allocator, ')', depth);
    try expectThrew("RangeError: Maximum call stack size exceeded", nested.items, .{});
}

test "built-ins cut from code mode throw an error that names them" {
    try expectReturned("[]",
        \\const cut = [
        \\  "Proxy", "WeakRef", "FinalizationRegistry",
        \\  "ArrayBuffer", "SharedArrayBuffer", "Atomics", "DataView",
        \\  "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array",
        \\  "Int32Array", "Uint32Array", "Float16Array", "Float32Array", "Float64Array",
        \\  "BigInt64Array", "BigUint64Array",
        \\];
        \\const wrong = [];
        \\for (const name of cut) {
        \\  try { globalThis[name]; wrong.push(name + " was reachable"); }
        \\  catch (e) {
        \\    if (!(e instanceof TypeError) || e.message !== name + " is not available in code mode") wrong.push(name + ": " + e);
        \\  }
        \\}
        \\return wrong;
    , .{});
    try expectThrew("TypeError: Proxy is not available in code mode", "return new Proxy({}, {});", .{});
    try expectThrew("TypeError: Uint8Array is not available in code mode", "return new Uint8Array(4).length;", .{});
    // Even `typeof` reads the name, so it throws too.
    try expectThrew("TypeError: Proxy is not available in code mode", "return typeof Proxy;", .{});
}

test "no path reaches eval or the Function constructors" {
    const blocked = [_][]const u8{
        "return eval('1 + 1');",
        "return (0, eval)('1 + 1');",
        "return new Function('return 1')();",
        "return (function () {}).constructor('return 1')();",
        "return (async function () {}).constructor('return 1');",
        "return (function* () {}).constructor('yield 1');",
        "return (async function* () {}).constructor('yield 1');",
        "return Reflect.getPrototypeOf(() => 0).constructor('return 1');",
        "return Object.getOwnPropertyDescriptor(Function.prototype, 'constructor').value('return 1');",
        "return Reflect.construct(Function, ['return 1'])();",
        "return Function.prototype.constructor.call(null, 'return 1')();",
    };
    for (blocked) |source| try expectThrew("is not available in code mode", source, .{});
    try expectThrew("TypeError: The Function constructor is not available in code mode", "return Function('return 1');", .{});
    try expectThrew("TypeError: The AsyncFunction constructor is not available in code mode", "return (async () => {}).constructor('return 1');", .{});
    try expectThrew("TypeError: eval is not available in code mode", "return eval('1 + 1');", .{});
    // The program can't take the blocks back down.
    try expectThrew("TypeError", "Object.defineProperty(globalThis, 'eval', { value: (s) => s });", .{});
    try expectThrew("TypeError", "'use strict'; delete globalThis.Proxy;", .{});
    try expectThrew("TypeError", "Object.defineProperty(Function.prototype, 'constructor', { value: 1 });", .{});
}

test "programs can still name eval and the Function constructors" {
    try expectReturned("[true,true,\"Function\",\"AsyncFunction\",\"GeneratorFunction\",\"AsyncGeneratorFunction\",\"call\",\"function\",\"function\",1,true,[3,4,5]]",
        \\const f = function (a) { return this.k + a; };
        \\return [
        \\  (() => 1) instanceof Function,
        \\  (() => 1).constructor === Function,
        \\  (() => 1).constructor.name,
        \\  (async () => 1).constructor.name,
        \\  (function* () {}).constructor.name,
        \\  (async function* () {}).constructor.name,
        \\  Function.prototype.call.name,
        \\  typeof eval,
        \\  typeof Function,
        \\  Function.length,
        \\  Object.getPrototypeOf(async () => 1) === (async () => 1).constructor.prototype,
        \\  [f.call({ k: 1 }, 2), f.apply({ k: 1 }, [3]), f.bind({ k: 1 })(4)],
        \\];
    , .{});
}

test "code mode keeps the built-ins programs use" {
    try expectReturned("[\"function\",\"a,b\",3,\"x1\",true,\"18446744073709551616\",\"aGk=\",\"hi\",\"2026\",\"number\",[\"a\",1],\"y\",\"function\",\"symbol\"]",
        \\const set = new Set(["a", "b", "a"]);
        \\const map = new Map([["k", 3]]);
        \\const weak = new WeakMap([[{}, 1]]);
        \\const groups = "x1".match(/(?<letter>[a-z])(?<digit>\d)/u).groups;
        \\return [
        \\  typeof Promise.all,
        \\  [...set].join(","),
        \\  map.get("k"),
        \\  groups.letter + groups.digit,
        \\  weak instanceof WeakMap,
        \\  String(2n ** 64n),
        \\  btoa("hi"),
        \\  atob("aGk="),
        \\  new Date(Date.UTC(2026, 0, 1)).toISOString().slice(0, 4),
        \\  typeof performance.now(),
        \\  Object.entries({ a: 1 })[0],
        \\  JSON.parse('{"x":"y"}').x,
        \\  typeof Math.max,
        \\  typeof Symbol.iterator,
        \\];
    , .{});
}

/// A host for tests. It answers each tool by name, records every call, and
/// collects `console` lines.
const FakeHost = struct {
    io: std.Io,
    answer_fn: *const fn (name: []const u8, args_json: []const u8) CallResult = answerHello,
    /// Time each call takes, spent before it answers.
    delay_ms: u32 = 0,
    stopped: bool = false,
    calls: std.ArrayList(u8) = .empty,
    logs: std.ArrayList(u8) = .empty,

    fn host(fake: *FakeHost) Host {
        return .{ .context = fake, .call_fn = call, .log_fn = log };
    }

    fn deinit(fake: *FakeHost) void {
        fake.calls.deinit(testing.allocator);
        fake.logs.deinit(testing.allocator);
    }

    fn call(context: *anyopaque, name: []const u8, args_json: []const u8) CallError!CallResult {
        const fake: *FakeHost = @ptrCast(@alignCast(context));
        if (fake.stopped) return error.Stopped;
        const until = std.Io.Clock.awake.now(fake.io).toNanoseconds() + @as(i96, fake.delay_ms) * std.time.ns_per_ms;
        while (std.Io.Clock.awake.now(fake.io).toNanoseconds() < until) {}
        fake.calls.print(testing.allocator, "{s} {s}\n", .{ name, args_json }) catch return error.OutOfMemory;
        return fake.answer_fn(name, args_json);
    }

    fn log(context: *anyopaque, line: []const u8) void {
        const fake: *FakeHost = @ptrCast(@alignCast(context));
        fake.logs.print(testing.allocator, "{s}\n", .{line}) catch {};
    }
};

fn runWithHost(fake: *FakeHost, source: []const u8, limits: Limits) !Outcome {
    return run(testing.allocator, testing.io, source, limits, fake.host());
}

fn answerHello(_: []const u8, _: []const u8) CallResult {
    return .{ .ok = true, .text = "hello" };
}

test "a program calls its tools and gets their text back" {
    var fake: FakeHost = .{ .io = testing.io };
    defer fake.deinit();
    const outcome = try runWithHost(&fake, "return [await tools.read_file({ path: 'a' }), await tools.read_file()];", .{});
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings("[\"hello\",\"hello\"]", outcome.returned.?);
    try testing.expectEqualStrings("read_file {\"path\":\"a\"}\nread_file {}\n", fake.calls.items);
}

test "a failed tool call throws an Error with the tool's whole message" {
    const answer = struct {
        const message: [400]u8 = @splat('x');
        fn answer(_: []const u8, _: []const u8) CallResult {
            return .{ .ok = false, .text = &message };
        }
    }.answer;
    var fake: FakeHost = .{ .io = testing.io, .answer_fn = answer };
    defer fake.deinit();
    const outcome = try runWithHost(&fake,
        \\try { await tools.shell({ command: "false" }); } catch (e) { return [e instanceof Error, e.message.length]; }
    , .{});
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings("[true,400]", outcome.returned.?);
}

test "tools reaches any tool name and the program can't change it" {
    var fake: FakeHost = .{ .io = testing.io };
    defer fake.deinit();
    const outcome = try runWithHost(&fake,
        \\tools = null;
        \\tools.read_file = null;
        \\tools.added = 1;
        \\return [
        \\  typeof tools.read_file,
        \\  typeof tools.mcp_server_anything,
        \\  Object.isExtensible(tools),
        \\  Object.getPrototypeOf(tools),
        \\  await tools['mcp_a"b']({}),
        \\  typeof __fx_tools,
        \\  typeof __fx_log,
        \\];
    , .{});
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings(
        \\["function","function",false,null,"hello","undefined","undefined"]
    , outcome.returned.?);
    try testing.expectEqualStrings("mcp_a\"b {}\n", fake.calls.items);
}

test "the language's own lookups on tools never call a tool" {
    var fake: FakeHost = .{ .io = testing.io };
    defer fake.deinit();
    const outcome = try runWithHost(&fake,
        \\const awaited = await tools;
        \\return [
        \\  awaited === tools,
        \\  JSON.stringify(tools),
        \\  JSON.stringify({ tools }),
        \\  (() => { try { return `${tools}`; } catch (e) { return e.name; } })(),
        \\  typeof tools.then,
        \\  typeof tools[Symbol.iterator],
        \\];
    , .{});
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings(
        \\[true,"{}","{\"tools\":{}}","TypeError","undefined","undefined"]
    , outcome.returned.?);
    try testing.expectEqualStrings("", fake.calls.items);
}

test "a tool's arguments must have a JSON form" {
    var fake: FakeHost = .{ .io = testing.io };
    defer fake.deinit();
    const outcome = try runWithHost(&fake,
        \\try { await tools.read_file(() => 1); } catch (e) { return [e.name, e.message]; }
    , .{});
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings(
        \\["TypeError","A tool's arguments must be a value JSON can hold, such as an object."]
    , outcome.returned.?);
    try testing.expectEqualStrings("", fake.calls.items);
}

test "a program's tool calls stop at the call limit with a catchable RangeError" {
    var fake: FakeHost = .{ .io = testing.io };
    defer fake.deinit();
    const outcome = try runWithHost(&fake,
        \\let made = 0;
        \\try { for (;;) { await tools.read_file({}); made++; } } catch (e) { return [made, e.name]; }
    , .{ .max_calls = 3 });
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings("[3,\"RangeError\"]", outcome.returned.?);
}

test "time spent in a tool call doesn't count against the time limit" {
    var fake: FakeHost = .{ .io = testing.io, .delay_ms = 150 };
    defer fake.deinit();
    const outcome = try runWithHost(&fake, "for (let i = 0; i < 3; i++) await tools.read_file({}); return 'done';", .{ .time_ms = 100 });
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings("\"done\"", outcome.returned.?);
}

test "a stopped run ends the program with an error it cannot catch" {
    var fake: FakeHost = .{ .io = testing.io, .stopped = true };
    defer fake.deinit();
    const outcome = try runWithHost(&fake, "try { await tools.read_file({}); } catch { return 'caught'; } finally { return 'finally'; }", .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, outcome.threw, "InternalError: the program was stopped"));
}

test "console lines reach the host" {
    var fake: FakeHost = .{ .io = testing.io };
    defer fake.deinit();
    const outcome = try runWithHost(&fake,
        \\console.log("a", 1, { b: [2] }, undefined);
        \\console.error("e");
        \\const loop = {}; loop.self = loop;
        \\console.log(loop);
    , .{});
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings("a 1 {\"b\":[2]} undefined\ne\n[a value that cannot be turned into text]\n", fake.logs.items);
}

test "a program run without a host has no tools or console" {
    try expectReturned("[\"undefined\",\"undefined\"]", "return [typeof tools, typeof console];", .{});
}

/// Answers shaped like the real tools' results for the models' programs.
fn answerEvalTool(name: []const u8, args_json: []const u8) CallResult {
    const eql = std.mem.eql;
    if (eql(u8, name, "read_file")) return .{ .ok = true, .text = if (std.mem.find(u8, args_json, ".json\"") != null)
        \\{"name":"svc","port":8080,"owner":"infra"}
    else
        "line one\nTODO: two\nline three" };
    if (eql(u8, name, "glob_files")) return .{ .ok = true, .text = "services/a/service.json\nservices/b/service.json" };
    if (eql(u8, name, "mcp_tracker_get_issue")) return .{ .ok = true, .text =
    \\{"id":"T-1","status":"blocked","priority":"P0","comments":[]}
    };
    if (eql(u8, name, "mcp_tracker_search_logs")) return .{ .ok = true, .text = "ERROR payment-gateway timeout\nINFO ok" };
    return .{ .ok = true, .text = "ok" };
}

test "the models' eval programs run against the host" {
    var programs = std.mem.splitSequence(u8, @embedFile("testdata/eval_programs.js"), "\n// ----\n");
    var count: usize = 0;
    while (programs.next()) |program| {
        count += 1;
        var fake: FakeHost = .{
            .io = testing.io,
            .answer_fn = answerEvalTool,
        };
        defer fake.deinit();
        const outcome = try runWithHost(&fake, program, .{ .time_ms = 5_000 });
        defer outcome.deinit(testing.allocator);
        switch (outcome) {
            .returned => {},
            .threw => |text| {
                // Programs may trip on the stand-in data, but never on a cut.
                if (std.mem.find(u8, text, "not available in code mode") != null or
                    std.mem.find(u8, text, "Maximum call stack size exceeded") != null or
                    std.mem.startsWith(u8, text, "ReferenceError"))
                {
                    std.debug.print("program {d} hit a cut:\n{s}\n", .{ count, text });
                    return error.TestUnexpectedResult;
                }
            },
            .timed_out, .unsettled => {
                std.debug.print("program {d}: {t}\n", .{ count, outcome });
                return error.TestUnexpectedResult;
            },
        }
        try testing.expect(fake.calls.items.len > 0);
    }
    try testing.expectEqual(@as(usize, 30), count);
}

test "built-ins that call back into JavaScript fit in the default stack" {
    try expectReturned("[true,\"1\",2,\"xb\",2,1,\"1,2\"]",
        \\return [
        \\  /1/.test("1"),
        \\  "x1".match(/1/)[0],
        \\  "a,b".split(/,/).length,
        \\  "ab".replace(/a/, () => "x"),
        \\  [..."a1b2".matchAll(/\d/g)].length,
        \\  [3, 1, 2].sort((a, b) => a - b)[0],
        \\  [1, 2].map(String).join(),
        \\];
    , .{});
    const depth = if (builtin.optimize == .debug) 30 else 500;
    try expectReturned(std.fmt.comptimePrint("{d}", .{depth}), std.fmt.comptimePrint(
        \\function down(n) {{ return n === 0 ? 0 : 1 + down(n - 1); }}
        \\return down({d});
    , .{depth}), .{});
}

test "built-ins that grow buffers through QuickJS's allocator keep the function-type check" {
    // `normalize` and `localeCompare` reach `unicode_normalize`, whose
    // realloc callback the fork wraps (see quickjs/FORK.md).
    try expectReturned("[2,1,-1,0]",
        \\return [
        \\  "\u00e9".normalize("NFD").length,
        \\  "e\u0301".normalize("NFC").length,
        \\  "a".localeCompare("b"),
        \\  "\u00e9".localeCompare("e\u0301"),
        \\];
    , .{});
}

test "import() is refused with an error that says so" {
    try expectThrew("TypeError: import() is not available in code mode", "return await import('fs');", .{});
    try expectThrew("SyntaxError", "import fs from 'fs';", .{});
}

/// Tight enough that a fuzz round spends its time on new inputs, not on
/// programs that loop until the deadline.
const fuzz_limits: Limits = .{ .heap_bytes = 8 * 1024 * 1024, .time_ms = 50 };

test "fuzzed programs end in an outcome and free every byte" {
    try testing.fuzz({}, fuzzProgram, .{ .corpus = &(.{""} ++ @import("build_options").fuzz_corpus_js_program.*) });
}

fn fuzzProgram(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];
    const outcome = try run(testing.allocator, testing.io, source, fuzz_limits, null);
    outcome.deinit(testing.allocator);
}

test "fuzzed regular expressions end in an outcome and free every byte" {
    try testing.fuzz({}, fuzzRegExp, .{ .corpus = &(.{""} ++ @import("build_options").fuzz_corpus_js_regexp.*) });
}

/// The input is one flags byte, then the pattern, a 0 byte, and the subject.
fn fuzzRegExp(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [1024]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];
    if (input.len == 0) return;
    const rest = input[1..];
    const split = std.mem.findScalar(u8, rest, 0) orelse rest.len;
    const subject = if (split < rest.len) rest[split + 1 ..] else "";

    var program: std.Io.Writer.Allocating = .init(testing.allocator);
    defer program.deinit();
    const w = &program.writer;
    try w.writeAll("const re = new RegExp(");
    try writeJsString(w, rest[0..split]);
    try w.writeAll(", \"");
    // Bit i turns on the i-th flag. "u" and "v" together are a SyntaxError,
    // which is an outcome like any other.
    for ("dgimsuyv", 0..) |flag, bit| {
        if (input[0] & (@as(u8, 1) << @intCast(bit)) != 0) try w.writeByte(flag);
    }
    try w.writeAll("\");\nconst s = ");
    try writeJsString(w, subject);
    try w.writeAll(";\nreturn [re.exec(s), s.replace(re, \"<$&>\"), s.split(re).length, re.test(s)];");

    const outcome = try run(testing.allocator, testing.io, program.written(), fuzz_limits, null);
    outcome.deinit(testing.allocator);
}

test "fuzzed JSON prints back to text that parses to the same value" {
    try testing.fuzz({}, fuzzJson, .{ .corpus = &(.{""} ++ @import("build_options").fuzz_corpus_js_json.*) });
}

fn fuzzJson(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [1024]u8 = undefined;
    const text = buffer[0..smith.slice(&buffer)];

    var program: std.Io.Writer.Allocating = .init(testing.allocator);
    defer program.deinit();
    const w = &program.writer;
    try w.writeAll("const text = ");
    try writeJsString(w, text);
    try w.writeAll(
        \\;
        \\let value;
        \\try { value = JSON.parse(text); } catch (e) { return "rejected"; }
        \\const printed = JSON.stringify(value);
        \\return printed === JSON.stringify(JSON.parse(printed)) ? "stable" : "unstable: " + printed;
    );

    const outcome = try run(testing.allocator, testing.io, program.written(), fuzz_limits, null);
    defer outcome.deinit(testing.allocator);
    switch (outcome) {
        .returned => |json| {
            const result = json orelse return error.TestUnexpectedResult;
            if (!std.mem.eql(u8, result, "\"stable\"") and !std.mem.eql(u8, result, "\"rejected\"")) {
                std.debug.print("JSON did not survive a round trip: {s}\n", .{result});
                return error.TestUnexpectedResult;
            }
        },
        // Nesting deeper than the stack, or a value larger than the heap.
        .threw => |message| if (std.mem.find(u8, message, "Maximum call stack size exceeded") == null and
            std.mem.find(u8, message, "out of memory") == null)
        {
            std.debug.print("JSON round trip threw: {s}\n", .{message});
            return error.TestUnexpectedResult;
        },
        .timed_out => {},
        .unsettled => return error.TestUnexpectedResult,
    }
}

/// `bytes` as a JavaScript string literal of one `\xHH` code unit per byte,
/// so arbitrary input can't end the literal or break the program around it.
fn writeJsString(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (bytes) |byte| try w.print("\\x{x:0>2}", .{byte});
    try w.writeByte('"');
}

test "each run starts from a fresh runtime" {
    try expectReturned("1", "globalThis.counter = (globalThis.counter ?? 0) + 1; return counter;", .{});
    try expectReturned("1", "globalThis.counter = (globalThis.counter ?? 0) + 1; return counter;", .{});
}

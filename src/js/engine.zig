//! The embedded JavaScript engine. `run` executes one short program in a
//! fresh QuickJS runtime with limits on its heap, its time, and the native
//! stack it may use, and returns what the program produced.
//!
//! The engine is fx's fork of quickjs-ng in `quickjs/`; `quickjs/FORK.md`
//! records where it came from and what fx changed. Programs get only the
//! ECMAScript built-ins: no `std` or `os` module, files, network, processes,
//! or timers. Outside code imports only this file, and the module imports
//! only the standard library and its own files.

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
    /// Time the whole run may take, including promise jobs. Past it the
    /// program is stopped, and nothing it does can catch that.
    time_ms: u32 = 30_000,
};

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
pub fn run(gpa: std.mem.Allocator, io: std.Io, source: []const u8, limits: Limits) RunError!Outcome {
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

    var deadline: Deadline = .start(io, limits.time_ms);
    qjs.JS_SetInterruptHandler(rt, Deadline.onInterrupt, &deadline);

    const ctx = qjs.JS_NewContext(rt) orelse return error.OutOfMemory;
    defer qjs.JS_FreeContext(ctx);

    const completion = qjs.JS_Eval(ctx, program.ptr, program.len, "<program>", qjs.eval_type_global);
    defer qjs.JS_FreeValue(ctx, completion);
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
        try text.appendSlice(gpa, message);
    } else {
        // Its toString threw or ran out of memory; drop that second error.
        qjs.JS_FreeValue(ctx, qjs.JS_GetException(ctx));
        try text.appendSlice(gpa, "a thrown value that cannot be turned into text");
    }

    if (qjs.JS_IsError(thrown)) {
        const stack = qjs.JS_GetPropertyStr(ctx, thrown, "stack");
        defer qjs.JS_FreeValue(ctx, stack);
        if (stack.isException()) {
            qjs.JS_FreeValue(ctx, qjs.JS_GetException(ctx));
        } else if (stack.isString()) {
            if (jsText(ctx, stack)) |trace| {
                defer qjs.JS_FreeCString(ctx, trace.ptr);
                const trimmed = std.mem.trimEnd(u8, trace, "\n");
                if (trimmed.len > 0) {
                    try text.append(gpa, '\n');
                    try text.appendSlice(gpa, trimmed);
                }
            } else {
                qjs.JS_FreeValue(ctx, qjs.JS_GetException(ctx));
            }
        }
    }
    return text.toOwnedSlice(gpa);
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
    const outcome = try run(testing.allocator, testing.io, source, limits);
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
    const outcome = try run(testing.allocator, testing.io, source, limits);
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
    const outcome = try run(testing.allocator, testing.io, source, limits);
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
        \\try { new ArrayBuffer(1 << 30); } finally { return 'finally ran'; }
    , .{});
    // Ordinary errors stay catchable.
    try expectReturned("\"caught RangeError\"",
        \\try { new ArrayBuffer(-1); } catch (e) { return 'caught ' + e.name; }
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
    try expectThrew("Error", std.fmt.comptimePrint("return eval('('.repeat({d}) + '1' + ')'.repeat({d}));", .{ depth, depth }), .{});
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

test "each run starts from a fresh runtime" {
    try expectReturned("1", "globalThis.counter = (globalThis.counter ?? 0) + 1; return counter;", .{});
    try expectReturned("1", "globalThis.counter = (globalThis.counter ?? 0) + 1; return counter;", .{});
}

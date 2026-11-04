//! The part of the QuickJS C API that the engine uses, declared by hand from
//! `quickjs/quickjs.h`. fx builds without translate-c, so a change to one of
//! these declarations in the fork must be copied here.
//!
//! Every `Value` a function returns is a new reference that the caller frees
//! with `JS_FreeValue`, except where a comment says otherwise.

const std = @import("std");

pub const Runtime = opaque {};
pub const Context = opaque {};

/// `JSValue` without NaN boxing, the layout quickjs.h uses on 64-bit targets.
pub const Value = extern struct {
    u: extern union {
        uint64: u64,
        float64: f64,
        ptr: ?*anyopaque,
        short_big_int: i32,
    },
    tag: i64,

    /// `JS_VALUE_GET_TAG`: the tag is the low 32 bits.
    fn tagOf(value: Value) i32 {
        return @truncate(value.tag);
    }

    pub fn isException(value: Value) bool {
        return value.tagOf() == tag_exception;
    }

    pub fn isUndefined(value: Value) bool {
        return value.tagOf() == tag_undefined;
    }

    pub fn isString(value: Value) bool {
        const tag = value.tagOf();
        return tag == tag_string or tag == tag_string_rope;
    }
};

comptime {
    // quickjs.h switches to NaN boxing, a different `JSValue`, below 64 bits.
    if (@bitSizeOf(usize) != 64) @compileError("the QuickJS bindings assume a 64-bit target");
    std.debug.assert(@sizeOf(Value) == 16);
}

const tag_string: i32 = -7;
const tag_string_rope: i32 = -6;
const tag_undefined: i32 = 3;
const tag_exception: i32 = 6;

/// `JS_UNDEFINED`.
pub const undefined_value: Value = .{ .u = .{ .uint64 = 0 }, .tag = tag_undefined };

/// `JSMallocFunctions`. `opaque` is the pointer passed to `JS_NewRuntime2`.
pub const MallocFunctions = extern struct {
    js_calloc: *const fn (@"opaque": ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque,
    js_malloc: *const fn (@"opaque": ?*anyopaque, size: usize) callconv(.c) ?*anyopaque,
    js_free: *const fn (@"opaque": ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void,
    js_realloc: *const fn (@"opaque": ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque,
    js_malloc_usable_size: *const fn (ptr: ?*const anyopaque) callconv(.c) usize,
};

/// `JSInterruptHandler`: returning nonzero stops the running program with an
/// error it cannot catch.
pub const InterruptHandler = fn (ctx: ?*Context, @"opaque": ?*anyopaque) callconv(.c) c_int;

/// `JSPromiseStateEnum`.
pub const PromiseState = enum(c_int) {
    not_a_promise = -1,
    pending = 0,
    fulfilled = 1,
    rejected = 2,
    _,
};

/// `JS_EVAL_TYPE_GLOBAL`.
pub const eval_type_global: c_int = 0;

pub extern fn JS_NewRuntime2(mf: *const MallocFunctions, @"opaque": ?*anyopaque) ?*Runtime;
pub extern fn JS_FreeRuntime(rt: *Runtime) void;
pub extern fn JS_SetMemoryLimit(rt: *Runtime, limit: usize) void;
pub extern fn JS_SetMaxStackSize(rt: *Runtime, stack_size: usize) void;
pub extern fn JS_UpdateStackTop(rt: *Runtime) void;
pub extern fn JS_SetInterruptHandler(rt: *Runtime, cb: ?*const InterruptHandler, @"opaque": ?*anyopaque) void;
pub extern fn JS_NewContext(rt: *Runtime) ?*Context;
pub extern fn JS_FreeContext(ctx: *Context) void;
/// `input[input_len]` must be 0.
pub extern fn JS_Eval(ctx: *Context, input: [*:0]const u8, input_len: usize, filename: [*:0]const u8, eval_flags: c_int) Value;
pub extern fn JS_IsJobPending(rt: *Runtime) bool;
/// Returns 1 after running a job, 0 when none was pending, and below 0 when
/// the job raised an error; `pctx` receives the job's context.
pub extern fn JS_ExecutePendingJob(rt: *Runtime, pctx: *?*Context) c_int;
pub extern fn JS_PromiseState(ctx: *Context, promise: Value) PromiseState;
pub extern fn JS_PromiseResult(ctx: *Context, promise: Value) Value;
pub extern fn JS_GetException(ctx: *Context) Value;
pub extern fn JS_JSONStringify(ctx: *Context, obj: Value, replacer: Value, space0: Value) Value;
/// Returns null on error. Free the text with `JS_FreeCString`.
pub extern fn JS_ToCStringLen2(ctx: *Context, plen: *usize, val: Value, cesu8: bool) ?[*]const u8;
pub extern fn JS_FreeCString(ctx: *Context, ptr: [*]const u8) void;
pub extern fn JS_FreeValue(ctx: *Context, v: Value) void;
pub extern fn JS_IsError(val: Value) bool;
pub extern fn JS_GetPropertyStr(ctx: *Context, this_obj: Value, prop: [*:0]const u8) Value;

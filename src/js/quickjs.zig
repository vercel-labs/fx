//! The part of the QuickJS C API that the engine uses, declared by hand from
//! `quickjs/quickjs.h`. fx builds without translate-c, so a change to one of
//! these declarations in the fork must be copied here.
//!
//! Every `Value` a function returns is a new reference that the caller frees
//! with `JS_FreeValue`, except where a comment says otherwise.

const std = @import("std");

pub const Runtime = opaque {};
pub const Context = opaque {};
pub const ModuleDef = opaque {};

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

    pub fn isSymbol(value: Value) bool {
        return value.tagOf() == tag_symbol;
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

const tag_symbol: i32 = -8;
const tag_string: i32 = -7;
const tag_string_rope: i32 = -6;
const tag_undefined: i32 = 3;
const tag_exception: i32 = 6;

/// `JS_UNDEFINED`.
pub const undefined_value: Value = .{ .u = .{ .uint64 = 0 }, .tag = tag_undefined };
/// `JS_EXCEPTION`: what a native function returns once an exception is
/// pending.
pub const exception_value: Value = .{ .u = .{ .uint64 = 0 }, .tag = tag_exception };

/// `JSCFunction`. `argv` holds `argc` values, borrowed for the call.
pub const CFunction = fn (ctx: ?*Context, this_val: Value, argc: c_int, argv: ?[*]const Value) callconv(.c) Value;
/// `JSCFunctionData`: a `CFunction` that also gets the values it was made
/// with.
pub const CFunctionData = fn (ctx: ?*Context, this_val: Value, argc: c_int, argv: ?[*]const Value, magic: c_int, func_data: ?[*]const Value) callconv(.c) Value;

pub const Atom = u32;
pub const ClassId = u32;

/// `JSClassExoticMethods`. fx sets only `get_property`; the others keep
/// QuickJS's ordinary behavior.
pub const ClassExoticMethods = extern struct {
    get_own_property: ?*const anyopaque = null,
    get_own_property_names: ?*const anyopaque = null,
    delete_property: ?*const anyopaque = null,
    define_own_property: ?*const anyopaque = null,
    has_property: ?*const anyopaque = null,
    get_property: ?*const fn (ctx: ?*Context, obj: Value, atom: Atom, receiver: Value) callconv(.c) Value = null,
    set_property: ?*const anyopaque = null,
};

/// `JSClassDef`.
pub const ClassDef = extern struct {
    class_name: [*:0]const u8,
    finalizer: ?*const anyopaque = null,
    gc_mark: ?*const anyopaque = null,
    call: ?*const anyopaque = null,
    exotic: ?*const ClassExoticMethods = null,
};
/// `JS_CFUNC_generic`.
pub const cfunc_generic: c_int = 0;

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

/// `JSModuleNormalizeFunc`: returns the resolved name, allocated with
/// `js_malloc`, or null with an exception pending.
pub const ModuleNormalizeFunc = fn (ctx: ?*Context, module_base_name: [*:0]const u8, module_name: [*:0]const u8, @"opaque": ?*anyopaque) callconv(.c) ?[*:0]u8;

/// `JSModuleLoaderFunc`: returns the loaded module, or null with an
/// exception pending.
pub const ModuleLoaderFunc = fn (ctx: ?*Context, module_name: [*:0]const u8, @"opaque": ?*anyopaque) callconv(.c) ?*ModuleDef;

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
/// A null `module_normalize` keeps QuickJS's own name resolution.
pub extern fn JS_SetModuleLoaderFunc(rt: *Runtime, module_normalize: ?*const ModuleNormalizeFunc, module_loader: ?*const ModuleLoaderFunc, @"opaque": ?*anyopaque) void;
/// `fmt` is a printf format. Returns `JS_EXCEPTION`, which holds no reference.
pub extern fn JS_ThrowTypeError(ctx: *Context, fmt: [*:0]const u8, ...) Value;
/// A context with only the basic objects; the `JS_AddIntrinsic*` and
/// `JS_AddPerformance` calls each add a group of built-ins and return 0, or
/// -1 when out of memory.
pub extern fn JS_NewContextRaw(rt: *Runtime) ?*Context;
pub extern fn JS_AddIntrinsicBaseObjects(ctx: *Context) c_int;
pub extern fn JS_AddIntrinsicDate(ctx: *Context) c_int;
pub extern fn JS_AddIntrinsicEval(ctx: *Context) c_int;
pub extern fn JS_AddIntrinsicRegExp(ctx: *Context) c_int;
pub extern fn JS_AddIntrinsicJSON(ctx: *Context) c_int;
pub extern fn JS_AddIntrinsicMapSet(ctx: *Context) c_int;
pub extern fn JS_AddIntrinsicPromise(ctx: *Context) c_int;
pub extern fn JS_AddIntrinsicAToB(ctx: *Context) c_int;
pub extern fn JS_AddPerformance(ctx: *Context) c_int;
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
/// Takes ownership of `val`. Returns -1 with an exception pending on failure.
pub extern fn JS_SetPropertyStr(ctx: *Context, this_obj: Value, prop: [*:0]const u8, val: Value) c_int;
pub extern fn JS_GetGlobalObject(ctx: *Context) Value;
pub extern fn JS_NewCFunction2(ctx: *Context, func: *const CFunction, name: [*:0]const u8, length: c_int, cproto: c_int, magic: c_int) Value;
pub extern fn JS_NewStringLen(ctx: *Context, str: [*]const u8, len: usize) Value;
pub extern fn JS_NewError(ctx: *Context) Value;
/// Takes ownership of `obj` and returns `exception_value`.
pub extern fn JS_Throw(ctx: *Context, obj: Value) Value;
pub extern fn JS_ThrowRangeError(ctx: *Context, fmt: [*:0]const u8, ...) Value;
pub extern fn JS_ThrowInternalError(ctx: *Context, fmt: [*:0]const u8, ...) Value;
pub extern fn JS_SetContextOpaque(ctx: *Context, @"opaque": ?*anyopaque) void;
/// Allocates an id from `rt` when `pclass_id` points to 0.
pub extern fn JS_NewClassID(rt: *Runtime, pclass_id: *ClassId) ClassId;
pub extern fn JS_NewClass(rt: *Runtime, class_id: ClassId, class_def: *const ClassDef) c_int;
pub extern fn JS_NewObjectClass(ctx: *Context, class_id: ClassId) Value;
pub extern fn JS_AtomToValue(ctx: *Context, atom: Atom) Value;
pub extern fn JS_NewCFunctionData(ctx: *Context, func: *const CFunctionData, length: c_int, magic: c_int, data_len: c_int, data: [*]const Value) Value;
pub extern fn JS_GetContextOpaque(ctx: *Context) ?*anyopaque;

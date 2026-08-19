const std = @import("std");
const builtin = @import("builtin");

pub const State = opaque {};

pub const CFunction = *const fn (L: ?*State) callconv(.c) c_int;
pub const KFunction = *const fn (L: ?*State, status: c_int, ctx: KContext) callconv(.c) c_int;
pub const Integer = i64;
pub const Number = f64;
pub const Unsigned = u64;
pub const KContext = isize;

pub const OK: c_int = 0;
pub const YIELD: c_int = 1;
pub const ERRRUN: c_int = 2;
pub const ERRSYNTAX: c_int = 3;
pub const ERRMEM: c_int = 4;
pub const ERRERR: c_int = 5;
pub const ERRFILE: c_int = 6;

pub const TNONE: c_int = -1;
pub const TNIL: c_int = 0;
pub const TBOOLEAN: c_int = 1;
pub const TLIGHTUSERDATA: c_int = 2;
pub const TNUMBER: c_int = 3;
pub const TSTRING: c_int = 4;
pub const TTABLE: c_int = 5;
pub const TFUNCTION: c_int = 6;
pub const TUSERDATA: c_int = 7;
pub const TTHREAD: c_int = 8;

pub const MULTRET: c_int = -1;
pub const MINSTACK: c_int = 20;
pub const NOREF: c_int = -2;
pub const REFNIL: c_int = -1;

const max_stack: c_int = if (@bitSizeOf(c_int) >= 32) 1_000_000 else 15_000;
pub const REGISTRYINDEX: c_int = -max_stack - 1000;

pub const RIDX_MAINTHREAD: Integer = 1;
pub const RIDX_GLOBALS: Integer = 2;

pub extern fn luaL_newstate() ?*State;
pub extern fn lua_close(L: ?*State) void;
pub extern fn luaL_openlibs(L: ?*State) void;
pub extern fn lua_gettop(L: ?*State) c_int;
pub extern fn lua_settop(L: ?*State, idx: c_int) void;
pub extern fn lua_pushvalue(L: ?*State, idx: c_int) void;
pub extern fn lua_rotate(L: ?*State, idx: c_int, n: c_int) void;
pub extern fn lua_type(L: ?*State, idx: c_int) c_int;
pub extern fn lua_typename(L: ?*State, tp: c_int) [*:0]const u8;
pub extern fn lua_toboolean(L: ?*State, idx: c_int) c_int;
pub extern fn lua_tointegerx(L: ?*State, idx: c_int, isnum: ?*c_int) Integer;
pub extern fn lua_tonumberx(L: ?*State, idx: c_int, isnum: ?*c_int) Number;
pub extern fn lua_tolstring(L: ?*State, idx: c_int, len: ?*usize) ?[*:0]const u8;
pub extern fn lua_touserdata(L: ?*State, idx: c_int) ?*anyopaque;
pub extern fn lua_topointer(L: ?*State, idx: c_int) ?*const anyopaque;
pub extern fn lua_pushnil(L: ?*State) void;
pub extern fn lua_pushboolean(L: ?*State, b: c_int) void;
pub extern fn lua_pushinteger(L: ?*State, n: Integer) void;
pub extern fn lua_pushnumber(L: ?*State, n: Number) void;
pub extern fn lua_pushlstring(L: ?*State, s: [*]const u8, len: usize) ?[*:0]const u8;
pub extern fn lua_pushstring(L: ?*State, s: [*:0]const u8) ?[*:0]const u8;
pub extern fn lua_pushcclosure(L: ?*State, fn_: CFunction, n: c_int) void;
pub extern fn lua_pushlightuserdata(L: ?*State, p: ?*anyopaque) void;
pub extern fn lua_createtable(L: ?*State, narr: c_int, nrec: c_int) void;
pub extern fn lua_getglobal(L: ?*State, name: [*:0]const u8) c_int;
pub extern fn lua_setglobal(L: ?*State, name: [*:0]const u8) void;
pub extern fn lua_getfield(L: ?*State, idx: c_int, k: [*:0]const u8) c_int;
pub extern fn lua_setfield(L: ?*State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_setmetatable(L: ?*State, objindex: c_int) c_int;
pub extern fn lua_gettable(L: ?*State, idx: c_int) c_int;
pub extern fn lua_settable(L: ?*State, idx: c_int) void;
pub extern fn lua_rawget(L: ?*State, idx: c_int) c_int;
pub extern fn lua_rawset(L: ?*State, idx: c_int) void;
pub extern fn lua_rawgeti(L: ?*State, idx: c_int, n: Integer) c_int;
pub extern fn lua_rawseti(L: ?*State, idx: c_int, n: Integer) void;
pub extern fn lua_rawgetp(L: ?*State, idx: c_int, p: *const anyopaque) c_int;
pub extern fn lua_rawsetp(L: ?*State, idx: c_int, p: *const anyopaque) void;
pub extern fn lua_next(L: ?*State, idx: c_int) c_int;
pub extern fn lua_pcallk(
    L: ?*State,
    nargs: c_int,
    nresults: c_int,
    errfunc: c_int,
    ctx: KContext,
    k: ?KFunction,
) c_int;
pub extern fn lua_callk(
    L: ?*State,
    nargs: c_int,
    nresults: c_int,
    ctx: KContext,
    k: ?KFunction,
) void;
pub extern fn lua_error(L: ?*State) c_int;
pub extern fn luaL_loadfilex(L: ?*State, filename: [*:0]const u8, mode: ?[*:0]const u8) c_int;
pub extern fn luaL_loadstring(L: ?*State, s: [*:0]const u8) c_int;
pub extern fn luaL_loadbufferx(
    L: ?*State,
    buff: [*]const u8,
    sz: usize,
    name: [*:0]const u8,
    mode: ?[*:0]const u8,
) c_int;
pub extern fn luaL_ref(L: ?*State, t: c_int) c_int;
pub extern fn luaL_unref(L: ?*State, t: c_int, ref: c_int) void;
pub extern fn luaL_traceback(L: ?*State, L1: ?*State, msg: ?[*:0]const u8, level: c_int) void;
pub extern fn luaL_checklstring(L: ?*State, arg: c_int, len: ?*usize) [*:0]const u8;
pub extern fn luaL_optlstring(L: ?*State, arg: c_int, def: [*:0]const u8, len: ?*usize) [*:0]const u8;
pub extern fn luaL_checktype(L: ?*State, arg: c_int, t: c_int) void;
pub extern fn luaL_argerror(L: ?*State, arg: c_int, extramsg: [*:0]const u8) c_int;
pub extern fn lua_absindex(L: ?*State, idx: c_int) c_int;
pub extern fn lua_checkstack(L: ?*State, n: c_int) c_int;

pub fn checkstack(L: ?*State, n: c_int) bool {
    return lua_checkstack(L, n) != 0;
}
pub extern fn lua_iscfunction(L: ?*State, idx: c_int) c_int;
pub extern fn lua_tocfunction(L: ?*State, idx: c_int) ?CFunction;

pub fn pop(L: ?*State, n: c_int) void {
    lua_settop(L, -n - 1);
}

pub fn pcall(L: ?*State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    return lua_pcallk(L, nargs, nresults, errfunc, 0, null);
}

pub fn pushcfunction(L: ?*State, fn_: CFunction) void {
    lua_pushcclosure(L, fn_, 0);
}

pub fn newtable(L: ?*State) void {
    lua_createtable(L, 0, 0);
}

pub fn insert(L: ?*State, idx: c_int) void {
    lua_rotate(L, idx, 1);
}

pub fn tostring(L: ?*State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const ptr = lua_tolstring(L, idx, &len) orelse return null;
    return ptr[0..len];
}

pub fn pushslice(L: ?*State, s: []const u8) void {
    if (s.len == 0) {
        _ = lua_pushlstring(L, &[_]u8{0}, 0);
        return;
    }
    _ = lua_pushlstring(L, s.ptr, s.len);
}

pub fn isnoneornil(L: ?*State, idx: c_int) bool {
    const tp = lua_type(L, idx);
    return tp == TNONE or tp == TNIL;
}

pub fn isfunction(L: ?*State, idx: c_int) bool {
    return lua_type(L, idx) == TFUNCTION;
}

pub fn istable(L: ?*State, idx: c_int) bool {
    return lua_type(L, idx) == TTABLE;
}

pub fn isstring(L: ?*State, idx: c_int) bool {
    const tp = lua_type(L, idx);
    return tp == TSTRING or tp == TNUMBER;
}

pub fn tointeger(L: ?*State, idx: c_int) Integer {
    return lua_tointegerx(L, idx, null);
}

pub fn extraspace(L: *State) *?*anyopaque {
    const bytes: [*]u8 = @ptrCast(L);
    return @ptrCast(@alignCast(bytes - @sizeOf(*anyopaque)));
}

pub fn raise(L: ?*State, message: []const u8) c_int {
    pushslice(L, message);
    return lua_error(L);
}

pub fn upvalue(i: c_int) c_int {
    return REGISTRYINDEX - i;
}

comptime {
    if (builtin.cpu.arch.endian() == .little) {
        std.debug.assert(@sizeOf(Integer) == 8);
    }
}

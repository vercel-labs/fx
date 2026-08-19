const std = @import("std");
const builtin = @import("builtin");
const command_specs = @import("../slash_commands/command_specs.zig");
const hooks = @import("../hooks/hooks.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const SlashSpec = command_specs.SlashSpec;
const SlashRegistry = command_specs.SlashRegistry;

pub const enabled = !host_target.is_wasm;

const lua = if (enabled) @import("lua.zig") else struct {
    pub const State = opaque {};
    pub const CFunction = *const fn (L: ?*State) callconv(.c) c_int;
};

pub const Notice = struct {
    tone: types.NoticeTone,
    body: []u8,
};

pub const Host = struct {
    ctx: *anyopaque = undefined,
    notify: *const fn (ctx: *anyopaque, message: []const u8, tone: types.NoticeTone) void = silentNotify,
    model: *const fn (ctx: *anyopaque) []const u8 = emptyString,
    provider: *const fn (ctx: *anyopaque) []const u8 = emptyString,
    get_opt: *const fn (ctx: *anyopaque, alloc: Allocator, key: []const u8) anyerror!?[]u8 = missingOpt,
    set_opt: *const fn (ctx: *anyopaque, key: []const u8, value: []const u8) anyerror!void = rejectOpt,
    open_view: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void = rejectView,
    allow_process: *const fn (ctx: *anyopaque) bool = denyProcess,
};

const RegisteredCommand = struct {
    slash: []u8,
    description: []u8,
    lua_ref: c_int,
};

const RegisteredKeymap = struct {
    byte: u8,
    lua_ref: c_int,
};

const RegisteredHook = struct {
    kind: hooks.HookKind,
    lua_ref: c_int,
};

pub const Runtime = struct {
    alloc: Allocator = std.heap.page_allocator,
    host: Host = .{},
    mutex: std.Io.Mutex = .init,
    state: ?*lua.State = null,
    home: []u8 = &.{},
    workspace_root: []u8 = &.{},
    builtin_specs: []const SlashSpec = &.{},
    combined_specs: []SlashSpec = &.{},
    loaded_files: std.ArrayList([]u8) = .empty,
    commands: std.ArrayList(RegisteredCommand) = .empty,
    keymaps: std.ArrayList(RegisteredKeymap) = .empty,
    lua_hooks: std.ArrayList(RegisteredHook) = .empty,
    notices: std.ArrayList(Notice) = .empty,
    hook_text: std.ArrayList(u8) = .empty,

    pub fn init(alloc: Allocator) Runtime {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Runtime) void {
        self.closeState();
        self.freeOwned();
        self.* = .{ .alloc = self.alloc };
    }

    pub fn setBuiltinSlashSpecs(self: *Runtime, specs: []const SlashSpec) void {
        self.builtin_specs = specs;
    }

    pub fn slashRegistry(self: *const Runtime, builtins: SlashRegistry) SlashRegistry {
        if (self.combined_specs.len == 0) return builtins;
        return .{ .commands = self.combined_specs };
    }

    pub fn bindHost(self: *Runtime, host: Host) void {
        self.host = host;
    }

    pub fn loadInit(self: *Runtime, home: ?[]const u8, workspace_root: []const u8) void {
        if (comptime !enabled) return;
        if (workspace_root.len == 0) return;
        self.lock();
        defer self.unlock();
        self.resetSession(home, workspace_root);
        self.ensureState() catch |err| {
            self.addNotice(.@"error", "Lua runtime failed to start ({s}).", .{@errorName(err)}) catch {};
            return;
        };
        if (home) |home_dir| {
            if (profile_paths.initLuaPath(self.alloc, home_dir)) |path| {
                defer self.alloc.free(path);
                self.loadFile(path);
            } else |_| {}
        }
        if (profile_paths.workspaceInitLuaPath(self.alloc, workspace_root)) |path| {
            defer self.alloc.free(path);
            self.loadFile(path);
        } else |_| {}
        self.rebuildCombinedSpecs() catch {};
    }

    pub fn reload(self: *Runtime) void {
        if (comptime !enabled) return;
        const home = if (self.home.len == 0) null else self.home;
        const workspace = self.alloc.dupe(u8, self.workspace_root) catch {
            self.addNotice(.@"error", "Lua reload failed (OutOfMemory).", .{}) catch {};
            return;
        };
        defer self.alloc.free(workspace);
        var home_copy: ?[]u8 = null;
        defer if (home_copy) |value| self.alloc.free(value);
        if (home) |dir| {
            home_copy = self.alloc.dupe(u8, dir) catch {
                self.addNotice(.@"error", "Lua reload failed (OutOfMemory).", .{}) catch {};
                return;
            };
        }
        self.loadInit(if (home_copy) |dir| dir else null, workspace);
    }

    pub fn statusText(self: *const Runtime, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        if (comptime !enabled) {
            try out.writer.writeAll("Lua is not available on this host.");
            return out.toOwnedSlice();
        }
        if (self.state == null) {
            try out.writer.writeAll("Lua is not loaded.");
            return out.toOwnedSlice();
        }
        try out.writer.writeAll("Loaded:");
        if (self.loaded_files.items.len == 0) {
            try out.writer.writeAll("\n  (none)");
        } else {
            for (self.loaded_files.items) |path| {
                try out.writer.writeAll("\n  ");
                try out.writer.writeAll(path);
            }
        }
        try out.writer.writeAll("\nCommands:");
        if (self.commands.items.len == 0) {
            try out.writer.writeAll("\n  (none)");
        } else {
            for (self.commands.items) |command| {
                try out.writer.writeAll("\n  ");
                try out.writer.writeAll(command.slash);
                if (command.description.len > 0) {
                    try out.writer.writeAll("  ");
                    try out.writer.writeAll(command.description);
                }
            }
        }
        return out.toOwnedSlice();
    }

    pub fn takeNotices(self: *Runtime) []Notice {
        const items = self.notices.toOwnedSlice(self.alloc) catch return &.{};
        self.notices = .empty;
        return items;
    }

    pub fn freeNotices(self: *Runtime, items: []Notice) void {
        for (items) |notice| self.alloc.free(notice.body);
        if (items.len > 0) self.alloc.free(items);
    }

    pub fn hasCommand(self: *const Runtime, slash: []const u8) bool {
        return self.findCommand(slash) != null;
    }

    pub fn invokeCommand(self: *Runtime, slash: []const u8, payload: []const u8) void {
        if (comptime !enabled) return;
        const command = self.findCommand(slash) orelse {
            self.addNotice(.@"error", "Unknown Lua command {s}.", .{slash}) catch {};
            return;
        };
        const L = self.state orelse return;
        self.lock();
        defer self.unlock();
        if (!lua.checkstack(L, 4)) {
            self.addNotice(.@"error", "Lua stack overflow while running {s}.", .{slash}) catch {};
            return;
        }
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, command.lua_ref);
        lua.pushslice(L, payload);
        if (lua.pcall(L, 1, 0, 0) != lua.OK) {
            const err = lua.tostring(L, -1) orelse "Lua command failed";
            self.addNotice(.@"error", "{s}: {s}", .{ slash, err }) catch {};
            lua.pop(L, 1);
        }
    }

    pub fn dispatchKeymap(self: *Runtime, byte: u8) bool {
        if (comptime !enabled) return false;
        const keymap = self.findKeymap(byte) orelse return false;
        const L = self.state orelse return false;
        self.lock();
        defer self.unlock();
        if (!lua.checkstack(L, 2)) return false;
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, keymap.lua_ref);
        if (lua.pcall(L, 0, 0, 0) != lua.OK) {
            const err = lua.tostring(L, -1) orelse "Lua keymap failed";
            self.addNotice(.@"error", "{s}", .{err}) catch {};
            lua.pop(L, 1);
        }
        return true;
    }

    pub fn registerLifecycleHooks(self: *Runtime, lifecycle: *hooks.Runtime) !void {
        if (comptime !enabled) return;
        try lifecycle.registerPreToolUse(.{
            .name = "fx.lua.pre_tool_use",
            .ctx = self,
            .run = preToolUseTrampoline,
        });
        try lifecycle.registerStop(.{
            .name = "fx.lua.stop",
            .ctx = self,
            .run = stopTrampoline,
        });
        try lifecycle.registerPostTurnEnd(.{
            .name = "fx.lua.post_turn_end",
            .ctx = self,
            .run = postTurnEndTrampoline,
        });
        try lifecycle.registerAttentionRequired(.{
            .name = "fx.lua.attention_required",
            .ctx = self,
            .run = attentionRequiredTrampoline,
        });
    }

    fn resetSession(self: *Runtime, home: ?[]const u8, workspace_root: []const u8) void {
        self.closeState();
        self.clearRegistrations();
        if (self.home.len > 0) {
            self.alloc.free(self.home);
            self.home = &.{};
        }
        if (self.workspace_root.len > 0) {
            self.alloc.free(self.workspace_root);
            self.workspace_root = &.{};
        }
        if (home) |dir| {
            self.home = self.alloc.dupe(u8, dir) catch &.{};
        }
        self.workspace_root = self.alloc.dupe(u8, workspace_root) catch &.{};
    }

    fn ensureState(self: *Runtime) !void {
        if (comptime !enabled) return;
        if (self.state != null) return;
        const L = lua.luaL_newstate() orelse return error.LuaInitFailed;
        errdefer lua.lua_close(L);
        lua.extraspace(L).* = self;
        lua.luaL_openlibs(L);
        self.installSandbox(L);
        self.installApi(L);
        self.state = L;
    }

    fn closeState(self: *Runtime) void {
        if (comptime !enabled) return;
        if (self.state) |L| {
            lua.lua_close(L);
            self.state = null;
        }
    }

    fn clearRegistrations(self: *Runtime) void {
        for (self.loaded_files.items) |path| self.alloc.free(path);
        self.loaded_files.clearRetainingCapacity();
        for (self.commands.items) |command| {
            self.alloc.free(command.slash);
            self.alloc.free(command.description);
        }
        self.commands.clearRetainingCapacity();
        self.keymaps.clearRetainingCapacity();
        self.lua_hooks.clearRetainingCapacity();
        if (self.combined_specs.len > 0) {
            self.alloc.free(self.combined_specs);
            self.combined_specs = &.{};
        }
    }

    fn freeOwned(self: *Runtime) void {
        self.clearRegistrations();
        self.loaded_files.deinit(self.alloc);
        self.commands.deinit(self.alloc);
        self.keymaps.deinit(self.alloc);
        self.lua_hooks.deinit(self.alloc);
        self.hook_text.deinit(self.alloc);
        self.freeNotices(self.takeNotices());
        self.notices.deinit(self.alloc);
        if (self.home.len > 0) self.alloc.free(self.home);
        if (self.workspace_root.len > 0) self.alloc.free(self.workspace_root);
        self.home = &.{};
        self.workspace_root = &.{};
    }

    fn loadFile(self: *Runtime, path: []const u8) void {
        if (comptime !enabled) return;
        const L = self.state orelse return;
        std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return;
        const path_z = self.alloc.dupeZ(u8, path) catch {
            self.addNotice(.@"error", "Lua failed to load {s} (OutOfMemory).", .{path}) catch {};
            return;
        };
        defer self.alloc.free(path_z);
        if (lua.luaL_loadfilex(L, path_z, null) != lua.OK) {
            const err = lua.tostring(L, -1) orelse "failed to load Lua file";
            self.addNotice(.@"error", "{s}", .{err}) catch {};
            lua.pop(L, 1);
            return;
        }
        if (lua.pcall(L, 0, 0, 0) != lua.OK) {
            const err = lua.tostring(L, -1) orelse "Lua file failed";
            self.addNotice(.@"error", "{s}", .{err}) catch {};
            lua.pop(L, 1);
            return;
        }
        const copied = self.alloc.dupe(u8, path) catch return;
        self.loaded_files.append(self.alloc, copied) catch {
            self.alloc.free(copied);
        };
    }

    fn rebuildCombinedSpecs(self: *Runtime) !void {
        if (self.combined_specs.len > 0) {
            self.alloc.free(self.combined_specs);
            self.combined_specs = &.{};
        }
        if (self.commands.items.len == 0) return;
        const builtins = self.builtin_specs;
        const next = try self.alloc.alloc(SlashSpec, builtins.len + self.commands.items.len);
        if (builtins.len > 0) @memcpy(next[0..builtins.len], builtins);
        for (self.commands.items, 0..) |command, i| {
            next[builtins.len + i] = .{
                .kind = .lua,
                .command = command.slash,
                .help_entry = command.slash,
                .completion_description = if (command.description.len == 0)
                    "Lua command"
                else
                    command.description,
                .presentation_category = .extensions,
                .has_args = true,
                .accepts_payload = true,
            };
        }
        self.combined_specs = next;
    }

    fn findCommand(self: *const Runtime, slash: []const u8) ?*const RegisteredCommand {
        for (self.commands.items) |*command| {
            if (std.mem.eql(u8, command.slash, slash)) return command;
        }
        return null;
    }

    fn findKeymap(self: *const Runtime, byte: u8) ?*const RegisteredKeymap {
        var i = self.keymaps.items.len;
        while (i > 0) {
            i -= 1;
            if (self.keymaps.items[i].byte == byte) return &self.keymaps.items[i];
        }
        return null;
    }

    fn addNotice(self: *Runtime, tone: types.NoticeTone, comptime fmt: []const u8, args: anytype) !void {
        const body = try std.fmt.allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(body);
        try self.notices.append(self.alloc, .{ .tone = tone, .body = body });
    }

    fn lock(self: *Runtime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
    }

    fn unlock(self: *Runtime) void {
        self.mutex.unlock(io_mod.getIo());
    }

    fn current(L: ?*lua.State) ?*Runtime {
        if (comptime !enabled) return null;
        const state = L orelse return null;
        const extra = lua.extraspace(state).*;
        return @ptrCast(@alignCast(extra orelse return null));
    }

    fn installSandbox(self: *Runtime, L: *lua.State) void {
        if (comptime !enabled) return;
        _ = lua.lua_getglobal(L, "os");
        if (lua.istable(L, -1)) {
            wrapField(L, "execute", sandboxedExecute);
            wrapField(L, "remove", sandboxedDenied);
            wrapField(L, "rename", sandboxedDenied);
        }
        lua.pop(L, 1);

        _ = lua.lua_getglobal(L, "io");
        if (lua.istable(L, -1)) {
            wrapField(L, "popen", sandboxedPopen);
            wrapField(L, "open", sandboxedOpen);
        }
        lua.pop(L, 1);

        lua.pushcfunction(L, sandboxedLoadfile);
        lua.lua_setglobal(L, "loadfile");
        lua.pushcfunction(L, sandboxedDofile);
        lua.lua_setglobal(L, "dofile");

        _ = lua.lua_getglobal(L, "package");
        if (lua.istable(L, -1)) {
            const path = self.packagePath() catch "";
            defer if (path.len > 0) self.alloc.free(path);
            lua.pushslice(L, path);
            lua.lua_setfield(L, -2, "path");
            _ = lua.lua_pushstring(L, "");
            lua.lua_setfield(L, -2, "cpath");
            lua.pushcfunction(L, sandboxedLoadlib);
            lua.lua_setfield(L, -2, "loadlib");
            _ = lua.lua_getfield(L, -1, "searchers");
            if (lua.istable(L, -1)) {
                lua.lua_pushnil(L);
                lua.lua_rawseti(L, -2, 3);
                lua.lua_pushnil(L);
                lua.lua_rawseti(L, -2, 4);
            }
            lua.pop(L, 1);
        }
        lua.pop(L, 1);
    }

    fn wrapField(L: *lua.State, name: [*:0]const u8, replacement: lua.CFunction) void {
        _ = lua.lua_getfield(L, -1, name);
        lua.lua_pushcclosure(L, replacement, 1);
        lua.lua_setfield(L, -2, name);
    }

    fn packagePath(self: *Runtime) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        var first = true;
        if (self.home.len > 0) {
            try appendPackageEntry(&out.writer, &first, self.home, ".fx/lua/?.lua");
            try appendPackageEntry(&out.writer, &first, self.home, ".fx/lua/?/init.lua");
            try appendPackageEntry(&out.writer, &first, self.home, ".fx/pack/?/lua/?.lua");
            try appendPackageEntry(&out.writer, &first, self.home, ".fx/pack/?/lua/?/init.lua");
        }
        if (self.workspace_root.len > 0) {
            try appendPackageEntry(&out.writer, &first, self.workspace_root, ".fx/lua/?.lua");
            try appendPackageEntry(&out.writer, &first, self.workspace_root, ".fx/lua/?/init.lua");
            try appendPackageEntry(&out.writer, &first, self.workspace_root, ".fx/?/init.lua");
        }
        return out.toOwnedSlice();
    }

    fn installApi(self: *Runtime, L: *lua.State) void {
        _ = self;
        if (comptime !enabled) return;
        lua.newtable(L);
        lua.pushcfunction(L, apiCommand);
        lua.lua_setfield(L, -2, "command");
        lua.pushcfunction(L, apiKeymap);
        lua.lua_setfield(L, -2, "keymap");
        lua.pushcfunction(L, apiHook);
        lua.lua_setfield(L, -2, "hook");
        lua.pushcfunction(L, apiNotify);
        lua.lua_setfield(L, -2, "notify");
        lua.pushcfunction(L, apiModel);
        lua.lua_setfield(L, -2, "model");
        lua.pushcfunction(L, apiProvider);
        lua.lua_setfield(L, -2, "provider");

        lua.newtable(L);
        lua.newtable(L);
        lua.pushcfunction(L, apiOptIndex);
        lua.lua_setfield(L, -2, "__index");
        lua.pushcfunction(L, apiOptNewindex);
        lua.lua_setfield(L, -2, "__newindex");
        _ = lua.lua_setmetatable(L, -2);
        lua.lua_setfield(L, -2, "opt");

        lua.newtable(L);
        lua.pushcfunction(L, apiViewOpen);
        lua.lua_setfield(L, -2, "open");
        lua.lua_setfield(L, -2, "view");

        lua.lua_setglobal(L, "fx");
    }

    fn pathAllowed(self: *const Runtime, path: []const u8) bool {
        if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return false;
        if (io_mod.realpathAlloc(self.alloc, path)) |resolved| {
            defer self.alloc.free(resolved);
            return self.absoluteAllowed(resolved);
        } else |_| {}
        return self.lexicalAllowed(path);
    }

    fn absoluteAllowed(self: *const Runtime, path: []const u8) bool {
        if (self.home.len > 0) {
            if (underJoin(self.alloc, self.home, ".fx/lua", path)) return true;
            if (underJoin(self.alloc, self.home, ".fx/pack", path)) return true;
        }
        if (self.workspace_root.len > 0) {
            if (underJoin(self.alloc, self.workspace_root, ".fx", path)) return true;
        }
        return false;
    }

    fn lexicalAllowed(self: *const Runtime, path: []const u8) bool {
        if (std.fs.path.isAbsolute(path)) return self.absoluteAllowed(path);
        var roots: [3][]const u8 = undefined;
        var count: usize = 0;
        if (self.home.len > 0) {
            roots[count] = self.home;
            count += 1;
        }
        if (self.workspace_root.len > 0) {
            roots[count] = self.workspace_root;
            count += 1;
        }
        for (roots[0..count]) |root| {
            const joined = std.fs.path.join(self.alloc, &.{ root, path }) catch continue;
            defer self.alloc.free(joined);
            if (self.absoluteAllowed(joined)) return true;
        }
        return false;
    }
};

fn appendPackageEntry(writer: *std.Io.Writer, first: *bool, root: []const u8, rel: []const u8) !void {
    if (!first.*) try writer.writeByte(';');
    first.* = false;
    try writer.writeAll(root);
    if (root.len > 0 and root[root.len - 1] != std.fs.path.sep) try writer.writeByte(std.fs.path.sep);
    try writer.writeAll(rel);
}

fn underJoin(alloc: Allocator, root: []const u8, rel: []const u8, path: []const u8) bool {
    const prefix = std.fs.path.join(alloc, &.{ root, rel }) catch return false;
    defer alloc.free(prefix);
    return isUnder(path, prefix);
}

fn isUnder(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == std.fs.path.sep;
}

fn silentNotify(_: *anyopaque, _: []const u8, _: types.NoticeTone) void {}
fn emptyString(_: *anyopaque) []const u8 {
    return "";
}
fn denyProcess(_: *anyopaque) bool {
    return false;
}
fn missingOpt(_: *anyopaque, _: Allocator, _: []const u8) anyerror!?[]u8 {
    return null;
}
fn rejectOpt(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
    return error.Unsupported;
}
fn rejectView(_: *anyopaque, _: []const u8) anyerror!void {
    return error.Unsupported;
}

fn sandboxedDenied(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    return lua.raise(L, "this Lua function is not permitted");
}

fn sandboxedExecute(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    if (!rt.host.allow_process(rt.host.ctx)) {
        return lua.raise(L, "os.execute is not permitted");
    }
    return callUpvalue(L);
}

fn sandboxedPopen(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    if (!rt.host.allow_process(rt.host.ctx)) {
        return lua.raise(L, "io.popen is not permitted");
    }
    return callUpvalue(L);
}

fn sandboxedOpen(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const path = lua.tostring(L, 1) orelse return lua.raise(L, "io.open requires a path");
    if (!rt.pathAllowed(path)) {
        return lua.raise(L, "file is outside the Lua sandbox");
    }
    return callUpvalue(L);
}

fn sandboxedLoadfile(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    if (lua.isnoneornil(L, 1)) return lua.raise(L, "loadfile requires a path");
    const path = lua.tostring(L, 1) orelse return lua.raise(L, "loadfile requires a path");
    if (!rt.pathAllowed(path)) {
        return lua.raise(L, "file is outside the Lua sandbox");
    }
    const path_z = rt.alloc.dupeZ(u8, path) catch return lua.raise(L, "OutOfMemory");
    defer rt.alloc.free(path_z);
    const mode: ?[*:0]const u8 = if (lua.isnoneornil(L, 2)) null else blk: {
        const text = lua.tostring(L, 2) orelse break :blk null;
        break :blk @ptrCast(text.ptr);
    };
    const status = lua.luaL_loadfilex(L, path_z, mode);
    if (status != lua.OK) return 1;
    return 1;
}

fn sandboxedDofile(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const top = lua.lua_gettop(L);
    lua.lua_settop(L, 1);
    _ = sandboxedLoadfile(L);
    if (lua.lua_type(L, -1) != lua.TFUNCTION) return 1;
    const status = lua.pcall(L, 0, lua.MULTRET, 0);
    if (status != lua.OK) return lua.lua_error(L);
    return lua.lua_gettop(L) - top + 1;
}

fn sandboxedLoadlib(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    return lua.raise(L, "package.loadlib is not permitted");
}

fn callUpvalue(L: ?*lua.State) c_int {
    const nargs = lua.lua_gettop(L);
    lua.lua_pushvalue(L, lua.upvalue(1));
    lua.insert(L, 1);
    lua.lua_callk(L, nargs, lua.MULTRET, 0, null);
    return lua.lua_gettop(L);
}

fn apiCommand(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    const name = lua.tostring(L, 1) orelse return lua.raise(L, "command name required");
    const slash = normalizeCommandName(rt.alloc, name) catch |err| switch (err) {
        error.InvalidCommandName => return lua.raise(L, "invalid Lua command name"),
        error.OutOfMemory => return lua.raise(L, "OutOfMemory"),
    };
    errdefer rt.alloc.free(slash);
    if (rt.findCommand(slash) != null or builtinHasCommand(rt.builtin_specs, slash)) {
        rt.alloc.free(slash);
        return lua.raise(L, "command is already registered");
    }
    var description: []u8 = &.{};
    if (lua.istable(L, 3)) {
        _ = lua.lua_getfield(L, 3, "desc");
        if (lua.isnoneornil(L, -1)) {
            lua.pop(L, 1);
            _ = lua.lua_getfield(L, 3, "description");
        }
        if (lua.tostring(L, -1)) |text| {
            description = rt.alloc.dupe(u8, text) catch {
                rt.alloc.free(slash);
                return lua.raise(L, "OutOfMemory");
            };
        }
        lua.pop(L, 1);
    }
    lua.lua_pushvalue(L, 2);
    const ref = lua.luaL_ref(L, lua.REGISTRYINDEX);
    rt.commands.append(rt.alloc, .{
        .slash = slash,
        .description = description,
        .lua_ref = ref,
    }) catch {
        lua.luaL_unref(L, lua.REGISTRYINDEX, ref);
        rt.alloc.free(slash);
        if (description.len > 0) rt.alloc.free(description);
        return lua.raise(L, "OutOfMemory");
    };
    return 0;
}

fn apiKeymap(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    const lhs = lua.tostring(L, 1) orelse return lua.raise(L, "keymap lhs required");
    const byte = parseKeymapLhs(lhs) orelse return lua.raise(L, "unsupported keymap");
    lua.lua_pushvalue(L, 2);
    const ref = lua.luaL_ref(L, lua.REGISTRYINDEX);
    rt.keymaps.append(rt.alloc, .{ .byte = byte, .lua_ref = ref }) catch {
        lua.luaL_unref(L, lua.REGISTRYINDEX, ref);
        return lua.raise(L, "OutOfMemory");
    };
    return 0;
}

fn apiHook(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    const kind_name = lua.tostring(L, 1) orelse return lua.raise(L, "hook kind required");
    const kind = std.meta.stringToEnum(hooks.HookKind, kind_name) orelse
        return lua.raise(L, "unknown hook kind");
    lua.lua_pushvalue(L, 2);
    const ref = lua.luaL_ref(L, lua.REGISTRYINDEX);
    rt.lua_hooks.append(rt.alloc, .{ .kind = kind, .lua_ref = ref }) catch {
        lua.luaL_unref(L, lua.REGISTRYINDEX, ref);
        return lua.raise(L, "OutOfMemory");
    };
    return 0;
}

fn apiNotify(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    const message = lua.tostring(L, 1) orelse return 0;
    var tone: types.NoticeTone = .neutral;
    if (lua.istable(L, 2)) {
        _ = lua.lua_getfield(L, 2, "tone");
        if (lua.tostring(L, -1)) |name| {
            tone = std.meta.stringToEnum(types.NoticeTone, name) orelse .neutral;
        }
        lua.pop(L, 1);
    }
    rt.host.notify(rt.host.ctx, message, tone);
    return 0;
}

fn apiModel(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.pushslice(L, rt.host.model(rt.host.ctx));
    return 1;
}

fn apiProvider(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const value = rt.host.get_opt(rt.host.ctx, rt.alloc, "provider") catch {
        lua.pushslice(L, "vercel_gateway");
        return 1;
    } orelse {
        lua.pushslice(L, rt.host.provider(rt.host.ctx));
        return 1;
    };
    defer rt.alloc.free(value);
    lua.pushslice(L, value);
    return 1;
}

fn apiOptIndex(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const key = lua.tostring(L, 2) orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    const value = rt.host.get_opt(rt.host.ctx, rt.alloc, key) catch {
        lua.lua_pushnil(L);
        return 1;
    } orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    defer rt.alloc.free(value);
    lua.pushslice(L, value);
    return 1;
}

fn apiOptNewindex(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const key = lua.tostring(L, 2) orelse return lua.raise(L, "setting name required");
    const value = if (lua.lua_type(L, 3) == lua.TBOOLEAN)
        if (lua.lua_toboolean(L, 3) != 0) "on" else "off"
    else
        lua.tostring(L, 3) orelse return lua.raise(L, "setting value required");
    rt.host.set_opt(rt.host.ctx, key, value) catch |err| {
        return lua.raise(L, @errorName(err));
    };
    return 0;
}

fn apiViewOpen(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    const path = lua.tostring(L, 1) orelse return lua.raise(L, "path required");
    rt.host.open_view(rt.host.ctx, path) catch |err| {
        return lua.raise(L, @errorName(err));
    };
    return 0;
}

fn builtinHasCommand(specs: []const SlashSpec, slash: []const u8) bool {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.command, slash)) return true;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, alias, slash)) return true;
        }
    }
    return false;
}

fn normalizeCommandName(alloc: Allocator, name: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, name, " \t/");
    if (trimmed.len == 0) return error.InvalidCommandName;
    if (trimmed.len > 64) return error.InvalidCommandName;
    for (trimmed, 0..) |byte, i| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
        if (!ok) return error.InvalidCommandName;
        if (i == 0 and !std.ascii.isAlphabetic(byte)) return error.InvalidCommandName;
    }
    const slash = try alloc.alloc(u8, trimmed.len + 1);
    slash[0] = '/';
    @memcpy(slash[1..], trimmed);
    return slash;
}

fn parseKeymapLhs(lhs: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, lhs, " \t");
    if (trimmed.len == 1) return trimmed[0];
    if (trimmed.len == 5 and trimmed[0] == '<' and trimmed[4] == '>' and
        (trimmed[1] == 'C' or trimmed[1] == 'c') and trimmed[2] == '-')
    {
        const letter = std.ascii.toLower(trimmed[3]);
        if (letter < 'a' or letter > 'z') return null;
        return letter - 'a' + 1;
    }
    if (eqlIgnoreCase(trimmed, "<CR>") or eqlIgnoreCase(trimmed, "<Enter>")) return '\r';
    if (eqlIgnoreCase(trimmed, "<Tab>")) return '\t';
    if (eqlIgnoreCase(trimmed, "<Esc>")) return 0x1b;
    if (eqlIgnoreCase(trimmed, "<Space>")) return ' ';
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn preToolUseTrampoline(
    ctx: *anyopaque,
    input: hooks.PreToolUseInput,
) hooks.HandlerError!hooks.PreToolUseAction {
    if (comptime !enabled) return .continue_;
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const L = self.state orelse return .continue_;
    self.lock();
    defer self.unlock();
    for (self.lua_hooks.items) |hook| {
        if (hook.kind != .pre_tool_use) continue;
        if (!lua.checkstack(L, 8)) return error.Failed;
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, hook.lua_ref);
        pushPreToolUseInput(L, input);
        if (lua.pcall(L, 1, 1, 0) != lua.OK) {
            lua.pop(L, 1);
            return error.Failed;
        }
        const action = readPreToolUseAction(self, L) catch {
            lua.pop(L, 1);
            return error.Failed;
        };
        lua.pop(L, 1);
        switch (action) {
            .continue_ => {},
            else => return action,
        }
    }
    return .continue_;
}

fn stopTrampoline(
    ctx: *anyopaque,
    input: hooks.StopInput,
) hooks.HandlerError!hooks.StopAction {
    if (comptime !enabled) return .allow;
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const L = self.state orelse return .allow;
    self.lock();
    defer self.unlock();
    for (self.lua_hooks.items) |hook| {
        if (hook.kind != .stop) continue;
        if (!lua.checkstack(L, 8)) return error.Failed;
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, hook.lua_ref);
        lua.newtable(L);
        lua.pushslice(L, input.assistant_text);
        lua.lua_setfield(L, -2, "assistant_text");
        if (lua.pcall(L, 1, 1, 0) != lua.OK) {
            lua.pop(L, 1);
            return error.Failed;
        }
        if (lua.istable(L, -1)) {
            _ = lua.lua_getfield(L, -1, "action");
            const action_name = lua.tostring(L, -1) orelse "";
            lua.pop(L, 1);
            if (std.mem.eql(u8, action_name, "continue_once")) {
                _ = lua.lua_getfield(L, -1, "context");
                const context = lua.tostring(L, -1) orelse "";
                self.hook_text.clearRetainingCapacity();
                self.hook_text.appendSlice(self.alloc, context) catch {
                    lua.pop(L, 2);
                    return error.Failed;
                };
                lua.pop(L, 2);
                return .{ .continue_once = self.hook_text.items };
            }
            lua.pop(L, 1);
        } else {
            lua.pop(L, 1);
        }
    }
    return .allow;
}

fn postTurnEndTrampoline(ctx: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
    _ = input;
    runSideEffectHooks(ctx, .post_turn_end);
}

fn attentionRequiredTrampoline(ctx: *anyopaque, input: hooks.AttentionRequiredInput) hooks.HandlerError!void {
    _ = input;
    runSideEffectHooks(ctx, .attention_required);
}

fn runSideEffectHooks(ctx: *anyopaque, kind: hooks.HookKind) void {
    if (comptime !enabled) return;
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const L = self.state orelse return;
    self.lock();
    defer self.unlock();
    for (self.lua_hooks.items) |hook| {
        if (hook.kind != kind) continue;
        if (!lua.checkstack(L, 4)) continue;
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, hook.lua_ref);
        lua.newtable(L);
        if (lua.pcall(L, 1, 0, 0) != lua.OK) lua.pop(L, 1);
    }
}

fn pushPreToolUseInput(L: ?*lua.State, input: hooks.PreToolUseInput) void {
    lua.newtable(L);
    lua.pushslice(L, input.tool_name);
    lua.lua_setfield(L, -2, "tool_name");
    lua.pushslice(L, input.arguments_json);
    lua.lua_setfield(L, -2, "arguments_json");
    lua.pushslice(L, input.call_id);
    lua.lua_setfield(L, -2, "call_id");
    lua.lua_pushinteger(L, @intCast(input.step_index));
    lua.lua_setfield(L, -2, "step_index");
}

fn readPreToolUseAction(self: *Runtime, L: ?*lua.State) !hooks.PreToolUseAction {
    if (lua.isnoneornil(L, -1)) return .continue_;
    if (lua.lua_type(L, -1) == lua.TSTRING) {
        const name = lua.tostring(L, -1) orelse return .continue_;
        if (std.mem.eql(u8, name, "continue")) return .continue_;
        return error.Failed;
    }
    if (!lua.istable(L, -1)) return .continue_;
    _ = lua.lua_getfield(L, -1, "action");
    const action_name = lua.tostring(L, -1) orelse "continue";
    lua.pop(L, 1);
    if (std.mem.eql(u8, action_name, "block")) {
        _ = lua.lua_getfield(L, -1, "reason");
        const reason = lua.tostring(L, -1) orelse "blocked by Lua hook";
        self.hook_text.clearRetainingCapacity();
        try self.hook_text.appendSlice(self.alloc, reason);
        lua.pop(L, 1);
        return .{ .block = self.hook_text.items };
    }
    if (std.mem.eql(u8, action_name, "rewrite")) {
        _ = lua.lua_getfield(L, -1, "arguments");
        const arguments = lua.tostring(L, -1) orelse return error.Failed;
        self.hook_text.clearRetainingCapacity();
        try self.hook_text.appendSlice(self.alloc, arguments);
        lua.pop(L, 1);
        return .{ .rewrite_arguments = self.hook_text.items };
    }
    return .continue_;
}

test "broken init.lua is a notice and does not abort" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "this is not lua [[[");

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.loadInit(null, workspace);

    try std.testing.expect(runtime.state != null);
    try std.testing.expectEqual(@as(usize, 0), runtime.loaded_files.items.len);
    try std.testing.expect(runtime.notices.items.len >= 1);
    try std.testing.expect(runtime.hasCommand("/hello") == false);
}

test "/hello from init.lua registers and runs" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.command("hello", function(payload)
        \\  fx.notify("hello " .. (payload or ""))
        \\end, { desc = "say hello" })
        \\
    );

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(alloc);
    const Ctx = struct {
        seen: *std.ArrayList(u8),
        alloc: Allocator,
        fn notify(raw: *anyopaque, message: []const u8, _: types.NoticeTone) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.seen.appendSlice(ctx.alloc, message) catch {};
        }
    };
    var ctx = Ctx{ .seen = &seen, .alloc = alloc };

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = &ctx,
        .notify = Ctx.notify,
    });
    runtime.setBuiltinSlashSpecs(&.{
        .{ .kind = .help, .command = "/help" },
    });
    runtime.loadInit(null, workspace);

    try std.testing.expect(runtime.hasCommand("/hello"));
    const registry = runtime.slashRegistry(.{ .commands = &.{} });
    const spec = registry.lookup("/hello") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(command_specs.SlashKind.lua, spec.kind);
    runtime.invokeCommand("/hello", "world");
    try std.testing.expectEqualStrings("hello world", seen.items);
}

test "os.execute is denied unless the host grants process access" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "os.execute('true')\n");

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.loadInit(null, workspace);
    try std.testing.expect(runtime.notices.items.len >= 1);
    try std.testing.expect(std.mem.find(u8, runtime.notices.items[0].body, "os.execute") != null);
}

test "profile then workspace init.lua load in order" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.fx");
    var profile = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/init.lua", .{});
    try profile.writeStreamingAll(io_mod.getIo(), "fx.command('from_profile', function() end)\n");
    profile.close(io_mod.getIo());
    var workspace_file = try tmp.dir.createFile(io_mod.getIo(), "workspace/.fx/init.lua", .{});
    try workspace_file.writeStreamingAll(io_mod.getIo(), "fx.command('from_workspace', function() end)\n");
    workspace_file.close(io_mod.getIo());

    const home = try std.fs.path.join(alloc, &.{ root, "home" });
    defer alloc.free(home);
    const workspace = try std.fs.path.join(alloc, &.{ root, "workspace" });
    defer alloc.free(workspace);

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.loadInit(home, workspace);
    try std.testing.expect(runtime.hasCommand("/from_profile"));
    try std.testing.expect(runtime.hasCommand("/from_workspace"));
    try std.testing.expectEqual(@as(usize, 2), runtime.loaded_files.items.len);
}

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    path: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = .{ .path = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "open_file arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "open_file arguments must be an object") };
    }

    const path_value = parsed.value.object.get("path") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "open_file field \"path\" is required") };
    };
    if (path_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "open_file field \"path\" must be a string") };
    }

    const owned_path = try ctx.allocator.dupe(u8, path_value.string);
    errdefer ctx.allocator.free(owned_path);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .path = owned_path };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return callWithLauncher(ctx, erased, builtin.os.tag, .{});
}

const LaunchResult = struct {
    term: std.process.Child.Term,
};

const LaunchFn = *const fn (*anyopaque, Allocator, []const []const u8) anyerror!LaunchResult;

const Launcher = struct {
    ctx: *anyopaque = undefined,
    launch: LaunchFn = launchActual,
};

fn launchActual(_: *anyopaque, arena: Allocator, argv: []const []const u8) anyerror!LaunchResult {
    const result = try std.process.run(arena, io_mod.getIo(), .{ .argv = argv });
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);
    return .{ .term = result.term };
}

fn callWithLauncher(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput, os_tag: std.Target.Os.Tag, launcher: Launcher) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| return mapPathError(err);
    const display_path = try displayPath(arena, ctx.workspace_root, target);
    return launch_file(ctx.allocator, display_path, target, os_tag, launcher);
}

fn mapPathError(err: anyerror) tool_dispatch.DispatchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPath => error.InvalidPath,
        error.FileNotFound => error.FileNotFound,
        error.HomeNotSet => error.HomeNotSet,
        error.PathOutsideWorkspace => error.PathOutsideWorkspace,
        error.WorkspaceUnavailable => error.WorkspaceUnavailable,
        else => error.InvalidPath,
    };
}

test "open_file preserves missing home path errors" {
    try std.testing.expectEqual(error.HomeNotSet, mapPathError(error.HomeNotSet));
}

fn displayPath(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8) ![]const u8 {
    const rel = try pathing.workspaceRelativePath(arena, workspace_root, absolute_path);
    return if (rel.len == 0) "." else rel;
}

fn launch_file(alloc: Allocator, display_path: []const u8, target: []const u8, os_tag: std.Target.Os.Tag, launcher: Launcher) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const macos_argv = [_][]const u8{ "open", target };
    const linux_argv = [_][]const u8{ "xdg-open", target };
    const windows_argv = [_][]const u8{ "rundll32.exe", "url.dll,FileProtocolHandler", target };
    const argv: []const []const u8 = switch (os_tag) {
        .windows => &windows_argv,
        .macos => &macos_argv,
        .linux => &linux_argv,
        else => return .{ .failure = try alloc.dupe(u8, "open_file not supported on this OS") },
    };

    const result = launcher.launch(launcher.ctx, alloc, argv) catch |err| {
        debug_trace.logf("core", "open_file launcher failed err={s} path={s} target={s}", .{ @errorName(err), display_path, target });
        return .{ .failure = try std.fmt.allocPrint(alloc, "failed to open {s}", .{target}) };
    };
    switch (result.term) {
        .exited => |code| if (code == 0) {
            return .{ .success = try std.fmt.allocPrint(alloc, "opened {s}", .{display_path}) };
        },
        else => {},
    }

    logUnsuccessfulTerm("open_file", display_path, target, result.term);
    return .{ .failure = try std.fmt.allocPrint(alloc, "failed to open {s}", .{target}) };
}

fn logUnsuccessfulTerm(tool_name: []const u8, display_path: []const u8, target: []const u8, term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| debug_trace.logf("core", "{s} launcher unsuccessful exit_code={d} path={s} target={s}", .{ tool_name, code, display_path, target }),
        .signal => |sig| debug_trace.logf("core", "{s} launcher unsuccessful term=signal signal={d} path={s} target={s}", .{ tool_name, @intFromEnum(sig), display_path, target }),
        .stopped => |sig| debug_trace.logf("core", "{s} launcher unsuccessful term=stopped signal={d} path={s} target={s}", .{ tool_name, @intFromEnum(sig), display_path, target }),
        .unknown => |code| debug_trace.logf("core", "{s} launcher unsuccessful term=unknown status={d} path={s} target={s}", .{ tool_name, code, display_path, target }),
    }
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

fn stackInput(input: *Input) tool_dispatch.ToolInput {
    return .{ .ptr = input, .deinit_fn = noopInputDeinit };
}

fn validateStackInput(alloc: Allocator, input: *Input) !?[]u8 {
    return validate(.{ .allocator = alloc }, stackInput(input));
}

fn expectDecodeFailure(args_json: []const u8, reason: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(reason, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(false);
        },
    }
}

fn expectDecodeInput(args_json: []const u8, path: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(Input);
            try std.testing.expectEqualStrings(path, input.path);
        },
    }
}

fn expectSuccessBody(result: tool_dispatch.ToolResult, expected: []const u8) !void {
    switch (result) {
        .success => |body| try std.testing.expectEqualStrings(expected, body),
        .failure => try std.testing.expect(false),
    }
}

fn expectFailureBody(result: tool_dispatch.ToolResult, expected: []const u8) !void {
    switch (result) {
        .success => try std.testing.expect(false),
        .failure => |body| try std.testing.expectEqualStrings(expected, body),
    }
}

const MockLauncher = struct {
    calls: usize = 0,
    term: std.process.Child.Term = .{ .exited = 0 },
    err: ?anyerror = null,
    argv: std.ArrayList([]u8) = .empty,

    fn deinit(self: *@This(), alloc: Allocator) void {
        for (self.argv.items) |arg| alloc.free(arg);
        self.argv.deinit(alloc);
    }

    fn launch(ctx: *anyopaque, alloc: Allocator, argv: []const []const u8) anyerror!LaunchResult {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        for (argv) |arg| {
            const owned = try alloc.dupe(u8, arg);
            errdefer alloc.free(owned);
            try self.argv.append(alloc, owned);
        }
        if (self.err) |err| return err;
        return .{ .term = self.term };
    }
};

fn callPathWithMock(alloc: Allocator, workspace_root: []const u8, path: []const u8, os_tag: std.Target.Os.Tag, launcher: *MockLauncher) !tool_dispatch.ToolResult {
    var input = Input{ .path = try alloc.dupe(u8, path) };
    defer input.deinit(alloc);
    return callWithLauncher(.{ .allocator = alloc, .workspace_root = workspace_root }, stackInput(&input), os_tag, .{
        .ctx = @ptrCast(launcher),
        .launch = MockLauncher.launch,
    });
}

fn writeTempFile(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) ![]u8 {
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

test "open_file rejects invalid JSON" {
    try expectDecodeFailure("{", "open_file arguments must be valid JSON");
}

test "open_file rejects non-object JSON" {
    try expectDecodeFailure("[]", "open_file arguments must be an object");
}

test "open_file rejects missing path" {
    try expectDecodeFailure("{}", "open_file field \"path\" is required");
}

test "open_file rejects non-string path" {
    try expectDecodeFailure("{\"path\":1}", "open_file field \"path\" must be a string");
}

test "open_file decodes owned path input" {
    try expectDecodeInput("{\"path\":\"docs/readme.md\"}", "docs/readme.md");
}

test "open_file validation preserves path bytes" {
    const alloc = std.testing.allocator;
    var input = Input{ .path = try alloc.dupe(u8, " \t docs/readme.md \n") };
    defer input.deinit(alloc);

    try std.testing.expect((try validateStackInput(alloc, &input)) == null);
    try std.testing.expectEqualStrings(" \t docs/readme.md \n", input.path);
}

test "open_file validation does not reject empty path before active resolver" {
    const alloc = std.testing.allocator;
    var input = Input{ .path = try alloc.dupe(u8, "") };
    defer input.deinit(alloc);

    try std.testing.expect((try validateStackInput(alloc, &input)) == null);
    try std.testing.expectEqualStrings("", input.path);
}

test "open_file resolution failure propagates active resolver error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var launcher = MockLauncher{};
    defer launcher.deinit(alloc);

    try std.testing.expectError(error.FileNotFound, callPathWithMock(alloc, workspace, "missing.txt", .macos, &launcher));
    try std.testing.expectEqual(@as(usize, 0), launcher.calls);
}

test "open_file displays workspace-relative path on success" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const target = try writeTempFile(alloc, &tmp, "notes.txt", "hello\n");
    defer alloc.free(target);
    var launcher = MockLauncher{};
    defer launcher.deinit(alloc);

    var result = try callPathWithMock(alloc, workspace, "notes.txt", .macos, &launcher);
    defer result.deinit(alloc);

    try expectSuccessBody(result, "opened notes.txt");
    try std.testing.expectEqual(@as(usize, 1), launcher.calls);
    try std.testing.expectEqual(@as(usize, 2), launcher.argv.items.len);
    try std.testing.expectEqualStrings("open", launcher.argv.items[0]);
    try std.testing.expectEqualStrings(target, launcher.argv.items[1]);
}

test "open_file uses the Windows file protocol handler" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const target = try writeTempFile(alloc, &tmp, "notes.txt", "hello\n");
    defer alloc.free(target);
    var launcher = MockLauncher{};
    defer launcher.deinit(alloc);

    var result = try callPathWithMock(alloc, workspace, "notes.txt", .windows, &launcher);
    defer result.deinit(alloc);

    try expectSuccessBody(result, "opened notes.txt");
    try std.testing.expectEqual(@as(usize, 3), launcher.argv.items.len);
    try std.testing.expectEqualStrings("rundll32.exe", launcher.argv.items[0]);
    try std.testing.expectEqualStrings("url.dll,FileProtocolHandler", launcher.argv.items[1]);
    try std.testing.expectEqualStrings(target, launcher.argv.items[2]);
}

test "open_file accepts external absolute paths through active workspace resolver" {
    const alloc = std.testing.allocator;
    var workspace_tmp = std.testing.tmpDir(.{});
    defer workspace_tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, workspace_tmp.dir, ".");
    defer alloc.free(workspace);
    var external_tmp = std.testing.tmpDir(.{});
    defer external_tmp.cleanup();
    const target = try writeTempFile(alloc, &external_tmp, "outside.txt", "hello\n");
    defer alloc.free(target);
    var launcher = MockLauncher{};
    defer launcher.deinit(alloc);

    var result = try callPathWithMock(alloc, workspace, target, .linux, &launcher);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "opened {s}", .{target});
    defer alloc.free(expected);
    try expectSuccessBody(result, expected);
    try std.testing.expectEqual(@as(usize, 1), launcher.calls);
    try std.testing.expectEqual(@as(usize, 2), launcher.argv.items.len);
    try std.testing.expectEqualStrings("xdg-open", launcher.argv.items[0]);
    try std.testing.expectEqualStrings(target, launcher.argv.items[1]);
}

test "open_file unsupported os does not launch" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const target = try writeTempFile(alloc, &tmp, "notes.txt", "hello\n");
    defer alloc.free(target);
    var launcher = MockLauncher{};
    defer launcher.deinit(alloc);

    var result = try callPathWithMock(alloc, workspace, "notes.txt", .freebsd, &launcher);
    defer result.deinit(alloc);

    try expectFailureBody(result, "open_file not supported on this OS");
    try std.testing.expectEqual(@as(usize, 0), launcher.calls);
    try std.testing.expectEqual(@as(usize, 0), launcher.argv.items.len);
}

test "open_file returns failure body for nonzero exit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const target = try writeTempFile(alloc, &tmp, "notes.txt", "hello\n");
    defer alloc.free(target);
    var launcher = MockLauncher{ .term = .{ .exited = 1 } };
    defer launcher.deinit(alloc);

    var result = try callPathWithMock(alloc, workspace, "notes.txt", .macos, &launcher);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "failed to open {s}", .{target});
    defer alloc.free(expected);
    try expectFailureBody(result, expected);
    try std.testing.expectEqual(@as(usize, 1), launcher.calls);
}

test "open_file returns failure body for launcher error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const target = try writeTempFile(alloc, &tmp, "notes.txt", "hello\n");
    defer alloc.free(target);
    var launcher = MockLauncher{ .err = error.AccessDenied };
    defer launcher.deinit(alloc);

    var result = try callPathWithMock(alloc, workspace, "notes.txt", .macos, &launcher);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "failed to open {s}", .{target});
    defer alloc.free(expected);
    try expectFailureBody(result, expected);
    try std.testing.expectEqual(@as(usize, 1), launcher.calls);
}

test "open_file returns failure body for non-exited term" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const target = try writeTempFile(alloc, &tmp, "notes.txt", "hello\n");
    defer alloc.free(target);
    var launcher = MockLauncher{ .term = .{ .unknown = 9 } };
    defer launcher.deinit(alloc);

    var result = try callPathWithMock(alloc, workspace, "notes.txt", .linux, &launcher);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "failed to open {s}", .{target});
    defer alloc.free(expected);
    try expectFailureBody(result, expected);
    try std.testing.expectEqual(@as(usize, 1), launcher.calls);
}

test "open_file classifiers are side-effecting and reversible" {
    const alloc = std.testing.allocator;
    var input = Input{ .path = try alloc.dupe(u8, "notes.txt") };
    defer input.deinit(alloc);
    const erased = stackInput(&input);

    try std.testing.expect(!readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
}

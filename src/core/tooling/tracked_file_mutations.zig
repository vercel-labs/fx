const std = @import("std");
const builtin = @import("builtin");
const permissions = @import("../permissions/permissions.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;

pub const Input = struct {
    dispatch_ctx: tool_dispatch.DispatchContext,
    registry: tool_dispatch.Registry,
    tracker: ?*change_tracker.ChangeTracker = null,
};

pub fn dispatchDelete(
    dispatch_ctx: tool_dispatch.DispatchContext,
    registry: tool_dispatch.Registry,
    call: types.ToolCall,
) tool_dispatch.DispatchError!tool_dispatch.DispatchResult {
    return executeDelete(.{
        .dispatch_ctx = dispatch_ctx,
        .registry = registry,
        .tracker = dispatch_ctx.change_tracker,
    }, call);
}

pub fn dispatchRename(
    dispatch_ctx: tool_dispatch.DispatchContext,
    registry: tool_dispatch.Registry,
    call: types.ToolCall,
) tool_dispatch.DispatchError!tool_dispatch.DispatchResult {
    return executeRename(.{
        .dispatch_ctx = dispatch_ctx,
        .registry = registry,
        .tracker = dispatch_ctx.change_tracker,
    }, call);
}

pub fn dispatchCopy(
    dispatch_ctx: tool_dispatch.DispatchContext,
    registry: tool_dispatch.Registry,
    call: types.ToolCall,
) tool_dispatch.DispatchError!tool_dispatch.DispatchResult {
    return executeCopy(.{
        .dispatch_ctx = dispatch_ctx,
        .registry = registry,
        .tracker = dispatch_ctx.change_tracker,
    }, call);
}

pub fn executeDelete(
    input: Input,
    call: types.ToolCall,
) tool_dispatch.DispatchError!tool_dispatch.DispatchResult {
    const arena = input.dispatch_ctx.allocator;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const path_arg = try tool_args.requiredStringArg(args, "path");
    const target = permissions.resolveFileToolPath(
        arena,
        input.dispatch_ctx.workspace_root,
        "delete_file",
        path_arg,
        .existing,
    ) catch |err| return mapPathError(err);
    return executeCaptured(input, call, captureDelete(input.tracker, target));
}

pub fn executeRename(
    input: Input,
    call: types.ToolCall,
) tool_dispatch.DispatchError!tool_dispatch.DispatchResult {
    const arena = input.dispatch_ctx.allocator;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const old_path_arg = try tool_args.requiredStringArg(args, "old_path");
    const new_path_arg = try tool_args.requiredStringArg(args, "new_path");
    const old_target = permissions.resolveFileToolPath(
        arena,
        input.dispatch_ctx.workspace_root,
        "rename_file",
        old_path_arg,
        .existing,
    ) catch |err| return mapPathError(err);
    const new_target = permissions.resolveFileToolPath(
        arena,
        input.dispatch_ctx.workspace_root,
        "rename_file",
        new_path_arg,
        .create,
    ) catch |err| return mapPathError(err);
    return executeCaptured(
        input,
        call,
        captureRename(input.tracker, old_target, new_target),
    );
}

pub fn executeCopy(
    input: Input,
    call: types.ToolCall,
) tool_dispatch.DispatchError!tool_dispatch.DispatchResult {
    const arena = input.dispatch_ctx.allocator;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const source_arg = try tool_args.requiredStringArg(args, "source");
    const destination_arg = try tool_args.requiredStringArg(args, "destination");
    _ = permissions.resolveFileToolPath(
        arena,
        input.dispatch_ctx.workspace_root,
        "copy_file",
        source_arg,
        .existing,
    ) catch |err| return mapPathError(err);
    const destination = permissions.resolveFileToolPath(
        arena,
        input.dispatch_ctx.workspace_root,
        "copy_file",
        destination_arg,
        .create,
    ) catch |err| return mapPathError(err);
    return executeCaptured(input, call, captureCopy(input.tracker, destination));
}

fn executeCaptured(
    input: Input,
    call: types.ToolCall,
    captured_operation: ?change_tracker.FileOperation,
) tool_dispatch.DispatchError!tool_dispatch.DispatchResult {
    var operation = captured_operation;
    errdefer freeCapturedOperation(operation);

    const result = try tool_dispatch.dispatchAuthorizedToolCallDefault(
        input.dispatch_ctx,
        input.registry,
        call,
    );
    if (result.status == .failure) {
        freeCapturedOperation(operation);
        return result;
    }

    if (input.tracker) |tracker| {
        if (operation) |*value| {
            value.timestamp_ms = io_mod.milliTimestamp();
            tracker.pushOperation(std.heap.c_allocator, value.*) catch {
                freeCapturedOperation(value.*);
            };
            operation = null;
        }
    } else {
        freeCapturedOperation(operation);
    }
    return result;
}

fn captureDelete(
    tracker: ?*change_tracker.ChangeTracker,
    path: []const u8,
) ?change_tracker.FileOperation {
    if (tracker == null) return null;
    const owned_path = std.heap.c_allocator.dupe(u8, path) catch return null;
    const preimage = capturePreimage(path);
    return .{
        .kind = .delete,
        .path = owned_path,
        .previous_content = preimage.content,
        .timestamp_ms = 0,
        .preimage_unavailable = preimage.unavailable,
    };
}

fn captureRename(
    tracker: ?*change_tracker.ChangeTracker,
    old_path: []const u8,
    new_path: []const u8,
) ?change_tracker.FileOperation {
    if (tracker == null) return null;
    const owned_old_path = std.heap.c_allocator.dupe(u8, old_path) catch return null;
    const owned_new_path = std.heap.c_allocator.dupe(u8, new_path) catch null;
    const preimage = capturePreimage(new_path);
    return .{
        .kind = .rename,
        .path = owned_old_path,
        .previous_content = preimage.content,
        .new_path = owned_new_path,
        .timestamp_ms = 0,
        .preimage_unavailable = preimage.unavailable,
    };
}

fn captureCopy(
    tracker: ?*change_tracker.ChangeTracker,
    destination: []const u8,
) ?change_tracker.FileOperation {
    if (tracker == null) return null;
    const owned_path = std.heap.c_allocator.dupe(u8, destination) catch return null;
    const preimage = capturePreimage(destination);
    return .{
        .kind = .write,
        .path = owned_path,
        .previous_content = preimage.content,
        .timestamp_ms = 0,
        .preimage_unavailable = preimage.unavailable,
    };
}

const Preimage = struct {
    content: ?[]u8 = null,
    unavailable: bool = false,
};

/// Resolves the preimage an undo record needs. A file proven absent records no content
/// and stays undoable, because undo reads that as "the tool created this". A file whose
/// state could not be read records no content either, but is marked unavailable so undo
/// refuses it instead of deleting a file the tool never created.
fn capturePreimage(capture_path: []const u8) Preimage {
    return switch (change_tracker.ChangeTracker.captureFileState(std.heap.c_allocator, capture_path)) {
        .captured => |content| .{ .content = content },
        .absent => .{},
        .unavailable => .{ .unavailable = true },
    };
}

fn freeCapturedOperation(maybe_operation: ?change_tracker.FileOperation) void {
    const operation = maybe_operation orelse return;
    std.heap.c_allocator.free(operation.path);
    if (operation.previous_content) |content| std.heap.c_allocator.free(content);
    if (operation.new_path) |new_path| std.heap.c_allocator.free(new_path);
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

const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.delete_file,
    test_builtin_tools.rename_file,
    test_builtin_tools.copy_file,
};
const test_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };

fn testInput(
    allocator: Allocator,
    workspace_root: []const u8,
    tracker: ?*change_tracker.ChangeTracker,
) Input {
    return .{
        .dispatch_ctx = .{
            .allocator = allocator,
            .workspace_root = workspace_root,
        },
        .registry = test_registry,
        .tracker = tracker,
    };
}

fn testCall(name: []const u8, arguments_json: []const u8) types.ToolCall {
    return .{
        .id = "test-call",
        .name = name,
        .arguments_json = arguments_json,
    };
}

fn markedDeleteCall(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const result = try test_builtin_tools.delete_file.call(ctx, input);
    return switch (result) {
        .success => |body| blk: {
            ctx.allocator.free(body);
            break :blk .{
                .success = try ctx.allocator.dupe(
                    u8,
                    "registered delete callback",
                ),
            };
        },
        .failure => |body| .{ .failure = body },
    };
}

test "tracked delete captures prior content after adapter success" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    var file = try tmp.dir.createFile(io_mod.getIo(), "workspace/delete.txt", .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "delete\n");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace_root);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try executeDelete(
        testInput(arena_state.allocator(), workspace_root, &tracker),
        testCall("delete_file", "{\"path\":\"delete.txt\"}"),
    );

    try std.testing.expectEqualStrings("deleted delete.txt", result.body);
    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    try std.testing.expectEqual(change_tracker.OperationKind.delete, tracker.stack.items[0].kind);
    try std.testing.expectEqualStrings("delete\n", tracker.stack.items[0].previous_content.?);
}

test "tracked delete executes the registered callback before tracker publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "workspace/delete.txt", "delete\n");

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    var registered_delete = test_builtin_tools.delete_file;
    registered_delete.call = markedDeleteCall;
    const registered_tools = [_]tool_dispatch.Tool{registered_delete};
    var input = testInput(arena_state.allocator(), workspace, &tracker);
    input.registry = .{ .tools = registered_tools[0..] };

    const result = try executeDelete(
        input,
        testCall("delete_file", "{\"path\":\"delete.txt\"}"),
    );

    try std.testing.expectEqualStrings("registered delete callback", result.body);
    try std.testing.expect(!pathExists(tmp.dir, "workspace/delete.txt"));
    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    try std.testing.expectEqualStrings("delete\n", tracker.stack.items[0].previous_content.?);
}

test "tracked delete preserves file and directory adapter output" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/remove.txt", "delete me");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/empty-dir");
    try writeTestFile(tmp.dir, "workspace/non-empty/child.txt", "keep");

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const input = testInput(arena_state.allocator(), workspace, null);

    const file_deleted = try executeDelete(input, testCall("delete_file", "{\"path\":\"remove.txt\"}"));
    try std.testing.expectEqualStrings("deleted remove.txt", file_deleted.body);
    try std.testing.expect(!pathExists(tmp.dir, "workspace/remove.txt"));

    const dir_deleted = try executeDelete(input, testCall("delete_file", "{\"path\":\"empty-dir\"}"));
    try std.testing.expectEqualStrings("deleted empty-dir", dir_deleted.body);
    try std.testing.expect(!pathExists(tmp.dir, "workspace/empty-dir"));

    const refused = try executeDelete(input, testCall("delete_file", "{\"path\":\"non-empty\"}"));
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.failure, refused.status);
    try std.testing.expectEqualStrings("delete_file failed: directory not empty: non-empty", refused.body);
    try std.testing.expect(pathExists(tmp.dir, "workspace/non-empty"));
}

test "tracked rename and copy preserve adapter output and tracker paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/old/name.txt", "moved content");
    try writeTestFile(tmp.dir, "workspace/source.txt", "copied content");

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const input = testInput(arena_state.allocator(), workspace, &tracker);

    const renamed = try executeRename(input, testCall("rename_file", "{\"old_path\":\"old/name.txt\",\"new_path\":\"new/deep/name.txt\"}"));
    try std.testing.expectEqualStrings("renamed old/name.txt -> new/deep/name.txt", renamed.body);
    try std.testing.expect(!pathExists(tmp.dir, "workspace/old/name.txt"));
    const moved = try readFileAlloc(arena_state.allocator(), tmp.dir, "workspace/new/deep/name.txt");
    try std.testing.expectEqualStrings("moved content", moved);

    const copied = try executeCopy(input, testCall("copy_file", "{\"source\":\"source.txt\",\"destination\":\"copied/deep/target.txt\",\"overwrite\":true}"));
    try std.testing.expectEqualStrings("copied source.txt -> copied/deep/target.txt", copied.body);
    const source = try readFileAlloc(arena_state.allocator(), tmp.dir, "workspace/source.txt");
    const destination = try readFileAlloc(arena_state.allocator(), tmp.dir, "workspace/copied/deep/target.txt");
    try std.testing.expectEqualStrings("copied content", source);
    try std.testing.expectEqualStrings("copied content", destination);

    try std.testing.expectEqual(@as(usize, 2), tracker.stack.items.len);
    try std.testing.expectEqual(change_tracker.OperationKind.rename, tracker.stack.items[0].kind);
    try std.testing.expect(tracker.stack.items[0].previous_content == null);
    try std.testing.expectEqual(change_tracker.OperationKind.write, tracker.stack.items[1].kind);
    try std.testing.expect(tracker.stack.items[1].previous_content == null);
}

test "tracked overwrite rename captures destination and undo restores both paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/source.txt", "source-bytes");
    try writeTestFile(tmp.dir, "workspace/dest.txt", "dest-preimage");

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const input = testInput(arena_state.allocator(), workspace, &tracker);

    const renamed = try executeRename(
        input,
        testCall("rename_file", "{\"old_path\":\"source.txt\",\"new_path\":\"dest.txt\"}"),
    );
    try std.testing.expectEqualStrings("renamed source.txt -> dest.txt", renamed.body);
    try std.testing.expect(!pathExists(tmp.dir, "workspace/source.txt"));
    const after_rename = try readFileAlloc(arena_state.allocator(), tmp.dir, "workspace/dest.txt");
    try std.testing.expectEqualStrings("source-bytes", after_rename);

    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    try std.testing.expectEqualStrings("dest-preimage", tracker.stack.items[0].previous_content.?);

    const undo = tracker.undoLast(std.heap.c_allocator);
    switch (undo) {
        .restored => |restored_path| {
            defer std.heap.c_allocator.free(restored_path);
            try std.testing.expect(std.mem.endsWith(u8, restored_path, "source.txt"));
        },
        else => return error.ExpectedRestore,
    }

    const restored_source = try readFileAlloc(arena_state.allocator(), tmp.dir, "workspace/source.txt");
    try std.testing.expectEqualStrings("source-bytes", restored_source);
    const restored_dest = try readFileAlloc(arena_state.allocator(), tmp.dir, "workspace/dest.txt");
    try std.testing.expectEqualStrings("dest-preimage", restored_dest);
}

test "tracked overwrite copy captures destination and undo restores it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/source.txt", "copied-bytes");
    try writeTestFile(tmp.dir, "workspace/dest.txt", "dest-preimage");

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const input = testInput(arena_state.allocator(), workspace, &tracker);

    const copied = try executeCopy(
        input,
        testCall("copy_file", "{\"source\":\"source.txt\",\"destination\":\"dest.txt\",\"overwrite\":true}"),
    );
    try std.testing.expectEqualStrings("copied source.txt -> dest.txt", copied.body);
    const after_copy = try readFileAlloc(arena_state.allocator(), tmp.dir, "workspace/dest.txt");
    try std.testing.expectEqualStrings("copied-bytes", after_copy);

    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    try std.testing.expectEqual(change_tracker.OperationKind.write, tracker.stack.items[0].kind);
    try std.testing.expectEqualStrings("dest-preimage", tracker.stack.items[0].previous_content.?);

    const undo = tracker.undoLast(std.heap.c_allocator);
    switch (undo) {
        .restored => |restored_path| {
            defer std.heap.c_allocator.free(restored_path);
            try std.testing.expect(std.mem.endsWith(u8, restored_path, "dest.txt"));
        },
        else => return error.ExpectedRestore,
    }

    const restored_dest = try readFileAlloc(arena_state.allocator(), tmp.dir, "workspace/dest.txt");
    try std.testing.expectEqualStrings("dest-preimage", restored_dest);
    const source = try readFileAlloc(arena_state.allocator(), tmp.dir, "workspace/source.txt");
    try std.testing.expectEqualStrings("copied-bytes", source);
}

test "tracked copy preserves destination on failed atomic replacement" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/source.txt", "new content");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/dest");

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const copied = try executeCopy(
        testInput(arena_state.allocator(), workspace, &tracker),
        testCall("copy_file", "{\"source\":\"source.txt\",\"destination\":\"dest\",\"overwrite\":true}"),
    );
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.failure, copied.status);
    try std.testing.expectEqualStrings("copy_file failed: source.txt", copied.body);
    const stat = try tmp.dir.statFile(io_mod.getIo(), "workspace/dest", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
}

test "tracked copy and rename reject destination symlinks escaping workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/source.txt", "source\n");
    try writeTestFile(tmp.dir, "workspace/rename-source.txt", "rename\n");
    try writeTestFile(tmp.dir, "outside.txt", "outside\n");

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const outside = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outside.txt");
    defer alloc.free(outside);
    try createSymlinkOrSkip(&tmp, outside, "workspace/outside-link", false);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const input = testInput(arena_state.allocator(), workspace, null);

    try std.testing.expectError(error.PathOutsideWorkspace, executeCopy(input, testCall("copy_file", "{\"source\":\"source.txt\",\"destination\":\"outside-link\",\"overwrite\":true}")));
    const outside_after_copy = try readFileAlloc(arena_state.allocator(), tmp.dir, "outside.txt");
    try std.testing.expectEqualStrings("outside\n", outside_after_copy);

    try std.testing.expectError(error.PathOutsideWorkspace, executeRename(input, testCall("rename_file", "{\"old_path\":\"rename-source.txt\",\"new_path\":\"outside-link\"}")));
    try std.testing.expect(pathExists(tmp.dir, "workspace/rename-source.txt"));
    const outside_after_rename = try readFileAlloc(arena_state.allocator(), tmp.dir, "outside.txt");
    try std.testing.expectEqualStrings("outside\n", outside_after_rename);
}

test "tracked mutation failures skip tracker publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/non-empty");
    try writeTestFile(tmp.dir, "workspace/non-empty/child.txt", "keep\n");
    try writeTestFile(tmp.dir, "workspace/rename-source.txt", "rename\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/rename-destination");
    try writeTestFile(tmp.dir, "workspace/rename-destination/child.txt", "keep\n");
    try writeTestFile(tmp.dir, "workspace/copy-source.txt", "copy\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/copy-destination");

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);

    const calls = [_]struct {
        kind: enum { delete, rename, copy },
        tool_name: []const u8,
        args_json: []const u8,
        failure_prefix: []const u8,
    }{
        .{ .kind = .delete, .tool_name = "delete_file", .args_json = "{\"path\":\"non-empty\"}", .failure_prefix = "delete_file failed:" },
        .{ .kind = .rename, .tool_name = "rename_file", .args_json = "{\"old_path\":\"rename-source.txt\",\"new_path\":\"rename-destination\"}", .failure_prefix = "rename_file failed:" },
        .{ .kind = .copy, .tool_name = "copy_file", .args_json = "{\"source\":\"copy-source.txt\",\"destination\":\"copy-destination\"}", .failure_prefix = "copy_file failed:" },
    };

    for (calls) |call| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const input = testInput(arena_state.allocator(), workspace, &tracker);
        const tool_call = testCall(call.tool_name, call.args_json);
        const result = switch (call.kind) {
            .delete => try executeDelete(input, tool_call),
            .rename => try executeRename(input, tool_call),
            .copy => try executeCopy(input, tool_call),
        };
        try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.failure, result.status);
        try std.testing.expect(std.mem.startsWith(u8, result.body, call.failure_prefix));
        try std.testing.expectEqual(@as(usize, 0), tracker.stack.items.len);
    }
}

const ConcurrentCopy = struct {
    workspace_root: []const u8,
    arguments_json: []const u8,
    tracker: ?*change_tracker.ChangeTracker,
    ready: *std.atomic.Value(usize),
    start: *std.atomic.Value(bool),
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena_state.deinit();
        _ = self.ready.fetchAdd(1, .seq_cst);
        while (!self.start.load(.seq_cst)) {
            std.atomic.spinLoopHint();
        }
        const result = executeCopy(
            testInput(arena_state.allocator(), self.workspace_root, self.tracker),
            testCall("copy_file", self.arguments_json),
        ) catch |err| {
            self.failure = err;
            return;
        };
        if (result.status != .success) self.failure = error.TestUnexpectedResult;
    }
};

test "concurrent child mutations never enter root undo history" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "workspace/source.txt", "source\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/root");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/child-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/child-b");

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var root_tracker: change_tracker.ChangeTracker = .{};
    defer root_tracker.deinit(std.heap.c_allocator);

    for (0..100) |iteration| {
        const root_args = try std.fmt.allocPrint(
            alloc,
            "{{\"source\":\"source.txt\",\"destination\":\"root/{d}.txt\"}}",
            .{iteration},
        );
        defer alloc.free(root_args);
        const child_a_args = try std.fmt.allocPrint(
            alloc,
            "{{\"source\":\"source.txt\",\"destination\":\"child-a/{d}.txt\"}}",
            .{iteration},
        );
        defer alloc.free(child_a_args);
        const child_b_args = try std.fmt.allocPrint(
            alloc,
            "{{\"source\":\"source.txt\",\"destination\":\"child-b/{d}.txt\"}}",
            .{iteration},
        );
        defer alloc.free(child_b_args);

        var ready = std.atomic.Value(usize).init(0);
        var start = std.atomic.Value(bool).init(false);
        var root_copy = ConcurrentCopy{
            .workspace_root = workspace,
            .arguments_json = root_args,
            .tracker = &root_tracker,
            .ready = &ready,
            .start = &start,
        };
        var child_a_copy = ConcurrentCopy{
            .workspace_root = workspace,
            .arguments_json = child_a_args,
            .tracker = null,
            .ready = &ready,
            .start = &start,
        };
        var child_b_copy = ConcurrentCopy{
            .workspace_root = workspace,
            .arguments_json = child_b_args,
            .tracker = null,
            .ready = &ready,
            .start = &start,
        };
        var root_thread: ?std.Thread = null;
        var child_a_thread: ?std.Thread = null;
        var child_b_thread: ?std.Thread = null;
        var joined = false;
        defer if (!joined) {
            start.store(true, .seq_cst);
            if (root_thread) |thread| thread.join();
            if (child_a_thread) |thread| thread.join();
            if (child_b_thread) |thread| thread.join();
        };
        root_thread = try std.Thread.spawn(.{}, ConcurrentCopy.run, .{&root_copy});
        child_a_thread = try std.Thread.spawn(.{}, ConcurrentCopy.run, .{&child_a_copy});
        child_b_thread = try std.Thread.spawn(.{}, ConcurrentCopy.run, .{&child_b_copy});
        while (ready.load(.seq_cst) != 3) std.atomic.spinLoopHint();
        start.store(true, .seq_cst);
        root_thread.?.join();
        child_a_thread.?.join();
        child_b_thread.?.join();
        joined = true;

        try std.testing.expect(root_copy.failure == null);
        try std.testing.expect(child_a_copy.failure == null);
        try std.testing.expect(child_b_copy.failure == null);
        try std.testing.expectEqual(iteration + 1, root_tracker.stack.items.len);
    }

    for (root_tracker.stack.items) |operation| {
        try std.testing.expect(std.mem.find(u8, operation.path, "/root/") != null);
        try std.testing.expect(std.mem.find(u8, operation.path, "/child-") == null);
    }
    const undo = root_tracker.undoLast(std.heap.c_allocator);
    switch (undo) {
        .deleted => |path| std.heap.c_allocator.free(path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!pathExists(tmp.dir, "workspace/root/99.txt"));
    try std.testing.expect(pathExists(tmp.dir, "workspace/child-a/99.txt"));
    try std.testing.expect(pathExists(tmp.dir, "workspace/child-b/99.txt"));
    try std.testing.expectEqual(@as(usize, 99), root_tracker.stack.items.len);
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
}

fn readFileAlloc(alloc: Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 4096);
}

fn pathExists(dir: std.Io.Dir, path: []const u8) bool {
    _ = dir.statFile(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn createSymlinkOrSkip(tmp: *std.testing.TmpDir, target_path: []const u8, link_path: []const u8, is_directory: bool) !void {
    if (std.fs.path.dirname(link_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    tmp.dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = is_directory }) catch |err| {
        if (err == error.SymLinkLoop or err == error.AccessDenied or err == error.OperationNotSupported) {
            return error.SkipZigTest;
        }
        return err;
    };
}

test "copy over a destination that cannot be captured refuses to undo it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "workspace/source.txt", "small source");
    {
        var destination = try tmp.dir.createFile(std.testing.io, "workspace/dest.bin", .{ .truncate = true });
        defer destination.close(io_mod.getIo());
        try destination.setLength(io_mod.getIo(), 10 * 1024 * 1024 + 1);
    }

    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    var tracker: change_tracker.ChangeTracker = .{};
    defer tracker.deinit(std.heap.c_allocator);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const input = testInput(arena_state.allocator(), workspace, &tracker);

    _ = try executeCopy(
        input,
        testCall("copy_file", "{\"source\":\"source.txt\",\"destination\":\"dest.bin\",\"overwrite\":true}"),
    );

    // The destination predates the copy, so undo must never treat it as a file the copy created.
    try std.testing.expectEqual(@as(usize, 1), tracker.stack.items.len);
    try std.testing.expect(tracker.stack.items[0].preimage_unavailable);

    const undo = tracker.undoLast(std.heap.c_allocator);
    switch (undo) {
        .unavailable => |path| std.heap.c_allocator.free(path),
        else => return error.ExpectedUnavailable,
    }
    try std.testing.expect(pathExists(tmp.dir, "workspace/dest.bin"));
}

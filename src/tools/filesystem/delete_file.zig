const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const permission_gate = @import("../../core/permissions/permission_gate.zig");
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
        return .{ .failure = try ctx.allocator.dupe(u8, "delete_file arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "delete_file arguments must be an object") };
    }

    const path_value = parsed.value.object.get("path") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "delete_file field \"path\" is required") };
    };
    if (path_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "delete_file field \"path\" must be a string") };
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
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve delete target: {s} ({s})", .{ input.path, @errorName(err) }) };
    };
    const rel = try displayPath(arena, ctx.workspace_root, target);

    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), target, .{}) catch {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "delete_file failed: path not found: {s}", .{rel}) };
    };

    const zio = io_mod.getIo();
    if (stat.kind == .directory) {
        std.Io.Dir.deleteDirAbsolute(zio, target) catch |err| {
            if (err == error.DirNotEmpty) {
                return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "delete_file failed: directory not empty: {s}", .{rel}) };
            }
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "delete_file failed: {s}", .{rel}) };
        };
    } else {
        std.Io.Dir.deleteFileAbsolute(zio, target) catch {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "delete_file failed: {s}", .{rel}) };
        };
    }

    return .{ .success = try std.fmt.allocPrint(ctx.allocator, "deleted {s}", .{rel}) };
}

fn statPathEntry(path: []const u8) !std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false });
}

fn displayPath(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8) ![]const u8 {
    const rel = try pathing.workspaceRelativePath(arena, workspace_root, absolute_path);
    return if (rel.len == 0) "." else rel;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

const delete_file_dispatch_tool = tool_dispatch.Tool{
    .name = "delete_file",
    .description = "Delete file dispatch test fixture.",
    .descriptor = .{
        .name = "delete_file",
        .description = "Delete file dispatch test fixture.",
    },
    .executor_kind = .delete_file,
    .activity_kind = .write,
    .requires_approval = true,
    .permission_target_kind = .path_existing,
    .decode = decode,
    .validate = validate,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

fn validateStackInput(alloc: Allocator, input: *Input, workspace_root: []const u8) !?[]u8 {
    return validate(.{ .allocator = alloc, .workspace_root = workspace_root }, .{ .ptr = input, .deinit_fn = noopInputDeinit });
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

fn deleteArgsJson(alloc: Allocator, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchDeleteFile(alloc: Allocator, workspace_root: []const u8, path: []const u8) !tool_dispatch.DispatchResult {
    const args = try deleteArgsJson(alloc, path);
    defer alloc.free(args);

    const registry = tool_dispatch.Registry{ .tools = &.{delete_file_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .permission_decider = allowDecision,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "delete_file",
        .arguments_json = args,
    });
}

fn allowDecision(_: *const tool_dispatch.Tool, _: tool_dispatch.ToolInput, _: tool_dispatch.DispatchContext) permission_gate.Decision {
    return .{ .action = .allow, .reason = "allowed by test" };
}

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn writeTempFile(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) ![]u8 {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn readAbsolute(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn createSymlinkOrSkip(tmp: *std.testing.TmpDir, target_path: []const u8, link_path: []const u8, is_directory: bool) !void {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = is_directory }) catch |err| {
        if (isSymlinkPermissionError(err)) return error.SkipZigTest;
        return err;
    };
}

fn isSymlinkPermissionError(err: anyerror) bool {
    return err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied");
}

test "delete_file rejects invalid JSON" {
    try expectDecodeFailure("{", "delete_file arguments must be valid JSON");
}

test "delete_file rejects non-object JSON" {
    try expectDecodeFailure("[]", "delete_file arguments must be an object");
}

test "delete_file rejects missing path" {
    try expectDecodeFailure("{}", "delete_file field \"path\" is required");
}

test "delete_file rejects non-string path" {
    try expectDecodeFailure("{\"path\":1}", "delete_file field \"path\" must be a string");
}

test "delete_file leaves path normalization to active resolver" {
    const alloc = std.testing.allocator;
    var empty = Input{ .path = try alloc.dupe(u8, "") };
    defer empty.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty, "/tmp/workspace")) == null);

    var whitespace_path = Input{ .path = try alloc.dupe(u8, " \t\r\n ") };
    defer whitespace_path.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &whitespace_path, "/tmp/workspace")) == null);
}

test "delete_file deletes regular file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "notes.txt", "hello\n");
    defer alloc.free(path);

    const result = try dispatchDeleteFile(alloc, workspace, "notes.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("deleted notes.txt", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}));
}

test "delete_file deletes empty directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "empty");
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "empty");
    defer alloc.free(path);

    const result = try dispatchDeleteFile(alloc, workspace, "empty");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("deleted empty", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}));
}

test "delete_file refuses non-empty directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const child = try writeTempFile(alloc, &tmp, "dir/file.txt", "x\n");
    defer alloc.free(child);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchDeleteFile(alloc, workspace, "dir");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("delete_file failed: directory not empty: dir", result.body);
    try std.testing.expect(std.mem.find(u8, result.body, workspace) == null);
}

test "delete_file reports missing target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchDeleteFile(alloc, workspace, "missing.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve delete target: missing.txt (FileNotFound)", result.body);
    try std.testing.expect(std.mem.find(u8, result.body, workspace) == null);
}

test "delete_file accepts external absolute path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const outside = try writeTempFile(alloc, &tmp, "outside.txt", "x\n");
    defer alloc.free(outside);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const result = try dispatchDeleteFile(alloc, workspace, outside);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "deleted {s}", .{outside});
    defer alloc.free(expected);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(expected, result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), outside, .{}));
}

test "delete_file follows final symlink to file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try writeTempFile(alloc, &tmp, "target.txt", "target\n");
    defer alloc.free(target);
    try createSymlinkOrSkip(&tmp, "target.txt", "link.txt", false);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const link_path = try std.fs.path.join(alloc, &.{ workspace, "link.txt" });
    defer alloc.free(link_path);

    const result = try dispatchDeleteFile(alloc, workspace, "link.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("deleted target.txt", result.body);
    const link_stat = try statPathEntry(link_path);
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link_stat.kind);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), target, .{}));
}

test "delete_file follows final symlink to directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "target-dir");
    try createSymlinkOrSkip(&tmp, "target-dir", "dir-link", true);
    const target_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "target-dir");
    defer alloc.free(target_dir);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const link_path = try std.fs.path.join(alloc, &.{ workspace, "dir-link" });
    defer alloc.free(link_path);

    const result = try dispatchDeleteFile(alloc, workspace, "dir-link");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("deleted target-dir", result.body);
    const link_stat = try statPathEntry(link_path);
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link_stat.kind);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), target_dir, .{}));
}

test "delete_file rejects symlink resolving outside workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const outside = try writeTempFile(alloc, &tmp, "outside.txt", "outside\n");
    defer alloc.free(outside);
    tmp.dir.symLink(std.testing.io, outside, "workspace/outside-link", .{}) catch |err| {
        if (isSymlinkPermissionError(err)) return error.SkipZigTest;
        return err;
    };
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const result = try dispatchDeleteFile(alloc, workspace, "outside-link");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve delete target: outside-link (PathOutsideWorkspace)", result.body);
    const content = try readAbsolute(alloc, outside);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("outside\n", content);
}

test "delete_file classifiers are mutating and irreversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{ .path = try std.testing.allocator.dupe(u8, "file.txt") };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(!readsOnly(erased));
    try std.testing.expect(isIrreversible(erased));
}

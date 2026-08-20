const std = @import("std");
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
        return .{ .failure = try ctx.allocator.dupe(u8, "create_folder arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "create_folder arguments must be an object") };
    }

    const path_value = parsed.value.object.get("path") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "create_folder field \"path\" is required") };
    };
    if (path_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "create_folder field \"path\" must be a string") };
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

    const target = pathing.resolveWorkspaceOrExternalCreatePath(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve folder target: {s} ({s})", .{ input.path, @errorName(err) }) };
    };

    const rel = try displayPath(arena, ctx.workspace_root, target);
    const zio = io_mod.getIo();
    std.Io.Dir.createDirAbsolute(zio, target, .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            if (!targetIsDirectory(target)) {
                return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "create_folder failed: target exists and is not a directory: {s}", .{rel}) };
            }
            return .{ .success = try std.fmt.allocPrint(ctx.allocator, "directory already exists: {s}", .{rel}) };
        }

        pathing.ensureParentDirectories(target) catch |parent_err| {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "create_folder failed: {s} ({s})", .{ rel, @errorName(parent_err) }) };
        };
        std.Io.Dir.createDirAbsolute(zio, target, .default_dir) catch {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "create_folder failed: {s}", .{rel}) };
        };
    };

    return .{ .success = try std.fmt.allocPrint(ctx.allocator, "created {s}", .{rel}) };
}

fn displayPath(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8) ![]const u8 {
    const rel = try pathing.workspaceRelativePath(arena, workspace_root, absolute_path);
    return if (rel.len == 0) "." else rel;
}

fn targetIsDirectory(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return false;
    return stat.kind == .directory;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

const create_folder_dispatch_tool = tool_dispatch.Tool{
    .name = "create_folder",
    .description = "Create folder dispatch test fixture.",
    .descriptor = .{
        .name = "create_folder",
        .description = "Create folder dispatch test fixture.",
    },
    .executor_kind = .create_folder,
    .activity_kind = .write,
    .requires_approval = true,
    .permission_target_kind = .path_create_parent,
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

fn createFolderArgsJson(alloc: Allocator, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchCreateFolder(alloc: Allocator, workspace_root: []const u8, path: []const u8) !tool_dispatch.DispatchResult {
    const args = try createFolderArgsJson(alloc, path);
    defer alloc.free(args);

    const registry = tool_dispatch.Registry{ .tools = &.{create_folder_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .permission_decider = allowDecision,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "create_folder",
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

test "create_folder rejects invalid JSON" {
    try expectDecodeFailure("{", "create_folder arguments must be valid JSON");
}

test "create_folder rejects non-object JSON" {
    try expectDecodeFailure("[]", "create_folder arguments must be an object");
}

test "create_folder rejects missing path" {
    try expectDecodeFailure("{}", "create_folder field \"path\" is required");
}

test "create_folder rejects non-string path" {
    try expectDecodeFailure("{\"path\":1}", "create_folder field \"path\" must be a string");
}

test "create_folder leaves path normalization to active resolver" {
    const alloc = std.testing.allocator;
    var empty = Input{ .path = try alloc.dupe(u8, "") };
    defer empty.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty, "/tmp/workspace")) == null);

    var whitespace_path = Input{ .path = try alloc.dupe(u8, " \t\r\n ") };
    defer whitespace_path.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &whitespace_path, "/tmp/workspace")) == null);
}

test "create_folder creates directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try std.fs.path.join(alloc, &.{ workspace, "new-dir" });
    defer alloc.free(path);

    const result = try dispatchCreateFolder(alloc, workspace, "new-dir");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("created new-dir", result.body);
    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
}

test "create_folder creates missing intermediate parents" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try std.fs.path.join(alloc, &.{ workspace, "nested/dir/new-dir" });
    defer alloc.free(path);

    const result = try dispatchCreateFolder(alloc, workspace, "nested/dir/new-dir");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("created nested/dir/new-dir", result.body);
    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
}

test "create_folder returns idempotent success for existing directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "existing");
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchCreateFolder(alloc, workspace, "existing");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("directory already exists: existing", result.body);
}

test "create_folder returns failure when regular file exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file_path = try writeTempFile(alloc, &tmp, "existing", "file\n");
    defer alloc.free(file_path);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchCreateFolder(alloc, workspace, "existing");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("create_folder failed: target exists and is not a directory: existing", result.body);
    try std.testing.expect(std.mem.find(u8, result.body, workspace) == null);
    const content = try readAbsolute(alloc, file_path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("file\n", content);
}

test "create_folder accepts external absolute path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const outside = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(outside);
    const outside_target = try std.fs.path.join(alloc, &.{ outside, "outside-dir" });
    defer alloc.free(outside_target);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const result = try dispatchCreateFolder(alloc, workspace, outside_target);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "created {s}", .{outside_target});
    defer alloc.free(expected);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(expected, result.body);
    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), outside_target, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
}

test "create_folder rejects dangling symlink escaping workspace" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    const outside_target = try std.fs.path.join(alloc, &.{ external, "created-dir" });
    defer alloc.free(outside_target);
    tmp.dir.symLink(std.testing.io, outside_target, "workspace/outside-link", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) return error.SkipZigTest;
        return err;
    };

    const result = try dispatchCreateFolder(alloc, workspace, "outside-link");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve folder target: outside-link (PathOutsideWorkspace)", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), outside_target, .{}));
}

test "create_folder classifiers are mutating and reversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{ .path = try std.testing.allocator.dupe(u8, "dir") };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(!readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
}

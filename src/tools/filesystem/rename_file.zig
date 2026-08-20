const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const permission_gate = @import("../../core/permissions/permission_gate.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    old_path: []u8,
    new_path: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.old_path);
        alloc.free(self.new_path);
        self.* = .{ .old_path = &.{}, .new_path = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "rename_file arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "rename_file arguments must be an object") };
    }

    const old_value = parsed.value.object.get("old_path") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "rename_file field \"old_path\" is required") };
    };
    if (old_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "rename_file field \"old_path\" must be a string") };
    }

    const new_value = parsed.value.object.get("new_path") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "rename_file field \"new_path\" is required") };
    };
    if (new_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "rename_file field \"new_path\" must be a string") };
    }

    const owned_old = try ctx.allocator.dupe(u8, old_value.string);
    errdefer ctx.allocator.free(owned_old);
    const owned_new = try ctx.allocator.dupe(u8, new_value.string);
    errdefer ctx.allocator.free(owned_new);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .old_path = owned_old,
        .new_path = owned_new,
    };

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

    const source = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.old_path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve rename source: {s} ({s})", .{ input.old_path, @errorName(err) }) };
    };
    const destination = pathing.resolveWorkspaceOrExternalCreatePath(arena, ctx.workspace_root, input.new_path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve rename destination: {s} ({s})", .{ input.new_path, @errorName(err) }) };
    };

    const old_rel = try displayPath(arena, ctx.workspace_root, source);
    const new_rel = try displayPath(arena, ctx.workspace_root, destination);

    pathing.ensureParentDirectories(destination) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to rename: {s} -> {s} ({s})", .{ old_rel, new_rel, @errorName(err) }) };
    };

    std.Io.Dir.renameAbsolute(source, destination, io_mod.getIo()) catch {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "rename_file failed: {s}", .{old_rel}) };
    };

    return .{ .success = try std.fmt.allocPrint(ctx.allocator, "renamed {s} -> {s}", .{ old_rel, new_rel }) };
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

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

const rename_file_dispatch_tool = tool_dispatch.Tool{
    .name = "rename_file",
    .description = "Rename file dispatch test fixture.",
    .descriptor = .{
        .name = "rename_file",
        .description = "Rename file dispatch test fixture.",
    },
    .executor_kind = .rename_file,
    .activity_kind = .write,
    .requires_approval = true,
    .action_label = "Renaming",
    .completed_action_label = "Renamed",
    .label_arg_kind = .old_path,
    .label_arg_default = "file",
    .permission_target_kind = .none,
    .decode = decode,
    .validate = validate,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

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

fn renameArgsJson(alloc: Allocator, old_path: []const u8, new_path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"old_path\":");
    try std.json.Stringify.value(old_path, .{}, &out.writer);
    try out.writer.writeAll(",\"new_path\":");
    try std.json.Stringify.value(new_path, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchRenameFileJson(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{rename_file_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .permission_decider = allowDecision,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "rename_file",
        .arguments_json = args_json,
    });
}

fn dispatchRenameFile(alloc: Allocator, workspace_root: []const u8, old_path: []const u8, new_path: []const u8) !tool_dispatch.DispatchResult {
    const args = try renameArgsJson(alloc, old_path, new_path);
    defer alloc.free(args);
    return dispatchRenameFileJson(alloc, workspace_root, args);
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

fn pathJoin(alloc: Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ a, b });
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

fn readLinkAbsolute(path: []const u8, buffer: []u8) ![]const u8 {
    const len = try std.Io.Dir.readLinkAbsolute(io_mod.getIo(), path, buffer);
    return buffer[0..len];
}

test "rename_file rejects invalid JSON" {
    try expectDecodeFailure("{", "rename_file arguments must be valid JSON");
}

test "rename_file rejects non-object JSON" {
    try expectDecodeFailure("[]", "rename_file arguments must be an object");
}

test "rename_file rejects missing old_path" {
    try expectDecodeFailure("{\"new_path\":\"b\"}", "rename_file field \"old_path\" is required");
}

test "rename_file rejects missing new_path" {
    try expectDecodeFailure("{\"old_path\":\"a\"}", "rename_file field \"new_path\" is required");
}

test "rename_file rejects non-string path fields" {
    try expectDecodeFailure("{\"old_path\":1,\"new_path\":\"b\"}", "rename_file field \"old_path\" must be a string");
    try expectDecodeFailure("{\"old_path\":\"a\",\"new_path\":1}", "rename_file field \"new_path\" must be a string");
}

test "rename_file leaves path normalization to active resolver" {
    const alloc = std.testing.allocator;
    var empty_old = Input{
        .old_path = try alloc.dupe(u8, " \n "),
        .new_path = try alloc.dupe(u8, "next"),
    };
    defer empty_old.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty_old, "/tmp/workspace")) == null);

    var empty_new = Input{
        .old_path = try alloc.dupe(u8, "old"),
        .new_path = try alloc.dupe(u8, " \t "),
    };
    defer empty_new.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty_new, "/tmp/workspace")) == null);
}

test "rename_file renames file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_path = try writeTempFile(alloc, &tmp, "old.txt", "hello\n");
    defer alloc.free(old_path);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const new_path = try pathJoin(alloc, workspace, "new.txt");
    defer alloc.free(new_path);

    const result = try dispatchRenameFile(alloc, workspace, "old.txt", "new.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("renamed old.txt -> new.txt", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), old_path, .{}));
    const content = try readAbsolute(alloc, new_path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("hello\n", content);
}

test "rename_file creates missing parent directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_path = try writeTempFile(alloc, &tmp, "old.txt", "hello\n");
    defer alloc.free(old_path);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const new_path = try pathJoin(alloc, workspace, "nested/dir/new.txt");
    defer alloc.free(new_path);

    const result = try dispatchRenameFile(alloc, workspace, "old.txt", "nested/dir/new.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("renamed old.txt -> nested/dir/new.txt", result.body);
    const content = try readAbsolute(alloc, new_path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("hello\n", content);
}

test "rename_file allows same path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(alloc, &tmp, "same.txt", "same\n");
    defer alloc.free(path);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchRenameFile(alloc, workspace, "same.txt", "same.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("renamed same.txt -> same.txt", result.body);
    const content = try readAbsolute(alloc, path);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("same\n", content);
}

test "rename_file accepts legacy overwrite false without changing replacement behavior" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "source.txt", "source\n");
    defer alloc.free(source);
    const destination = try writeTempFile(alloc, &tmp, "dest.txt", "dest\n");
    defer alloc.free(destination);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchRenameFileJson(
        alloc,
        workspace,
        "{\"old_path\":\"source.txt\",\"new_path\":\"dest.txt\",\"overwrite\":false}",
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("renamed source.txt -> dest.txt", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), source, .{}));
    const dest_content = try readAbsolute(alloc, destination);
    defer alloc.free(dest_content);
    try std.testing.expectEqualStrings("source\n", dest_content);
}

test "rename_file replaces existing regular destination" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "source.txt", "source\n");
    defer alloc.free(source);
    const destination = try writeTempFile(alloc, &tmp, "dest.txt", "dest\n");
    defer alloc.free(destination);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchRenameFile(alloc, workspace, "source.txt", "dest.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("renamed source.txt -> dest.txt", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), source, .{}));
    const dest_content = try readAbsolute(alloc, destination);
    defer alloc.free(dest_content);
    try std.testing.expectEqualStrings("source\n", dest_content);
}

test "rename_file replaces existing destination symlink target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "source.txt", "source\n");
    defer alloc.free(source);
    const target = try writeTempFile(alloc, &tmp, "target.txt", "target\n");
    defer alloc.free(target);
    try createSymlinkOrSkip(&tmp, "target.txt", "dest-link", false);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const destination = try pathJoin(alloc, workspace, "dest-link");
    defer alloc.free(destination);

    const result = try dispatchRenameFile(alloc, workspace, "source.txt", "dest-link");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("renamed source.txt -> target.txt", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), source, .{}));
    const destination_stat = try statPathEntry(destination);
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, destination_stat.kind);
    const destination_content = try readAbsolute(alloc, destination);
    defer alloc.free(destination_content);
    try std.testing.expectEqualStrings("source\n", destination_content);
    const target_content = try readAbsolute(alloc, target);
    defer alloc.free(target_content);
    try std.testing.expectEqualStrings("source\n", target_content);
}

test "rename_file reports missing old path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchRenameFile(alloc, workspace, "missing.txt", "dest.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve rename source: missing.txt (FileNotFound)", result.body);
}

test "rename_file accepts external absolute source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const outside = try writeTempFile(alloc, &tmp, "outside.txt", "outside\n");
    defer alloc.free(outside);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const destination = try pathJoin(alloc, workspace, "dest.txt");
    defer alloc.free(destination);

    const result = try dispatchRenameFile(alloc, workspace, outside, "dest.txt");
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "renamed {s} -> dest.txt", .{outside});
    defer alloc.free(expected);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(expected, result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), outside, .{}));
    const content = try readAbsolute(alloc, destination);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("outside\n", content);
}

test "rename_file renames symlink to file as link" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try writeTempFile(alloc, &tmp, "target.txt", "target\n");
    defer alloc.free(target);
    try createSymlinkOrSkip(&tmp, "target.txt", "link.txt", false);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const old_link = try pathJoin(alloc, workspace, "link.txt");
    defer alloc.free(old_link);
    const new_link = try pathJoin(alloc, workspace, "moved-link.txt");
    defer alloc.free(new_link);

    const result = try dispatchRenameFile(alloc, workspace, "link.txt", "moved-link.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("renamed target.txt -> moved-link.txt", result.body);
    const old_stat = try statPathEntry(old_link);
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, old_stat.kind);
    const moved_stat = try statPathEntry(new_link);
    try std.testing.expectEqual(std.Io.File.Kind.file, moved_stat.kind);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), target, .{}));
    const moved_content = try readAbsolute(alloc, new_link);
    defer alloc.free(moved_content);
    try std.testing.expectEqualStrings("target\n", moved_content);
}

test "rename_file rejects source symlink resolving outside workspace" {
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
    const result = try dispatchRenameFile(alloc, workspace, "outside-link", "moved-outside-link");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve rename source: outside-link (PathOutsideWorkspace)", result.body);
    const outside_content = try readAbsolute(alloc, outside);
    defer alloc.free(outside_content);
    try std.testing.expectEqualStrings("outside\n", outside_content);
}

test "rename_file replaces safe dangling destination symlink" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "source.txt", "source\n");
    defer alloc.free(source);
    try createSymlinkOrSkip(&tmp, "missing-target.txt", "dangling", false);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchRenameFile(alloc, workspace, "source.txt", "dangling");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("renamed source.txt -> dangling", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), source, .{}));
}

test "rename_file rejects destination symlink escaping workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const outside = try writeTempFile(alloc, &tmp, "outside.txt", "outside\n");
    defer alloc.free(outside);
    const source = try writeTempFile(alloc, &tmp, "workspace/source.txt", "source\n");
    defer alloc.free(source);
    try createSymlinkOrSkip(&tmp, outside, "workspace/outside-link", false);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const link_path = try pathJoin(alloc, workspace, "outside-link");
    defer alloc.free(link_path);

    const result = try dispatchRenameFile(alloc, workspace, "source.txt", "outside-link");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve rename destination: outside-link (PathOutsideWorkspace)", result.body);
    const source_content = try readAbsolute(alloc, source);
    defer alloc.free(source_content);
    try std.testing.expectEqualStrings("source\n", source_content);
    const outside_content = try readAbsolute(alloc, outside);
    defer alloc.free(outside_content);
    try std.testing.expectEqualStrings("outside\n", outside_content);
    const link_stat = try statPathEntry(link_path);
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link_stat.kind);
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(outside, try readLinkAbsolute(link_path, &buffer));
}

test "rename_file rejects dangling destination symlink escaping workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const source = try writeTempFile(alloc, &tmp, "workspace/source.txt", "source\n");
    defer alloc.free(source);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    const outside_target = try pathJoin(alloc, external, "created.txt");
    defer alloc.free(outside_target);
    try createSymlinkOrSkip(&tmp, outside_target, "workspace/outside-link", false);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const result = try dispatchRenameFile(alloc, workspace, "source.txt", "outside-link");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve rename destination: outside-link (PathOutsideWorkspace)", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), outside_target, .{}));
    const source_content = try readAbsolute(alloc, source);
    defer alloc.free(source_content);
    try std.testing.expectEqualStrings("source\n", source_content);
}

test "rename_file classifiers are mutating and irreversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{
        .old_path = try std.testing.allocator.dupe(u8, "old.txt"),
        .new_path = try std.testing.allocator.dupe(u8, "new.txt"),
    };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(!readsOnly(erased));
    try std.testing.expect(isIrreversible(erased));
}

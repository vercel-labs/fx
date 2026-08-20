const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const permission_gate = @import("../../core/permissions/permission_gate.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    source: []u8,
    destination: []u8,
    overwrite: bool,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.source);
        alloc.free(self.destination);
        self.* = .{ .source = &.{}, .destination = &.{}, .overwrite = true };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "copy_file arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "copy_file arguments must be an object") };
    }

    const source_value = parsed.value.object.get("source") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "copy_file field \"source\" is required") };
    };
    if (source_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "copy_file field \"source\" must be a string") };
    }

    const destination_value = parsed.value.object.get("destination") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "copy_file field \"destination\" is required") };
    };
    if (destination_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "copy_file field \"destination\" must be a string") };
    }

    const owned_source = try ctx.allocator.dupe(u8, source_value.string);
    errdefer ctx.allocator.free(owned_source);
    const owned_destination = try ctx.allocator.dupe(u8, destination_value.string);
    errdefer ctx.allocator.free(owned_destination);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .source = owned_source,
        .destination = owned_destination,
        .overwrite = true,
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

    const source = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.source) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve copy source: {s} ({s})", .{ input.source, @errorName(err) }) };
    };
    const destination = pathing.resolveWorkspaceOrExternalCreatePath(arena, ctx.workspace_root, input.destination) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve copy destination: {s} ({s})", .{ input.destination, @errorName(err) }) };
    };

    const source_rel = try displayPath(arena, ctx.workspace_root, source);
    const dest_rel = try displayPath(arena, ctx.workspace_root, destination);

    pathing.ensureParentDirectories(destination) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to copy: {s} -> {s} ({s})", .{ source_rel, dest_rel, @errorName(err) }) };
    };

    io_mod.copyFileAtomic(ctx.allocator, source, destination) catch {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "copy_file failed: {s}", .{source_rel}) };
    };

    return .{ .success = try std.fmt.allocPrint(ctx.allocator, "copied {s} -> {s}", .{ source_rel, dest_rel }) };
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

const copy_file_dispatch_tool = tool_dispatch.Tool{
    .name = "copy_file",
    .description = "Copy file dispatch test fixture.",
    .descriptor = .{
        .name = "copy_file",
        .description = "Copy file dispatch test fixture.",
    },
    .executor_kind = .copy_file,
    .activity_kind = .write,
    .requires_approval = true,
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

fn copyArgsJson(alloc: Allocator, source: []const u8, destination: []const u8, overwrite: ?bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"source\":");
    try std.json.Stringify.value(source, .{}, &out.writer);
    try out.writer.writeAll(",\"destination\":");
    try std.json.Stringify.value(destination, .{}, &out.writer);
    if (overwrite) |value| {
        try out.writer.print(",\"overwrite\":{}", .{value});
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchCopyFile(alloc: Allocator, workspace_root: []const u8, source: []const u8, destination: []const u8, overwrite: ?bool) !tool_dispatch.DispatchResult {
    const args = try copyArgsJson(alloc, source, destination, overwrite);
    defer alloc.free(args);

    const registry = tool_dispatch.Registry{ .tools = &.{copy_file_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .permission_decider = allowDecision,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "copy_file",
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

test "copy_file rejects invalid JSON" {
    try expectDecodeFailure("{", "copy_file arguments must be valid JSON");
}

test "copy_file rejects non-object JSON" {
    try expectDecodeFailure("[]", "copy_file arguments must be an object");
}

test "copy_file rejects missing source" {
    try expectDecodeFailure("{\"destination\":\"b\"}", "copy_file field \"source\" is required");
}

test "copy_file rejects missing destination" {
    try expectDecodeFailure("{\"source\":\"a\"}", "copy_file field \"destination\" is required");
}

test "copy_file rejects non-string fields and ignores unsigned overwrite" {
    try expectDecodeFailure("{\"source\":1,\"destination\":\"b\"}", "copy_file field \"source\" must be a string");
    try expectDecodeFailure("{\"source\":\"a\",\"destination\":1}", "copy_file field \"destination\" must be a string");

    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"source\":\"a\",\"destination\":\"b\",\"overwrite\":\"no\"}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(input.as(Input).overwrite);
        },
    }
}

test "copy_file leaves path normalization to active resolver" {
    const alloc = std.testing.allocator;
    var empty_source = Input{
        .source = try alloc.dupe(u8, " \n "),
        .destination = try alloc.dupe(u8, "next"),
        .overwrite = true,
    };
    defer empty_source.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty_source, "/tmp/workspace")) == null);

    var empty_destination = Input{
        .source = try alloc.dupe(u8, "old"),
        .destination = try alloc.dupe(u8, " \t "),
        .overwrite = true,
    };
    defer empty_destination.deinit(alloc);
    try std.testing.expect((try validateStackInput(alloc, &empty_destination, "/tmp/workspace")) == null);
}

test "copy_file copies file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "source.txt", "source\n");
    defer alloc.free(source);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const destination = try pathJoin(alloc, workspace, "dest.txt");
    defer alloc.free(destination);

    const result = try dispatchCopyFile(alloc, workspace, "source.txt", "dest.txt", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("copied source.txt -> dest.txt", result.body);
    const content = try readAbsolute(alloc, destination);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("source\n", content);
}

test "copy_file copies into missing parent directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "source.txt", "source\n");
    defer alloc.free(source);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const destination = try pathJoin(alloc, workspace, "nested/dir/dest.txt");
    defer alloc.free(destination);

    const result = try dispatchCopyFile(alloc, workspace, "source.txt", "nested/dir/dest.txt", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("copied source.txt -> nested/dir/dest.txt", result.body);
    const content = try readAbsolute(alloc, destination);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("source\n", content);
}

test "copy_file allows same path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "same.txt", "same\n");
    defer alloc.free(source);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchCopyFile(alloc, workspace, "same.txt", "same.txt", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("copied same.txt -> same.txt", result.body);
    const content = try readAbsolute(alloc, source);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("same\n", content);
}

test "copy_file ignores unsigned overwrite false and replaces existing destination" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "source.txt", "source\n");
    defer alloc.free(source);
    const destination = try writeTempFile(alloc, &tmp, "dest.txt", "dest\n");
    defer alloc.free(destination);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchCopyFile(alloc, workspace, "source.txt", "dest.txt", false);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("copied source.txt -> dest.txt", result.body);
    const dest_content = try readAbsolute(alloc, destination);
    defer alloc.free(dest_content);
    try std.testing.expectEqualStrings("source\n", dest_content);
}

test "copy_file default overwrite replaces destination content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "source.txt", "source\n");
    defer alloc.free(source);
    const destination = try writeTempFile(alloc, &tmp, "dest.txt", "dest\n");
    defer alloc.free(destination);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchCopyFile(alloc, workspace, "source.txt", "dest.txt", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("copied source.txt -> dest.txt", result.body);
    const dest_content = try readAbsolute(alloc, destination);
    defer alloc.free(dest_content);
    try std.testing.expectEqualStrings("source\n", dest_content);
}

test "copy_file rejects non-regular existing destination" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try writeTempFile(alloc, &tmp, "source.txt", "source\n");
    defer alloc.free(source);
    try tmp.dir.createDirPath(io_mod.getIo(), "dest");
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchCopyFile(alloc, workspace, "source.txt", "dest", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("copy_file failed: source.txt", result.body);
}

test "copy_file reports nonexistent source with raw input" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchCopyFile(alloc, workspace, "missing.txt", "dest.txt", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve copy source: missing.txt (FileNotFound)", result.body);
}

test "copy_file accepts external absolute source" {
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

    const result = try dispatchCopyFile(alloc, workspace, outside, "dest.txt", null);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "copied {s} -> dest.txt", .{outside});
    defer alloc.free(expected);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(expected, result.body);
    const content = try readAbsolute(alloc, destination);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("outside\n", content);
}

test "copy_file follows source symlink to file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try writeTempFile(alloc, &tmp, "target.txt", "target\n");
    defer alloc.free(target);
    try createSymlinkOrSkip(&tmp, "target.txt", "link.txt", false);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const destination = try pathJoin(alloc, workspace, "copied.txt");
    defer alloc.free(destination);

    const result = try dispatchCopyFile(alloc, workspace, "link.txt", "copied.txt", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("copied target.txt -> copied.txt", result.body);
    const content = try readAbsolute(alloc, destination);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("target\n", content);
}

test "copy_file rejects destination symlink escaping workspace" {
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

    const result = try dispatchCopyFile(alloc, workspace, "source.txt", "outside-link", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve copy destination: outside-link (PathOutsideWorkspace)", result.body);
    const outside_content = try readAbsolute(alloc, outside);
    defer alloc.free(outside_content);
    try std.testing.expectEqualStrings("outside\n", outside_content);
}

test "copy_file rejects dangling destination symlink escaping workspace" {
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

    const result = try dispatchCopyFile(alloc, workspace, "source.txt", "outside-link", null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("Unable to resolve copy destination: outside-link (PathOutsideWorkspace)", result.body);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io_mod.getIo(), outside_target, .{}));
    const source_content = try readAbsolute(alloc, source);
    defer alloc.free(source_content);
    try std.testing.expectEqualStrings("source\n", source_content);
}

test "copy_file classifiers are mutating and irreversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{
        .source = try std.testing.allocator.dupe(u8, "source.txt"),
        .destination = try std.testing.allocator.dupe(u8, "dest.txt"),
        .overwrite = true,
    };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(!readsOnly(erased));
    try std.testing.expect(isIrreversible(erased));
}

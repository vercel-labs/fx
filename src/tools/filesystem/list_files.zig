const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const list_files_listing = @import("../../core/workspace/list_files_listing.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");

const Allocator = std.mem.Allocator;

/// Typed input for the built-in list_files tool.
pub const Input = struct {
    path: []u8,
    path_provided: bool,

    /// Frees the owned normalized path.
    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = .{ .path = &.{}, .path_provided = false };
    }
};

/// Decodes list_files JSON into an owned Input released by ToolInput.deinit.
pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "list_files arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "list_files arguments must be an object") };
    }

    const path_value = parsed.value.object.get("path");
    const path_string: ?[]const u8 = if (path_value) |value| switch (value) {
        .string => |path| path,
        else => null,
    } else null;

    const owned_path = try ctx.allocator.dupe(u8, path_string orelse "");
    errdefer ctx.allocator.free(owned_path);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .path = owned_path,
        .path_provided = path_string != null,
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

const DirEntrySource = struct {
    iterator: std.Io.Dir.Iterator,

    pub fn next(self: *@This()) !?list_files_listing.SourceEntry {
        const entry = (try self.iterator.next(io_mod.getIo())) orelse return null;
        return .{
            .name = entry.name,
            .kind = switch (entry.kind) {
                .directory => .directory,
                .sym_link => .sym_link,
                else => .other,
            },
        };
    }
};

/// Lists the resolved directory and returns an owned tool result body.
pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const requested = if (input.path_provided) input.path else ".";

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resolved = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, requested) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "list_files", requested, err) };
        }
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve list root: {s} ({s})", .{ requested, @errorName(err) }) };
    };

    const zio = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(zio, resolved, .{ .iterate = true }) catch |err| {
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "list_files", resolved, err) };
        }
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to open list directory: {s} ({s})", .{ resolved, @errorName(err) }) };
    };
    defer dir.close(zio);

    var source = DirEntrySource{ .iterator = dir.iterate() };
    return list_files_listing.listResolvedDirectory(
        ctx.allocator,
        arena,
        ctx.workspace_root,
        resolved,
        ctx.ignored_list_entries,
        ctx.max_list_entries,
        &source,
    );
}

/// Reports that list_files only observes filesystem names.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

/// Reports that list_files has no irreversible side effects.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

const list_files_dispatch_tool = tool_dispatch.Tool{
    .name = "list_files",
    .description = "List files dispatch test fixture.",
    .descriptor = .{
        .name = "list_files",
        .description = "List files dispatch test fixture.",
    },
    .executor_kind = .list_files,
    .activity_kind = .list,
    .permission_target_kind = .path_optional_existing,
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

fn expectDecodeInput(args_json: []const u8, path: []const u8, path_provided: bool) !void {
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
            try std.testing.expectEqual(path_provided, input.path_provided);
        },
    }
}

fn listArgsJson(alloc: Allocator, maybe_path: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeByte('{');
    if (maybe_path) |path| {
        try out.writer.writeAll("\"path\":");
        try std.json.Stringify.value(path, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchListFiles(alloc: Allocator, workspace_root: []const u8, maybe_path: ?[]const u8) !tool_dispatch.DispatchResult {
    const args = try listArgsJson(alloc, maybe_path);
    defer alloc.free(args);
    return dispatchListFilesRaw(alloc, workspace_root, args);
}

fn dispatchListFilesRaw(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{list_files_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "list_files",
        .arguments_json = args_json,
    });
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

fn firstLine(body: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, body, '\n') orelse body.len;
    return body[0..end];
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

fn setMode(path: []const u8, mode: std.posix.mode_t) !void {
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), path, std.Io.File.Permissions.fromMode(mode), .{});
}

fn restoreMode(path: []const u8, mode: std.posix.mode_t) void {
    // Best-effort test cleanup; tmpDir cleanup will surface any remaining filesystem issue.
    setMode(path, mode) catch {};
}

test "list_files rejects invalid JSON" {
    try expectDecodeFailure("{", "list_files arguments must be valid JSON");
}

test "list_files rejects non-object JSON" {
    try expectDecodeFailure("[]", "list_files arguments must be an object");
}

test "list_files ignores non-string optional path" {
    try expectDecodeInput("{\"path\":1}", "", false);
}

test "list_files decodes omitted path and dispatches workspace root" {
    const alloc = std.testing.allocator;
    try expectDecodeInput("{}", "", false);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "visible.txt", "x\n");
    defer alloc.free(path);

    const result = try dispatchListFiles(alloc, workspace, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, ".:\n"));
    try std.testing.expect(std.mem.find(u8, result.body, "- visible.txt\n") != null);
}

test "list_files provided empty paths use active path resolution behavior" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    var empty_result = try dispatchListFiles(alloc, workspace, "");
    defer empty_result.deinit(alloc);
    try std.testing.expectEqual(.failure, empty_result.status);
    try std.testing.expect(std.mem.find(u8, empty_result.body, "InvalidPath") != null);

    var whitespace_result = try dispatchListFiles(alloc, workspace, "   ");
    defer whitespace_result.deinit(alloc);
    try std.testing.expectEqual(.failure, whitespace_result.status);
    try std.testing.expect(std.mem.find(u8, whitespace_result.body, "InvalidPath") != null);
}

test "list_files ignores unknown JSON keys" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"path\":\".\",\"unknown\":\"x\"}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(Input);
            try std.testing.expect((try validateStackInput(alloc, input, "/tmp/workspace")) == null);
            try std.testing.expectEqualStrings(".", input.path);
            try std.testing.expect(input.path_provided);
        },
    }
}

test "list_files omitted path header displays workspace root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const first = try writeTempFile(alloc, &tmp, "a.txt", "a\n");
    defer alloc.free(first);
    const second = try writeTempFile(alloc, &tmp, "b.txt", "b\n");
    defer alloc.free(second);

    const result = try dispatchListFiles(alloc, workspace, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, ".:\n"));
    try std.testing.expect(std.mem.find(u8, result.body, "- a.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "- b.txt\n") != null);
}

test "list_files external absolute path header stays absolute" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);
    const external_file = try writeTempFile(alloc, &tmp, "external/outside.txt", "x\n");
    defer alloc.free(external_file);

    const result = try dispatchListFiles(alloc, workspace, external);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "{s}:\n", .{external});
    defer alloc.free(expected);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, expected));
}

test "list_files empty directory output is exact" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchListFiles(alloc, workspace, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(".:\n(empty)\n", result.body);
}

test "list_files marks symlink entries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const target = try writeTempFile(alloc, &tmp, "target.txt", "x\n");
    defer alloc.free(target);
    try createSymlinkOrSkip(&tmp, "target.txt", "linked", false);

    const result = try dispatchListFiles(alloc, workspace, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "- linked@\n") != null);
}

test "list_files active header omits entry count" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "only.txt", "x\n");
    defer alloc.free(path);

    const result = try dispatchListFiles(alloc, workspace, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(".:", firstLine(result.body));
}

test "list_files regular file target reports open failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const path = try writeTempFile(alloc, &tmp, "file.txt", "x\n");
    defer alloc.free(path);

    const result = try dispatchListFiles(alloc, workspace, path);
    defer result.deinit(alloc);

    const expected = try std.fmt.allocPrint(alloc, "Unable to open list directory: {s} (NotDir)", .{path});
    defer alloc.free(expected);
    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, expected) != null);
}

test "list_files permission denied directory returns structured recovery" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const root = try std.fmt.allocPrint(alloc, "/tmp/fx-list-files-access-{d}", .{io_mod.nanoTimestamp()});
    defer alloc.free(root);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), root) catch {};
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), root);
    const workspace = try io_mod.realpathAlloc(alloc, root);
    defer alloc.free(workspace);
    const blocked = try std.fs.path.join(alloc, &.{ workspace, "blocked" });
    defer alloc.free(blocked);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), blocked);

    setMode(blocked, 0) catch return error.SkipZigTest;
    defer restoreMode(blocked, 0o700);

    const result = try dispatchListFiles(alloc, workspace, blocked);
    defer result.deinit(alloc);
    if (result.status == .success) return error.SkipZigTest;

    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(result.body));
    try std.testing.expect(std.mem.find(u8, result.body, "\"tool_name\":\"list_files\"") != null);
    try std.testing.expect(std.mem.find(u8, result.body, blocked) != null);
    try std.testing.expect(std.mem.find(u8, result.body, "AccessDenied") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "symlink") != null);
}

test "list_files missing relative path reports resolver failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchListFiles(alloc, workspace, "missing");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "Unable to resolve list root: missing (FileNotFound)") != null);
}

test "list_files symlink directory request displays resolved target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "foo");
    const target = try writeTempFile(alloc, &tmp, "foo/inside.txt", "x\n");
    defer alloc.free(target);
    try createSymlinkOrSkip(&tmp, "foo", "link-to-foo", true);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchListFiles(alloc, workspace, "link-to-foo");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.body, "foo:\n"));
    try std.testing.expect(std.mem.find(u8, result.body, "- inside.txt\n") != null);
}

test "list_files classifiers are read-only and reversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{
        .path = try std.testing.allocator.dupe(u8, ""),
        .path_provided = false,
    };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
}

const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const whitespace = " \t\r\n";

pub const Input = struct {
    path: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = .{ .path = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "file_info arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "file_info arguments must be an object") };
    }

    const path_value = parsed.value.object.get("path") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "file_info field \"path\" is required") };
    };
    if (path_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "file_info field \"path\" must be a string") };
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

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    try replaceField(ctx.allocator, &input.path, std.mem.trim(u8, input.path, whitespace));
    if (input.path.len == 0) {
        return try ctx.allocator.dupe(u8, "file_info field \"path\" must not be empty");
    }
    return null;
}

fn replaceField(alloc: Allocator, field: *[]u8, next: []const u8) tool_dispatch.DispatchError!void {
    if (std.mem.eql(u8, field.*, next)) return;
    const owned = try alloc.dupe(u8, next);
    alloc.free(field.*);
    field.* = owned;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.FileNotFound) {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "file_info failed: not found: {s}", .{input.path}) };
        }
        return mapPathError(err);
    };

    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), target, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const rel = try displayPath(arena, ctx.workspace_root, target);
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "file_info failed: not found: {s}", .{rel}) };
        }
        return mapPathError(err);
    };

    const rel = try displayPath(arena, ctx.workspace_root, target);
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();

    out.writer.print("path: {s}\n", .{rel}) catch return error.OutOfMemory;
    out.writer.print("type: {s}\n", .{kindLabel(stat.kind)}) catch return error.OutOfMemory;
    out.writer.print("size: {d} bytes\n", .{stat.size}) catch return error.OutOfMemory;
    try writeModified(&out.writer, stat.mtime.nanoseconds);
    if (extensionForPath(rel, stat.kind)) |ext| {
        out.writer.print("extension: {s}\n", .{ext}) catch return error.OutOfMemory;
    }

    return .{ .success = try out.toOwnedSlice() };
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

test "file_info preserves missing home path errors" {
    try std.testing.expectEqual(error.HomeNotSet, mapPathError(error.HomeNotSet));
}

fn kindLabel(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .directory => "directory",
        .sym_link => "symlink",
        .file => "file",
        else => "other",
    };
}

fn writeModified(writer: *std.Io.Writer, mtime_ns: i128) tool_dispatch.DispatchError!void {
    const mtime_s = @divTrunc(mtime_ns, std.time.ns_per_s);
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(mtime_s) };
    const day_seconds = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    writer.print("modified: {d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch return error.OutOfMemory;
}

fn extensionForPath(path: []const u8, kind: std.Io.File.Kind) ?[]const u8 {
    if (kind != .file) return null;
    const dot = std.mem.findScalarLast(u8, path, '.') orelse return null;
    if (dot >= path.len) return null;
    return path[dot + 1 ..];
}

fn displayPath(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8) ![]const u8 {
    const rel = try pathing.workspaceRelativePath(arena, workspace_root, absolute_path);
    return if (rel.len == 0) "." else rel;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

const file_info_dispatch_tool = tool_dispatch.Tool{
    .name = "file_info",
    .description = "File info dispatch test fixture.",
    .descriptor = .{
        .name = "file_info",
        .description = "File info dispatch test fixture.",
    },
    .executor_kind = .file_info,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Inspecting",
    .completed_action_label = "Inspected",
    .label_arg_kind = .path,
    .label_arg_default = "path",
    .permission_target_kind = .path_existing,
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

fn fileInfoArgsJson(alloc: Allocator, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchFileInfo(alloc: Allocator, workspace_root: []const u8, path: []const u8) !tool_dispatch.DispatchResult {
    const args = try fileInfoArgsJson(alloc, path);
    defer alloc.free(args);

    const registry = tool_dispatch.Registry{ .tools = &.{file_info_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "file_info",
        .arguments_json = args,
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

fn writeTempFileWithMtime(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8, mtime_ns: i96) ![]u8 {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    try file.setTimestamps(io_mod.getIo(), .{
        .access_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
    });
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn setMode(path: []const u8, mode: std.posix.mode_t) !void {
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), path, std.Io.File.Permissions.fromMode(mode), .{});
}

fn expectNoExtension(body: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, body, "extension:") == null);
}

fn lineAt(body: []const u8, index: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) {
        if (i == index) return line;
    }
    return null;
}

fn lineCountIncludingTrailingEmpty(body: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |_| count += 1;
    return count;
}

fn modifiedLineForUnixSeconds(alloc: Allocator, seconds: i128) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModified(&out.writer, seconds * std.time.ns_per_s);
    return try out.toOwnedSlice();
}

test "file_info rejects invalid JSON" {
    try expectDecodeFailure("{", "file_info arguments must be valid JSON");
}

test "file_info rejects non-object JSON" {
    try expectDecodeFailure("[]", "file_info arguments must be an object");
}

test "file_info rejects missing path" {
    try expectDecodeFailure("{}", "file_info field \"path\" is required");
}

test "file_info rejects non-string path" {
    try expectDecodeFailure("{\"path\":1}", "file_info field \"path\" must be a string");
}

test "file_info validates empty path" {
    const alloc = std.testing.allocator;
    var empty = Input{ .path = try alloc.dupe(u8, " \t\n ") };
    defer empty.deinit(alloc);
    const reason = (try validateStackInput(alloc, &empty, "/tmp/workspace")).?;
    defer alloc.free(reason);
    try std.testing.expectEqualStrings("file_info field \"path\" must not be empty", reason);
}

test "file_info modified formatting handles epoch zero" {
    const alloc = std.testing.allocator;
    const line = try modifiedLineForUnixSeconds(alloc, 0);
    defer alloc.free(line);
    try std.testing.expectEqualStrings("modified: 1970-01-01T00:00:00Z\n", line);
}

test "file_info modified formatting handles positive epoch seconds" {
    const alloc = std.testing.allocator;
    const line = try modifiedLineForUnixSeconds(alloc, 1622924906);
    defer alloc.free(line);
    try std.testing.expectEqualStrings("modified: 2021-06-05T20:28:26Z\n", line);
}

test "file_info reports regular file with extension" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFileWithMtime(alloc, &tmp, "file.txt", "hello\n", 0);
    defer alloc.free(path);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchFileInfo(alloc, workspace, "file.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("path: file.txt", lineAt(result.body, 0).?);
    try std.testing.expectEqualStrings("type: file", lineAt(result.body, 1).?);
    try std.testing.expectEqualStrings("size: 6 bytes", lineAt(result.body, 2).?);
    try std.testing.expectEqualStrings("modified: 1970-01-01T00:00:00Z", lineAt(result.body, 3).?);
    try std.testing.expectEqualStrings("extension: txt", lineAt(result.body, 4).?);
    try std.testing.expectEqual(@as(usize, 6), lineCountIncludingTrailingEmpty(result.body));
}

test "file_info directory has no extension line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "dir.ext");
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchFileInfo(alloc, workspace, "dir.ext");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("path: dir.ext", lineAt(result.body, 0).?);
    try std.testing.expectEqualStrings("type: directory", lineAt(result.body, 1).?);
    try expectNoExtension(result.body);
}

test "file_info extension predicate follows active display-path behavior" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const no_dot = try writeTempFile(alloc, &tmp, "plain", "x");
    defer alloc.free(no_dot);
    const hidden = try writeTempFile(alloc, &tmp, ".bashrc", "x");
    defer alloc.free(hidden);
    const trailing = try writeTempFile(alloc, &tmp, "foo.", "x");
    defer alloc.free(trailing);
    const parent_dot = try writeTempFile(alloc, &tmp, "src.dir/index", "x");
    defer alloc.free(parent_dot);
    const dotted_file = try writeTempFile(alloc, &tmp, "src.dir/file.txt", "x");
    defer alloc.free(dotted_file);

    var plain = try dispatchFileInfo(alloc, workspace, "plain");
    defer plain.deinit(alloc);
    try expectNoExtension(plain.body);

    var parent_only_dot = try dispatchFileInfo(alloc, workspace, "src.dir/index");
    defer parent_only_dot.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, parent_only_dot.body, "extension: dir/index\n") != null);

    var dotted = try dispatchFileInfo(alloc, workspace, "src.dir/file.txt");
    defer dotted.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, dotted.body, "extension: txt\n") != null);

    var bashrc = try dispatchFileInfo(alloc, workspace, ".bashrc");
    defer bashrc.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, bashrc.body, "extension: bashrc\n") != null);

    var trailing_dot = try dispatchFileInfo(alloc, workspace, "foo.");
    defer trailing_dot.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, trailing_dot.body, "extension: \n") != null);
}

test "file_info owner preserves active absolute display behind permission gate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const external = try writeTempFile(alloc, &tmp, "external.txt", "x");
    defer alloc.free(external);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    const result = try dispatchFileInfo(alloc, workspace, external);
    defer result.deinit(alloc);

    const expected_header = try std.fmt.allocPrint(alloc, "path: {s}", .{external});
    defer alloc.free(expected_header);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(expected_header, lineAt(result.body, 0).?);
}

test "file_info reports missing path with raw input" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchFileInfo(alloc, workspace, "missing.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expectEqualStrings("file_info failed: not found: missing.txt", result.body);
}

test "file_info line order without extension is exact" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFileWithMtime(alloc, &tmp, "plain", "abc", 0);
    defer alloc.free(path);
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchFileInfo(alloc, workspace, "plain");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("path: plain", lineAt(result.body, 0).?);
    try std.testing.expectEqualStrings("type: file", lineAt(result.body, 1).?);
    try std.testing.expectEqualStrings("size: 3 bytes", lineAt(result.body, 2).?);
    try std.testing.expectEqualStrings("modified: 1970-01-01T00:00:00Z", lineAt(result.body, 3).?);
    try std.testing.expectEqual(@as(usize, 5), lineCountIncludingTrailingEmpty(result.body));
}

test "file_info active output omits readonly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempFile(alloc, &tmp, "readonly.txt", "x");
    defer alloc.free(path);
    setMode(path, 0o444) catch return error.SkipZigTest;
    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{});
    if (!stat.permissions.readOnly()) return error.SkipZigTest;
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);

    const result = try dispatchFileInfo(alloc, workspace, "readonly.txt");
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "readonly:") == null);
}

test "file_info classifiers are read-only and reversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{ .path = try std.testing.allocator.dupe(u8, "file.txt") };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
}

const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const io_mod = @import("../../core/shared/io.zig");
const model_context_encoding = @import("../../core/shared/model_context_encoding.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    source: []u8,
    skill: ?[]u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.source);
        if (self.skill) |skill| alloc.free(skill);
        self.* = .{ .source = &.{}, .skill = null };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "install_skill arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "install_skill arguments must be an object") };
    }

    const source_value = parsed.value.object.get("source") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "install_skill field \"source\" is required") };
    };
    if (source_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "install_skill field \"source\" must be a string") };
    }

    const skill_value = parsed.value.object.get("skill");
    const skill: ?[]u8 = if (skill_value) |value| blk: {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "install_skill field \"skill\" must be a string") };
        }
        break :blk try ctx.allocator.dupe(u8, value.string);
    } else null;
    errdefer if (skill) |owned| ctx.allocator.free(owned);

    const source = try ctx.allocator.dupe(u8, source_value.string);
    errdefer ctx.allocator.free(source);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .source = source, .skill = skill };

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
    const output = executeFromSource(ctx.allocator, ctx.skills_dir, input.source, input.skill) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "install_skill failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

pub fn matchesRunCommand(command: []const u8) bool {
    return builtin_skills.looksLikeInstallCommand(command);
}

pub fn executeRunCommand(
    ctx: tool_dispatch.DispatchContext,
    command: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const output = executeFromSource(ctx.allocator, ctx.skills_dir, command, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try tool_result_errors.formatToolExecutionErrorJson(
            ctx.allocator,
            "shell",
            err,
        ) },
    };
    return .{ .success = output };
}

pub fn execute(arena: Allocator, skills_dir: []const u8, args_json: []const u8) ![]u8 {
    if (skills_dir.len == 0) return std.fmt.allocPrint(arena, "Skill installation is unavailable in this runtime.", .{});

    const args = try tool_args.parseToolArgsObject(arena, args_json);
    const source = try tool_args.requiredStringArg(args, "source");
    const filter = tool_args.optionalStringArg(args, "skill");
    return executeFromSource(arena, skills_dir, source, filter);
}

pub fn executeFromSource(alloc: Allocator, skills_dir: []const u8, source: []const u8, filter: ?[]const u8) ![]u8 {
    if (skills_dir.len == 0) return std.fmt.allocPrint(alloc, "Skill installation is unavailable in this runtime.", .{});

    var result = try builtin_skills.installFromSource(alloc, skills_dir, source, filter);
    defer result.deinit(alloc);

    if (result.installed.items.len == 0) return formatNoMatchOutput(alloc, source);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.print("Installed {d} skill(s) into fx.\n", .{result.installed.items.len});
    for (result.installed.items) |name| {
        try out.writer.writeAll("- ");
        try model_context_encoding.writeScalar(&out.writer, name);
        try out.writer.writeByte('\n');
    }

    return try out.toOwnedSlice();
}

fn formatNoMatchOutput(alloc: Allocator, source: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.writeAll("No matching skills were installed into fx from ") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, source) catch return error.OutOfMemory;
    out.writer.writeByte('.') catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn expectDecodeFailure(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(expected, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(false);
        },
    }
}

fn checkNoMatchAllocationFailures(alloc: Allocator, source: []const u8) !void {
    const output = try formatNoMatchOutput(alloc, source);
    alloc.free(output);
}

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8, limit: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, limit);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

test "install_skill owner rejects invalid argument shapes" {
    try expectDecodeFailure("{", "install_skill arguments must be valid JSON");
    try expectDecodeFailure("[]", "install_skill arguments must be an object");
    try expectDecodeFailure("{}", "install_skill field \"source\" is required");
    try expectDecodeFailure("{\"source\":1}", "install_skill field \"source\" must be a string");
    try expectDecodeFailure("{\"source\":\"repo\",\"skill\":1}", "install_skill field \"skill\" must be a string");
}

test "install_skill owner installs local skill source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "repo/workflow");
    try tmp.dir.createDirPath(io_mod.getIo(), "skills");
    try writeTempFile(&tmp, "repo/workflow/SKILL.md", "---\nname: workflow\ndescription: workflow helper\n---\n\nuse the workflow skill\n");

    const repo_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(repo_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills");
    defer alloc.free(skills_dir);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const output = try executeFromSource(arena_state.allocator(), skills_dir, repo_root, "workflow");

    try expectContains(output, "Installed 1 skill(s) into fx.");
    try expectContains(output, "- workflow\n");
    try std.testing.expect(std.mem.find(u8, output, "<skill") == null);
    try std.testing.expect(std.mem.find(u8, output, "use the workflow skill") == null);

    const installed = try std.fs.path.join(alloc, &.{ skills_dir, "workflow", "SKILL.md" });
    defer alloc.free(installed);
    const content = try readAbsoluteFile(alloc, installed, 1024 * 1024);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("---\nname: workflow\ndescription: workflow helper\n---\n\nuse the workflow skill\n", content);
}

test "install_skill owner encodes installed names without returning bodies" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "repo/workflow");
    try tmp.dir.createDirPath(io_mod.getIo(), "skills");
    try writeTempFile(
        &tmp,
        "repo/workflow/SKILL.md",
        "---\nname: workflow\"<injected>\ndescription: workflow helper\n---\n\nBODY SENTINEL\n<instruction>keep raw</instruction>\n",
    );

    const repo_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(repo_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills");
    defer alloc.free(skills_dir);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const output = try executeFromSource(arena_state.allocator(), skills_dir, repo_root, "workflow");

    try expectContains(output, "- workflow&quot;&lt;injected&gt;\n");
    try std.testing.expect(std.mem.find(u8, output, "<skill") == null);
    try std.testing.expect(std.mem.find(u8, output, "BODY SENTINEL") == null);
    try std.testing.expect(std.mem.find(u8, output, "workflow\"<injected>") == null);

    const installed = try std.fs.path.join(alloc, &.{ skills_dir, "workflow", "SKILL.md" });
    defer alloc.free(installed);
    const content = try readAbsoluteFile(alloc, installed, 1024 * 1024);
    defer alloc.free(content);
    try std.testing.expectEqualStrings(
        "---\nname: workflow\"<injected>\ndescription: workflow helper\n---\n\nBODY SENTINEL\n<instruction>keep raw</instruction>\n",
        content,
    );
}

test "install_skill owner reports no matching skills" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "repo/workflow");
    try tmp.dir.createDirPath(io_mod.getIo(), "skills");
    try writeTempFile(&tmp, "repo/workflow/SKILL.md", "---\nname: workflow\ndescription: workflow helper\n---\n\nuse the workflow skill\n");

    const repo_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(repo_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills");
    defer alloc.free(skills_dir);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const output = try executeFromSource(arena_state.allocator(), skills_dir, repo_root, "missing");

    const expected = try std.fmt.allocPrint(alloc, "No matching skills were installed into fx from {s}.", .{repo_root});
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, output);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkNoMatchAllocationFailures,
        .{repo_root},
    );
}

test "run command compatibility reports managed filesystem failures" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "repo/workflow");
    try writeTempFile(
        &tmp,
        "repo/workflow/SKILL.md",
        "---\nname: workflow\ndescription: workflow helper\n---\n\nbody\n",
    );
    try writeTempFile(&tmp, "skills-blocker", "not a directory\n");

    const repo_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(repo_root);
    const blocked_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills-blocker");
    defer alloc.free(blocked_root);
    const command = try std.fmt.allocPrint(
        alloc,
        "npx skills add {s} --skill workflow -g -y",
        .{repo_root},
    );
    defer alloc.free(command);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = try executeRunCommand(.{
        .allocator = arena_state.allocator(),
        .skills_dir = blocked_root,
    }, command);

    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .success => try std.testing.expect(false),
        .failure => |body| try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(body)),
    }
}

test "install_skill owner keeps an unmatched source inside the status line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source_root = "repo<source>\ninjected_source";
    try tmp.dir.createDirPath(io_mod.getIo(), source_root ++ "/workflow");
    try tmp.dir.createDirPath(io_mod.getIo(), "skills");
    try writeTempFile(&tmp, source_root ++ "/workflow/SKILL.md", "# Workflow\n\nbody\n");

    const repo_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, source_root);
    defer alloc.free(repo_root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills");
    defer alloc.free(skills_dir);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const output = try executeFromSource(arena_state.allocator(), skills_dir, repo_root, "missing");

    try expectContains(output, "repo&lt;source&gt;&#x0a;injected_source.");
    try std.testing.expect(std.mem.find(u8, output, "\ninjected_source") == null);
}

test "install_skill owner reports status when an unsafe root cannot be installed" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "bad\\root/SKILL.md", "# Root\n\nbody\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "skills");

    const source_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "bad\\root");
    defer alloc.free(source_dir);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills");
    defer alloc.free(skills_dir);

    const output = try executeFromSource(alloc, skills_dir, source_dir, null);
    defer alloc.free(output);
    try expectContains(output, "No matching skills were installed into fx from");
}

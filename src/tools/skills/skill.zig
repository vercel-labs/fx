const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const skill_invocation = @import("../../core/skills/skill_invocation.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const context_limits = @import("../../core/config/context_limits.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    name: []u8,
    location: ?[]u8 = null,
    resource: ?[]u8 = null,
    offset: usize = 0,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.location) |location| alloc.free(location);
        if (self.resource) |resource| alloc.free(resource);
        self.* = .{ .name = &.{}, .location = null, .resource = null };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "skill arguments must be valid JSON") },
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill arguments must be an object") };
    }

    const name_value = parsed.value.object.get("name") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"name\" is required") };
    };
    if (name_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"name\" must be a string") };
    }
    const location_value = parsed.value.object.get("location");
    if (location_value) |value| {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"location\" must be a string") };
        }
    }
    const resource_value = parsed.value.object.get("resource");
    if (resource_value) |value| {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"resource\" must be a string") };
        }
    }
    const offset_value = parsed.value.object.get("offset");
    if (offset_value) |value| {
        if (value != .integer or value.integer < 0) {
            return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"offset\" must be a non-negative integer") };
        }
    }

    const name = try ctx.allocator.dupe(u8, name_value.string);
    errdefer ctx.allocator.free(name);
    const location = if (location_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (location) |value| ctx.allocator.free(value);
    const resource = if (resource_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (resource) |value| ctx.allocator.free(value);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .name = name,
        .location = location,
        .resource = resource,
        .offset = if (offset_value) |value| std.math.cast(usize, value.integer) orelse return error.InvalidToolArguments else 0,
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
    const result = loadByIdentity(
        ctx.allocator,
        ctx.workspace_root,
        ctx.skills_dir,
        input.name,
        input.location,
        input.resource,
        input.offset,
        ctx.context_limits,
        ctx.max_tool_result_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "skill failed: {s}", .{@errorName(err)}) },
    };
    errdefer skill_invocation.freeExecuteResult(ctx.allocator, result);
    if (result.contextNotice()) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
    if (result.diagnosticNotice()) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
    return switch (result) {
        .failure => .{ .failure = skill_invocation.takeModelOutput(ctx.allocator, result) },
        .loaded => .{ .success = skill_invocation.takeModelOutput(ctx.allocator, result) },
    };
}

pub fn execute(arena: Allocator, workspace_root: []const u8, skills_dir: []const u8, args_json: []const u8) ![]u8 {
    const result = try executeForSession(arena, workspace_root, skills_dir, args_json);
    return skill_invocation.takeModelOutput(arena, result);
}

pub fn executeForSession(
    arena: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
    args_json: []const u8,
) !skill_invocation.ExecuteResult {
    const args = try tool_args.parseToolArgsObject(arena, args_json);
    const name = try tool_args.requiredStringArg(args, "name");
    const location = if (args.get("location")) |value| blk: {
        if (value != .string) return error.InvalidToolArguments;
        break :blk value.string;
    } else null;
    const resource = if (args.get("resource")) |value| blk: {
        if (value != .string) return error.InvalidToolArguments;
        break :blk value.string;
    } else null;
    const offset = if (args.get("offset")) |value| blk: {
        if (value != .integer or value.integer < 0) return error.InvalidToolArguments;
        break :blk std.math.cast(usize, value.integer) orelse return error.InvalidToolArguments;
    } else 0;
    return loadByIdentity(
        arena,
        workspace_root,
        skills_dir,
        name,
        location,
        resource,
        offset,
        .{},
        tool_result_limits.default_max_tool_result_bytes,
    );
}

fn loadByIdentity(
    alloc: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
    name: []const u8,
    location: ?[]const u8,
    resource: ?[]const u8,
    offset: usize,
    limits: context_limits.Values,
    max_tool_result_bytes: ?usize,
) !skill_invocation.ExecuteResult {
    var discovery = try builtin_skills.loadVisibleSkillsForTool(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    skill_runtime.traceDiagnostics("skill_tool", discovery.diagnostics);
    return skill_invocation.loadByIdentity(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        name,
        location,
        resource,
        offset,
        limits,
        max_tool_result_bytes,
    );
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

test "skill tool decodes only valid argument shapes" {
    try expectDecodeFailure("{", "skill arguments must be valid JSON");
    try expectDecodeFailure("[]", "skill arguments must be an object");
    try expectDecodeFailure("{}", "skill field \"name\" is required");
    try expectDecodeFailure("{\"name\":1}", "skill field \"name\" must be a string");
    try expectDecodeFailure("{\"name\":\"workflow\",\"location\":1}", "skill field \"location\" must be a string");

    const alloc = std.testing.allocator;
    const exact = try decode(.{ .allocator = alloc }, "{\"name\":\"workflow\",\"location\":\"/tmp/skills/workflow\"}");
    switch (exact) {
        .input => |input| {
            defer input.deinit(alloc);
            const typed = input.as(Input);
            try std.testing.expectEqualStrings("workflow", typed.name);
            try std.testing.expectEqualStrings("/tmp/skills/workflow", typed.location.?);
        },
        .failure => |body| {
            defer alloc.free(body);
            return error.TestExpectedEqual;
        },
    }
}

fn checkDecodeAllocationFailures(alloc: Allocator) !void {
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"name\":\"workflow\",\"location\":\"/tmp/skills/workflow\"}",
    );
    switch (decoded) {
        .input => |input| input.deinit(alloc),
        .failure => |body| {
            alloc.free(body);
            return error.TestExpectedDecodedInput;
        },
    }
}

test "skill tool decode cleans allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkDecodeAllocationFailures,
        .{},
    );
}

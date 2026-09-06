const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const skill_invocation = @import("../../core/skills/skill_invocation.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const skill_contract = @import("../../core/skills/skill_contract.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const context_limits = @import("../../core/config/context_limits.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    name: ?[]u8 = null,
    location: ?[]u8 = null,
    resource: ?[]u8 = null,
    offset: usize = 0,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        if (self.name) |name| alloc.free(name);
        if (self.location) |location| alloc.free(location);
        if (self.resource) |resource| alloc.free(resource);
        self.* = .{};
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

    const name_value = parsed.value.object.get("name");
    if (name_value) |value| if (value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"name\" must be a string") };
    };
    const location_value = parsed.value.object.get("location");
    if (name_value == null and location_value == null) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill requires an advertised location") };
    }
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
    if (name_value == null and offset_value != null) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill offset requires the legacy named resource form") };
    }
    if (offset_value) |value| {
        if (value != .integer or value.integer < 0) {
            return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"offset\" must be a non-negative integer") };
        }
    }

    const name = if (name_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (name) |value| ctx.allocator.free(value);
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

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const resource = skill_contract.resource_path_or_main(if (args.get("resource")) |value| resource: {
        if (value != .string) return null;
        break :resource value.string;
    } else null);
    const offset = if (args.get("offset")) |value| offset: {
        if (value != .integer or value.integer < 0) return null;
        break :offset std.math.cast(usize, value.integer) orelse return null;
    } else 0;
    if (offset == 0 and std.mem.eql(u8, resource, "SKILL.md")) return null;
    return .{
        .activity_kind = .read,
        .action_label = "Reading skill resource",
        .completed_action_label = "Read skill resource",
        .label_arg_kind = if (std.mem.eql(u8, resource, "SKILL.md")) .none else .resource,
        .label_arg_default = "SKILL.md",
    };
}

pub fn prepare(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!skill_contract.CallPreparation {
    const decoded = try decode(ctx, args_json);
    const input = switch (decoded) {
        .failure => |reason| return .{ .failure = .{ .model_output = reason } },
        .input => |value| value,
    };
    defer input.deinit(ctx.allocator);
    return prepareInput(ctx, input.as(Input)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return .{ .failure = .{ .model_output = try std.fmt.allocPrint(ctx.allocator, "skill failed: {s}. Refresh available skills and retry with an exact advertised location.", .{@errorName(err)}) } },
    };
}

fn prepareInput(ctx: tool_dispatch.DispatchContext, input: *const Input) !skill_contract.CallPreparation {
    if (ctx.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    const locations = if (ctx.skill_locations) |value| value.* else skill_contract.Locations{};
    const location = if (input.location) |value| try locations.resolve(ctx.allocator, value) else null;
    defer if (location) |value| ctx.allocator.free(value);
    if (location) |path| {
        for (locations.skills) |skill| {
            if (!std.mem.eql(u8, skill.path, path)) continue;
            return skill_invocation.prepareIdentity(ctx.allocator, .{ .skills = locations.skills, .diagnostics = locations.diagnostics }, input.name, path, ctx.max_tool_result_bytes);
        }
        if (std.mem.startsWith(u8, input.location.?, "skill:")) {
            return skill_invocation.prepareIdentity(ctx.allocator, .{ .skills = locations.skills, .diagnostics = locations.diagnostics }, input.name, path, ctx.max_tool_result_bytes);
        }
    }
    var discovery = try builtin_skills.loadVisibleSkillsForTool(ctx.allocator, ctx.workspace_root, ctx.skills_dir);
    defer discovery.deinit(ctx.allocator);
    skill_runtime.traceDiagnostics("skill_tool", discovery.diagnostics);
    return skill_invocation.prepareIdentity(ctx.allocator, .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics }, input.name, location, ctx.max_tool_result_bytes);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const result = loadInput(ctx, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "skill failed: {s}", .{@errorName(err)}) },
    };
    errdefer skill_invocation.freeExecuteResult(ctx.allocator, result);
    if (result.contextNotice()) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
    if (result.diagnosticNotice()) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
    if (result == .loaded and result.loaded.complete) {
        if (ctx.model_content_kind_sink) |kind| kind.* = .complete_skill;
    }
    return switch (result) {
        .failure => .{ .failure = skill_invocation.takeModelOutput(ctx.allocator, result) },
        .loaded => .{ .success = skill_invocation.takeModelOutput(ctx.allocator, result) },
    };
}

fn loadInput(ctx: tool_dispatch.DispatchContext, input: *const Input) !skill_invocation.ExecuteResult {
    if (ctx.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    if (ctx.resolved_skill) |skill| return loadSelected(ctx, input, skill.*);
    const preparation = try prepareInput(ctx, input);
    return switch (preparation) {
        .failure => |output| .{ .failure = output },
        .selected => |skill| selected: {
            defer skill_invocation.freeCallPreparation(ctx.allocator, preparation);
            break :selected try loadSelected(ctx, input, skill);
        },
    };
}

fn loadSelected(ctx: tool_dispatch.DispatchContext, input: *const Input, prepared: skill_contract.PreparedSkill) !skill_invocation.ExecuteResult {
    const skill = prepared.skill;
    const catalog: skill_invocation.Catalog = .{ .skills = &.{skill}, .diagnostics = prepared.diagnostics };
    if (input.name != null) {
        return skill_invocation.loadByIdentity(ctx.allocator, catalog, skill.name, skill.path, input.resource, input.offset, ctx.context_limits, ctx.max_tool_result_bytes);
    }
    return skill_invocation.loadWholeByLocation(ctx.allocator, catalog, skill.path, input.resource, ctx.context_limits, ctx.max_tool_result_bytes, ctx.cancel_flag);
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

test "skill tool does not rebind an advertised location to a renamed skill" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "skills/workflow");
    var file = try tmp.dir.createFile(io_mod.getIo(), "skills/workflow/SKILL.md", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "---\nname: changed\ndescription: changed identity\n---\nWRONG_IDENTITY_BODY\n");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills");
    defer alloc.free(skills_dir);
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills/workflow");
    defer alloc.free(path);
    const skills = [_]skill_contract.Skill{.{ .name = "original", .description = "original identity", .path = path, .source = .global_fx }};
    const locations: skill_contract.Locations = .{ .namespace = 1, .roots = &.{skills_dir}, .skills = &skills };
    const decoded = try decode(.{ .allocator = alloc }, "{\"location\":\"skill:0000000000000001:0/workflow\"}");
    const input = decoded.input;
    defer input.deinit(alloc);
    const result = try loadInput(.{ .allocator = alloc, .workspace_root = root, .skills_dir = skills_dir, .skill_locations = &locations }, input.as(Input));
    defer skill_invocation.freeExecuteResult(alloc, result);
    try std.testing.expect(result == .failure);
    try std.testing.expect(std.mem.find(u8, result.modelOutput(), "WRONG_IDENTITY_BODY") == null);
}

test "skill preparation binds retained aliases and canonical paths before reading" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "skills/workflow");
    var file = try tmp.dir.createFile(io_mod.getIo(), "skills/workflow/SKILL.md", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "---\nname: renamed\n---\nREPLACEMENT BODY\n");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const skills_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills");
    defer alloc.free(skills_dir);
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "skills/workflow");
    defer alloc.free(path);
    const skills = [_]skill_contract.Skill{.{ .name = "original", .description = "", .path = path, .source = .global_fx }};
    const diagnostics = [_]skill_contract.SkillDiagnostic{.{ .path = "/malformed", .source = .global_fx, .scope = .candidate, .cause = .{ .invalid_metadata = .missing_name } }};
    const locations: skill_contract.Locations = .{ .namespace = 7, .roots = &.{skills_dir}, .skills = &skills, .diagnostics = &diagnostics };
    for ([_][]const u8{ "skill:0000000000000007:0/workflow", path }) |location| {
        const args = try std.json.Stringify.valueAlloc(alloc, .{ .location = location }, .{});
        defer alloc.free(args);
        var ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc, .workspace_root = root, .skills_dir = skills_dir, .skill_locations = &locations };
        const preparation = try prepare(ctx, args);
        defer skill_invocation.freeCallPreparation(alloc, preparation);
        const selected = switch (preparation) {
            .selected => |value| value,
            .failure => return error.UnexpectedSkillPreparationFailure,
        };
        try std.testing.expectEqualStrings("original", selected.skill.name);
        try std.testing.expectEqual(@as(usize, 1), selected.diagnostics.len);
        ctx.resolved_skill = &selected;
        const decoded = try decode(ctx, args);
        defer decoded.input.deinit(alloc);
        const result = try loadInput(ctx, decoded.input.as(Input));
        defer skill_invocation.freeExecuteResult(alloc, result);
        try std.testing.expect(result == .failure);
        try std.testing.expect(std.mem.find(u8, result.modelOutput(), "REPLACEMENT BODY") == null);
        try std.testing.expect(std.mem.find(u8, result.diagnosticNotice().?, "metadata is invalid (missing_name)") != null);
        ctx.resolved_skill = null;
        const direct = try loadInput(ctx, decoded.input.as(Input));
        defer skill_invocation.freeExecuteResult(alloc, direct);
        try std.testing.expect(direct == .failure);
        try std.testing.expect(std.mem.find(u8, direct.modelOutput(), "REPLACEMENT BODY") == null);
    }
    const stale = try prepare(.{ .allocator = alloc, .skill_locations = &locations }, "{\"location\":\"skill:0000000000000006:0/workflow\"}");
    defer skill_invocation.freeCallPreparation(alloc, stale);
    try std.testing.expect(std.mem.find(u8, stale.failure.model_output, "StaleSkillLocation") != null);
    const mismatch = try prepare(.{ .allocator = alloc, .skill_locations = &locations }, "{\"name\":\"renamed\",\"location\":\"skill:0000000000000007:0/workflow\"}");
    defer skill_invocation.freeCallPreparation(alloc, mismatch);
    try std.testing.expect(std.mem.find(u8, mismatch.failure.model_output, "does not match") != null);
}

test "skill preparation discovers canonical locations added after the catalog" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "managed/new-directory");
    var file = try tmp.dir.createFile(io_mod.getIo(), "managed/new-directory/SKILL.md", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "---\nname: newly-installed-name\n---\nNEW INSTRUCTIONS\n");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const managed = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "managed");
    defer alloc.free(managed);
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "managed/new-directory");
    defer alloc.free(path);
    const args = try std.json.Stringify.valueAlloc(alloc, .{ .location = path }, .{});
    defer alloc.free(args);
    const empty_catalog: skill_contract.Locations = .{ .namespace = 3 };
    const preparation = try prepare(.{ .allocator = alloc, .workspace_root = root, .skills_dir = managed, .skill_locations = &empty_catalog }, args);
    defer skill_invocation.freeCallPreparation(alloc, preparation);
    const selected = switch (preparation) {
        .selected => |value| value,
        .failure => return error.NewSkillNotDiscovered,
    };
    try std.testing.expectEqualStrings("newly-installed-name", selected.skill.name);
    try std.testing.expectEqualStrings(path, selected.skill.path);
}

test "skill tool accepts an exact location without a guessed name" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"location\":\"/installed/workflow\"}");
    switch (decoded) {
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqualStrings("/installed/workflow", input.as(Input).location.?);
        },
        .failure => |body| {
            defer alloc.free(body);
            return error.TestExpectedSkillInput;
        },
    }
}

test "skill tool decodes only valid argument shapes" {
    try expectDecodeFailure("{", "skill arguments must be valid JSON");
    try expectDecodeFailure("[]", "skill arguments must be an object");
    try expectDecodeFailure("{}", "skill requires an advertised location");
    try expectDecodeFailure("{\"name\":1}", "skill field \"name\" must be a string");
    try expectDecodeFailure("{\"name\":\"workflow\",\"location\":1}", "skill field \"location\" must be a string");
    try expectDecodeFailure("{\"location\":\"/installed/workflow\",\"resource\":null}", "skill field \"resource\" must be a string");
    try expectDecodeFailure("{\"location\":\"/installed/workflow\",\"resource\":1}", "skill field \"resource\" must be a string");

    const alloc = std.testing.allocator;
    const exact = try decode(.{ .allocator = alloc }, "{\"name\":\"workflow\",\"location\":\"/tmp/skills/workflow\"}");
    switch (exact) {
        .input => |input| {
            defer input.deinit(alloc);
            const typed = input.as(Input);
            try std.testing.expectEqualStrings("workflow", typed.name.?);
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

test "skill presentation distinguishes the initial document from resource reads" {
    const Case = struct {
        args: []const u8,
        expected: ?struct {
            active: []const u8,
            completed: []const u8,
            value: []const u8,
        },
    };
    const cases = [_]Case{
        .{ .args = "{\"name\":\"workflow\"}", .expected = null },
        .{ .args = "{\"location\":\"/installed/workflow\",\"resource\":\"\"}", .expected = null },
        .{ .args = "{\"name\":\"workflow\",\"resource\":\"SKILL.md\",\"offset\":0}", .expected = null },
        .{ .args = "{\"name\":\"workflow\",\"resource\":\"references/contract-design.md\"}", .expected = .{
            .active = "Reading skill resource",
            .completed = "Read skill resource",
            .value = "references/contract-design.md",
        } },
        .{ .args = "{\"name\":\"workflow\",\"offset\":128}", .expected = .{
            .active = "Reading skill resource",
            .completed = "Read skill resource",
            .value = "SKILL.md",
        } },
        .{ .args = "{\"name\":\"workflow\",\"resource\":\"\",\"offset\":128}", .expected = .{
            .active = "Reading skill resource",
            .completed = "Read skill resource",
            .value = "SKILL.md",
        } },
    };

    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.args, .{});
        defer parsed.deinit();
        const resolved = presentation(parsed.value.object);
        if (case.expected) |expected| {
            const value = resolved orelse return error.TestExpectedEqual;
            try std.testing.expectEqualStrings(expected.active, value.action_label);
            try std.testing.expectEqualStrings(expected.completed, value.completed_action_label);
            try std.testing.expectEqualStrings(
                expected.value,
                tool_dispatch.presentationLabelValue(value, parsed.value.object) orelse value.label_arg_default,
            );
        } else {
            try std.testing.expect(resolved == null);
        }
    }
}

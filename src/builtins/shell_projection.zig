//! The model tool projection for a surface that advertises `shell`. Every
//! surface builds its projection through this file, so the choice between the
//! four `shell` schemas is made in one place.

const std = @import("std");
const builtin_tools = @import("tools.zig");
const modes = @import("modes.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const tool_projection = @import("../core/tooling/tool_projection.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");

pub const ShellVariant = builtin_tools.ShellVariant;

/// Builds through `registry`, the mode-aware path that `fx ask` and ACP use.
/// The default variant is the plain build.
pub fn buildModelToolProjection(
    alloc: std.mem.Allocator,
    registry: mode_registry.Registry,
    tool_set: tool_set_contract.ToolSet,
    mode_id: []const u8,
    options: tool_projection.Options,
    variant: ShellVariant,
) !tool_projection.EffectiveToolProjection {
    const tools = (try swappedTools(alloc, tool_set, variant)) orelse
        return registry.buildModelToolProjection(alloc, tool_set, mode_id, options);
    defer alloc.free(tools);
    return registry.buildModelToolProjection(alloc, withTools(tool_set, tools), mode_id, options);
}

/// Builds for a set with no mode, the path the TUI uses. The default variant
/// is the plain build.
pub fn buildModelToolProjectionForSet(
    alloc: std.mem.Allocator,
    tool_set: tool_set_contract.ToolSet,
    options: tool_projection.Options,
    variant: ShellVariant,
) !tool_projection.EffectiveToolProjection {
    const tools = (try swappedTools(alloc, tool_set, variant)) orelse
        return tool_projection.buildModelToolProjectionForSet(alloc, tool_set, options);
    defer alloc.free(tools);
    return tool_projection.buildModelToolProjectionForSet(alloc, withTools(tool_set, tools), options);
}

/// A copy of the tool list with its `shell` tool replaced. Null when the
/// variant is the default, or when the set has no terminal `shell` tool.
fn swappedTools(
    alloc: std.mem.Allocator,
    tool_set: tool_set_contract.ToolSet,
    variant: ShellVariant,
) !?[]tool_dispatch.Tool {
    if (!variant.process_only and !variant.runner) return null;
    const shell_index = shellIndex(tool_set) orelse return null;
    const tools = try alloc.dupe(tool_dispatch.Tool, tool_set.registry.tools);
    tools[shell_index] = builtin_tools.shellSpecFor(variant);
    return tools;
}

fn shellIndex(tool_set: tool_set_contract.ToolSet) ?usize {
    for (tool_set.registry.tools, 0..) |tool, index| {
        if (tool.executor_kind == .terminal and std.mem.eql(u8, tool.name, "shell")) return index;
    }
    return null;
}

fn withTools(tool_set: tool_set_contract.ToolSet, tools: []const tool_dispatch.Tool) tool_set_contract.ToolSet {
    return .{
        .registry = .{ .tools = tools },
        .order = tool_set.order,
        .read_only_tool_names = tool_set.read_only_tool_names,
    };
}

fn functionNamed(projection: tool_projection.EffectiveToolProjection, name: []const u8) ?model_tool_schema.FunctionSchema {
    for (projection.advertised_functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn hasProperty(function: model_tool_schema.FunctionSchema, name: []const u8) bool {
    for (function.input_schema.properties) |property| {
        if (std.mem.eql(u8, property.name, name)) return true;
    }
    return false;
}

test "the default variant is the plain projection, and each runner variant adds only its shell schema" {
    const alloc = std.testing.allocator;
    const tool_set = builtin_tools.advertisement_set;

    var direct = try modes.registry.buildModelToolProjection(alloc, tool_set, "auto", .{});
    defer direct.deinit(alloc);
    var plain = try buildModelToolProjection(alloc, modes.registry, tool_set, "auto", .{}, .{});
    defer plain.deinit(alloc);
    try std.testing.expectEqual(direct.advertised_functions.len, plain.advertised_functions.len);
    for (direct.advertised_functions, plain.advertised_functions) |want, got| {
        const want_json = try model_tool_schema.builtinFunctionSchemaJsonAlloc(alloc, want);
        defer alloc.free(want_json);
        const got_json = try model_tool_schema.builtinFunctionSchemaJsonAlloc(alloc, got);
        defer alloc.free(got_json);
        try std.testing.expectEqualStrings(want_json, got_json);
    }

    var runner = try buildModelToolProjection(alloc, modes.registry, tool_set, "auto", .{}, .{ .runner = true });
    defer runner.deinit(alloc);
    const runner_shell = functionNamed(runner, "shell") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hasProperty(runner_shell, "runner"));
    try std.testing.expect(hasProperty(runner_shell, "tty"));

    var process_only = try buildModelToolProjection(alloc, modes.registry, tool_set, "auto", .{}, .{ .process_only = true, .runner = true });
    defer process_only.deinit(alloc);
    const process_shell = functionNamed(process_only, "shell") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hasProperty(process_shell, "runner"));
    try std.testing.expect(!hasProperty(process_shell, "tty"));
}

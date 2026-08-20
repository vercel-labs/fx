const std = @import("std");
const builtin_tools = @import("tools.zig");
const browser_terminal = @import("../tools/terminal/browser_terminal.zig");
const tool_set = @import("../core/tooling/tool_set.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

const terminal_description =
    "Run a foreground command inside the browser workspace with action=exec. This clean root-fixed shell is the workspace interface: use commands such as rg, sed, awk, find, jq, mkdir, mv, and redirection to inspect and modify files. Native host paths, git, Node, npm, Python, background processes, durable terminal actions, and operating-system access are unavailable.";

const terminal = buildTerminalSpec();

fn buildTerminalSpec() tool_dispatch.Tool {
    var spec = builtin_tools.terminal;
    spec.description = terminal_description;
    spec.descriptor = .{
        .name = "terminal",
        .description = terminal_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"exec"} } },
                .{
                    .name = "command",
                    .json_type = .string,
                    .max_length = 64 * 1024,
                    .description = "Foreground command to run in the browser workspace.",
                },
            },
            .required = &.{ "action", "command" },
            .additional_properties = false,
        },
    };
    spec.decode = browser_terminal.decode;
    spec.executor_kind = .run_command;
    spec.permission_target_kind = .command_cwd;
    spec.captured_command_host = .workspace_clean;
    return spec;
}

const all = [_]tool_dispatch.Tool{terminal};
pub const registry = tool_dispatch.Registry{ .tools = all[0..] };
const advertisement_order = [_][]const u8{"terminal"};
const advertisement_set = tool_set.ToolSet{
    .registry = registry,
    .order = advertisement_order[0..],
    .read_only_tool_names = &.{},
};

pub fn selectToolSet(comptime native_tools: bool, workspace_available: bool) tool_set.ToolSet {
    if (comptime native_tools) return builtin_tools.advertisement_set;
    return if (workspace_available) advertisement_set else tool_set.empty;
}

test "browser workspace projects exactly one command-only terminal" {
    try std.testing.expectEqual(@as(usize, 1), registry.tools.len);
    try std.testing.expectEqualStrings("terminal", registry.tools[0].name);
    try std.testing.expectEqual(@as(usize, 1), advertisement_set.order.len);
    try std.testing.expectEqualStrings("terminal", advertisement_set.order[0]);
    try std.testing.expectEqual(@as(usize, 0), advertisement_set.read_only_tool_names.len);

    const schema = registry.tools[0].descriptor;
    try std.testing.expectEqual(@as(usize, 2), schema.input_schema.properties.len);
    try std.testing.expectEqualStrings("action", schema.input_schema.properties[0].name);
    try std.testing.expectEqualStrings("command", schema.input_schema.properties[1].name);
    try std.testing.expectEqual(@as(?usize, 64 * 1024), schema.input_schema.properties[1].max_length);
    try std.testing.expectEqual(false, schema.input_schema.additional_properties.?);
    try std.testing.expect(std.mem.find(u8, schema.description, "shell is the workspace interface") != null);
    try std.testing.expect(std.mem.find(u8, schema.description, "clean root-fixed") != null);
}

fn expectDecodeFailure(arguments_json: []const u8) !void {
    const decoded = try registry.tools[0].decode(.{
        .allocator = std.testing.allocator,
    }, arguments_json);
    switch (decoded) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedDecodeFailure;
        },
        .failure => |body| std.testing.allocator.free(body),
    }
}

test "browser workspace rejects missing action native fields and unknown arguments" {
    try expectDecodeFailure("{\"command\":\"pwd\"}");
    try expectDecodeFailure("{\"action\":\"start\",\"command\":\"pwd\"}");
    try expectDecodeFailure("{\"action\":\"exec\",\"command\":\"pwd\",\"cwd\":\"/tmp\"}");
    try expectDecodeFailure("{\"action\":\"exec\",\"command\":\"pwd\",\"profile\":\"clean\"}");
}

test "tool set selection preserves native and gates the browser projection" {
    const native = selectToolSet(true, false);
    try std.testing.expectEqual(builtin_tools.registry.tools.len, native.registry.tools.len);
    try std.testing.expect(native.registry.lookup("background_process") == builtin_tools.registry.lookup("background_process"));

    const absent = selectToolSet(false, false);
    try std.testing.expectEqual(@as(usize, 0), absent.registry.tools.len);
    try std.testing.expectEqual(@as(usize, 0), absent.order.len);

    const present = selectToolSet(false, true);
    try std.testing.expectEqual(@as(usize, 1), present.registry.tools.len);
    try std.testing.expectEqualStrings("terminal", present.registry.tools[0].name);
}

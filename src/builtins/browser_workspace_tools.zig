const std = @import("std");
const builtin_tools = @import("tools.zig");
const browser_shell = @import("../tools/shell/browser_shell.zig");
const tool_set = @import("../core/tooling/tool_set.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

const shell_description =
    "Run one completion-only command inside the browser workspace with action=run. This clean root-fixed shell is the workspace interface. Native host paths, git, Node, npm, Python, managed running handles, TTY input, and operating-system access are unavailable.";

const shell = buildShellSpec();

fn buildShellSpec() tool_dispatch.Tool {
    var spec = builtin_tools.shell;
    spec.description = shell_description;
    spec.model_schema = .{
        .name = "shell",
        .description = shell_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"run"} } },
                .{
                    .name = "command",
                    .json_type = .string,
                    .bounds = &.{ .max_length = 64 * 1024 },
                    .description = "Foreground command to run in the browser workspace.",
                },
            },
            .required = &.{ "action", "command" },
            .additional_properties = false,
        },
    };
    spec.decode = browser_shell.decode;
    spec.validate = null;
    spec.call = browser_shell.call;
    spec.reads_only_fn = browser_shell.readsOnly;
    spec.irreversible_fn = browser_shell.isIrreversible;
    spec.executor_kind = .run_command;
    spec.captured_command_action = null;
    spec.captured_command_fn = null;
    spec.process_local_fn = null;
    spec.permission_target_kind = .command_cwd;
    spec.captured_command_host = .workspace_clean;
    return spec;
}

const all = [_]tool_dispatch.Tool{shell};
pub const registry = tool_dispatch.Registry{ .tools = all[0..] };
const advertisement_order = [_][]const u8{"shell"};
const advertisement_set = tool_set.ToolSet{
    .registry = registry,
    .order = advertisement_order[0..],
    .read_only_tool_names = &.{},
};

pub fn selectToolSet(comptime native_tools: bool, workspace_available: bool) tool_set.ToolSet {
    if (comptime native_tools) return builtin_tools.advertisement_set;
    return if (workspace_available) advertisement_set else tool_set.empty;
}

test "browser workspace projects exactly one completion-only shell" {
    try std.testing.expectEqual(@as(usize, 1), registry.tools.len);
    try std.testing.expectEqualStrings("shell", registry.tools[0].name);
    try std.testing.expectEqual(@as(usize, 1), advertisement_set.order.len);
    try std.testing.expectEqualStrings("shell", advertisement_set.order[0]);
    try std.testing.expectEqual(@as(usize, 0), advertisement_set.read_only_tool_names.len);

    const schema = registry.tools[0].model_schema;
    try std.testing.expectEqual(@as(usize, 2), schema.input_schema.properties.len);
    try std.testing.expectEqualStrings("action", schema.input_schema.properties[0].name);
    try std.testing.expectEqualStrings("command", schema.input_schema.properties[1].name);
    try std.testing.expectEqual(@as(?usize, 64 * 1024), schema.input_schema.properties[1].bounds.?.max_length);
    try std.testing.expectEqual(false, schema.input_schema.additional_properties.?);
    try std.testing.expect(std.mem.find(u8, schema.description, "shell is the workspace interface") != null);
    try std.testing.expect(std.mem.find(u8, schema.description, "clean root-fixed") != null);
}

test "browser workspace model-facing tool contract stays byte exact" {
    const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
    const schema_json = try model_tool_schema.builtinFunctionSchemaJsonAlloc(
        std.testing.allocator,
        registry.tools[0].model_schema,
    );
    defer std.testing.allocator.free(schema_json);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(schema_json, &digest, .{});
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "7646b1773d02e366cec366f77a2760b218865831ff828c18d9ce61748aaab4c8",
        &actual_hex,
    );
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
    try expectDecodeFailure("{\"request\":{\"action\":\"run\",\"command\":\"pwd\"}}");
    try expectDecodeFailure("{\"action\":\"wait\",\"session_id\":\"x\"}");
    try expectDecodeFailure("{\"action\":\"run\",\"command\":\"pwd\",\"cwd\":\"/tmp\"}");
    try expectDecodeFailure("{\"action\":\"run\",\"command\":\"pwd\",\"profile\":\"clean\"}");
}

test "browser workspace supplies its private timeout without widening public input" {
    const decoded = try registry.tools[0].decode(.{
        .allocator = std.testing.allocator,
    }, "{\"action\":\"run\",\"command\":\"pwd\"}");
    switch (decoded) {
        .failure => |body| {
            defer std.testing.allocator.free(body);
            return error.TestUnexpectedDecodeFailure;
        },
        .input => |input| input.deinit(std.testing.allocator),
    }
}

test "tool set selection preserves native and gates the browser projection" {
    const native = selectToolSet(true, false);
    try std.testing.expectEqual(builtin_tools.registry.tools.len, native.registry.tools.len);
    try std.testing.expect(native.registry.lookup("shell") == builtin_tools.registry.lookup("shell"));

    const absent = selectToolSet(false, false);
    try std.testing.expectEqual(@as(usize, 0), absent.registry.tools.len);
    try std.testing.expectEqual(@as(usize, 0), absent.order.len);

    const present = selectToolSet(false, true);
    try std.testing.expectEqual(@as(usize, 1), present.registry.tools.len);
    try std.testing.expectEqualStrings("shell", present.registry.tools[0].name);
}

//! The tool set behind `experimental.bash_tool`: one `bash` tool in place of
//! fx's file, search, web, and shell tools, plus subagent, toolbox, and vision.

const std = @import("std");
const build_options = @import("build_options");
const builtin_tools = @import("tools.zig");
const bash_impl = @import("../tools/bash/bash.zig");
const bash_session = @import("../core/bash_session/bash_session.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const terminal_contracts = @import("../core/terminal/contracts.zig");
const tool_set = @import("../core/tooling/tool_set.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

/// The one name of this tool: its spec, its model schema, and its advertised order.
const tool_name = "bash";

const bash_description = std.fmt.comptimePrint(
    "Run one bash program in the workspace. Its variables, functions, aliases, shell options, and working folder carry over to the next program. Use it for all work: read files (cat, sed -n, head), search (rg, rg --files), change files only with edit PATH (SEARCH/REPLACE blocks on stdin) and write PATH (the whole file on stdin), never with sed -i, perl -pi, or a > redirect, so fx can show and undo each change, run tests and builds, and use git. A call waits up to {d} s. When the program is still running, send {s} as the whole program to wait for it; only one program runs at a time. Reach this session's MCP tools with fx mcp call. A program can also use skills, subagents, and the web: skill list, skill open NAME, agent message NAME TEXT, agent wait, agent status, agent stop NAME, web URL, search QUERY. Each program's full output is saved as $FX_OUT/N.txt and listed in $FX_OUT/index.tsv; a long one comes back as a preview, so read the rest with rg, sed, or jq instead of running the program again.",
    .{ bash_impl.program_yield_ms / 1000, bash_session.wait_word },
);

const command_description = "The bash program to run. Send " ++ bash_session.wait_word ++ " alone to wait for a program that is still running.";

comptime {
    // A longer description is cut before it reaches the model.
    if (bash_description.len > model_tool_schema.description_max_bytes) @compileError("bash description exceeds the tool description limit");
    if (command_description.len > model_tool_schema.description_max_bytes) @compileError("bash command description exceeds the tool description limit");
}

test "the bash description says to change files with edit and write, not with sed or a redirect" {
    try std.testing.expect(std.mem.find(u8, bash_description, "change files only with edit PATH (SEARCH/REPLACE blocks on stdin) and write PATH (the whole file on stdin), never with sed -i, perl -pi, or a > redirect, so fx can show and undo each change") != null);
    try std.testing.expect(std.mem.find(u8, bash_description, "python3, or a heredoc") == null);
}

test "the bash description tells the model about the skill and agent functions" {
    try std.testing.expect(std.mem.find(u8, bash_description, "A program can also use skills, subagents, and the web: skill list, skill open NAME, agent message NAME TEXT, agent wait, agent status, agent stop NAME, web URL, search QUERY.") != null);
}

test "the bash description names the web and search functions, within the byte limit" {
    try std.testing.expect(std.mem.find(u8, bash_description, "web URL") != null);
    try std.testing.expect(std.mem.find(u8, bash_description, "search QUERY") != null);
    try std.testing.expect(bash_description.len <= model_tool_schema.description_max_bytes);
}

const bash = tool_dispatch.Tool{
    .name = tool_name,
    .description = bash_description,
    .model_schema = .{
        .name = tool_name,
        .description = bash_description,
        .input_schema = .{
            .properties = &.{.{
                .name = "command",
                .json_type = .string,
                .bounds = &.{ .max_length = @intCast(terminal_contracts.max_command_bytes) },
                .description = command_description,
            }},
            .required = &.{"command"},
            .additional_properties = false,
        },
    },
    .executor_kind = .terminal,
    .activity_kind = .command,
    .requires_approval = true,
    .action_label = "Running",
    .completed_action_label = "Ran",
    .label_arg_kind = .command,
    .label_arg_default = "bash program",
    .permission_target_kind = .none,
    .decode = bash_impl.decode,
    .validate = bash_impl.validate,
    .call = bash_impl.call,
    .runtime_provider = .run_command,
    .captured_command_host = .bash_session,
    .captured_command_action = @tagName(bash_impl.Action.run),
    .captured_command_fn = bash_impl.isCapturedCommand,
    .infer_action_fn = bash_impl.inferAction,
    .process_local_fn = bash_impl.isProcessLocal,
    .reads_only_fn = bash_impl.readsOnly,
    .irreversible_fn = bash_impl.isIrreversible,
};

const all = [_]tool_dispatch.Tool{ bash, builtin_tools.subagent, builtin_tools.toolbox, builtin_tools.vision };

// As tools.zig does: a build without the tools' code keeps each tool's name and
// answers Unsupported tool, so it does not link the bash tool's code.
const registry = tool_dispatch.Registry{ .tools = if (build_options.builtin_tools) all[0..] else names_only[0..] };

const names_only = builtin_tools.namesOnly(&all);

const advertisement_order = [_][]const u8{ tool_name, "subagent", "toolbox" };

const advertisement_set = tool_set.ToolSet{
    .registry = registry,
    .order = advertisement_order[0..],
    .read_only_tool_names = &.{},
};

/// The tool set a host advertises: `advertisement_set` when `enabled`, else
/// `base` unchanged. Hosts call it only where they use
/// `builtin_tools.advertisement_set` today.
pub fn select(enabled: bool, base: tool_set.ToolSet) tool_set.ToolSet {
    return if (enabled) advertisement_set else base;
}

test "the bash tool set projects bash with the advertised built-in tools, in order" {
    const names = [_][]const u8{ "bash", "subagent", "toolbox", "vision" };
    try std.testing.expectEqual(names.len, registry.tools.len);
    for (names, registry.tools) |name, tool| try std.testing.expectEqualStrings(name, tool.name);

    const advertised = [_][]const u8{ "bash", "subagent", "toolbox" };
    try std.testing.expectEqual(advertised.len, advertisement_set.order.len);
    for (advertised, advertisement_set.order) |name, ordered| try std.testing.expectEqualStrings(name, ordered);
    try std.testing.expectEqual(@as(usize, 0), advertisement_set.read_only_tool_names.len);
}

test "every projected tool names its schema and keeps its descriptions within the cap" {
    for (registry.tools) |tool| {
        try std.testing.expectEqualStrings(tool.name, tool.model_schema.name);
        try std.testing.expectEqualStrings(tool.description, tool.model_schema.description);
        try std.testing.expect(tool.description.len <= model_tool_schema.description_max_bytes);
        for (tool.model_schema.input_schema.properties) |property| {
            try std.testing.expect(property.description.len <= model_tool_schema.description_max_bytes);
        }
    }
}

test "the bash spec keeps its command contract: one closed command property, run in the session" {
    const spec = registry.lookup("bash").?;
    const schema = spec.model_schema.input_schema;
    try std.testing.expectEqual(@as(usize, 1), schema.properties.len);
    try std.testing.expectEqualStrings("command", schema.properties[0].name);
    try std.testing.expectEqual(@as(u32, 64 * 1024), schema.properties[0].bounds.?.max_length);
    try std.testing.expectEqualStrings(command_description, schema.properties[0].description);
    try std.testing.expectEqual(@as(usize, 1), schema.required.len);
    try std.testing.expectEqualStrings("command", schema.required[0]);
    try std.testing.expectEqual(@as(?bool, false), schema.additional_properties);

    try std.testing.expect(spec.executor_kind == .terminal);
    try std.testing.expect(spec.activity_kind == .command);
    try std.testing.expect(spec.requires_approval);
    try std.testing.expectEqualStrings("Running", spec.action_label);
    try std.testing.expectEqualStrings("Ran", spec.completed_action_label);
    try std.testing.expect(spec.label_arg_kind == .command);
    try std.testing.expectEqualStrings("bash program", spec.label_arg_default);
    try std.testing.expect(spec.permission_target_kind == .none);
    try std.testing.expect(spec.runtime_provider == .run_command);
    try std.testing.expect(spec.captured_command_host == .bash_session);
    try std.testing.expectEqualStrings("run", spec.captured_command_action.?);
    try std.testing.expect(spec.captured_command_fn != null);
    try std.testing.expect(spec.infer_action_fn != null);
    try std.testing.expect(spec.process_local_fn != null);
}

test "the bash gateway schema stays byte exact" {
    const schema_json = try model_tool_schema.builtinFunctionSchemaJsonAlloc(
        std.testing.allocator,
        bash.model_schema,
    );
    defer std.testing.allocator.free(schema_json);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(schema_json, &digest, .{});
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "0957e655028fb6b941ec9f47b810463d3e619de745a0a0752071488de9cd5067",
        &actual_hex,
    );
}

test "without the tools' code the set keeps every name and answers Unsupported tool" {
    try std.testing.expectEqual(all.len, names_only.len);
    for (names_only, all) |tool, real| {
        try std.testing.expectEqualStrings(real.name, tool.name);
        try std.testing.expect(!tool.model_visible);
    }
    const names = tool_dispatch.Registry{ .tools = names_only[0..] };
    for (advertisement_order) |name| try std.testing.expect(names.lookup(name) != null);

    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "bash" };
    const decoded = try names.lookup("bash").?.decode(ctx, "{\"command\":\"true\"}");
    defer std.testing.allocator.free(decoded.failure);
    try std.testing.expectEqualStrings("Unsupported tool: bash", decoded.failure);
}

test "select keeps the base set when disabled and projects the bash set when enabled" {
    const base = builtin_tools.advertisement_set;

    const kept = select(false, base);
    try std.testing.expectEqual(base.registry.tools.ptr, kept.registry.tools.ptr);
    try std.testing.expectEqual(base.registry.tools.len, kept.registry.tools.len);
    try std.testing.expectEqual(base.order.ptr, kept.order.ptr);
    try std.testing.expectEqual(base.order.len, kept.order.len);

    const projected = select(true, base);
    try std.testing.expect(projected.registry.lookup("bash") != null);
    try std.testing.expect(projected.registry.lookup("shell") == null);
    try std.testing.expectEqual(@as(usize, 3), projected.order.len);
    try std.testing.expectEqualStrings("bash", projected.order[0]);
}

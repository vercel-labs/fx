const std = @import("std");
const model_tool_schema = @import("model_tool_schema.zig");
const permissions = @import("../permissions/permissions.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_set_contract = @import("tool_set.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    permission_mode: types.PermissionMode = .auto,
    permission_rules: types.PermissionRuleSet = .{},
    subagent_available: bool = false,
};

const BuildKind = enum { full, read_only };

const TestInput = struct {};

fn testInputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    alloc.destroy(@as(*TestInput, @ptrCast(@alignCast(ptr))));
}

fn decodeTestInput(ctx: tool_dispatch.DispatchContext, _: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const input = try ctx.allocator.create(TestInput);
    input.* = .{};
    return .{ .input = .{ .ptr = input, .deinit_fn = testInputDeinit } };
}

fn callTestTool(ctx: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, "test tool result") };
}

fn testToolReadsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

fn testToolIsIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

const test_tool_seed = tool_dispatch.Tool{
    .name = "test_tool",
    .description = "Test registered tool.",
    .model_schema = .{
        .name = "test_tool",
        .description = "Test registered tool.",
    },
    .decode = decodeTestInput,
    .call = callTestTool,
    .reads_only_fn = testToolReadsOnly,
    .irreversible_fn = testToolIsIrreversible,
};

const test_read_file = blk: {
    var spec = test_tool_seed;
    spec.name = "read_file";
    spec.description = "Test file read. When to use: exercise registered read projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.model_schema = .{
        .name = "read_file",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    };
    spec.executor_kind = .read_file;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Reading";
    spec.completed_action_label = "Read";
    spec.label_arg_kind = .path;
    spec.label_arg_default = "file";
    spec.permission_target_kind = .path_existing;
    break :blk spec;
};

const test_write_file = blk: {
    var spec = test_read_file;
    spec.name = "write_file";
    spec.description = "Test file write. When to use: exercise registered mutation projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.model_schema = .{
        .name = "write_file",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "content", .json_type = .string },
            },
            .required = &.{ "path", "content" },
        },
    };
    spec.executor_kind = .write_file;
    spec.activity_kind = .write;
    spec.requires_approval = true;
    spec.action_label = "Writing";
    spec.completed_action_label = "Wrote";
    spec.label_arg_kind = .path;
    spec.label_arg_default = "file";
    spec.permission_target_kind = .path_create_parent;
    break :blk spec;
};

const test_edit_file = blk: {
    var spec = test_read_file;
    spec.name = "edit_file";
    spec.description = "Test file editing. When to use: exercise registered edit projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.model_schema = .{
        .name = "edit_file",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
                .{ .name = "old_string", .json_type = .string },
                .{ .name = "new_string", .json_type = .string },
            },
            .required = &.{ "path", "old_string", "new_string" },
        },
    };
    spec.executor_kind = .edit_file;
    spec.activity_kind = .edit;
    spec.requires_approval = true;
    spec.action_label = "Editing";
    spec.completed_action_label = "Edited";
    spec.label_arg_kind = .path;
    spec.label_arg_default = "file";
    spec.permission_target_kind = .path_existing_parent;
    break :blk spec;
};

const test_glob_files = blk: {
    var spec = test_read_file;
    spec.name = "glob_files";
    spec.description = "Test filename matching. When to use: exercise registered search projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.model_schema = .{
        .name = "glob_files",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "pattern", .json_type = .string },
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"pattern"},
        },
    };
    spec.executor_kind = .glob_files;
    spec.activity_kind = .list;
    spec.action_label = "Matching";
    spec.completed_action_label = "Matched";
    spec.label_arg_kind = .pattern;
    spec.label_arg_default = "pattern";
    break :blk spec;
};

const test_grep_files = blk: {
    var spec = test_read_file;
    spec.name = "grep_files";
    spec.description = "Test text search. When to use: exercise registered search projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.model_schema = .{
        .name = "grep_files",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "pattern", .json_type = .string },
            },
            .required = &.{"pattern"},
        },
    };
    spec.executor_kind = .grep_files;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Searching";
    spec.completed_action_label = "Searched";
    spec.label_arg_kind = .pattern;
    spec.label_arg_default = "pattern";
    spec.permission_target_kind = .path_optional_existing;
    break :blk spec;
};

fn writeTestWebSearchProviderAdvertisement(
    _: Allocator,
    writer: *std.Io.Writer,
) tool_dispatch.ProviderAdvertisementError!void {
    try writer.writeAll("{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\",\"args\":{}}");
}

const test_web_fetch = blk: {
    var spec = test_read_file;
    spec.name = "web_fetch";
    spec.model_schema = .{
        .name = "web_fetch",
        .description = spec.description,
    };
    spec.executor_kind = .web_fetch;
    spec.label_arg_kind = .url;
    spec.label_arg_default = "url";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_web_search_base = blk: {
    var spec = test_web_fetch;
    spec.name = "web_search";
    spec.description = "Test web search guidance.";
    spec.model_schema = .{
        .name = "web_search",
        .description = spec.description,
    };
    spec.executor_kind = .web_search;
    spec.label_arg_kind = .query;
    spec.label_arg_default = "web";
    break :blk spec;
};

const test_web_search = blk: {
    var spec = test_web_search_base;
    spec.write_provider_advertisement_fn = writeTestWebSearchProviderAdvertisement;
    spec.provider_executed = true;
    break :blk spec;
};

const test_shell = blk: {
    var spec = test_read_file;
    spec.name = "shell";
    spec.description = "Test shell. When to use: exercise registered shell projection. When NOT to use: assert product-specific shell behavior.";
    spec.model_schema = .{
        .name = "shell",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"run"} } },
                .{ .name = "command", .json_type = .string },
            },
            .required = &.{ "action", "command" },
            .additional_properties = false,
        },
    };
    spec.executor_kind = .terminal;
    spec.activity_kind = .command;
    spec.requires_approval = true;
    spec.action_label = "Running shell";
    spec.completed_action_label = "Ran shell";
    spec.label_arg_kind = .action;
    spec.label_arg_default = "session";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_skill = blk: {
    var spec = test_read_file;
    spec.name = "skill";
    spec.description = "Test skill. When to use: exercise registered skill projection. When NOT to use: assert product-specific skill loading.";
    spec.model_schema = .{
        .name = "skill",
        .description = spec.description,
    };
    spec.executor_kind = .skill;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Loading skill";
    spec.completed_action_label = "Loaded skill";
    spec.label_arg_kind = .name;
    spec.label_arg_default = "skill";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_capability_search = blk: {
    var spec = test_skill;
    spec.name = "capability_search";
    spec.description = "Test capability search. When to use: discover skill and MCP metadata together. When NOT to use: load or execute a match.";
    spec.model_schema = .{
        .name = "capability_search",
        .description = spec.description,
    };
    spec.model_visible = true;
    spec.action_label = "Searching capabilities";
    spec.completed_action_label = "Searched capabilities";
    spec.label_arg_kind = .query;
    spec.label_arg_default = "capabilities";
    break :blk spec;
};

const test_install_skill = blk: {
    var spec = test_skill;
    spec.name = "install_skill";
    spec.description = "Test install skill. When to use: exercise registered write-tool projection. When NOT to use: assert product-specific installation behavior.";
    spec.model_schema = .{
        .name = "install_skill",
        .description = spec.description,
    };
    spec.executor_kind = .install_skill;
    spec.activity_kind = .write;
    spec.requires_approval = true;
    spec.action_label = "Installing skill";
    spec.completed_action_label = "Installed skill";
    spec.label_arg_kind = .source;
    break :blk spec;
};

const test_subagent = blk: {
    var spec = test_skill;
    spec.name = "subagent";
    spec.description = "Test subagent. When to use: exercise registered subagent projection. When NOT to use: assert product-specific child management.";
    spec.model_schema = .{
        .name = "subagent",
        .description = spec.description,
    };
    spec.executor_kind = .subagent;
    spec.activity_kind = .subagent;
    spec.action_label = "Managing";
    spec.completed_action_label = "Managed";
    spec.label_arg_kind = .none;
    spec.label_arg_default = "subagent";
    break :blk spec;
};

const test_mcp_select_tool = blk: {
    var spec = test_skill;
    spec.name = "mcp_select_tool";
    spec.description = "Test MCP selection. When to use: exercise deferred MCP projection. When NOT to use: assert product-specific MCP guidance.";
    spec.model_schema = .{
        .name = "mcp_select_tool",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "name", .json_type = .string },
            },
            .required = &.{"name"},
        },
    };
    spec.executor_kind = .mcp_select_tool;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Selecting MCP tool";
    spec.completed_action_label = "Selected MCP tool";
    spec.label_arg_kind = .name;
    spec.label_arg_default = "dynamic tool";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_ask_user_question = blk: {
    var spec = test_subagent;
    spec.name = "ask_user_question";
    spec.description = "Test user question. When to use: exercise registered interactive projection. When NOT to use: assert product-specific question behavior.";
    spec.model_schema = .{
        .name = "ask_user_question",
        .description = spec.description,
    };
    spec.executor_kind = .ask_user_question;
    spec.activity_kind = .ask;
    spec.requires_approval = false;
    spec.action_label = "Asking";
    spec.completed_action_label = "Asked";
    spec.label_arg_kind = .none;
    spec.label_arg_default = "";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_vision = blk: {
    var spec = test_read_file;
    spec.name = "vision";
    spec.description = "Test route-filtered vision capability.";
    spec.model_schema = .{
        .name = "vision",
        .description = spec.description,
    };
    spec.executor_kind = .vision;
    spec.activity_kind = .read;
    spec.requires_approval = true;
    spec.approval_policy = .ask_only;
    spec.action_label = "Inspecting";
    spec.completed_action_label = "Inspected";
    spec.label_arg_kind = .none;
    spec.label_arg_default = "images";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_read_tool_result = blk: {
    var spec = test_read_file;
    spec.name = "read_tool_result";
    spec.description = "Test tool result lookup. When to use: exercise registry projection. When NOT to use: assert product-specific session behavior.";
    spec.model_schema = .{
        .name = "read_tool_result",
        .description = spec.description,
    };
    spec.executor_kind = .read_tool_result;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Reading";
    spec.completed_action_label = "Read";
    spec.label_arg_kind = .path;
    spec.label_arg_default = "tool result";
    spec.permission_target_kind = .none;
    break :blk spec;
};

fn writeTestMirrorProviderAdvertisement(
    _: Allocator,
    writer: *std.Io.Writer,
) tool_dispatch.ProviderAdvertisementError!void {
    try writer.writeAll("{\"type\":\"provider\",\"id\":\"gateway.mirror_search\",\"name\":\"mirror_search\",\"args\":{}}");
}

const test_mirror_provider_tool = blk: {
    var spec = test_web_search_base;
    spec.name = "mirror_search";
    spec.write_provider_advertisement_fn = writeTestMirrorProviderAdvertisement;
    spec.provider_executed = true;
    break :blk spec;
};

/// Owns the selected registry names and any separate guidance required by
/// included provider-executed tools. The caller must deinitialize the result
/// with the allocator passed to the builder.
pub const EffectiveToolProjection = struct {
    /// Borrowed registry names selected for model advertisement. The slice
    /// storage is owned by this projection.
    advertised_names: []const []const u8,
    /// Exact borrowed built-in schemas selected for model advertisement. The
    /// slice storage is owned by this projection.
    advertised_functions: []const model_tool_schema.FunctionSchema,
    custom_guidance: []u8,

    pub fn deinit(self: *EffectiveToolProjection, alloc: Allocator) void {
        alloc.free(self.advertised_names);
        alloc.free(self.advertised_functions);
        alloc.free(self.custom_guidance);
        self.* = undefined;
    }
};

pub fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

const test_all_tools = [_]tool_dispatch.Tool{
    test_glob_files,
    test_grep_files,
    test_read_file,
    test_write_file,
    test_edit_file,
    test_web_fetch,
    test_web_search,
    test_shell,
    test_capability_search,
    test_skill,
    test_install_skill,
    test_subagent,
    test_mcp_select_tool,
    test_ask_user_question,
    test_vision,
    test_read_tool_result,
};

const test_order = [_][]const u8{
    "read_file",
    "glob_files",
    "grep_files",
    "edit_file",
    "write_file",
    "shell",
    "subagent",
    "capability_search",
    "skill",
    "install_skill",
    "mcp_select_tool",
    "ask_user_question",
    "web_fetch",
    "web_search",
};

const test_read_only_names = [_][]const u8{
    "read_file",
    "glob_files",
    "grep_files",
};

const test_tool_set = tool_set_contract.ToolSet{
    .registry = .{ .tools = test_all_tools[0..] },
    .order = test_order[0..],
    .read_only_tool_names = test_read_only_names[0..],
};

fn testToolSetForRegistry(tools: []const tool_dispatch.Tool) tool_set_contract.ToolSet {
    return .{
        .registry = .{ .tools = tools },
        .order = test_order[0..],
        .read_only_tool_names = test_read_only_names[0..],
    };
}

fn buildTestModelToolProjection(alloc: Allocator, options: Options) !EffectiveToolProjection {
    return buildModelToolProjectionForSet(alloc, test_tool_set, options);
}

fn buildTestModelToolProjectionForRegistry(alloc: Allocator, tools: []const tool_dispatch.Tool, options: Options) !EffectiveToolProjection {
    return buildModelToolProjectionForSet(alloc, testToolSetForRegistry(tools), options);
}

fn buildTestReadOnlyModelToolProjection(alloc: Allocator, options: Options) !EffectiveToolProjection {
    return buildReadOnlyModelToolProjectionForSet(alloc, test_tool_set, options);
}

pub fn buildModelToolProjectionForSet(alloc: Allocator, tool_set: tool_set_contract.ToolSet, options: Options) !EffectiveToolProjection {
    return buildToolProjection(alloc, tool_set, .full, options);
}

pub fn buildReadOnlyModelToolProjectionForSet(alloc: Allocator, tool_set: tool_set_contract.ToolSet, options: Options) !EffectiveToolProjection {
    return buildToolProjection(alloc, tool_set, .read_only, options);
}

fn buildToolProjection(alloc: Allocator, tool_set: tool_set_contract.ToolSet, kind: BuildKind, options: Options) !EffectiveToolProjection {
    var advertised_names: std.ArrayList([]const u8) = .empty;
    errdefer advertised_names.deinit(alloc);
    var advertised_functions: std.ArrayList(model_tool_schema.FunctionSchema) = .empty;
    errdefer advertised_functions.deinit(alloc);
    var guidance_out: std.Io.Writer.Allocating = .init(alloc);
    errdefer guidance_out.deinit();

    var first_custom_guidance = true;

    for (tool_set.order) |tool_name| {
        const tool = tool_set.registry.lookup(tool_name) orelse continue;
        try appendBuiltinTool(alloc, &advertised_names, &advertised_functions, &guidance_out.writer, &first_custom_guidance, tool.*, kind, tool_set, options);
    }

    if (kind == .full) {
        for (tool_set.registry.tools) |tool| {
            if (isCanonicalToolName(tool_set, tool.name)) continue;
            try appendBuiltinTool(alloc, &advertised_names, &advertised_functions, &guidance_out.writer, &first_custom_guidance, tool, kind, tool_set, options);
        }
    }

    const custom_guidance = try guidance_out.toOwnedSlice();
    errdefer alloc.free(custom_guidance);
    const names = try advertised_names.toOwnedSlice(alloc);
    errdefer alloc.free(names);
    const functions = try advertised_functions.toOwnedSlice(alloc);
    return .{
        .advertised_names = names,
        .advertised_functions = functions,
        .custom_guidance = custom_guidance,
    };
}
fn appendBuiltinTool(
    alloc: Allocator,
    advertised_names: *std.ArrayList([]const u8),
    advertised_functions: *std.ArrayList(model_tool_schema.FunctionSchema),
    guidance_writer: *std.Io.Writer,
    first_custom_guidance: *bool,
    tool: tool_dispatch.Tool,
    kind: BuildKind,
    tool_set: tool_set_contract.ToolSet,
    options: Options,
) !void {
    if (!tool.model_visible) return;
    if (!includeBuiltinForKind(tool.name, kind, tool_set)) return;
    if (std.mem.eql(u8, tool.name, "subagent") and !options.subagent_available) return;
    if (std.mem.eql(u8, tool.name, "vision")) return;
    if (options.permission_mode != .yolo) {
        if (tool.provider_executed and !providerExecutionIsAllowed(tool.name, options.permission_rules)) return;
        if (permissions.rulesDenyAllTargetsForTool(options.permission_rules, tool.name)) return;
    }
    try advertised_names.append(alloc, tool.name);
    if (!tool.provider_executed and tool.write_provider_advertisement_fn == null) {
        try advertised_functions.append(alloc, tool.model_schema);
    }
    if (tool.write_provider_advertisement_fn != null) {
        if (first_custom_guidance.*) {
            first_custom_guidance.* = false;
        } else {
            try guidance_writer.writeAll("\n\n");
        }
        try guidance_writer.writeAll(tool.description);
    }
}

/// A provider-executed tool is never dispatched locally, so an unsettled `ask`
/// hides it exactly like a `deny`. The tool name doubles as the target pattern
/// because the provider owns the call and fx never sees its arguments.
fn providerExecutionIsAllowed(tool_name: []const u8, rules: types.PermissionRuleSet) bool {
    const permission = permissions.permissionNameForTool(tool_name);
    return switch (permissions.ruleDecisionForPermissionPattern(rules, permission, tool_name, .none)) {
        .none, .allow => true,
        .ask, .deny => false,
    };
}

fn includeBuiltinForKind(tool_name: []const u8, kind: BuildKind, tool_set: tool_set_contract.ToolSet) bool {
    const names = builtinNamesForKind(kind, tool_set) orelse return true;
    return toolNameInSet(names, tool_name);
}

fn builtinNamesForKind(kind: BuildKind, tool_set: tool_set_contract.ToolSet) ?[]const []const u8 {
    return switch (kind) {
        .full => null,
        .read_only => tool_set.read_only_tool_names,
    };
}

fn toolNameInSet(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn isCanonicalToolName(tool_set: tool_set_contract.ToolSet, name: []const u8) bool {
    for (tool_set.order) |tool_name| {
        if (std.mem.eql(u8, tool_name, name)) return true;
    }
    return false;
}

fn expectContainsName(names: []const []const u8, expected: []const u8) !void {
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) return;
    }
    return error.TestExpectedEqual;
}

fn expectNotContainsName(names: []const []const u8, expected: []const u8) !void {
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) return error.TestExpectedEqual;
    }
}

fn indexOfName(names: []const []const u8, expected: []const u8) !usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, expected)) return index;
    }
    return error.TestExpectedEqual;
}

test "provider-executed search follows settled advertisement permission" {
    const cases = [_]struct {
        action: ?types.PermissionAction,
        advertised: bool,
    }{
        .{ .action = null, .advertised = true },
        .{ .action = .allow, .advertised = true },
        .{ .action = .ask, .advertised = false },
        .{ .action = .deny, .advertised = false },
    };

    for (cases) |case| {
        var rules = [_]types.PermissionRule{.{
            .permission = @constCast("web_search"),
            .pattern = @constCast("*"),
            .action = case.action orelse .deny,
        }};
        const options: Options = if (case.action != null)
            .{ .permission_rules = .{ .rules = &rules } }
        else
            .{};
        var projection = try buildTestModelToolProjection(std.testing.allocator, options);
        defer projection.deinit(std.testing.allocator);

        try std.testing.expectEqual(
            case.advertised,
            containsName(projection.advertised_names, "web_search"),
        );
        try std.testing.expectEqualStrings(
            if (case.advertised) test_web_search.description else "",
            projection.custom_guidance,
        );
    }
}

test "provider execution gate follows the registry declaration" {
    const tools = [_]tool_dispatch.Tool{test_mirror_provider_tool};
    inline for (.{
        .{ types.PermissionAction.allow, true },
        .{ types.PermissionAction.ask, false },
        .{ types.PermissionAction.deny, false },
    }) |case| {
        var rules = [_]types.PermissionRule{.{
            .permission = @constCast("mirror_search"),
            .pattern = @constCast("*"),
            .action = case[0],
        }};
        var projection = try buildTestModelToolProjectionForRegistry(
            std.testing.allocator,
            &tools,
            .{ .permission_rules = .{ .rules = &rules } },
        );
        defer projection.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[1], containsName(projection.advertised_names, "mirror_search"));
    }
}

test "ask keeps advertising locally executed tools" {
    const tools = [_]tool_dispatch.Tool{test_web_search_base};
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("web_search"),
        .pattern = @constCast("*"),
        .action = .ask,
    }};
    var projection = try buildTestModelToolProjectionForRegistry(
        std.testing.allocator,
        &tools,
        .{ .permission_rules = .{ .rules = &rules } },
    );
    defer projection.deinit(std.testing.allocator);
    try expectContainsName(projection.advertised_names, "web_search");
}

test "yolo advertisement ignores permission filtering" {
    var rules = [_]types.PermissionRule{.{
        .permission = @constCast("*"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{
        .permission_mode = .yolo,
        .permission_rules = .{ .rules = &rules },
    });
    defer projection.deinit(std.testing.allocator);
    try expectContainsName(projection.advertised_names, "shell");
    try expectContainsName(projection.advertised_names, "write_file");
    try expectContainsName(projection.advertised_names, "web_search");
}

test "category-wide denies and later overrides select the expected tools" {
    var denied_rules = [_]types.PermissionRule{.{
        .permission = @constCast("edit"),
        .pattern = @constCast("*"),
        .action = .deny,
    }};
    var denied = try buildTestModelToolProjection(std.testing.allocator, .{
        .permission_rules = .{ .rules = &denied_rules },
    });
    defer denied.deinit(std.testing.allocator);
    try expectNotContainsName(denied.advertised_names, "edit_file");
    try expectNotContainsName(denied.advertised_names, "write_file");

    var overridden_rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("*"), .action = .deny },
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/*"), .action = .ask },
    };
    var overridden = try buildTestModelToolProjection(std.testing.allocator, .{
        .permission_rules = .{ .rules = &overridden_rules },
    });
    defer overridden.deinit(std.testing.allocator);
    try expectContainsName(overridden.advertised_names, "edit_file");
    try expectContainsName(overridden.advertised_names, "write_file");
}

fn checkEffectiveToolProjectionAllocationFailures(alloc: Allocator) !void {
    var projection = buildTestModelToolProjection(alloc, .{}) catch |err|
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    defer projection.deinit(alloc);
    try expectContainsName(projection.advertised_names, "read_file");
    try std.testing.expectEqualStrings(test_web_search.description, projection.custom_guidance);
}

test "effective tool projection cleans up every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkEffectiveToolProjectionAllocationFailures,
        .{},
    );
}

test "base tool projection includes MCP discovery and explicit selection" {
    const alloc = std.testing.allocator;
    var projection = try buildTestModelToolProjection(alloc, .{});
    defer projection.deinit(alloc);
    try expectContainsName(projection.advertised_names, "capability_search");
    try expectContainsName(projection.advertised_names, "mcp_select_tool");
}

test "subagent and shell selection follow host capability" {
    var unavailable = try buildTestModelToolProjection(std.testing.allocator, .{});
    defer unavailable.deinit(std.testing.allocator);
    try expectNotContainsName(unavailable.advertised_names, "subagent");
    try expectNotContainsName(unavailable.advertised_names, "task");
    try expectContainsName(unavailable.advertised_names, "shell");

    var available = try buildTestModelToolProjection(std.testing.allocator, .{
        .subagent_available = true,
    });
    defer available.deinit(std.testing.allocator);
    try expectContainsName(available.advertised_names, "subagent");
    try expectNotContainsName(available.advertised_names, "task");
    try expectContainsName(available.advertised_names, "shell");
}

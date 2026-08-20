const std = @import("std");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const tool_descriptor = @import("tool_descriptor.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const permissions = @import("../permissions/permissions.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_set_contract = @import("tool_set.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    permission_mode: types.PermissionMode = .auto,
    permission_rules: types.PermissionRuleSet = .{},
    mcp_runtime: ?*mcp_runtime.McpRuntime = null,
    subagent_available: bool = false,
    provider_tools: []const agent_stream_provider.ProviderTool = &.{},
    fx_web_search_installed: bool = false,
    terminal_available: bool = false,
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
    .descriptor = .{
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
    spec.descriptor = .{
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

const test_file_info = blk: {
    var spec = test_read_file;
    spec.name = "file_info";
    spec.description = "Test file metadata. When to use: exercise registered metadata projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.descriptor = .{
        .name = "file_info",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    };
    spec.executor_kind = .file_info;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Inspecting";
    spec.completed_action_label = "Inspected";
    spec.label_arg_kind = .path;
    spec.label_arg_default = "path";
    spec.permission_target_kind = .path_existing;
    break :blk spec;
};

const test_open_file = blk: {
    var spec = test_read_file;
    spec.name = "open_file";
    spec.description = "Test file open. When to use: exercise registered launcher projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.descriptor = .{
        .name = "open_file",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    };
    spec.executor_kind = .open_file;
    spec.activity_kind = .open;
    spec.requires_approval = true;
    spec.action_label = "Opening";
    spec.completed_action_label = "Opened";
    spec.label_arg_kind = .path;
    spec.label_arg_default = "file";
    spec.permission_target_kind = .path_existing;
    break :blk spec;
};

const test_memory = blk: {
    var spec = test_read_file;
    spec.name = "memory";
    spec.description = "Test durable memory. When to use: exercise registered memory projection. When NOT to use: assert product-specific persistence behavior.";
    spec.descriptor = .{
        .name = "memory",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{ "save", "list", "clear" } } },
                .{ .name = "fact", .json_type = .string },
            },
            .required = &.{"action"},
        },
    };
    spec.executor_kind = .memory;
    spec.activity_kind = .write;
    spec.requires_approval = false;
    spec.action_label = "Remembering";
    spec.completed_action_label = "Remembered";
    spec.label_arg_kind = .action;
    spec.label_arg_default = "memory";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_semantic_search = blk: {
    var spec = test_read_file;
    spec.name = "semantic_search";
    spec.description = "Test lexical search. When to use: exercise registered search projection. When NOT to use: assert product-specific search behavior.";
    spec.descriptor = .{
        .name = "semantic_search",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "query", .json_type = .string },
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"query"},
        },
    };
    spec.executor_kind = .semantic_search;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Searching";
    spec.completed_action_label = "Searched";
    spec.label_arg_kind = .query;
    spec.label_arg_default = "query";
    spec.permission_target_kind = .path_optional_existing;
    break :blk spec;
};

const test_write_file = blk: {
    var spec = test_read_file;
    spec.name = "write_file";
    spec.description = "Test file write. When to use: exercise registered mutation projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.descriptor = .{
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
    spec.descriptor = .{
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

const test_delete_file = blk: {
    var spec = test_read_file;
    spec.name = "delete_file";
    spec.description = "Test file deletion. When to use: exercise registered delete projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.descriptor = .{
        .name = "delete_file",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    };
    spec.executor_kind = .delete_file;
    spec.activity_kind = .write;
    spec.requires_approval = true;
    spec.action_label = "Deleting";
    spec.completed_action_label = "Deleted";
    spec.label_arg_kind = .path;
    spec.label_arg_default = "file";
    spec.permission_target_kind = .path_existing;
    break :blk spec;
};

const test_rename_file = blk: {
    var spec = test_read_file;
    spec.name = "rename_file";
    spec.description = "Test file rename. When to use: exercise registered rename projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.descriptor = .{
        .name = "rename_file",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "old_path", .json_type = .string },
                .{ .name = "new_path", .json_type = .string },
            },
            .required = &.{ "old_path", "new_path" },
        },
    };
    spec.executor_kind = .rename_file;
    spec.activity_kind = .write;
    spec.requires_approval = true;
    spec.action_label = "Renaming";
    spec.completed_action_label = "Renamed";
    spec.label_arg_kind = .old_path;
    spec.label_arg_default = "file";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_copy_file = blk: {
    var spec = test_read_file;
    spec.name = "copy_file";
    spec.description = "Test file copying. When to use: exercise registered copy projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.descriptor = .{
        .name = "copy_file",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "source", .json_type = .string },
                .{ .name = "destination", .json_type = .string },
            },
            .required = &.{ "source", "destination" },
        },
    };
    spec.executor_kind = .copy_file;
    spec.activity_kind = .write;
    spec.requires_approval = true;
    spec.action_label = "Copying";
    spec.completed_action_label = "Copied";
    spec.label_arg_kind = .source;
    spec.label_arg_default = "file";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_create_folder = blk: {
    var spec = test_read_file;
    spec.name = "create_folder";
    spec.description = "Test folder creation. When to use: exercise registered creation projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.descriptor = .{
        .name = "create_folder",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    };
    spec.executor_kind = .create_folder;
    spec.activity_kind = .write;
    spec.requires_approval = true;
    spec.action_label = "Creating";
    spec.completed_action_label = "Created";
    spec.label_arg_kind = .path;
    spec.label_arg_default = "folder";
    spec.permission_target_kind = .path_create_parent;
    break :blk spec;
};

const test_list_files = blk: {
    var spec = test_read_file;
    spec.name = "list_files";
    spec.description = "Test directory listing. When to use: exercise registered list projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.descriptor = .{
        .name = "list_files",
        .description = spec.description,
        .input_schema = .{ .properties = &.{
            .{ .name = "path", .json_type = .string },
        } },
    };
    spec.executor_kind = .list_files;
    spec.activity_kind = .list;
    spec.requires_approval = false;
    spec.action_label = "Listing";
    spec.completed_action_label = "Listed";
    spec.label_arg_kind = .path;
    spec.label_arg_default = ".";
    spec.permission_target_kind = .path_optional_existing;
    break :blk spec;
};

const test_glob_files = blk: {
    var spec = test_list_files;
    spec.name = "glob_files";
    spec.description = "Test filename matching. When to use: exercise registered search projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.descriptor = .{
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
    spec.descriptor = .{
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

const test_web_fetch = blk: {
    var spec = test_read_file;
    spec.name = "web_fetch";
    spec.descriptor = .{
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
    spec.descriptor = .{
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
    spec.provider_tool = .web_search;
    break :blk spec;
};

const test_terminal = blk: {
    var spec = test_read_file;
    spec.name = "terminal";
    spec.description = "Test terminal. When to use: exercise registered terminal projection. When NOT to use: assert product-specific terminal behavior.";
    spec.descriptor = .{
        .name = "terminal",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"exec"} } },
                .{ .name = "command", .json_type = .string },
            },
            .required = &.{ "action", "command" },
            .additional_properties = false,
        },
    };
    spec.executor_kind = .terminal;
    spec.activity_kind = .command;
    spec.requires_approval = true;
    spec.action_label = "Using terminal";
    spec.completed_action_label = "Used terminal";
    spec.label_arg_kind = .action;
    spec.label_arg_default = "session";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_skill = blk: {
    var spec = test_read_file;
    spec.name = "skill";
    spec.description = "Test skill. When to use: exercise registered skill projection. When NOT to use: assert product-specific skill loading.";
    spec.descriptor = .{
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

const test_install_skill = blk: {
    var spec = test_skill;
    spec.name = "install_skill";
    spec.description = "Test install skill. When to use: exercise registered write-tool projection. When NOT to use: assert product-specific installation behavior.";
    spec.descriptor = .{
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
    spec.descriptor = .{
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
    spec.descriptor = .{
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
    spec.descriptor = .{
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
    spec.descriptor = .{
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
    spec.descriptor = .{
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

const test_mcp_search_tools = blk: {
    var spec = test_mcp_select_tool;
    spec.name = "mcp_search_tools";
    spec.description = "Test MCP tool search. When to use: exercise deferred dynamic-tool discovery. When NOT to use: assert product-specific search guidance.";
    spec.descriptor = .{
        .name = "mcp_search_tools",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "query", .json_type = .string },
                .{ .name = "limit", .json_type = .integer },
            },
            .required = &.{"query"},
        },
    };
    spec.executor_kind = .mcp_search_tools;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Searching MCP tools";
    spec.completed_action_label = "Searched MCP tools";
    spec.label_arg_kind = .query;
    spec.label_arg_default = "dynamic tools";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_mirror_provider_tool = blk: {
    var spec = test_web_search_base;
    spec.name = "mirror_search";
    spec.provider_tool = .web_search;
    break :blk spec;
};

/// Owns the ordered descriptor slice and any separate guidance required by
/// included custom advertisements. Descriptor contents remain borrowed from
/// the immutable tool registry.
pub const EffectiveToolProjection = struct {
    tools: []tool_descriptor.Descriptor,
    provider_tools: []agent_stream_provider.ProviderToolAdvertisement,
    custom_guidance: []u8,

    pub fn deinit(self: *EffectiveToolProjection, alloc: Allocator) void {
        alloc.free(self.tools);
        alloc.free(self.provider_tools);
        alloc.free(self.custom_guidance);
        self.* = undefined;
    }

    pub fn contains(self: EffectiveToolProjection, name: []const u8) bool {
        return containsDescriptor(self.tools, name);
    }
};

pub fn containsDescriptor(
    descriptors: []const tool_descriptor.Descriptor,
    name: []const u8,
) bool {
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.name, name)) return true;
    }
    return false;
}

const test_all_tools = [_]tool_dispatch.Tool{
    test_list_files,
    test_glob_files,
    test_grep_files,
    test_read_file,
    test_write_file,
    test_edit_file,
    test_delete_file,
    test_rename_file,
    test_copy_file,
    test_create_folder,
    test_file_info,
    test_memory,
    test_semantic_search,
    test_open_file,
    test_web_fetch,
    test_web_search,
    test_terminal,
    test_skill,
    test_install_skill,
    test_subagent,
    test_mcp_search_tools,
    test_mcp_select_tool,
    test_ask_user_question,
    test_vision,
    test_read_tool_result,
};

const test_order = [_][]const u8{
    "read_file",
    "glob_files",
    "grep_files",
    "list_files",
    "file_info",
    "semantic_search",
    "edit_file",
    "write_file",
    "delete_file",
    "rename_file",
    "copy_file",
    "create_folder",
    "terminal",
    "subagent",
    "skill",
    "install_skill",
    "mcp_search_tools",
    "mcp_select_tool",
    "memory",
    "ask_user_question",
    "open_file",
    "web_fetch",
    "web_search",
};

const test_read_only_names = [_][]const u8{
    "read_file",
    "glob_files",
    "grep_files",
    "list_files",
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

pub fn buildModelToolProjectionForSet(alloc: Allocator, tool_set: tool_set_contract.ToolSet, options: Options) !EffectiveToolProjection {
    return buildToolProjection(alloc, tool_set, .full, options);
}

pub fn buildReadOnlyModelToolProjectionForSet(alloc: Allocator, tool_set: tool_set_contract.ToolSet, options: Options) !EffectiveToolProjection {
    return buildToolProjection(alloc, tool_set, .read_only, options);
}

pub fn buildModelTools(
    alloc: Allocator,
    base: []const tool_descriptor.Descriptor,
    selected_dynamic: []const tool_descriptor.Descriptor,
    vision_mode: agent_stream_provider.VisionMode,
    vision: ?tool_descriptor.Descriptor,
) ![]tool_descriptor.Descriptor {
    if (vision_mode == .required) {
        const descriptor = vision orelse return error.VisionToolNotRegistered;
        try descriptor.validate();
        const tools = try alloc.alloc(tool_descriptor.Descriptor, 1);
        tools[0] = descriptor;
        return tools;
    }

    var tools: std.ArrayList(tool_descriptor.Descriptor) = .empty;
    errdefer tools.deinit(alloc);
    for (base) |descriptor| try appendUniqueDescriptor(alloc, &tools, descriptor);
    for (selected_dynamic) |descriptor| try appendUniqueDescriptor(alloc, &tools, descriptor);
    if (vision_mode == .optional) {
        try appendUniqueDescriptor(
            alloc,
            &tools,
            vision orelse return error.VisionToolNotRegistered,
        );
    }
    return tools.toOwnedSlice(alloc);
}

fn appendUniqueDescriptor(
    alloc: Allocator,
    tools: *std.ArrayList(tool_descriptor.Descriptor),
    descriptor: tool_descriptor.Descriptor,
) !void {
    try descriptor.validate();
    for (tools.items) |existing| {
        if (std.mem.eql(u8, existing.name, descriptor.name)) return;
    }
    try tools.append(alloc, descriptor);
}

fn buildToolProjection(alloc: Allocator, tool_set: tool_set_contract.ToolSet, kind: BuildKind, options: Options) !EffectiveToolProjection {
    var tools: std.ArrayList(tool_descriptor.Descriptor) = .empty;
    errdefer tools.deinit(alloc);
    var guidance_out: std.Io.Writer.Allocating = .init(alloc);
    errdefer guidance_out.deinit();
    var provider_tools: std.ArrayList(agent_stream_provider.ProviderToolAdvertisement) = .empty;
    errdefer provider_tools.deinit(alloc);

    var first_custom_guidance = true;

    for (tool_set.order) |tool_name| {
        const tool = tool_set.registry.lookup(tool_name) orelse continue;
        try appendBuiltinTool(alloc, &tools, &guidance_out.writer, &provider_tools, &first_custom_guidance, tool.*, kind, tool_set, options);
    }

    if (kind == .full) {
        for (tool_set.registry.tools) |tool| {
            if (isCanonicalToolName(tool_set, tool.name)) continue;
            try appendBuiltinTool(alloc, &tools, &guidance_out.writer, &provider_tools, &first_custom_guidance, tool, kind, tool_set, options);
        }
    }

    const owned_tools = try tools.toOwnedSlice(alloc);
    errdefer alloc.free(owned_tools);
    const custom_guidance = try guidance_out.toOwnedSlice();
    errdefer alloc.free(custom_guidance);
    const owned_provider_tools = try provider_tools.toOwnedSlice(alloc);
    return .{
        .tools = owned_tools,
        .provider_tools = owned_provider_tools,
        .custom_guidance = custom_guidance,
    };
}

fn appendBuiltinTool(
    alloc: Allocator,
    tools: *std.ArrayList(tool_descriptor.Descriptor),
    guidance_writer: *std.Io.Writer,
    provider_tools: *std.ArrayList(agent_stream_provider.ProviderToolAdvertisement),
    first_custom_guidance: *bool,
    tool: tool_dispatch.Tool,
    kind: BuildKind,
    tool_set: tool_set_contract.ToolSet,
    options: Options,
) !void {
    if (!includeBuiltinForKind(tool.name, kind, tool_set)) return;
    if (std.mem.eql(u8, tool.name, "subagent") and !options.subagent_available) return;
    if (std.mem.eql(u8, tool.name, "vision")) return;
    if (tool.provider_tool) |provider_tool| {
        if (providerToolIsSupported(provider_tool, options.provider_tools) and
            (options.permission_mode == .yolo or providerExecutionIsAllowed(tool.name, options.permission_rules)))
        {
            if (!providerAdvertisementIsPresent(provider_tools.items, provider_tool)) {
                try provider_tools.append(alloc, .{
                    .tool = provider_tool,
                    .local_schema_position = tools.items.len,
                });
            }
            if (first_custom_guidance.*) {
                first_custom_guidance.* = false;
            } else {
                try guidance_writer.writeAll("\n\n");
            }
            try guidance_writer.writeAll(tool.description);
        }
        if (tool.executor_kind != .web_search or !options.fx_web_search_installed) return;
    }
    if (options.permission_mode != .yolo and
        permissions.rulesDenyAllTargetsForTool(options.permission_rules, tool.name)) return;
    try tool.descriptor.validate();
    try tools.append(alloc, tool.descriptor);
}

fn providerToolIsSupported(
    needle: agent_stream_provider.ProviderTool,
    tools: []const agent_stream_provider.ProviderTool,
) bool {
    for (tools) |tool| if (tool == needle) return true;
    return false;
}

fn providerAdvertisementIsPresent(
    tools: []const agent_stream_provider.ProviderToolAdvertisement,
    needle: agent_stream_provider.ProviderTool,
) bool {
    for (tools) |tool| if (tool.tool == needle) return true;
    return false;
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

fn collectDescriptorNames(
    alloc: Allocator,
    descriptors: []const tool_descriptor.Descriptor,
) !std.ArrayList([]const u8) {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer freeNames(alloc, &names);
    for (descriptors) |descriptor| {
        try names.append(alloc, try alloc.dupe(u8, descriptor.name));
    }
    return names;
}

fn freeNames(alloc: Allocator, names: *std.ArrayList([]const u8)) void {
    for (names.items) |name| alloc.free(name);
    names.deinit(alloc);
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

fn countName(names: []const []const u8, expected: []const u8) usize {
    var count: usize = 0;
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) count += 1;
    }
    return count;
}

fn indexOfName(names: []const []const u8, expected: []const u8) !usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, expected)) return index;
    }
    return error.TestExpectedEqual;
}

fn appendTestMcpTool(runtime: *mcp_runtime.McpRuntime, server_index: usize, name: []const u8) !void {
    const alloc = runtime.alloc;
    const description = try alloc.dupe(u8, "test MCP tool");
    errdefer alloc.free(description);
    const input_schema = try alloc.dupe(u8, "{\"type\":\"object\"}");
    errdefer alloc.free(input_schema);
    const tags = try alloc.alloc([]u8, 1);
    errdefer alloc.free(tags);
    tags[0] = try alloc.dupe(u8, "test");
    errdefer alloc.free(tags[0]);
    const search_text = try std.ascii.allocLowerString(alloc, name);
    errdefer alloc.free(search_text);
    try runtime.servers.items[server_index].tool_catalog.tools.append(alloc, .{
        .server_name = runtime.servers.items[server_index].config.name,
        .original_name = try alloc.dupe(u8, name),
        .prefixed_name = try alloc.dupe(u8, name),
        .description = description,
        .input_schema_json = input_schema,
        .tags = tags,
        .search_text = search_text,
    });
}

fn appendTestMcpServer(runtime: *mcp_runtime.McpRuntime, name: []const u8) !usize {
    const config = mcp_runtime.McpServerConfig{
        .name = try runtime.alloc.dupe(u8, name),
        .enabled = true,
    };
    try runtime.addServer(config);
    const index = runtime.servers.items.len - 1;
    runtime.servers.items[index].state = .ready;
    return index;
}

test "full routes project neutral provider search separately from local schemas" {
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("web_search"), .pattern = @constCast("*"), .action = .allow },
    };
    const options = Options{
        .permission_rules = .{ .rules = &rules },
        .provider_tools = &.{.web_search},
    };
    var default_projection = try buildTestModelToolProjection(std.testing.allocator, options);
    defer default_projection.deinit(std.testing.allocator);
    var registry_projection = try buildTestModelToolProjectionForRegistry(std.testing.allocator, test_all_tools[0..], options);
    defer registry_projection.deinit(std.testing.allocator);

    inline for (&.{ &default_projection, &registry_projection }) |projection| {
        var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
        defer freeNames(std.testing.allocator, &names);
        try expectNotContainsName(names.items, "perplexity_search");
        try expectNotContainsName(names.items, "web_search");
        try std.testing.expectEqual(@as(usize, 1), projection.provider_tools.len);
        try std.testing.expectEqual(.web_search, projection.provider_tools[0].tool);
        try std.testing.expectEqualStrings(test_web_search.description, projection.custom_guidance);
    }
}

test "explicit fx search install keeps local and provider authorities separate" {
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{
        .provider_tools = &.{.web_search},
        .fx_web_search_installed = true,
    });
    defer projection.deinit(std.testing.allocator);

    var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
    defer freeNames(std.testing.allocator, &names);
    try expectContainsName(names.items, "web_search");
    try expectNotContainsName(names.items, "perplexity_search");
    try std.testing.expectEqual(@as(usize, 1), projection.provider_tools.len);
    try std.testing.expectEqual(.web_search, projection.provider_tools[0].tool);
    try std.testing.expectEqualStrings(
        "web_search",
        names.items[projection.provider_tools[0].local_schema_position],
    );
    try std.testing.expectEqualStrings(test_web_search.description, projection.custom_guidance);
}

test "unsupported provider search advertises neither authority" {
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{});
    defer projection.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), projection.provider_tools.len);
    var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
    defer freeNames(std.testing.allocator, &names);
    try expectNotContainsName(names.items, "web_search");
    try std.testing.expectEqualStrings("", projection.custom_guidance);
}

test "provider search advertisement respects no-rule allow ask and deny" {
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
        var rules = [_]types.PermissionRule{
            .{ .permission = @constCast("web_search"), .pattern = @constCast("*"), .action = case.action orelse .deny },
        };
        const options: Options = if (case.action) |_| .{
            .permission_rules = .{ .rules = &rules },
            .provider_tools = &.{.web_search},
        } else .{ .provider_tools = &.{.web_search} };

        var full_projection = try buildTestModelToolProjection(std.testing.allocator, options);
        defer full_projection.deinit(std.testing.allocator);

        inline for (&.{&full_projection}) |projection| {
            var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
            defer freeNames(std.testing.allocator, &names);
            try std.testing.expectEqual(@as(usize, if (case.advertised) 1 else 0), projection.provider_tools.len);
            if (case.advertised) {
                try std.testing.expectEqualStrings(test_web_search.description, projection.custom_guidance);
            } else {
                try std.testing.expectEqualStrings("", projection.custom_guidance);
            }
            try expectNotContainsName(names.items, "web_search");
        }
    }
}

test "provider execution gate follows the registry declaration, not the tool name" {
    const cases = [_]struct {
        action: types.PermissionAction,
        advertised: bool,
    }{
        .{ .action = .allow, .advertised = true },
        .{ .action = .ask, .advertised = false },
        .{ .action = .deny, .advertised = false },
    };

    const tools = [_]tool_dispatch.Tool{test_mirror_provider_tool};
    for (cases) |case| {
        var rules = [_]types.PermissionRule{
            .{ .permission = @constCast("mirror_search"), .pattern = @constCast("*"), .action = case.action },
        };
        var projection = try buildTestModelToolProjectionForRegistry(
            std.testing.allocator,
            tools[0..],
            .{
                .permission_rules = .{ .rules = &rules },
                .provider_tools = &.{.web_search},
            },
        );
        defer projection.deinit(std.testing.allocator);

        try std.testing.expectEqual(
            case.advertised,
            projection.provider_tools.len == 1,
        );
        if (!case.advertised) try std.testing.expectEqualStrings("", projection.custom_guidance);
    }
}

test "ask keeps advertising a tool the provider does not execute" {
    const tools = [_]tool_dispatch.Tool{test_web_search_base};
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("web_search"), .pattern = @constCast("*"), .action = .ask },
    };
    var projection = try buildTestModelToolProjectionForRegistry(
        std.testing.allocator,
        tools[0..],
        .{ .permission_rules = .{ .rules = &rules } },
    );
    defer projection.deinit(std.testing.allocator);

    var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
    defer freeNames(std.testing.allocator, &names);
    try expectContainsName(names.items, "web_search");
}

test "shared tool permission mapping resolves provider tool names to themselves" {
    try std.testing.expectEqualStrings("web_search", permissions.permissionNameForTool("web_search"));
    try std.testing.expectEqualStrings("mirror_search", permissions.permissionNameForTool("mirror_search"));
}

test "yolo advertisement ignores permission filtering" {
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("*"), .pattern = @constCast("*"), .action = .deny },
    };
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{
        .permission_mode = .yolo,
        .permission_rules = .{ .rules = &rules },
        .provider_tools = &.{.web_search},
    });
    defer projection.deinit(std.testing.allocator);

    var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
    defer freeNames(std.testing.allocator, &names);
    try expectContainsName(names.items, "terminal");
    try expectContainsName(names.items, "write_file");
    try std.testing.expectEqual(@as(usize, 1), projection.provider_tools.len);
    try std.testing.expectEqual(.web_search, projection.provider_tools[0].tool);
}

test "edit category-wide deny strips aliased write tools" {
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("*"), .action = .deny },
    };
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{ .permission_rules = .{ .rules = &rules } });
    defer projection.deinit(std.testing.allocator);
    var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
    defer freeNames(std.testing.allocator, &names);

    try expectNotContainsName(names.items, "edit_file");
    try expectNotContainsName(names.items, "write_file");
}

test "later allow or ask after category deny keeps tools advertised" {
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("*"), .action = .deny },
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/*"), .action = .ask },
        .{ .permission = @constCast("bash"), .pattern = @constCast("*"), .action = .deny },
        .{ .permission = @constCast("bash"), .pattern = @constCast("git *"), .action = .allow },
    };
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{ .permission_rules = .{ .rules = &rules } });
    defer projection.deinit(std.testing.allocator);
    var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
    defer freeNames(std.testing.allocator, &names);

    try expectContainsName(names.items, "edit_file");
    try expectContainsName(names.items, "write_file");
    try expectContainsName(names.items, "terminal");
}

test "later category deny hides earlier target-specific overrides" {
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/*"), .action = .allow },
        .{ .permission = @constCast("edit"), .pattern = @constCast("*"), .action = .deny },
    };
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{ .permission_rules = .{ .rules = &rules } });
    defer projection.deinit(std.testing.allocator);
    var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
    defer freeNames(std.testing.allocator, &names);

    try expectNotContainsName(names.items, "edit_file");
    try expectNotContainsName(names.items, "write_file");
}

test "target-specific later deny overrides target-specific allow" {
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("*"), .action = .deny },
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/*"), .action = .allow },
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/*"), .action = .deny },
    };
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{ .permission_rules = .{ .rules = &rules } });
    defer projection.deinit(std.testing.allocator);
    var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
    defer freeNames(std.testing.allocator, &names);

    try expectNotContainsName(names.items, "edit_file");
    try expectNotContainsName(names.items, "write_file");
}

test "target-specific edit and bash denies keep tools advertised" {
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("/etc/**"), .action = .deny },
        .{ .permission = @constCast("bash"), .pattern = @constCast("rm -rf*"), .action = .deny },
    };
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{ .permission_rules = .{ .rules = &rules } });
    defer projection.deinit(std.testing.allocator);
    var names = try collectDescriptorNames(std.testing.allocator, projection.tools);
    defer freeNames(std.testing.allocator, &names);

    try expectContainsName(names.items, "edit_file");
    try expectContainsName(names.items, "write_file");
    try expectContainsName(names.items, "terminal");
}

fn checkEffectiveToolProjectionAllocationFailures(alloc: Allocator) !void {
    var projection = buildTestModelToolProjection(alloc, .{ .provider_tools = &.{.web_search} }) catch |err|
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    defer projection.deinit(alloc);
    for (projection.tools) |descriptor| try descriptor.validate();
    try std.testing.expectEqualStrings(test_web_search.description, projection.custom_guidance);
}

test "effective tool projection cleans up every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkEffectiveToolProjectionAllocationFailures,
        .{},
    );
}

test "full advertisement uses active structured builtin schemas" {
    var projection = try buildTestModelToolProjection(std.testing.allocator, .{
        .subagent_available = true,
    });
    defer projection.deinit(std.testing.allocator);
    var builtin_count: usize = 0;
    for (projection.tools) |descriptor| {
        try descriptor.validate();
        const description = descriptor.description;
        try std.testing.expect(description.len <= tool_descriptor.description_max_bytes);
        try std.testing.expect(std.mem.find(u8, description, "When to use") != null);
        try std.testing.expect(std.mem.find(u8, description, "When NOT to use") != null);
        builtin_count += 1;
    }

    try std.testing.expectEqual(test_all_tools.len - 2, builtin_count);
}

test "MCP dynamic tools are deferred from the base gateway advertisement" {
    const alloc = std.testing.allocator;
    var runtime = mcp_runtime.McpRuntime.init(alloc);
    defer runtime.deinit();
    const fs_index = try appendTestMcpServer(&runtime, "fs");
    try appendTestMcpTool(&runtime, fs_index, "mcp_fs_read");
    try appendTestMcpTool(&runtime, fs_index, "mcp_fs_write");

    var projection = try buildTestModelToolProjection(alloc, .{ .mcp_runtime = &runtime });
    defer projection.deinit(alloc);
    var names = try collectDescriptorNames(alloc, projection.tools);
    defer freeNames(alloc, &names);

    try expectContainsName(names.items, "mcp_search_tools");
    try expectContainsName(names.items, "mcp_select_tool");
    try expectNotContainsName(names.items, "mcp_fs_read");
    try expectNotContainsName(names.items, "mcp_fs_write");
}

test "deferred MCP base advertisement is stable across schema churn" {
    const alloc = std.testing.allocator;
    var first_runtime = mcp_runtime.McpRuntime.init(alloc);
    defer first_runtime.deinit();
    const first_server = try appendTestMcpServer(&first_runtime, "first");
    try appendTestMcpTool(&first_runtime, first_server, "mcp_first_a");

    var second_runtime = mcp_runtime.McpRuntime.init(alloc);
    defer second_runtime.deinit();
    const second_server = try appendTestMcpServer(&second_runtime, "second");
    try appendTestMcpTool(&second_runtime, second_server, "mcp_second_a");
    try appendTestMcpTool(&second_runtime, second_server, "mcp_second_b");

    var first_projection = try buildTestModelToolProjection(alloc, .{ .mcp_runtime = &first_runtime });
    defer first_projection.deinit(alloc);
    var second_projection = try buildTestModelToolProjection(alloc, .{ .mcp_runtime = &second_runtime });
    defer second_projection.deinit(alloc);

    try std.testing.expectEqual(first_projection.tools.len, second_projection.tools.len);
    for (first_projection.tools, second_projection.tools) |first, second| {
        try std.testing.expectEqualStrings(first.name, second.name);
    }
    try std.testing.expectEqualStrings(first_projection.custom_guidance, second_projection.custom_guidance);
}

test "selected MCP schemas are appended after deferred discovery" {
    const alloc = std.testing.allocator;
    const tools = try buildModelTools(alloc, &.{}, &.{.{ .name = "mcp_fs_read", .description = "Read" }}, .unavailable, null);
    defer alloc.free(tools);
    try std.testing.expectEqualStrings("mcp_fs_read", tools[0].name);
}

test "selected MCP schemas cannot duplicate builtin tool names in gateway advertisement" {
    const alloc = std.testing.allocator;
    var projection = try buildTestModelToolProjection(alloc, .{});
    defer projection.deinit(alloc);
    const tools = try buildModelTools(alloc, projection.tools, &.{.{
        .name = "mcp_search_tools",
        .description = "Dynamic collision",
    }}, .unavailable, null);
    defer alloc.free(tools);
    var matches: usize = 0;
    for (tools) |descriptor| if (std.mem.eql(u8, descriptor.name, "mcp_search_tools")) {
        matches += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), matches);
}

test "model tools preserve base dynamic vision order and first-name ownership" {
    const base = [_]tool_descriptor.Descriptor{
        .{ .name = "read_file", .description = "base" },
        .{ .name = "shared", .description = "base wins" },
    };
    const selected = [_]tool_descriptor.Descriptor{
        .{ .name = "shared", .description = "dynamic loses" },
        .{ .name = "mcp_read", .description = "dynamic" },
    };
    const tools = try buildModelTools(
        std.testing.allocator,
        &base,
        &selected,
        .optional,
        .{ .name = "vision", .description = "vision" },
    );
    defer std.testing.allocator.free(tools);

    try std.testing.expectEqual(@as(usize, 4), tools.len);
    try std.testing.expectEqualStrings("read_file", tools[0].name);
    try std.testing.expectEqualStrings("shared", tools[1].name);
    try std.testing.expectEqualStrings("base wins", tools[1].description);
    try std.testing.expectEqualStrings("mcp_read", tools[2].name);
    try std.testing.expectEqualStrings("vision", tools[3].name);

    const required = try buildModelTools(
        std.testing.allocator,
        &base,
        &selected,
        .required,
        .{ .name = "vision", .description = "vision" },
    );
    defer std.testing.allocator.free(required);
    try std.testing.expectEqual(@as(usize, 1), required.len);
    try std.testing.expectEqualStrings("vision", required[0].name);
}

fn checkModelToolAllocationFailures(alloc: Allocator) !void {
    const tools = try buildModelTools(
        alloc,
        &.{.{ .name = "base", .description = "base" }},
        &.{.{ .name = "dynamic", .description = "dynamic" }},
        .optional,
        .{ .name = "vision", .description = "vision" },
    );
    defer alloc.free(tools);
    try std.testing.expectEqual(@as(usize, 3), tools.len);
}

test "model tool composition cleans up every partial allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkModelToolAllocationFailures,
        .{},
    );
}

test "subagent advertisement follows writable host capability and task never appears" {
    var unavailable = try buildTestModelToolProjection(std.testing.allocator, .{});
    defer unavailable.deinit(std.testing.allocator);
    var unavailable_names = try collectDescriptorNames(std.testing.allocator, unavailable.tools);
    defer freeNames(std.testing.allocator, &unavailable_names);
    try expectNotContainsName(unavailable_names.items, "subagent");
    try expectNotContainsName(unavailable_names.items, "task");

    var available = try buildTestModelToolProjection(std.testing.allocator, .{
        .subagent_available = true,
    });
    defer available.deinit(std.testing.allocator);
    var available_names = try collectDescriptorNames(std.testing.allocator, available.tools);
    defer freeNames(std.testing.allocator, &available_names);
    try expectContainsName(available_names.items, "subagent");
    try expectNotContainsName(available_names.items, "task");
}

test "terminal advertisement remains available for captured execution" {
    var unavailable = try buildTestModelToolProjection(std.testing.allocator, .{});
    defer unavailable.deinit(std.testing.allocator);
    var unavailable_names = try collectDescriptorNames(std.testing.allocator, unavailable.tools);
    defer freeNames(std.testing.allocator, &unavailable_names);
    try expectContainsName(unavailable_names.items, "terminal");

    var available = try buildTestModelToolProjection(std.testing.allocator, .{});
    defer available.deinit(std.testing.allocator);
    var available_names = try collectDescriptorNames(std.testing.allocator, available.tools);
    defer freeNames(std.testing.allocator, &available_names);
    try expectContainsName(available_names.items, "terminal");
}

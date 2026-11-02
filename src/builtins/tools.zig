const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const builtin_gateway = @import("gateway.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_projection = @import("../core/tooling/tool_projection.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const tool_mcp_dispatch = @import("../core/tooling/tool_mcp_dispatch.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");
const tool_specs = @import("../core/tooling/tool_specs.zig");
const types = @import("../core/shared/types.zig");
const compactor = @import("../core/compactor/compactor.zig");
const capability_retrieval = @import("../core/tooling/capability_retrieval.zig");
const permission_gate = @import("../core/permissions/permission_gate.zig");
const ask_user_question_impl = @import("../tools/agent/ask_user_question.zig");
const question_answer = @import("../core/agent/question_answer.zig");
const subagent_impl = @import("../tools/agent/subagent.zig");
const vision_impl = @import("../tools/agent/vision.zig");
const edit_file_impl = @import("../tools/filesystem/edit_file.zig");
const glob_files_impl = @import("../tools/filesystem/glob_files.zig");
const grep_files_impl = @import("../tools/filesystem/grep_files.zig");
const read_file_impl = @import("../tools/filesystem/read_file.zig");
const write_file_impl = @import("../tools/filesystem/write_file.zig");
const read_tool_result_impl = @import("../tools/session/read_tool_result.zig");
const shell_impl = @import("../tools/shell/shell.zig");
const install_skill_impl = @import("../tools/skills/install_skill.zig");
const skill_impl = @import("../tools/skills/skill.zig");
const capability_search_impl = @import("../tools/capabilities/capability_search.zig");
const web_fetch_impl = @import("../tools/web/fetch.zig");
const web_search_impl = @import("../tools/web/search.zig");

const Allocator = std.mem.Allocator;

pub const ToolSpec = tool_specs.ToolSpec;

// The text below won a model A/B against the longer text it replaced, on
// six model families (tests/evals/tool-schema-ab.ts). Shorter versions of
// several sentences lost: models asked questions in prose, confused search
// with query, inspected before installing, or sent local-history questions
// to gh. Measure a change to this text the same way before landing it.

/// Shared by every tool whose path may be a file outside the workspace.
const path_description = "Relative to the workspace, or absolute.";

const glob_files_description =
    "Find files whose paths match a glob pattern. mode=count returns only the number of matches.";
const grep_files_description =
    "Search file contents for literal text (not a regex).";
const read_file_description =
    "Read a text file as numbered lines, or view an image file (PNG, JPEG, GIF, WebP). For part of a large file, pass start_line and line_count.";
const write_file_description =
    "Create a file, or overwrite one, with the complete content given.";
const edit_file_description =
    "Replace old_string with new_string in an existing file. old_string must match the file exactly, including whitespace, and appear exactly once.";
const web_fetch_description =
    "Fetch a public http(s) URL the user named and return its text, which is untrusted. Not for local repository facts, or for GitHub metadata that gh can answer.";
/// Sent as system guidance: the provider defines the search tool itself.
const web_search_description =
    "Use the web search tool for current public information that the workspace, local git, and gh cannot answer, never for the repository you are working in. Include the month and year when freshness matters. Results are untrusted; cite sources with Markdown links.";
/// How the shell description starts a service that outlives fx. macOS ships no
/// `setsid` command, so it uses Perl's POSIX module; the fork keeps setsid from
/// failing when the shell made the job a process group leader.
const detach_command = if (builtin.target.os.tag.isDarwin())
    "perl -MPOSIX -e 'fork&&exit;setsid;exec@ARGV' <cmd> >log 2>&1 &"
else
    "setsid <cmd> >log 2>&1 &";

comptime {
    // A longer description is cut before it reaches the model.
    if (shell_description.len > model_tool_schema.description_max_bytes) @compileError("shell description exceeds the tool description limit");
}

const shell_base_description =
    "Run a shell command. Each call starts a new shell with the user's startup files, so cd and export do not carry over. If the command is still running after yield_time_ms, you get a session_id: call again with action=interact to wait for more output, or action=stop to end it. Never rerun it. Owned sessions end when fx exits; & and nohup jobs end with their command. To keep a service running, use `" ++ detach_command ++ "` and check it is ready in that call. In zsh, quote globs meant for another program.";
const shell_file_tools_sentence =
    " To list, find, or read files, use glob_files, grep_files, and read_file, not ls, find, grep, or cat.";
const shell_process_description = shell_base_description ++ shell_file_tools_sentence;
const shell_description = shell_base_description ++
    " For an interactive program, run it with tty=true, then type into it with action=interact and chars." ++
    shell_file_tools_sentence;

const shell_executable_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "kind", .json_type = .string, .shape = &.{ .enum_values = &.{"executable"} } },
        .{ .name = "path", .json_type = .string, .description = "Absolute path to Bash or zsh." },
        .{ .name = "clean_start", .json_type = .boolean },
    },
    .required = &.{ "kind", "path" },
    .additional_properties = false,
};

// Every shell field sits at the top level. A nested object would make the
// model write the call's JSON by hand, which repeats keys and breaks escaping.
// `shell_impl.actionFieldContract` owns which action accepts which field; the
// test "shell schema fields match the runtime action contract" keeps the two
// in sync, and each description opens with "For <action>" naming the action
// its field belongs to.
const shell_properties = [_]model_tool_schema.Property{
    .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{ "run", "interact", "stop" } } },
    .{ .name = "command", .json_type = .string, .description = "For run." },
    .{ .name = "cwd", .json_type = .string, .description = "For run. Defaults to the workspace." },
    .{ .name = "profile", .json_type = .string, .shape = &.{ .enum_values = &.{ "clean", "user" } }, .description = "For run: clean skips the user's startup files." },
    .{ .name = "shell", .json_type = .object, .shape = &.{ .object = &shell_executable_schema }, .description = "For run with tty=true: use this shell instead of the default." },
    .{ .name = "tty", .json_type = .boolean, .description = "For run: give the command a terminal, for interactive programs." },
    .{ .name = "yield_time_ms", .json_type = .integer, .description = "For run and interact: how long to wait for output before returning. run waits up to 30000 (the default), interact up to 300000 (default 5000)." },
    .{ .name = "timeout_ms", .json_type = .integer, .description = "For run: kill the command after this long. Only when asked for a deadline." },
    .{ .name = "reload", .json_type = .boolean, .description = "For run: reload the user's startup files first, such as after installing a tool." },
    .{ .name = "session_id", .json_type = .string, .description = "For interact and stop." },
    .{ .name = "chars", .json_type = .string, .description = "For interact: text to type into a tty session. End with a real newline to press Enter, not a backslash and n." },
    .{ .name = "force", .json_type = .boolean, .description = "For stop: kill immediately." },
};

// Sessions that cannot keep a terminal open drop the tty fields.
const shell_process_properties = [_]model_tool_schema.Property{
    shell_properties[0],
    shell_properties[1],
    shell_properties[2],
    shell_properties[3],
    shell_properties[6],
    shell_properties[7],
    shell_properties[9],
    shell_properties[11],
};

const skill_description =
    "Load an installed skill's instructions, or one of its files. Paths a skill mentions are relative to the skill, not the workspace.";
const capability_search_description =
    "Search installed skills and configured MCP tools for a capability. Matching MCP tools become callable on your next step.";
const install_skill_description =
    "Install a skill into fx's skill storage when the user asks. Pass the source as given; fx checks it.";
const mcp_select_tool_description =
    "Make a configured MCP tool callable on your next step. Pass its exact name, such as mcp_server_tool.";
const ask_user_question_description = std.fmt.comptimePrint(
    "Ask the user 1-{d} multiple-choice questions when a decision blocks you, such as a preference the workspace cannot answer.",
    .{question_answer.max_questions},
);
const ask_user_question_option_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "label", .json_type = .string, .description = "1-5 words." },
        .{ .name = "description", .json_type = .string },
    },
    .required = &.{"label"},
};
const ask_user_question_question_schema = model_tool_schema.ObjectSchema{
    .properties = &.{
        .{ .name = "question", .json_type = .string },
        .{ .name = "options", .json_type = .array, .bounds = &.{ .min_items = 2, .max_items = 6 }, .shape = &.{ .array_objects = &ask_user_question_option_schema } },
    },
    .required = &.{ "question", "options" },
};

const subagent_description =
    "Delegate work to a child agent and get its final result. action=run starts a one-off child with task. action=message sends message to the persistent child named agent, creating it on first use. Results arrive on their own; do not poll.";

// Flat so a model never writes the call's JSON by hand inside a wrapper; the
// decoder in src/tools/agent/subagent.zig rejects a field the action does not
// take, and the test below keeps these properties in step with it. The
// decoder also owns every length limit, so the schema does not repeat them.
const subagent_properties = [_]model_tool_schema.Property{
    .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{ "run", "message" } } },
    .{ .name = "task", .json_type = .string, .description = "For run: the complete task." },
    .{ .name = "agent", .json_type = .string, .description = "For message: a lowercase name." },
    .{ .name = "message", .json_type = .string, .description = "For message." },
    .{ .name = "instructions", .json_type = .string, .description = "For message: system instructions for this child." },
    .{ .name = "model", .json_type = .string, .description = "Model ID for a new child. Defaults to yours." },
    .{ .name = "effort", .json_type = .string, .description = "Reasoning effort for a new child." },
};
const vision_description =
    "Look at images and return what is visible. Pass exactly one source, image_ids for images the user attached or paths for image files the user named, plus focus.";
const read_tool_result_description =
    "Read more of a truncated tool result by its handle: pass query to find lines containing some text, or start_byte and byte_count for a byte range. To find earlier turns and tool calls after context compaction, pass search instead of a handle.";

pub const glob_files = ToolSpec{
    .name = "glob_files",
    .description = glob_files_description,
    .model_schema = .{
        .name = "glob_files",
        .description = glob_files_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "pattern", .json_type = .string, .description = "Such as **/*.py or docs/*.md." },
                .{ .name = "path", .json_type = .string, .description = "Directory to search. Defaults to the workspace." },
                .{ .name = "mode", .json_type = .string, .shape = &.{ .enum_values = &.{ "matches", "count" } } },
            },
            .required = &.{"pattern"},
        },
    },
    .executor_kind = .glob_files,
    .activity_kind = .list,
    .requires_approval = false,
    .action_label = "Matching",
    .completed_action_label = "Matched",
    .label_arg_kind = .pattern,
    .label_arg_default = "pattern",
    .permission_target_kind = .path_optional_existing,
    .decode = glob_files_impl.decode,
    .validate = glob_files_impl.validate,
    .call = glob_files_impl.call,
    .reads_only_fn = glob_files_impl.readsOnly,
    .irreversible_fn = glob_files_impl.isIrreversible,
};

pub const grep_files = ToolSpec{
    .name = "grep_files",
    .description = grep_files_description,
    .model_schema = .{
        .name = "grep_files",
        .description = grep_files_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "pattern", .json_type = .string, .description = "Literal text to find." },
                .{ .name = "path", .json_type = .string, .description = "File or directory to search. Defaults to the workspace." },
                .{ .name = "include", .json_type = .string, .description = "Only search files matching this glob, such as *.py." },
                .{ .name = "case_insensitive", .json_type = .boolean },
                .{ .name = "mode", .json_type = .string, .shape = &.{ .enum_values = &.{ "matches", "files_with_matches", "count" } }, .description = "matches lists lines (default), files_with_matches lists paths, count gives totals." },
                .{ .name = "context_lines", .json_type = .integer, .description = "Lines to show before and after each match." },
                .{ .name = "head_limit", .json_type = .integer, .description = "Maximum results." },
                .{ .name = "offset", .json_type = .integer, .description = "Results to skip, for paging." },
            },
            .required = &.{"pattern"},
        },
    },
    .executor_kind = .grep_files,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Searching",
    .completed_action_label = "Searched",
    .label_arg_kind = .pattern,
    .label_arg_default = "pattern",
    .permission_target_kind = .path_optional_existing,
    .decode = grep_files_impl.decode,
    .validate = grep_files_impl.validate,
    .call = grep_files_impl.call,
    .reads_only_fn = grep_files_impl.readsOnly,
    .irreversible_fn = grep_files_impl.isIrreversible,
};

pub const read_file = ToolSpec{
    .name = "read_file",
    .description = read_file_description,
    .model_schema = .{
        .name = "read_file",
        .description = read_file_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string, .description = path_description },
                .{ .name = "start_line", .json_type = .integer, .description = "1-based first line." },
                .{ .name = "line_count", .json_type = .integer },
            },
            .required = &.{"path"},
        },
    },
    .executor_kind = .read_file,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Reading",
    .completed_action_label = "Read",
    .label_arg_kind = .path,
    .label_arg_default = "file",
    .permission_target_kind = .path_existing,
    .decode = read_file_impl.decode,
    .validate = read_file_impl.validate,
    .call = read_file_impl.call,
    .reads_only_fn = read_file_impl.readsOnly,
    .irreversible_fn = read_file_impl.isIrreversible,
};

pub const write_file = ToolSpec{
    .name = "write_file",
    .description = write_file_description,
    .model_schema = .{
        .name = "write_file",
        .description = write_file_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string, .description = path_description },
                .{ .name = "content", .json_type = .string },
            },
            .required = &.{ "path", "content" },
        },
    },
    .executor_kind = .write_file,
    .activity_kind = .write,
    .requires_approval = true,
    .action_label = "Writing",
    .completed_action_label = "Wrote",
    .label_arg_kind = .path,
    .label_arg_default = "file",
    .permission_target_kind = .path_create_parent,
    .decode = write_file_impl.decode,
    .validate = write_file_impl.validate,
    .call = write_file_impl.call,
    .take_file_mutation_input_fn = write_file_impl.takeFileMutationInput,
    .reads_only_fn = write_file_impl.readsOnly,
    .irreversible_fn = write_file_impl.isIrreversible,
};

pub const edit_file = ToolSpec{
    .name = "edit_file",
    .description = edit_file_description,
    .model_schema = .{
        .name = "edit_file",
        .description = edit_file_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string, .description = path_description },
                .{ .name = "old_string", .json_type = .string },
                .{ .name = "new_string", .json_type = .string },
            },
            .required = &.{ "path", "old_string", "new_string" },
        },
    },
    .executor_kind = .edit_file,
    .activity_kind = .edit,
    .requires_approval = true,
    .action_label = "Editing",
    .completed_action_label = "Edited",
    .label_arg_kind = .path,
    .label_arg_default = "file",
    .permission_target_kind = .path_existing_parent,
    .decode = edit_file_impl.decode,
    .validate = edit_file_impl.validate,
    .call = edit_file_impl.call,
    .take_file_mutation_input_fn = edit_file_impl.takeFileMutationInput,
    .reads_only_fn = edit_file_impl.readsOnly,
    .irreversible_fn = edit_file_impl.isIrreversible,
};

pub const web_fetch = ToolSpec{
    .name = "web_fetch",
    .description = web_fetch_description,
    .model_schema = .{
        .name = "web_fetch",
        .description = web_fetch_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "url", .json_type = .string },
            },
            .required = &.{"url"},
            .additional_properties = false,
        },
    },
    .executor_kind = .web_fetch,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Fetching",
    .completed_action_label = "Fetched",
    .label_arg_kind = .url,
    .label_arg_default = "url",
    .permission_target_kind = .none,
    .decode = web_fetch_impl.decode,
    .validate = web_fetch_impl.validate,
    .call = web_fetch_impl.call,
    .reads_only_fn = web_fetch_impl.readsOnly,
    .irreversible_fn = web_fetch_impl.isIrreversible,
};

fn writeWebSearchGatewayAdvertisement(
    alloc: Allocator,
    writer: *std.Io.Writer,
) tool_dispatch.ProviderAdvertisementError!void {
    const policy = builtin_gateway.default_web_search_policy;
    const provider_tools = try builtin_gateway.providerToolsJson(alloc, .{
        .backend = try builtin_gateway.selectedWebSearchBackend(),
        .max_results = policy.max_results,
        .max_output_tokens = policy.max_output_tokens,
        .max_output_chars = policy.max_output_chars,
    });
    defer alloc.free(provider_tools);
    if (provider_tools.len < 2 or provider_tools[0] != '[' or provider_tools[provider_tools.len - 1] != ']') {
        return error.InvalidGatewayAdvertisement;
    }
    try writer.writeAll(provider_tools[1 .. provider_tools.len - 1]);
}

pub const web_search = ToolSpec{
    .name = "web_search",
    .description = web_search_description,
    .model_schema = .{
        .name = "web_search",
        .description = web_search_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "query", .json_type = .string, .bounds = &.{ .min_length = 2 } },
                .{ .name = "allowed_domains", .json_type = .array, .shape = &.{ .array_values = .{ .json_type = .string } } },
                .{ .name = "blocked_domains", .json_type = .array, .shape = &.{ .array_values = .{ .json_type = .string } } },
            },
            .required = &.{"query"},
            .additional_properties = false,
        },
    },
    .write_provider_advertisement_fn = writeWebSearchGatewayAdvertisement,
    .provider_executed = true,
    .executor_kind = .web_search,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Searching",
    .completed_action_label = "Searched",
    .label_arg_kind = .query,
    .label_arg_default = "web",
    .permission_target_kind = .none,
    .decode = web_search_impl.decode,
    .validate = web_search_impl.validate,
    .call = web_search_impl.call,
    .reads_only_fn = web_search_impl.readsOnly,
    .irreversible_fn = web_search_impl.isIrreversible,
};

pub const shell = ToolSpec{
    .name = "shell",
    .description = shell_description,
    .model_schema = .{
        .name = "shell",
        .description = shell_description,
        .input_schema = .{
            .properties = &shell_properties,
            .required = &.{"action"},
            .additional_properties = false,
        },
    },
    .executor_kind = .terminal,
    .activity_kind = .command,
    .requires_approval = true,
    .action_label = "Running",
    .completed_action_label = "Ran",
    .label_arg_kind = .action,
    .label_arg_default = "shell request",
    .presentation_fn = shell_impl.presentation,
    .permission_target_kind = .none,
    .decode = shell_impl.decode,
    .validate = shell_impl.validate,
    .call = shell_impl.call,
    .runtime_provider = .run_command,
    .captured_command_action = "run",
    .captured_command_fn = shell_impl.isCapturedCommand,
    .infer_action_fn = shell_impl.inferAction,
    .process_local_fn = shell_impl.isProcessLocal,
    .reads_only_fn = shell_impl.readsOnly,
    .irreversible_fn = shell_impl.isIrreversible,
};

const shell_process_only = blk: {
    var spec = shell;
    spec.description = shell_process_description;
    spec.model_schema = .{
        .name = "shell",
        .description = shell_process_description,
        .input_schema = .{
            .properties = &shell_process_properties,
            .required = &.{"action"},
            .additional_properties = false,
        },
    };
    break :blk spec;
};

pub fn shellProcessOnlySpec() ToolSpec {
    return shell_process_only;
}

pub const capability_search = ToolSpec{
    .name = "capability_search",
    .internal = true,
    .description = capability_search_description,
    .model_schema = .{
        .name = "capability_search",
        .description = capability_search_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "query", .json_type = .string, .description = "What you need to do." },
                .{ .name = "server", .json_type = .string, .description = "Limit to one MCP server." },
            },
            .required = &.{"query"},
            .additional_properties = false,
        },
    },
    .executor_kind = .capability_search,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Searching capabilities",
    .completed_action_label = "Searched capabilities",
    .label_arg_kind = .query,
    .label_arg_default = "capabilities",
    .presentation_fn = capability_search_impl.presentation,
    .permission_target_kind = .none,
    .decode = capability_search_impl.decode,
    .validate = capability_search_impl.validate,
    .call = capability_search_impl.call,
    .reads_only_fn = capability_search_impl.readsOnly,
    .irreversible_fn = capability_search_impl.isIrreversible,
};

pub const skill = ToolSpec{
    .name = "skill",
    .description = skill_description,
    .model_schema = .{
        .name = "skill",
        .description = skill_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "location", .json_type = .string, .description = "The skill's location from the skill list." },
                .{ .name = "resource", .json_type = .string, .description = "A file inside the skill, such as template.md. Omit for SKILL.md." },
            },
            .required = &.{"location"},
            .additional_properties = false,
        },
    },
    .executor_kind = .skill,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Loading skill",
    .completed_action_label = "Loaded skill",
    .label_arg_kind = .name,
    .label_arg_default = "skill",
    .presentation_fn = skill_impl.presentation,
    .permission_target_kind = .none,
    .decode = skill_impl.decode,
    .prepare_skill_call_fn = skill_impl.prepare,
    .validate = skill_impl.validate,
    .call = skill_impl.call,
    .reads_only_fn = skill_impl.readsOnly,
    .irreversible_fn = skill_impl.isIrreversible,
};

pub const install_skill = ToolSpec{
    .name = "install_skill",
    .description = install_skill_description,
    .model_schema = .{
        .name = "install_skill",
        .description = install_skill_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "source", .json_type = .string, .description = "GitHub repo, local path, skills.sh URL, owner/repo@skill, or an `npx skills add` command." },
                .{ .name = "skill", .json_type = .string, .description = "Which skill to install from a source that has several." },
            },
            .required = &.{"source"},
        },
    },
    .executor_kind = .install_skill,
    .activity_kind = .write,
    .requires_approval = true,
    .action_label = "Installing skill",
    .completed_action_label = "Installed skill",
    .label_arg_kind = .source,
    .label_arg_default = "skill",
    .permission_target_kind = .none,
    .decode = install_skill_impl.decode,
    .validate = install_skill_impl.validate,
    .call = install_skill_impl.call,
    .reads_only_fn = install_skill_impl.readsOnly,
    .irreversible_fn = install_skill_impl.isIrreversible,
    .run_command_compatibility = .{
        .matches = install_skill_impl.matchesRunCommand,
        .execute = install_skill_impl.executeRunCommand,
    },
};

pub const subagent = ToolSpec{
    .name = "subagent",
    .description = subagent_description,
    .model_schema = .{
        .name = "subagent",
        .description = subagent_description,
        .input_schema = .{
            .properties = &subagent_properties,
            .required = &.{"action"},
            .additional_properties = false,
        },
    },
    .executor_kind = .subagent,
    .activity_kind = .subagent,
    .requires_approval = false,
    .action_label = "Managing",
    .completed_action_label = "Managed",
    .label_arg_kind = .none,
    .label_arg_default = "subagent",
    .permission_target_kind = .none,
    .decode = subagent_impl.decode,
    .validate = subagent_impl.validate,
    .call = subagent_impl.call,
    .runtime_provider = .subagent,
    .reads_only_fn = subagent_impl.readsOnly,
    .irreversible_fn = subagent_impl.isIrreversible,
};

pub const mcp_select_tool = ToolSpec{
    .name = "mcp_select_tool",
    .internal = true,
    .description = mcp_select_tool_description,
    .model_schema = .{
        .name = "mcp_select_tool",
        .description = mcp_select_tool_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "name", .json_type = .string },
            },
            .required = &.{"name"},
        },
    },
    .executor_kind = .mcp_select_tool,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Selecting MCP tool",
    .completed_action_label = "Selected MCP tool",
    .label_arg_kind = .name,
    .label_arg_default = "dynamic tool",
    .permission_target_kind = .none,
    .decode = tool_mcp_dispatch.decodeSelect,
    .validate = tool_mcp_dispatch.validate,
    .call = tool_mcp_dispatch.callSelect,
    .reads_only_fn = tool_mcp_dispatch.readsOnly,
    .irreversible_fn = tool_mcp_dispatch.isIrreversible,
};

pub const ask_user_question = ToolSpec{
    .name = "ask_user_question",
    .description = ask_user_question_description,
    .model_schema = .{
        .name = "ask_user_question",
        .description = ask_user_question_description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "questions", .json_type = .array, .bounds = &.{ .min_items = 1, .max_items = question_answer.max_questions }, .shape = &.{ .array_objects = &ask_user_question_question_schema } },
            },
            .required = &.{"questions"},
        },
    },
    .executor_kind = .ask_user_question,
    .activity_kind = .ask,
    .requires_approval = false,
    .action_label = "Asking",
    .completed_action_label = "Asked",
    .label_arg_kind = .none,
    .label_arg_default = "",
    .permission_target_kind = .none,
    .decode = ask_user_question_impl.decode,
    .validate = ask_user_question_impl.validate,
    .call = ask_user_question_impl.call,
    .cancel_if_requested_after_call = true,
    .reads_only_fn = ask_user_question_impl.readsOnly,
    .irreversible_fn = ask_user_question_impl.isIrreversible,
};

pub const vision = ToolSpec{
    .name = "vision",
    .description = vision_description,
    .model_schema = .{
        .name = "vision",
        .description = vision_description,
        .input_schema = .{
            .properties = &.{
                .{
                    .name = "image_ids",
                    .json_type = .array,
                    .bounds = &.{ .min_items = 1 },
                    .shape = &.{ .array_values = .{ .json_type = .integer } },
                },
                .{
                    .name = "paths",
                    .json_type = .array,
                    .description = "Relative to the workspace, or ~/...",
                    .bounds = &.{ .min_items = 1 },
                    .shape = &.{ .array_values = .{ .json_type = .string } },
                },
                .{ .name = "focus", .json_type = .string, .description = "What to look for." },
            },
            .required = &.{"focus"},
            .additional_properties = false,
            .min_properties = 2,
            .max_properties = 2,
        },
    },
    .executor_kind = .vision,
    .activity_kind = .read,
    .requires_approval = true,
    .approval_policy = .ask_only,
    .action_label = "Inspecting",
    .completed_action_label = "Inspected",
    .label_arg_kind = .none,
    .label_arg_default = "images",
    .permission_target_kind = .none,
    .decode = vision_impl.decode,
    .validate = vision_impl.validate,
    .call = vision_impl.call,
    .runtime_provider = .vision,
    .reads_only_fn = vision_impl.readsOnly,
    .irreversible_fn = vision_impl.isIrreversible,
};

const read_tool_result_properties = [_]model_tool_schema.Property{
    .{ .name = "handle", .json_type = .string, .description = "From a truncated result, or a saved ID such as T12." },
    .{ .name = "query", .json_type = .string, .description = "Text to find in the handle's output." },
    .{ .name = "start_byte", .json_type = .integer, .description = "1-based." },
    .{ .name = "byte_count", .json_type = .integer },
    .{
        .name = "search",
        .json_type = .array,
        .bounds = &.{ .max_items = compactor.max_search_phrases },
        .shape = &.{ .array_values = .{ .json_type = .string } },
        .description = "Without a handle: up to three phrases to find in turns and tool calls saved by compaction.",
    },
};

pub const read_tool_result = ToolSpec{
    .name = "read_tool_result",
    .internal = true,
    .description = read_tool_result_description,
    .model_schema = .{
        .name = "read_tool_result",
        .description = read_tool_result_description,
        .input_schema = .{
            .properties = &read_tool_result_properties,
            .additional_properties = false,
        },
    },
    .executor_kind = .read_tool_result,
    .activity_kind = .read,
    .requires_approval = false,
    .action_label = "Reading",
    .completed_action_label = "Read",
    .label_arg_default = "saved output",
    .presentation_fn = read_tool_result_impl.presentation,
    .permission_target_kind = .none,
    .decode = read_tool_result_impl.decode,
    .validate = read_tool_result_impl.validate,
    .call = read_tool_result_impl.call,
    .reads_only_fn = read_tool_result_impl.readsOnly,
    .irreversible_fn = read_tool_result_impl.isIrreversible,
};

pub const all = [_]tool_dispatch.Tool{
    glob_files,
    grep_files,
    read_file,
    write_file,
    edit_file,
    web_fetch,
    web_search,
    shell,
    capability_search,
    skill,
    install_skill,
    subagent,
    mcp_select_tool,
    ask_user_question,
    vision,
    read_tool_result,
};

/// fx's own tools. libfx's Node-API addon never runs them, because its agents
/// run only the host's tools, so it builds without their code: there, each
/// tool keeps only its name, which is enough for an MCP tool's alias to still
/// never take one.
pub const registry = tool_dispatch.Registry{ .tools = if (build_options.builtin_tools) all[0..] else names_only[0..] };

const names_only = blk: {
    var tools: [all.len]tool_dispatch.Tool = undefined;
    for (&tools, all) |*tool, real| tool.* = .{
        .name = real.name,
        .description = "",
        .model_schema = .{ .name = real.name, .description = "" },
        .model_visible = false,
        .decode = unavailableDecode,
        .call = unavailableCall,
        .reads_only_fn = unavailableReadsOnly,
        .irreversible_fn = unavailableIrreversible,
    };
    break :blk tools;
};

// A call that reaches a tool kept only by name gets the answer fx gives for
// any tool it doesn't have, which the model can read and recover from.
fn unavailableDecode(ctx: tool_dispatch.DispatchContext, _: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return .{ .failure = try unsupported(ctx) };
}

fn unavailableCall(ctx: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try unsupported(ctx) };
}

fn unsupported(ctx: tool_dispatch.DispatchContext) error{OutOfMemory}![]u8 {
    return ctx.allocator.print("Unsupported tool: {s}", .{ctx.tool_call_name});
}

fn unavailableReadsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn unavailableIrreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

test "without the tools' code, the registry keeps every tool's name and answers Unsupported tool" {
    try std.testing.expectEqual(all.len, names_only.len);
    for (names_only, all) |tool, real| {
        try std.testing.expectEqualStrings(real.name, tool.name);
        try std.testing.expect(!tool.model_visible);
    }
    const names = tool_dispatch.Registry{ .tools = names_only[0..] };
    for (advertisement_order) |name| try std.testing.expect(names.lookup(name) != null);
    try std.testing.expect(names.lookup("not_a_builtin_tool") == null);

    const entry = names.lookup("shell").?;
    const ctx = tool_dispatch.DispatchContext{ .allocator = std.testing.allocator, .tool_call_name = "shell" };
    const decoded = try entry.decode(ctx, "{\"action\":\"run\",\"command\":\"true\"}");
    defer std.testing.allocator.free(decoded.failure);
    try std.testing.expectEqualStrings("Unsupported tool: shell", decoded.failure);

    const NoInput = struct {
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };
    var unused: u8 = 0;
    const called = try entry.call(ctx, .{ .ptr = &unused, .deinit_fn = NoInput.deinit });
    defer called.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Unsupported tool: shell", called.failure);
}

pub const advertisement_order = [_][]const u8{
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

pub const read_only_tool_names = [_][]const u8{
    "read_file",
    "glob_files",
    "grep_files",
};

pub fn isReadOnlyToolName(name: []const u8) bool {
    for (read_only_tool_names) |tool_name| {
        if (std.mem.eql(u8, tool_name, name)) return true;
    }
    return false;
}

pub const advertisement_set = tool_set_contract.ToolSet{
    .registry = registry,
    .order = advertisement_order[0..],
    .read_only_tool_names = read_only_tool_names[0..],
};

pub fn lookup(name: []const u8) ?ToolSpec {
    const spec = registry.lookup(name) orelse return null;
    return spec.*;
}

pub fn toolLabelValue(spec: ToolSpec, args: std.json.ObjectMap) ?[]const u8 {
    return tool_specs.toolLabelValue(spec, args);
}

pub fn toolActivityKind(tool_name: []const u8) types.ToolActivityKind {
    return tool_dispatch.toolActivityKind(registry, tool_name);
}

pub fn toolRequiresApproval(tool_name: []const u8) bool {
    return if (lookup(tool_name)) |spec| spec.requires_approval else false;
}

pub fn toolHasPermissionContract(tool_name: []const u8) bool {
    return lookup(tool_name) != null;
}

test "built-in model-facing tool contract stays byte exact" {
    const alloc = std.testing.allocator;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    inline for (all) |tool| {
        try std.testing.expectEqualStrings(tool.name, tool.model_schema.name);
        try std.testing.expectEqualStrings(
            tool.description,
            tool.model_schema.description,
        );
        const schema_json = try tool_specs.toolGatewaySchemaJson(alloc, tool);
        defer alloc.free(schema_json);
        hasher.update(schema_json);
        hasher.update("\x00");
    }
    for (advertisement_order) |name| {
        hasher.update(name);
        hasher.update("\x00");
    }
    const process_only_json = try tool_specs.toolGatewaySchemaJson(
        alloc,
        shellProcessOnlySpec(),
    );
    defer alloc.free(process_only_json);
    hasher.update(process_only_json);

    const actual_hex = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    try std.testing.expectEqualStrings(
        if (builtin.target.os.tag.isDarwin())
            "e90a2960fe42b9c28ca6ce5abd7d18600ef79eac654c03ddaeaccec5d566bcde"
        else
            "3cfbe58765e1d905c392cc6861b8558d520811239faba54e22f0ad21bdeef53f",
        &actual_hex,
    );
}

test "registry classifies every built-in progress label" {
    inline for (all) |tool| {
        var started_buf: [96]u8 = undefined;
        const started = try std.mem.print(&started_buf, "{s} value", .{tool.action_label});
        try std.testing.expectEqual(
            tool_dispatch.ProgressLabelKind.started,
            tool_dispatch.classifyProgressLabel(registry, started),
        );

        var completed_buf: [96]u8 = undefined;
        const completed = try std.mem.print(&completed_buf, "{s} value", .{tool.completed_action_label});
        try std.testing.expectEqual(
            tool_dispatch.ProgressLabelKind.completed,
            tool_dispatch.classifyProgressLabel(registry, completed),
        );
    }
}

fn schemaProperty(schema: model_tool_schema.ObjectSchema, name: []const u8) ?model_tool_schema.Property {
    for (schema.properties) |property| {
        if (std.mem.eql(u8, property.name, name)) return property;
    }
    return null;
}

fn nameInSet(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

test "built-in tools register exact active local order" {
    const expected_names = [_][]const u8{
        "glob_files",
        "grep_files",
        "read_file",
        "write_file",
        "edit_file",
        "web_fetch",
        "web_search",
        "shell",
        "capability_search",
        "skill",
        "install_skill",
        "subagent",
        "mcp_select_tool",
        "ask_user_question",
        "vision",
        "read_tool_result",
    };

    try std.testing.expectEqual(expected_names.len, all.len);
    for (expected_names, 0..) |expected, index| {
        if (index >= all.len) return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(expected, all[index].name);
    }

    for ([_][]const u8{
        "list_files",
        "file_info",
        "delete_file",
        "rename_file",
        "copy_file",
        "create_folder",
        "semantic_search",
        "open_file",
    }) |removed| {
        try std.testing.expect(lookup(removed) == null);
    }
}

test "shell advertises only run interact and stop" {
    const alloc = std.testing.allocator;
    const schema_json = try tool_specs.toolGatewaySchemaJson(alloc, shell);
    defer alloc.free(schema_json);
    for ([_][]const u8{ "run", "interact", "stop" }) |action| {
        const needle = try alloc.print("\"{s}\"", .{action});
        defer alloc.free(needle);
        try std.testing.expect(std.mem.find(u8, schema_json, needle) != null);
    }
    for ([_][]const u8{
        "\"wait\"",
        "\"write\"",
        "\"list\"",
        "\"handoff\"",
        "\"next_turn\"",
        "\"input\"",
        "\"controls\"",
        "\"start\"",
        "\"monitor\"",
        "\"inspect\"",
        "\"resize\"",
        "\"signal\"",
        "\"close\"",
        "cursor_segment",
        "lease",
        "terminal.exec",
        "terminal.start",
        "\"request\"",
        "oneOf",
    }) |removed| {
        try std.testing.expect(std.mem.find(u8, schema_json, removed) == null);
    }
    for ([_][]const u8{
        "Only when asked for a deadline",
        "Never rerun it",
        "check it is ready in that call",
        "run waits up to 30000 (the default), interact up to 300000 (default 5000)",
        "run it with tty=true",
    }) |guidance| {
        try std.testing.expect(std.mem.find(u8, schema_json, guidance) != null);
    }
    try std.testing.expect(registry.lookup("terminal") == null);
    try std.testing.expect(registry.lookup("shell") != null);
}

test "shell schema fields match the runtime action contract" {
    const actions = std.enums.values(shell_impl.Action);
    try std.testing.expectEqualStrings("action", shell_properties[0].name);
    const advertised_actions = shell_properties[0].shape.?.enum_values;
    try std.testing.expectEqual(actions.len, advertised_actions.len);
    for (actions, advertised_actions) |action, advertised| {
        try std.testing.expectEqualStrings(@tagName(action), advertised);
    }

    const schema = model_tool_schema.ObjectSchema{ .properties = &shell_properties };
    for (actions) |action| {
        for (shell_impl.actionFieldContract(action).allowed) |name| {
            try std.testing.expect(schemaProperty(schema, name) != null);
        }
    }
    // Each field's description opens with "For <action>" naming an action
    // that accepts the field.
    for (shell_properties[1..]) |property| {
        try std.testing.expect(std.mem.startsWith(u8, property.description, "For "));
        const named = property.description["For ".len..];
        const owner = for (actions) |action| {
            if (std.mem.startsWith(u8, named, @tagName(action))) break action;
        } else return error.TestExpectedEqual;
        try std.testing.expect(nameInSet(shell_impl.actionFieldContract(owner).allowed, property.name));
    }

    const process_schema = model_tool_schema.ObjectSchema{ .properties = &shell_process_properties };
    for (shell_process_properties) |property| {
        try std.testing.expect(schemaProperty(schema, property.name) != null);
    }
    for ([_][]const u8{ "shell", "tty", "reload", "chars" }) |name| {
        try std.testing.expect(schemaProperty(process_schema, name) == null);
    }
}

test "process-only shell retains observation without tty input" {
    const alloc = std.testing.allocator;
    const schema_json = try tool_specs.toolGatewaySchemaJson(
        alloc,
        shellProcessOnlySpec(),
    );
    defer alloc.free(schema_json);
    for ([_][]const u8{ "\"run\"", "\"interact\"", "\"stop\"" }) |action| {
        try std.testing.expect(std.mem.find(u8, schema_json, action) != null);
    }
    for ([_][]const u8{ "\"chars\":", "\"tty\":", "\"shell\":{" }) |field| {
        try std.testing.expect(std.mem.find(u8, schema_json, field) == null);
    }
    // The description names no field this schema lacks.
    for ([_][]const u8{ "tty", "chars" }) |field| {
        try std.testing.expect(std.mem.find(u8, shellProcessOnlySpec().description, field) == null);
    }
}

test "built-in tool lookup and metadata use registered defaults" {
    const spec = lookup("shell") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(tool_specs.ExecutorKind.terminal, spec.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.command, toolActivityKind("shell"));
    try std.testing.expect(toolRequiresApproval("shell"));
    try std.testing.expect(toolHasPermissionContract("shell"));
    try std.testing.expect(lookup("capability_search") != null);
    try std.testing.expect(lookup("memory") == null);
    try std.testing.expect(lookup("skill_search") == null);
    try std.testing.expect(lookup("mcp_search_tools") == null);
    try std.testing.expect(lookup("run_command") == null);
    try std.testing.expect(lookup("missing_tool") == null);
}

test "built-in glob_files owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, glob_files);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("glob_files", glob_files.name);
    try std.testing.expect(std.mem.find(u8, glob_files.description, "mode=count returns only the number of matches") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"pattern\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"mode\":{\"type\":\"string\",\"enum\":[\"matches\",\"count\"]") != null);
    // The decoder reads an empty path as the workspace, so no bound is needed.
    try std.testing.expect(std.mem.find(u8, schema_json, "\"path\":{\"type\":\"string\",\"description\":\"Directory to search. Defaults to the workspace.\"}") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.glob_files, glob_files.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.list, glob_files.activity_kind);
    try std.testing.expect(!glob_files.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.pattern, glob_files.label_arg_kind);
    try std.testing.expectEqualStrings("pattern", glob_files.label_arg_default);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.path_optional_existing, glob_files.permission_target_kind);
    try std.testing.expectEqualStrings("Matching", glob_files.action_label);
    try std.testing.expectEqualStrings("Matched", glob_files.completed_action_label);
    try std.testing.expect(glob_files.decode == glob_files_impl.decode);
    try std.testing.expect(glob_files.validate.? == glob_files_impl.validate);
    try std.testing.expect(glob_files.call == glob_files_impl.call);
    try std.testing.expect(glob_files.reads_only_fn == glob_files_impl.readsOnly);
    try std.testing.expect(glob_files.irreversible_fn == glob_files_impl.isIrreversible);
}

test "built-in grep_files owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, grep_files);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("grep_files", grep_files.name);
    try std.testing.expect(std.mem.find(u8, grep_files.description, "literal text (not a regex)") != null);
    try std.testing.expect(std.mem.find(u8, grep_files.description, "shell") == null);
    try std.testing.expect(std.mem.find(u8, grep_files.description, "glob_files") == null);
    try std.testing.expect(std.mem.find(u8, grep_files.description, "read_file") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"pattern\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"include\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"case_insensitive\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"files_with_matches\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"head_limit\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"offset\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"context_lines\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "File or directory to search. Defaults to the workspace.") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.grep_files, grep_files.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.read, grep_files.activity_kind);
    try std.testing.expect(!grep_files.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.pattern, grep_files.label_arg_kind);
    try std.testing.expectEqualStrings("pattern", grep_files.label_arg_default);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.path_optional_existing, grep_files.permission_target_kind);
    try std.testing.expectEqualStrings("Searching", grep_files.action_label);
    try std.testing.expectEqualStrings("Searched", grep_files.completed_action_label);
    try std.testing.expect(grep_files.decode == grep_files_impl.decode);
    try std.testing.expect(grep_files.validate.? == grep_files_impl.validate);
    try std.testing.expect(grep_files.call == grep_files_impl.call);
    try std.testing.expect(grep_files.reads_only_fn == grep_files_impl.readsOnly);
    try std.testing.expect(grep_files.irreversible_fn == grep_files_impl.isIrreversible);
}

test "built-in read_file owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, read_file);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("read_file", read_file.name);
    try std.testing.expect(std.mem.find(u8, read_file.description, "numbered lines") != null);
    try std.testing.expect(std.mem.find(u8, read_file.description, "image file") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"path\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"start_line\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"line_count\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"path\":{\"type\":\"string\",\"description\":\"Relative to the workspace, or absolute.\"}") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.read_file, read_file.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.read, read_file.activity_kind);
    try std.testing.expect(!read_file.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.path, read_file.label_arg_kind);
    try std.testing.expectEqualStrings("file", read_file.label_arg_default);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.path_existing, read_file.permission_target_kind);
    try std.testing.expectEqualStrings("Reading", read_file.action_label);
    try std.testing.expectEqualStrings("Read", read_file.completed_action_label);
    try std.testing.expect(read_file.decode == read_file_impl.decode);
    try std.testing.expect(read_file.validate.? == read_file_impl.validate);
    try std.testing.expect(read_file.call == read_file_impl.call);
    try std.testing.expect(read_file.reads_only_fn == read_file_impl.readsOnly);
    try std.testing.expect(read_file.irreversible_fn == read_file_impl.isIrreversible);
}

test "built-in write_file owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, write_file);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("write_file", write_file.name);
    try std.testing.expect(std.mem.find(u8, write_file.description, "complete content") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"path\",\"content\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"path\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"content\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"path\":{\"type\":\"string\",\"description\":\"Relative to the workspace, or absolute.\"}") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.write_file, write_file.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.write, write_file.activity_kind);
    try std.testing.expect(write_file.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.path, write_file.label_arg_kind);
    try std.testing.expectEqualStrings("file", write_file.label_arg_default);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.path_create_parent, write_file.permission_target_kind);
    try std.testing.expectEqualStrings("Writing", write_file.action_label);
    try std.testing.expectEqualStrings("Wrote", write_file.completed_action_label);
    try std.testing.expect(write_file.decode == write_file_impl.decode);
    try std.testing.expect(write_file.validate.? == write_file_impl.validate);
    try std.testing.expect(write_file.call == write_file_impl.call);
    try std.testing.expect(write_file.take_file_mutation_input_fn.? == write_file_impl.takeFileMutationInput);
    try std.testing.expect(write_file.reads_only_fn == write_file_impl.readsOnly);
    try std.testing.expect(write_file.irreversible_fn == write_file_impl.isIrreversible);
}

test "built-in edit_file owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, edit_file);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("edit_file", edit_file.name);
    try std.testing.expect(std.mem.find(u8, edit_file.description, "appear exactly once") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"path\",\"old_string\",\"new_string\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "replace_all") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"path\":{\"type\":\"string\",\"description\":\"Relative to the workspace, or absolute.\"}") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.edit_file, edit_file.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.edit, edit_file.activity_kind);
    try std.testing.expect(edit_file.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.path, edit_file.label_arg_kind);
    try std.testing.expectEqualStrings("file", edit_file.label_arg_default);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.path_existing_parent, edit_file.permission_target_kind);
    try std.testing.expectEqualStrings("Editing", edit_file.action_label);
    try std.testing.expectEqualStrings("Edited", edit_file.completed_action_label);
    try std.testing.expect(edit_file.decode == edit_file_impl.decode);
    try std.testing.expect(edit_file.validate.? == edit_file_impl.validate);
    try std.testing.expect(edit_file.call == edit_file_impl.call);
    try std.testing.expect(edit_file.take_file_mutation_input_fn.? == edit_file_impl.takeFileMutationInput);
    try std.testing.expect(edit_file.reads_only_fn == edit_file_impl.readsOnly);
    try std.testing.expect(edit_file.irreversible_fn == edit_file_impl.isIrreversible);
}

test "built-in web_fetch owns product metadata and schema" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, web_fetch);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("web_fetch", web_fetch.name);
    try std.testing.expect(std.mem.find(u8, web_fetch.description, "public http(s) URL") != null);
    try std.testing.expect(std.mem.find(u8, web_fetch.description, "untrusted") != null);
    try std.testing.expect(std.mem.find(u8, web_fetch.description, "the user named") != null);
    try std.testing.expect(std.mem.find(u8, web_fetch.description, "Not for local repository facts") != null);
    try std.testing.expect(std.mem.find(u8, web_fetch.description, "GitHub metadata that gh can answer") != null);
    try std.testing.expect(std.mem.find(u8, web_fetch.description, "web_search") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"url\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"prompt\":{\"type\":\"string\"") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"url\"]") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.web_fetch, web_fetch.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.read, web_fetch.activity_kind);
    try std.testing.expect(!web_fetch.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.url, web_fetch.label_arg_kind);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.none, web_fetch.permission_target_kind);
    try std.testing.expectEqualStrings("Fetching", web_fetch.action_label);
    try std.testing.expectEqualStrings("Fetched", web_fetch.completed_action_label);
}

test "built-in web_search is registered in default production tools" {
    try std.testing.expect(lookup("web_search") != null);
}

test "built-in web_search owns its Gateway provider advertisement" {
    const registered = registry.lookup("web_search") orelse return error.TestExpectedEqual;
    const write_advertisement = registered.write_provider_advertisement_fn orelse return error.TestExpectedEqual;

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write_advertisement(std.testing.allocator, &out.writer);
    const json = try out.toOwnedSlice();
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        "{\"type\":\"provider\",\"id\":\"gateway.exa_search\",\"name\":\"exa_search\",\"args\":{\"numResults\":10,\"contents\":{\"highlights\":true}}}",
        json,
    );
}

fn expectWebSearchSchemaContains(needle: []const u8) !void {
    const json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, web_search);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.find(u8, json, needle) != null);
}

test "built-in web_search owns product metadata and schema" {
    try std.testing.expect(std.mem.find(u8, web_search.description, "current public information") != null);
    try std.testing.expect(std.mem.find(u8, web_search.description, "local git, and gh cannot answer") != null);
    try std.testing.expect(std.mem.find(u8, web_search.description, "never for the repository you are working in") != null);
    try std.testing.expect(std.mem.find(u8, web_search.description, "month and year") != null);
    try std.testing.expect(std.mem.find(u8, web_search.description, "untrusted") != null);
    try std.testing.expect(std.mem.find(u8, web_search.description, "cite sources with Markdown links") != null);
    try expectWebSearchSchemaContains("\"additionalProperties\":false");
    try expectWebSearchSchemaContains("\"query\":{\"type\":\"string\",\"minLength\":2");
    try expectWebSearchSchemaContains("\"allowed_domains\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}");
    try expectWebSearchSchemaContains("\"blocked_domains\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}");
    try expectWebSearchSchemaContains("\"required\":[\"query\"]");
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.web_search, web_search.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.read, web_search.activity_kind);
    try std.testing.expect(!web_search.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.query, web_search.label_arg_kind);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.none, web_search.permission_target_kind);
    try std.testing.expectEqualStrings("Searching", web_search.action_label);
    try std.testing.expectEqualStrings("Searched", web_search.completed_action_label);
}

test "built-in provider advertisements declare provider execution" {
    for (all) |tool| {
        if (tool.write_provider_advertisement_fn == null) continue;
        try std.testing.expect(tool.provider_executed);
    }
}

test "built-in skill owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, skill);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("skill", skill.name);
    try std.testing.expect(std.mem.find(u8, skill.description, "relative to the skill, not the workspace") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"location\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"resource\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"offset\":{\"type\":\"integer\"") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"location\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"name\",\"location\"]") == null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.skill, skill.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.read, skill.activity_kind);
    try std.testing.expect(!skill.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.name, skill.label_arg_kind);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.none, skill.permission_target_kind);
    try std.testing.expectEqualStrings("Loading skill", skill.action_label);
    try std.testing.expectEqualStrings("Loaded skill", skill.completed_action_label);
    try std.testing.expect(skill.presentation_fn == skill_impl.presentation);
    try std.testing.expect(skill.decode == skill_impl.decode);
    try std.testing.expect(skill.validate.? == skill_impl.validate);
    try std.testing.expect(skill.call == skill_impl.call);
    try std.testing.expect(skill.reads_only_fn == skill_impl.readsOnly);
    try std.testing.expect(skill.irreversible_fn == skill_impl.isIrreversible);
}

test "built-in subagent owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, subagent);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("subagent", subagent.name);
    try std.testing.expect(std.mem.find(u8, subagent.description, "one-off child") != null);
    try std.testing.expect(std.mem.find(u8, subagent.description, "persistent child named agent") != null);
    try std.testing.expect(std.mem.find(u8, subagent.description, "do not poll") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"request\"") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"oneOf\"") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"action\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"enum\":[\"run\",\"message\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"instructions\":") != null);
    // Creation-time routing overrides are advertised on both actions.
    try std.testing.expect(std.mem.find(u8, schema_json, "\"model\":") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"effort\":") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "Model ID for a new child. Defaults to yours.") != null);
    for ([_][]const u8{
        "\"command\":",
        "\"relationship\":",
        "\"configure\":",
        "\"notifications\":",
        "\"sections\":",
        "\"cursor\":",
        "\"generation\":",
        "\"reopen\"",
        "\"provider\"",
        "\"send\"",
        "\"wait\"",
        "\"stop\"",
        "\"child_id\"",
    }) |mechanism| {
        try std.testing.expect(std.mem.find(u8, schema_json, mechanism) == null);
    }
    try std.testing.expect(std.mem.find(u8, schema_json, "subagent_type") == null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.subagent, subagent.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.subagent, subagent.activity_kind);
    try std.testing.expect(!subagent.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.none, subagent.label_arg_kind);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.none, subagent.permission_target_kind);
    try std.testing.expectEqualStrings("Managing", subagent.action_label);
    try std.testing.expectEqualStrings("Managed", subagent.completed_action_label);
    try std.testing.expect(subagent.decode == subagent_impl.decode);
    try std.testing.expect(subagent.validate.? == subagent_impl.validate);
    try std.testing.expect(subagent.call == subagent_impl.call);
    try std.testing.expect(subagent.reads_only_fn == subagent_impl.readsOnly);
    try std.testing.expect(subagent.irreversible_fn == subagent_impl.isIrreversible);
}

test "subagent schema fields match the decoder's action fields" {
    const actions = [_]struct { name: []const u8, fields: []const []const u8 }{
        .{ .name = "run", .fields = &subagent_impl.run_fields },
        .{ .name = "message", .fields = &subagent_impl.message_fields },
    };
    // Every advertised property belongs to some action, and every field an
    // action takes is advertised, so a flat call can always say what it means.
    for (subagent_properties) |property| {
        const used = used: for (actions) |action| {
            for (action.fields) |field| {
                if (std.mem.eql(u8, field, property.name)) break :used true;
            }
        } else false;
        try std.testing.expect(used);
    }
    for (actions) |action| {
        for (action.fields) |field| {
            const advertised = for (subagent_properties) |property| {
                if (std.mem.eql(u8, property.name, field)) break true;
            } else false;
            try std.testing.expect(advertised);
        }
        const action_property = subagent_properties[0];
        try std.testing.expectEqualStrings("action", action_property.name);
        const listed = for (action_property.shape.?.enum_values) |value| {
            if (std.mem.eql(u8, value, action.name)) break true;
        } else false;
        try std.testing.expect(listed);
    }
}

test "built-in install_skill registers run_command compatibility" {
    const matched = (try tool_dispatch.matchRunCommandCompatibility(
        registry,
        "npx skills add vercel-labs/agent-skills --skill workflow -g -y",
    )) orelse return error.TestExpectedEqual;

    try std.testing.expectEqualStrings("install_skill", matched.tool.name);
    try std.testing.expect(try tool_dispatch.matchRunCommandCompatibility(registry, "zig build") == null);
}

test "built-in install_skill owns product metadata and schema" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, install_skill);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("install_skill", install_skill.name);
    try std.testing.expect(std.mem.find(u8, install_skill.description, "when the user asks") != null);
    try std.testing.expect(std.mem.find(u8, install_skill.description, "fx checks it") != null);
    try std.testing.expect(std.mem.find(u8, install_skill.description, "load an already-installed skill") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"source\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"skill\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"source\"]") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.install_skill, install_skill.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.write, install_skill.activity_kind);
    try std.testing.expect(install_skill.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.source, install_skill.label_arg_kind);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.none, install_skill.permission_target_kind);
    try std.testing.expectEqualStrings("Installing skill", install_skill.action_label);
    try std.testing.expectEqualStrings("Installed skill", install_skill.completed_action_label);
}

test "built-in capability_search owns unified bounded metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, capability_search);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("capability_search", capability_search.name);
    try std.testing.expect(std.mem.find(u8, capability_search.description, "configured MCP tools") != null);
    try std.testing.expect(std.mem.find(u8, capability_search.description, "callable on your next step") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"query\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"server\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"kind\"") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"limit\"") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"cursor\"") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"query\"]") != null);
    try std.testing.expect(capability_search.model_visible);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.capability_search, capability_search.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.read, capability_search.activity_kind);
    try std.testing.expect(!capability_search.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.query, capability_search.label_arg_kind);
    try std.testing.expect(capability_search.presentation_fn.? == capability_search_impl.presentation);
    try std.testing.expect(capability_search.decode == capability_search_impl.decode);
    try std.testing.expect(capability_search.call == capability_search_impl.call);
    try std.testing.expect(capability_search.reads_only_fn == capability_search_impl.readsOnly);
}

test "built-in mcp_select_tool owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, mcp_select_tool);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("mcp_select_tool", mcp_select_tool.name);
    try std.testing.expectEqualStrings(mcp_select_tool_description, mcp_select_tool.description);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"name\":\"mcp_select_tool\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"name\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"name\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "callable on your next step") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "mcp_search_tools") == null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.mcp_select_tool, mcp_select_tool.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.read, mcp_select_tool.activity_kind);
    try std.testing.expect(!mcp_select_tool.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.name, mcp_select_tool.label_arg_kind);
    try std.testing.expectEqualStrings("dynamic tool", mcp_select_tool.label_arg_default);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.none, mcp_select_tool.permission_target_kind);
    try std.testing.expectEqualStrings("Selecting MCP tool", mcp_select_tool.action_label);
    try std.testing.expectEqualStrings("Selected MCP tool", mcp_select_tool.completed_action_label);
    try std.testing.expect(mcp_select_tool.decode == tool_mcp_dispatch.decodeSelect);
    try std.testing.expect(mcp_select_tool.validate.? == tool_mcp_dispatch.validate);
    try std.testing.expect(mcp_select_tool.call == tool_mcp_dispatch.callSelect);
    try std.testing.expect(mcp_select_tool.reads_only_fn == tool_mcp_dispatch.readsOnly);
    try std.testing.expect(mcp_select_tool.irreversible_fn == tool_mcp_dispatch.isIrreversible);
}

test "built-in ask_user_question owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, ask_user_question);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("ask_user_question", ask_user_question.name);
    try std.testing.expectEqualStrings(ask_user_question_description, ask_user_question.description);
    try std.testing.expect(std.mem.find(u8, ask_user_question.description, "when a decision blocks you") != null);
    try std.testing.expect(std.mem.find(u8, ask_user_question.description, "the workspace cannot answer") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"name\":\"ask_user_question\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, ask_user_question.description, "Ask the user 1-20 multiple-choice questions"));
    try std.testing.expect(std.mem.find(u8, schema_json, "\"questions\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":20") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"options\":{\"type\":\"array\",\"minItems\":2,\"maxItems\":6") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"label\":{\"type\":\"string\",\"description\":\"1-5 words.\"}") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"question\",\"options\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"questions\"]") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.ask_user_question, ask_user_question.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.ask, ask_user_question.activity_kind);
    try std.testing.expect(!ask_user_question.requires_approval);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.none, ask_user_question.label_arg_kind);
    try std.testing.expectEqualStrings("", ask_user_question.label_arg_default);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.none, ask_user_question.permission_target_kind);
    try std.testing.expectEqualStrings("Asking", ask_user_question.action_label);
    try std.testing.expectEqualStrings("Asked", ask_user_question.completed_action_label);
    try std.testing.expect(ask_user_question.decode == ask_user_question_impl.decode);
    try std.testing.expect(ask_user_question.validate.? == ask_user_question_impl.validate);
    try std.testing.expect(ask_user_question.call == ask_user_question_impl.call);
    try std.testing.expect(ask_user_question.reads_only_fn == ask_user_question_impl.readsOnly);
    try std.testing.expect(ask_user_question.irreversible_fn == ask_user_question_impl.isIrreversible);
}

const AskDispatchFixture = struct {
    called: bool = false,

    fn request(raw_ctx: ?*anyopaque, alloc: Allocator, entries: []const types.QuestionBatchEntry) anyerror!?[][]u8 {
        const self: *AskDispatchFixture = @ptrCast(@alignCast(raw_ctx.?));
        self.called = true;
        try std.testing.expectEqual(@as(usize, 1), entries.len);
        try std.testing.expectEqualStrings("Proceed?", entries[0].question);

        const answers = try alloc.alloc([]u8, 1);
        errdefer alloc.free(answers);
        answers[0] = try alloc.dupe(u8, "Yes");
        return answers;
    }
};

test "built-in ask_user_question dispatch uses live interactive callback" {
    var fixture = AskDispatchFixture{};
    var result = try tool_dispatch.dispatchToolCall(.{
        .allocator = std.testing.allocator,
        .ask_question_ctx = &fixture,
        .ask_question_batch = AskDispatchFixture.request,
    }, registry, .{
        .id = "ask_1",
        .name = "ask_user_question",
        .arguments_json = "{\"questions\":[{\"question\":\"Proceed?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(fixture.called);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("[{\"question\":\"Proceed?\",\"answer\":\"Yes\"}]", result.body);
}

test "built-in ask_user_question dispatch returns noninteractive sentinel before parsing" {
    var result = try tool_dispatch.dispatchToolCall(.{ .allocator = std.testing.allocator }, registry, .{
        .id = "ask_1",
        .name = "ask_user_question",
        .arguments_json = "not-json",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings(ask_user_question_impl.not_available_sentinel, result.body);
}

test "built-in vision owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, vision);
    defer std.testing.allocator.free(schema_json);

    try std.testing.expectEqualStrings("vision", vision.name);
    try std.testing.expect(std.mem.find(u8, vision.description, "exactly one source") != null);
    try std.testing.expect(std.mem.find(u8, vision.description, "image files the user named") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"image_ids\":{\"type\":\"array\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"paths\":{\"type\":\"array\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"minItems\":1") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"focus\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"required\":[\"focus\"]") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"minProperties\":2") != null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"maxProperties\":2") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.vision, vision.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.read, vision.activity_kind);
    try std.testing.expect(vision.requires_approval);
    try std.testing.expectEqual(tool_dispatch.ApprovalPolicy.ask_only, vision.approval_policy);
    try std.testing.expectEqualStrings("Inspecting", vision.action_label);
    try std.testing.expectEqualStrings("Inspected", vision.completed_action_label);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.none, vision.label_arg_kind);
    try std.testing.expectEqualStrings("images", vision.label_arg_default);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.none, vision.permission_target_kind);
    try std.testing.expect(vision.decode == vision_impl.decode);
    try std.testing.expect(vision.validate.? == vision_impl.validate);
    try std.testing.expect(vision.call == vision_impl.call);
    try std.testing.expect(vision.reads_only_fn == vision_impl.readsOnly);
    try std.testing.expect(vision.irreversible_fn == vision_impl.isIrreversible);
}

test "built-in vision dispatch uses supplied runtime provider" {
    const Fixture = struct {
        called: bool = false,
        image_count: usize = 0,
        focus_matches: bool = false,

        fn execute(
            raw_ctx: ?*anyopaque,
            ctx: tool_dispatch.DispatchContext,
            input: tool_dispatch.ToolInput,
        ) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            const request = input.as(vision_impl.Input);
            self.called = true;
            self.image_count = request.image_ids().?.len;
            self.focus_matches = std.mem.eql(u8, request.focus, "read status");
            return .{ .success = try ctx.allocator.dupe(u8, "vision provider result") };
        }
    };

    var fixture = Fixture{};
    const vision_registry = tool_dispatch.Registry{ .tools = &.{vision} };
    var result = try tool_dispatch.dispatchAuthorizedToolCall(.{
        .allocator = std.testing.allocator,
        .vision_provider = .{
            .ctx = &fixture,
            .execute_fn = Fixture.execute,
        },
    }, vision_registry, .{
        .id = "vision_1",
        .name = "vision",
        .arguments_json = "{\"image_ids\":[7,9],\"focus\":\"read status\"}",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqualStrings("vision provider result", result.body);
    try std.testing.expect(fixture.called);
    try std.testing.expectEqual(@as(usize, 2), fixture.image_count);
    try std.testing.expect(fixture.focus_matches);
}

test "built-in read_tool_result owns product metadata schema and callbacks" {
    const schema_json = try tool_specs.toolGatewaySchemaJson(std.testing.allocator, read_tool_result);
    defer std.testing.allocator.free(schema_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema_json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("read_tool_result", read_tool_result.name);
    try std.testing.expect(std.mem.find(u8, read_tool_result.description, "pass query") != null);
    try std.testing.expect(std.mem.find(u8, read_tool_result.description, "pass search instead of a handle") != null);
    try std.testing.expect(std.mem.find(u8, read_tool_result.description, "request.") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"mode\"") == null);
    try std.testing.expect(std.mem.find(u8, schema_json, "\"oneOf\"") == null);
    const input_schema = parsed.value.object.get("inputSchema").?.object;
    try std.testing.expectEqualStrings("object", input_schema.get("type").?.string);
    // Search needs no handle, so no field is required by every call.
    try std.testing.expect(input_schema.get("required") == null);
    try std.testing.expect(!input_schema.get("additionalProperties").?.bool);
    const properties = input_schema.get("properties").?.object;
    try std.testing.expect(properties.get("request") == null);
    for ([_][]const u8{ "handle", "query", "start_byte", "byte_count", "search" }) |name| {
        try std.testing.expect(properties.get(name) != null);
    }
    try std.testing.expectEqual(@as(i64, 3), properties.get("search").?.object.get("maxItems").?.integer);
    try std.testing.expect(std.mem.find(u8, properties.get("search").?.object.get("description").?.string, "Without a handle") != null);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.read_tool_result, read_tool_result.executor_kind);
    try std.testing.expectEqual(types.ToolActivityKind.read, read_tool_result.activity_kind);
    try std.testing.expect(!read_tool_result.requires_approval);
    try std.testing.expectEqualStrings("Reading", read_tool_result.action_label);
    try std.testing.expectEqualStrings("Read", read_tool_result.completed_action_label);
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.none, read_tool_result.label_arg_kind);
    try std.testing.expectEqualStrings("saved output", read_tool_result.label_arg_default);
    try std.testing.expect(read_tool_result.presentation_fn.? == read_tool_result_impl.presentation);
    try std.testing.expectEqual(tool_dispatch.PermissionTargetKind.none, read_tool_result.permission_target_kind);
    try std.testing.expect(read_tool_result.decode == read_tool_result_impl.decode);
    try std.testing.expect(read_tool_result.validate.? == read_tool_result_impl.validate);
    try std.testing.expect(read_tool_result.call == read_tool_result_impl.call);
    try std.testing.expect(read_tool_result.reads_only_fn == read_tool_result_impl.readsOnly);
    try std.testing.expect(read_tool_result.irreversible_fn == read_tool_result_impl.isIrreversible);
}

test "built-in write and edit tools register canonical mutation input ownership" {
    const write = registry.lookup("write_file") orelse
        return error.TestExpectedEqual;
    const edit = registry.lookup("edit_file") orelse
        return error.TestExpectedEqual;
    const read = registry.lookup("read_file") orelse
        return error.TestExpectedEqual;

    try std.testing.expect(write.take_file_mutation_input_fn != null);
    try std.testing.expect(edit.take_file_mutation_input_fn != null);
    try std.testing.expect(read.take_file_mutation_input_fn == null);
}

test "built-in write and edit tools declare their mutation executor kind" {
    const write = registry.lookup("write_file") orelse
        return error.TestExpectedEqual;
    const edit = registry.lookup("edit_file") orelse
        return error.TestExpectedEqual;

    try std.testing.expectEqual(tool_dispatch.ExecutorKind.write_file, write.executor_kind);
    try std.testing.expectEqual(tool_dispatch.ExecutorKind.edit_file, edit.executor_kind);
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

fn stackWebFetchInput(input: *web_fetch_impl.Input) tool_dispatch.ToolInput {
    return .{
        .ptr = @ptrCast(input),
        .deinit_fn = noopInputDeinit,
    };
}

test "built-in registry uses executable web_fetch implementation" {
    const spec = registry.lookup("web_fetch") orelse return error.TestExpectedEqual;
    var input = web_fetch_impl.Input{
        .url = try std.testing.allocator.dupe(u8, "ftp://example.com"),
    };
    defer input.deinit(std.testing.allocator);

    var result = try spec.call(.{ .allocator = std.testing.allocator }, stackWebFetchInput(&input));
    defer result.deinit(std.testing.allocator);

    const body = switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .success => return error.TestUnexpectedResult,
        .failure => |body| body,
    };
    try std.testing.expect(std.mem.find(u8, body, "\"tool_name\":\"web_fetch\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "web_fetch failed") != null);
    try std.testing.expect(std.mem.find(u8, body, "UnsupportedScheme") != null);
}

test "built-in read-only tool set matches plan inspection tools" {
    const expected_names = [_][]const u8{
        "read_file",
        "glob_files",
        "grep_files",
    };

    try std.testing.expectEqual(expected_names.len, read_only_tool_names.len);
    for (expected_names, read_only_tool_names) |expected, name| {
        try std.testing.expectEqualStrings(expected, name);
        try std.testing.expect(isReadOnlyToolName(name));
    }
    try std.testing.expect(!isReadOnlyToolName("write_file"));
    try std.testing.expect(!isReadOnlyToolName("run_command"));
}

test "built-in skill registry order follows shell" {
    var shell_pos: ?usize = null;
    var skill_pos: ?usize = null;
    for (all, 0..) |tool, index| {
        if (std.mem.eql(u8, tool.name, "shell")) shell_pos = index;
        if (std.mem.eql(u8, tool.name, "skill")) skill_pos = index;
    }

    try std.testing.expect(shell_pos != null);
    try std.testing.expect(skill_pos != null);
    try std.testing.expect(shell_pos.? < skill_pos.?);
}

test "built-in install_skill registry order follows skill" {
    var skill_pos: ?usize = null;
    var install_skill_pos: ?usize = null;
    for (all, 0..) |tool, index| {
        if (std.mem.eql(u8, tool.name, "skill")) skill_pos = index;
        if (std.mem.eql(u8, tool.name, "install_skill")) install_skill_pos = index;
    }

    try std.testing.expect(skill_pos != null);
    try std.testing.expect(install_skill_pos != null);
    try std.testing.expect(skill_pos.? < install_skill_pos.?);
}

test "built-in subagent registry order follows install_skill" {
    var install_skill_pos: ?usize = null;
    var subagent_pos: ?usize = null;
    for (all, 0..) |tool, index| {
        if (std.mem.eql(u8, tool.name, "install_skill")) install_skill_pos = index;
        if (std.mem.eql(u8, tool.name, "subagent")) subagent_pos = index;
    }

    try std.testing.expect(install_skill_pos != null);
    try std.testing.expect(subagent_pos != null);
    try std.testing.expect(install_skill_pos.? < subagent_pos.?);
}

test "production registry keeps vision route-filtered from ordinary projections" {
    try std.testing.expect(registry.lookup("vision") != null);

    var full = try tool_projection.buildModelToolProjectionForSet(
        std.testing.allocator,
        advertisement_set,
        .{},
    );
    defer full.deinit(std.testing.allocator);
    var read_only = try tool_projection.buildReadOnlyModelToolProjectionForSet(
        std.testing.allocator,
        advertisement_set,
        .{},
    );
    defer read_only.deinit(std.testing.allocator);

    inline for (&.{ &full, &read_only }) |projection| {
        try std.testing.expect(!tool_projection.containsName(projection.advertised_names, "vision"));
    }
}

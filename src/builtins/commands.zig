const std = @import("std");
const command_specs = @import("../core/slash_commands/command_specs.zig");

const Allocator = std.mem.Allocator;

pub const TopLevelKind = command_specs.TopLevelKind;
pub const TopLevelSpec = command_specs.TopLevelSpec;
pub const TopLevelHelpGroup = command_specs.TopLevelHelpGroup;
pub const TopLevelFlag = command_specs.TopLevelFlag;
pub const TopLevelExample = command_specs.TopLevelExample;
pub const TopLevelResource = command_specs.TopLevelResource;
pub const TopLevelRegistry = command_specs.TopLevelRegistry;
pub const HelpStyle = command_specs.HelpStyle;
pub const SlashKind = command_specs.SlashKind;
pub const SlashPresentationCategory = command_specs.SlashPresentationCategory;
pub const SlashSpec = command_specs.SlashSpec;
pub const SlashRegistry = command_specs.SlashRegistry;

const json_option = command_specs.OptionDoc{ .flag = "--json", .description = "Emit machine-readable JSON instead of text" };

/// Options for `fx ask`. `cli_ask` parses against this list and its help is
/// rendered from it, so the two can't disagree.
/// Options for local commands that only take `--json`.
pub const json_only_options = [_]command_specs.OptionDoc{json_option};

const login_providers = [_]command_specs.SubcommandDoc{
    .{ .usage = "vercel", .description = "Vercel AI Gateway (the default)", .options = &login_options },
    .{ .usage = "codex", .description = "ChatGPT subscription" },
    .{ .usage = "grok", .description = "Grok subscription" },
};

pub const login_options = [_]command_specs.OptionDoc{
    .{ .flag = "--api-key", .description = "Paste a Vercel AI Gateway API key instead of signing in through the browser" },
};

pub const sessions_options = [_]command_specs.OptionDoc{
    .{ .flag = "--all", .description = "List saved sessions across every workspace in this profile" },
    .{ .flag = "--limit <1-100>", .description = "Set the maximum sessions returned per page" },
    .{ .flag = "--cursor <cursor>", .description = "Continue from a prior sessions result" },
    json_option,
};

pub const sessions_convert_options = [_]command_specs.OptionDoc{json_option};

pub const usage_options = [_]command_specs.OptionDoc{
    .{ .flag = "--period <today|7d|month>", .description = "Select the period, in UTC days (default: month)" },
    json_option,
};

pub const upgrade_options = [_]command_specs.OptionDoc{
    .{ .flag = "--channel <stable|dev>", .description = "Select and remember the release channel" },
    json_option,
};

pub const workspace_options = [_]command_specs.OptionDoc{json_option};

const workspace_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "list", .description = "List the primary and additional directories (default)" },
    .{ .usage = "add PATH", .description = "Persist an existing additional directory" },
    .{ .usage = "remove PATH", .description = "Remove an additional directory" },
    .{ .usage = "clear", .description = "Remove all additional directories" },
};

const config_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "list", .description = "List the values set in each settings file (default)", .options = &config_options },
    .{ .usage = "get <key>", .description = "Print the value fx uses for a setting", .options = &config_options },
    .{ .usage = "set <key> <value>", .description = "Save a preference in ~/.fx/settings.json", .settable_key = true },
    .{ .usage = "unset <key>", .description = "Remove a preference from ~/.fx/settings.json", .settable_key = true },
    .{ .usage = "schema", .description = "Print the JSON Schema for ~/.fx/settings.json", .options = &config_schema_options },
};

const config_schema_options = [_]command_specs.OptionDoc{
    .{ .flag = "--project", .description = "Print the schema for a project .fx.json instead" },
};

/// Every flag `fx config` parses: its own and `schema --project`.
pub const config_parse_options = config_options ++ config_schema_options;

const config_options = [_]command_specs.OptionDoc{
    .{ .flag = "--global", .description = "Only the profile's own settings" },
    .{ .flag = "--workspace", .description = "Only this workspace's override in the profile (list and get)" },
    .{ .flag = "--show-origin", .description = "Start each line with where the value is set" },
    json_option,
};

const session_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "last", .description = "Inspect the current workspace session" },
    .{ .usage = "resume [last|<id>]", .description = "Resume the latest workspace session or a session by id" },
    .{ .usage = "recover <id>", .description = "Copy a recoverable corrupt session into a new session" },
};

pub const session_options = [_]command_specs.OptionDoc{
    .{ .flag = "--id <id>", .description = "Inspect a saved session by exact id" },
    json_option,
};

pub const acp_options = agentRunOptions("sessions this server starts", .without_provider_order) ++ [_]command_specs.OptionDoc{
    .{ .flag = "--log-file <path>", .description = "Write ACP logs to a file" },
};

pub const acp_usage = "acp " ++ agent_run_usage_base ++ " [--log-file <path>]";

pub const pr_options = agentRunOptions("this request", .with_provider_order) ++ [_]command_specs.OptionDoc{
    .{ .flag = "--create", .description = "Publish the drafted pull request via the GitHub CLI" },
};

const issue_options = agentRunOptions("this request", .with_provider_order) ++ [_]command_specs.OptionDoc{
    .{ .flag = "--create", .description = "Publish the drafted issue via the GitHub CLI" },
};

pub const replay_options = [_]command_specs.OptionDoc{
    .{ .flag = "--frames", .description = "Render each captured frame" },
    .{ .flag = "--golden <path>", .description = "Write the final rendered grid to a file" },
    .{ .flag = "--frames-dir <path>", .description = "Write rendered frames to a directory" },
    json_option,
};

/// `fx mcp list` options; `fx mcp --help` shows them in its usage line.
const mcp_subcommands = [_]command_specs.SubcommandDoc{
    .{ .usage = "list", .description = "List configured servers; never connects", .options = &mcp_list_options },
    .{ .usage = "show NAME", .description = "Connect to a server: status, version, and tools", .options = &mcp_show_options },
    .{
        .usage = "add NAME URL",
        .description = "Add an HTTP server, or a command after --",
        .subcommands = &.{.{ .usage = "slack", .description = "Add Slack's server" }},
        .options = &mcp_add_options,
    },
    .{ .usage = "remove NAME", .description = "Remove a server and its login", .options = &mcp_scope_options },
    .{ .usage = "login NAME", .description = "Sign in to an HTTP server", .options = &mcp_login_options },
    .{ .usage = "logout NAME", .description = "Sign out and delete the login" },
    .{ .usage = "approve NAME", .description = "Approve a project server from .mcp.json", .options = &mcp_approve_options },
    .{ .usage = "reject NAME", .description = "Reject a project server" },
};

// The flags of the `fx mcp` and `/mcp` verbs, which `src/core/mcp_host/verbs.zig`
// parses and completion offers.

/// `--global` names ~/.fx/mcp.json, the default, and `--project` the
/// project's .mcp.json. `--profile` is the older name for `--global`.
pub const mcp_scope_options = [_]command_specs.OptionDoc{
    .{ .flag = "--global", .description = "Use ~/.fx/mcp.json, the default" },
    .{ .flag = "--profile", .description = "Older name for --global", .hidden = true },
    .{ .flag = "--project", .description = "Use the project's .mcp.json" },
};
pub const mcp_add_options = mcp_scope_options ++ [_]command_specs.OptionDoc{
    .{ .flag = "--env <KEY=VALUE>", .description = "Set an environment variable for a command server" },
    .{ .flag = "--header <KEY=VALUE>", .description = "Send a header to an HTTP server" },
};
/// `list --connect` moved to `show NAME`; it is read to say so.
const mcp_connect_option: command_specs.OptionDoc = .{ .flag = "--connect", .description = "Moved to show NAME", .hidden = true };
pub const mcp_list_options = [_]command_specs.OptionDoc{ json_option, mcp_connect_option };
/// `/mcp list` in a session prints no JSON.
pub const mcp_list_shell_options = [_]command_specs.OptionDoc{mcp_connect_option};
pub const mcp_show_options = [_]command_specs.OptionDoc{json_option};
pub const mcp_login_options = [_]command_specs.OptionDoc{
    .{ .flag = "--no-browser", .description = "Print the sign-in address instead of opening it" },
};
pub const mcp_approve_options = [_]command_specs.OptionDoc{
    .{ .flag = "--all", .description = "Approve every project server" },
};

const permission_modes = [_][]const u8{ "ask", "auto", "full-access" };
/// The built-in providers. A configured connection's name is also accepted.
const builtin_providers = [_][]const u8{ "gateway", "codex", "grok" };

/// Whether a command takes the gateway provider-order flags.
const ProviderOrder = enum { with_provider_order, without_provider_order };

/// The flags that shape an agent run, the same on every command that runs the
/// agent: `fx ask`, `fx pr`, `fx issue`, and `fx acp`. `scope` names what they
/// shape, such as "this request". `src/core/cli/agent_run_flags.zig` parses
/// them. `fx acp` leaves out the provider-order flags, because ACP sessions
/// don't apply gateway provider routing.
fn agentRunOptions(comptime scope: []const u8, comptime provider_order: ProviderOrder) [if (provider_order == .with_provider_order) 15 else 12]command_specs.OptionDoc {
    const all = [_]command_specs.OptionDoc{
        .{ .flag = "--permission-mode <mode>", .description = "Set the permission mode for " ++ scope ++ ": ask, auto, or full-access", .values = &permission_modes },
        .{ .flag = "--ask", .description = "Ask before each action that needs permission" },
        .{ .flag = "--auto", .description = "Automatically review unresolved permission requests" },
        .{ .flag = "--full-access", .description = "Disable fx permission checks" },
        .{ .flag = "--yolo", .description = "Alias for --full-access" },
        .{ .flag = "--provider <name>", .description = "Override the model provider for " ++ scope ++ " (gateway, codex, grok, or a configured name)", .values = &builtin_providers },
        .{ .flag = "--model <id>", .description = "Override the model for " ++ scope },
        .{ .flag = "--effort <level>", .description = "Override the reasoning effort for " ++ scope },
        .{ .flag = "--fast", .description = "Enable Fast mode for " ++ scope ++ " when the model supports it" },
        .{ .flag = "--no-fast", .description = "Disable Fast mode for " ++ scope },
        .{ .flag = "--ultrafast", .description = "Request Ultra mode for " ++ scope ++ " when the model supports it" },
        .{ .flag = "--no-ultrafast", .description = "Disable Ultra mode for " ++ scope },
        .{ .flag = "--provider-order <a,b,...>", .description = "Prefer these gateway providers in order for " ++ scope },
        .{ .flag = "--provider-strict", .description = "Restrict " ++ scope ++ " to only the providers in --provider-order" },
        .{ .flag = "--no-provider-strict", .description = "Clear the provider restriction for " ++ scope },
    };
    return if (provider_order == .with_provider_order) all else all[0..12].*;
}

/// The usage-line form of `agentRunOptions`.
const agent_run_usage_base = "[--permission-mode <mode>|--ask|--auto|--full-access] [--provider <name>] [--model <id>] [--effort <level>] [--fast|--no-fast] [--ultrafast|--no-ultrafast]";
const agent_run_usage = agent_run_usage_base ++ " [--provider-order <a,b,...>] [--provider-strict|--no-provider-strict]";

pub const ask_options = agentRunOptions("this request", .with_provider_order) ++ [_]command_specs.OptionDoc{
    .{ .flag = "--image PATH", .description = "Attach an image file; repeat for multiple images" },
    .{ .flag = "--system TEXT", .description = "Replace the built-in system prompt for this request" },
    json_option,
    .{ .flag = "--quiet", .description = "Suppress assistant output" },
    .{ .flag = "--prompt-permissions", .description = "Prompt for Y/N permission approval when stdin is a TTY" },
    .{ .flag = "--timeout <seconds>", .description = "Time limit for each shell command the agent runs" },
    .{ .flag = "--config <key=value>", .description = "Override a setting for this request, with the keys fx config set takes; repeatable" },
    .{ .flag = "--no-save", .description = "Do not save the session; incompatible with --resume" },
    .{ .flag = "--no-color", .description = "Render TTY output without colors or hyperlinks; NO_COLOR or TERM=dumb also turns color off" },
    .{ .flag = "--resume <last|<id>>", .description = "Continue the last session or a session by id" },
    .{ .flag = "--resume-id <id>", .description = "Continue a session by exact id", .replacement = "use --resume <id>" },
    .{ .flag = "--", .description = "Treat every following argument as prompt text" },
};

pub const top_level_specs = [_]TopLevelSpec{
    .{
        .kind = .help,
        .token = "help",
        .aliases = &.{ "--help", "-h" },
        .usage = "help",
        .summary = "Show this help",
    },
    .{
        .kind = .ask,
        .token = "ask",
        .usage = "ask " ++ agent_run_usage ++ " [--image PATH] [--system TEXT] [--json] [--quiet] [--prompt-permissions] [--timeout <seconds>] [--config <key=value>] [--no-save] [--no-color] [--resume <last|<id>>] [--] <prompt>",
        .summary = "Run one noninteractive request",
        .options = &ask_options,
        .details = &.{
            "The prompt may be passed as arguments or piped on stdin when no prompt args are given.",
            "TTY stdout uses the Minimal transcript presentation; redirected stdout emits raw assistant Markdown.",
            "Operational progress and diagnostics are written to stderr. JSON `output` keeps accumulated assistant Markdown; `final_output` contains only the completed final response, or an empty string when absent.",
            "JSON usage sums reported main-agent input_tokens and output_tokens, including with --no-save; unreported counts are null. cache_read_tokens and cache_write_tokens appear only when the provider reports them. Nested usage and dollar spend are excluded.",
            "--system replaces only the built-in base prompt for this request; tool, skill, project, and runtime context still apply.",
            "With --prompt-permissions, JSON and quiet requests may prompt on stderr only when stdin is a TTY.",
        },
    },
    .{
        .kind = .acp,
        .token = "acp",
        .usage = acp_usage,
        .summary = "Start an ACP server over stdio",
        .options = &acp_options,
    },
    .{
        .kind = .pr,
        .token = "pr",
        .usage = "pr " ++ agent_run_usage ++ " [--create] [--] [context]",
        .summary = "Draft or publish a pull request",
        .options = &pr_options,
        .details = &.{
            "Must run inside a git repository. Without --create, the drafted PR is printed only.",
        },
    },
    .{
        .kind = .issue,
        .token = "issue",
        .usage = "issue " ++ agent_run_usage ++ " [--create] [--] [context]",
        .summary = "Draft or publish a GitHub issue",
        .options = &issue_options,
    },
    .{
        .kind = .login,
        .token = "login",
        .usage = "login [vercel|codex|grok] [--api-key]",
        .summary = "Sign in to Vercel or a selected provider",
        .subcommands = &login_providers,
        .options = &login_options,
    },
    .{
        .kind = .logout,
        .token = "logout",
        .usage = "logout [vercel|codex|grok]",
        .summary = "Sign out of Vercel or a selected provider session",
        .subcommands = &login_providers,
    },
    .{
        .kind = .setup,
        .token = "setup",
        // Warns until it is removed.
        .hidden_from_top_level_help = true,
        .replaced_by = "fx login vercel --api-key",
        .usage = "setup",
        .summary = "Paste an AI Gateway API key (deprecated: use fx login vercel --api-key)",
    },
    .{
        .kind = .status,
        .token = "status",
        .usage = "status [--json]",
        .summary = "Show configuration and runtime information",
        .options = &.{json_option},
    },
    .{
        .kind = .permissions,
        .token = "permissions",
        .usage = "permissions [--json]",
        .summary = "Show the permission mode and rules",
        .options = &.{json_option},
        .details = &.{
            "Modes:",
            "  ask          Prompt before sensitive tool calls",
            "  auto         Apply rules, then review unresolved sensitive tool calls (default)",
            "  full-access  Disable fx permission checks",
            "",
            "Change the mode from the interactive shell with `/permissions [ask|auto|full-access|reset]`,",
            "and manage persistent allow rules with `/allowlist`.",
        },
    },
    .{
        .kind = .mcp,
        .token = "mcp",
        .usage = "mcp <command> ...",
        // `fx mcp -h` is the verbs' own help (`mcp_host/verbs.zig` writeUsage).
        .summary = "Manage MCP servers without opening the interactive shell",
        .subcommands = &mcp_subcommands,
    },
    .{
        .kind = .models,
        .token = "models",
        .usage = "models [--json]",
        .summary = "List available models",
        .options = &.{json_option},
    },
    .{
        .kind = .provider,
        .token = "provider",
        .usage = "provider <name>",
        .summary = "Choose the model provider used by fx",
    },
    .{
        .kind = .doctor,
        .token = "doctor",
        .usage = "doctor [--json]",
        .summary = "Run local health and preflight checks",
        .options = &.{json_option},
    },
    .{
        .kind = .teams,
        .token = "teams",
        .usage = "teams",
        .summary = "Choose the Vercel team used by AI Gateway",
    },
    .{
        .kind = .session,
        .token = "session",
        .usage = "session <last|id>|--id <id> [--json] | session resume [last|<id>] | session recover <id>|--id <id> [--json]",
        .summary = "Inspect, resume, or recover saved sessions",
        .subcommands = &session_subcommands,
        .options = &session_options,
    },
    .{
        .kind = .sessions,
        .token = "sessions",
        .usage = "sessions [--all] [--limit <1-100>] [--cursor <cursor>] [--json] | sessions convert [--json]",
        .summary = "List saved sessions for the current workspace",
        .subcommands = &.{.{ .usage = "convert", .description = "Convert every session saved in the previous format", .options = &sessions_convert_options }},
        .options = &sessions_options,
    },
    .{
        .kind = .@"resume",
        .token = "resume",
        .aliases = &.{ "--resume", "--continue", "-c", "-r" },
        .help_title = "--resume",
        .hidden_from_top_level_help = true,
        .usage = "session resume [last|<id>] | -r, --resume [last|<id>] | --continue | -c",
        .summary = "Continue a saved interactive session",
        .options = &.{
            .{ .flag = "-r", .description = "Short for --resume; with no value, choose a session from a picker" },
            .{ .flag = "last", .description = "Resume the most recent session" },
            .{ .flag = "<id>", .description = "Resume a session by id" },
        },
    },
    .{
        .kind = .credits,
        .token = "credits",
        .aliases = &.{"balance"},
        .usage = "credits [--json]",
        .summary = "Show the AI Gateway credit balance",
        .options = &.{json_option},
    },
    .{
        .kind = .usage,
        .token = "usage",
        .usage = "usage [--period <today|7d|month>] [--json]",
        .summary = "Show your provider's usage and spend",
        .options = &usage_options,
        .details = &.{
            "With AI Gateway, reads its usage reports: with fx login, your spend on the team and your budget; with an API key, that key's spend.",
            "With Codex, reads your ChatGPT plan's limits and activity; with Grok, your plan's allowance and credits.",
            "Finished days are cached under ~/.fx and fetched at most once a day.",
        },
    },
    .{
        .kind = .upgrade,
        .token = "upgrade",
        .aliases = &.{"update"},
        .usage = "upgrade [--channel <stable|dev>] [--json]",
        .summary = "Upgrade 𝒇x on the selected release channel",
        .options = &upgrade_options,
    },
    .{
        .kind = .replay,
        .token = "replay",
        .usage = "replay <tape> [--frames] [--json] [--golden <path>] [--frames-dir <path>]",
        .summary = "Replay a recorded terminal session",
        .hidden_from_top_level_help = true,
        .options = &replay_options,
        .details = &.{
            "Developer tool for reproducing terminal rendering bugs from FX_RECORD and FX_DEBUG_RECORD tapes. It is not listed in `fx help`.",
        },
    },
    .{
        .kind = .workspace,
        .token = "workspace",
        .usage = "workspace [list|add PATH|remove PATH|clear] [--json]",
        .summary = "Manage additional workspace directories",
        .subcommands = &workspace_subcommands,
        .options = &workspace_options,
        .details = &.{
            "Additional directories are stored for the current primary workspace.",
        },
    },
    .{
        .kind = .completion,
        .token = "completion",
        .usage = "completion bash|zsh|fish",
        .summary = "Print a shell completion script",
        .subcommands = &.{
            .{ .usage = "bash", .description = "Load it with: eval \"$(fx completion bash)\"" },
            .{ .usage = "zsh", .description = "Load it after compinit with: source <(fx completion zsh)" },
            .{ .usage = "fish", .description = "Load it with: fx completion fish | source" },
        },
        .details = &.{
            "Add the load line to ~/.bashrc, ~/.zshrc, or ~/.config/fish/config.fish to keep it in new shells.",
            "Tab completes commands, flags, setting keys after fx config get, set, and unset, and fixed flag values.",
        },
    },
    .{
        .kind = .config,
        .token = "config",
        .usage = "config [list|get <key>|set <key> <value>|unset <key>|schema [--project]] [--global|--workspace] [--show-origin] [--json]",
        .summary = "Show and change fx settings",
        .subcommands = &config_subcommands,
        .options = &config_options,
        .details = &.{
            "Values come from .fx.json, ~/.fx/settings.json, and this workspace's override in it. When a key repeats, the last line is the one fx uses.",
            "Keys are dotted, such as status_line.context. A flag or an FX_* variable can override a value for one run; fx status shows what a run uses.",
            "set and unset change plain preferences for every workspace, such as fast_mode, effort, theme, and status_line.context. Switches take true or false. Permission, model, provider, and account settings keep their own commands.",
            "schema prints a JSON Schema that editors use to complete and check ~/.fx/settings.json, and --project prints the one for .fx.json. A file whose \"$schema\" names https://fx.sh/schemas/settings.json or https://fx.sh/schemas/fx.json gets the same check.",
        },
    },
    command_specs.slack_install_spec,
};

pub const top_level_help_default_width = command_specs.top_level_help_default_width;
pub const top_level_help_fast_buffer_bytes: usize = 32 * 1024;

pub const top_level_help_groups = [_]TopLevelHelpGroup{
    .{ .entries = &.{
        .{ .kind = .ask, .usage = "ask <prompt>" },
    } },
    .{ .entries = &.{
        .{ .kind = .pr, .usage = "pr [context]" },
        .{ .kind = .issue, .usage = "issue [context]" },
    } },
    .{ .entries = &.{
        .{ .kind = .sessions, .usage = "sessions" },
        .{ .kind = .session, .usage = "session <last|id>" },
        .{ .usage = "session resume [last|id]", .summary = "Resume the latest workspace session or a session by id" },
        .{ .usage = "session recover <id>", .summary = "Copy a recoverable corrupt session" },
    } },
    .{ .entries = &.{
        .{ .kind = .login, .usage = "login [vercel|codex|grok] [--api-key]", .summary = "Sign in to a model provider" },
        .{ .kind = .logout, .usage = "logout [vercel|codex|grok]", .summary = "Sign out of a model provider" },
        .{ .kind = .provider, .usage = "provider <name>", .summary = "Choose the active model provider" },
        .{ .kind = .models, .usage = "models" },
    } },
    .{ .entries = &.{
        .{ .kind = .teams, .usage = "teams", .summary = "Choose a Vercel AI Gateway team" },
        .{ .kind = .credits, .usage = "credits|balance", .summary = "Show Vercel AI Gateway credits" },
    } },
    .{ .entries = &.{
        .{ .kind = .usage, .usage = "usage [--period <today|7d|month>]", .summary = "Show your provider's usage and spend" },
    } },
    .{ .entries = &.{
        .{ .kind = .status, .usage = "status" },
        .{ .kind = .doctor, .usage = "doctor" },
        .{ .kind = .mcp, .usage = "mcp <command> ..." },
        .{ .kind = .slack, .usage = "slack <install|status|refresh>" },
        .{ .kind = .permissions, .usage = "permissions" },
        .{ .kind = .workspace, .usage = "workspace" },
        .{ .kind = .config, .usage = "config" },
        .{ .kind = .upgrade, .usage = "upgrade|update", .summary = "Upgrade fx on the selected release channel" },
        .{ .kind = .acp, .usage = "acp" },
        .{ .kind = .completion, .usage = "completion <shell>" },
        .{ .kind = .help, .usage = "help" },
    } },
};

/// The launch-wide flags: they go before a command, which can't take them
/// itself, as `git -C dir log` does.
pub const launch_wide_options = [_]command_specs.OptionDoc{
    .{ .flag = "--context-limit <spec>", .description = "" },
    .{ .flag = "--add-dir <path>", .description = "" },
    .{ .flag = "--no-additional-dirs", .description = "" },
};

/// The flags `fx` reads before a command or an interactive launch, in the
/// form the shared flag parser reads. `top_level_flags` documents them in
/// `fx --help`, and a test checks that the two lists match. The usage line
/// after a launch-flag mistake is built from this list.
pub const launch_options = launch_wide_options ++ [_]command_specs.OptionDoc{
    .{ .flag = "--provider <name>", .description = "", .values = &builtin_providers },
    .{ .flag = "--provider-order <a,b,...>", .description = "" },
    .{ .flag = "--provider-strict", .description = "" },
    .{ .flag = "--no-provider-strict", .description = "" },
    .{ .flag = "--model <id>", .description = "" },
    .{ .flag = "--effort <level>", .description = "" },
    .{ .flag = "--fast", .description = "" },
    .{ .flag = "--no-fast", .description = "" },
    .{ .flag = "--ultrafast", .description = "" },
    .{ .flag = "--no-ultrafast", .description = "" },
    .{ .flag = "--permission-mode <mode>", .description = "", .values = &permission_modes },
    .{ .flag = "--ask", .description = "" },
    .{ .flag = "--auto", .description = "" },
    .{ .flag = "--full-access", .description = "" },
    .{ .flag = "--yolo", .description = "" },
};

/// `usage: fx [--context-limit <spec>] ... <command>`, from `launch_options`,
/// with each `--x` and `--no-x` pair written as `[--x|--no-x]`.
pub const launch_usage: []const u8 = blk: {
    @setEvalBranchQuota(20_000);
    var out: []const u8 = "usage: fx";
    var i: usize = 0;
    while (i < launch_options.len) : (i += 1) {
        const doc = launch_options[i];
        if (doc.hidden or doc.replacement != null) continue;
        const name = doc.flag[0 .. std.mem.findScalar(u8, doc.flag, ' ') orelse doc.flag.len];
        if (i + 1 < launch_options.len and std.mem.eql(u8, launch_options[i + 1].flag, "--no-" ++ name[2..])) {
            out = out ++ " [" ++ doc.flag ++ "|" ++ launch_options[i + 1].flag ++ "]";
            i += 1;
            continue;
        }
        out = out ++ " [" ++ doc.flag ++ "]";
    }
    break :blk out ++ " <command>\n";
};

pub const top_level_flags = [_]TopLevelFlag{
    .{
        .usage = "--context-limit <spec>",
        .description = "Set name=bytes|off; repeatable",
    },
    .{
        .usage = "--add-dir <path>",
        .description = "Add a workspace directory; repeatable",
    },
    .{
        .usage = "--no-additional-dirs",
        .description = "Ignore saved additional directories",
    },
    .{
        .usage = "--provider <name>",
        .description = "Override the model provider for an interactive session (gateway, codex, grok, or a configured name)",
    },
    .{
        .usage = "--provider-order <a,b,...>",
        .description = "Prefer these gateway providers in order for an interactive session",
    },
    .{
        .usage = "--provider-strict, --no-provider-strict",
        .description = "Restrict an interactive session to the providers in --provider-order, or clear the restriction",
    },
    .{
        .usage = "--model <id>",
        .description = "Override the model for an interactive session",
    },
    .{
        .usage = "--effort <level>",
        .description = "Override the reasoning effort for an interactive session",
    },
    .{
        .usage = "--fast, --no-fast",
        .description = "Turn Fast mode on or off for an interactive session",
    },
    .{
        .usage = "--ultrafast, --no-ultrafast",
        .description = "Request Ultra mode on or off for an interactive session",
    },
    .{
        .usage = "--permission-mode <mode>",
        .description = "Set the permission mode for an interactive session: ask, auto, or full-access",
    },
    .{
        .usage = "--ask, --auto, --full-access",
        .description = "Shortcuts for each permission mode; --yolo means --full-access",
    },
    .{
        .usage = "-c, --continue",
        .description = "Resume the remembered workspace session",
    },
    .{
        .usage = "-r, --resume [last|<id>]",
        .description = "Pick a saved session, or resume the latest or an exact ID",
    },
    .{
        .usage = "-h, --help",
        .description = "Display this help and exit",
    },
    .{
        .usage = "-v, --version",
        .description = "Print the fx version and exit",
    },
};

pub const top_level_examples = [_]TopLevelExample{
    .{ .command = "fx", .description = "Start a fresh interactive session" },
    .{ .command = "fx \"Fix the failing login test\"", .description = "Start a session with a first prompt" },
    .{ .command = "fx ask \"Explain the changes in this repository\"", .description = "Run one request and exit" },
    .{ .command = "fx session resume last", .description = "Continue the latest session for this workspace" },
    .{ .command = "fx status --json", .description = "Inspect the current configuration as JSON" },
};

pub const top_level_notes = [_][]const u8{
    "Run `fx <command> --help` for command-specific usage and options.",
    "Run `/help` inside an interactive session for slash commands.",
};

pub const top_level_resources = [_]TopLevelResource{
    .{ .label = "Learn more about fx:", .value = "https://fx.sh/docs", .link = true },
    .{ .label = "Report a problem:", .value = "run `/feedback` inside fx" },
};

pub const top_level_registry = TopLevelRegistry{
    .specs = top_level_specs[0..],
    .description = "Fast, native coding agent for the terminal.",
    .interactive_hint = "fx starts an interactive session by default. Use `fx ask` to run one noninteractive request.",
    .help_groups = top_level_help_groups[0..],
    .flags = top_level_flags[0..],
    .examples = top_level_examples[0..],
    .notes = top_level_notes[0..],
    .resources = top_level_resources[0..],
};

pub fn matchesTopLevel(token: []const u8, kind: TopLevelKind) bool {
    return command_specs.matchesTopLevel(top_level_registry, token, kind);
}

pub fn renderTopLevelHelp(alloc: Allocator, columns: usize, version: []const u8) ![]u8 {
    return command_specs.renderTopLevelHelp(alloc, top_level_registry, columns, version);
}

pub fn renderTopLevelHelpWithStyle(alloc: Allocator, columns: usize, version: []const u8, style: HelpStyle) ![]u8 {
    return command_specs.renderTopLevelHelpWithStyle(alloc, top_level_registry, columns, version, style);
}

pub fn renderTopLevelCommandHelp(alloc: Allocator, kind: TopLevelKind) ![]u8 {
    return command_specs.renderTopLevelCommandHelp(alloc, top_level_registry, kind);
}

pub fn topLevelKindFromToken(token: []const u8) ?TopLevelKind {
    return command_specs.topLevelKindFromToken(top_level_registry, token);
}

pub fn topLevelUsage(kind: TopLevelKind) []const u8 {
    return command_specs.topLevelUsage(top_level_registry, kind);
}

pub const slash_specs = [_]SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .clear_screen, .command = "/clear", .help_entry = "/clear", .completion_description = "start a fresh conversation while keeping managed processes", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .new_session, .command = "/new", .help_entry = "/new", .completion_description = "start a fresh session", .presentation_category = .session, .show_in_welcome = true },
    .{ .kind = .reset_session, .command = "/reset", .help_entry = "/reset", .completion_description = "reset the current session context", .presentation_category = .session },
    .{ .kind = .resume_session, .command = "/resume", .help_entry = "/resume", .completion_description = "resume a saved session", .presentation_category = .session },

    .{ .kind = .rename_session, .command = "/rename", .help_entry = "/rename <title>", .completion_description = "rename the current session", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .fork_session, .command = "/fork", .help_entry = "/fork", .completion_description = "fork the session before a prompt", .presentation_category = .session },
    .{ .kind = .login, .command = "/login", .help_entry = "/login", .completion_description = "choose the model provider and how it signs in", .presentation_category = .account, .has_args = true },
    .{ .kind = .logout, .command = "/logout", .help_entry = "/logout [vercel|codex|grok]", .completion_description = "sign out of a provider session", .presentation_category = .account, .has_args = true, .accepts_payload = true },
    .{ .kind = .provider, .command = "/provider", .aliases = &.{"/setup"}, .show_aliases_in_completion = false, .help_entry = "/provider", .completion_description = "choose the model provider and how it signs in", .presentation_category = .account, .has_args = true },
    .{ .kind = .stats, .command = "/stats", .help_entry = "/stats", .completion_description = "show token and turn statistics", .presentation_category = .account },
    .{ .kind = .usage, .command = "/usage", .aliases = &.{}, .help_entry = "/usage", .completion_description = "show your provider's usage and spend", .presentation_category = .account },
    .{ .kind = .status, .command = "/status", .help_entry = "/status", .completion_description = "show runtime configuration and the session ID", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .image, .command = "/image", .aliases = &.{"/img"}, .help_entry = "/image <path> (/img)", .completion_description = "attach an image by path", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .images, .command = "/images", .help_entry = "/images [clear]", .completion_description = "manage pending image attachments", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose what model and reasoning effort to use", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .effort, .command = "/effort", .help_entry = "/effort [level]", .completion_description = "choose the reasoning effort for the current model", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .permissions, .command = "/permissions", .help_entry = "/permissions [ask|auto|full-access|reset]", .completion_description = "choose what fx is allowed to do", .presentation_category = .security, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
    .{ .kind = .allowlist, .command = "/allowlist", .help_entry = "/allowlist [view [effective|workspace|global]|[workspace|global] add|remove|reset ...]", .completion_description = "manage trusted commands, tools, and URLs", .presentation_category = .security, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
    .{ .kind = .undo, .command = "/undo", .help_entry = "/undo", .completion_description = "undo the latest tracked file operation", .presentation_category = .session },
    .{ .kind = .mcp, .command = "/mcp", .help_entry = "/mcp [list|show|add|remove|login|logout|approve|reject]", .completion_description = "manage MCP servers and their logins", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .skills, .command = "/skills", .help_entry = "/skills [list|add|install|show|create|remove|path] [name|url|path] ($ opens skill search)", .completion_description = "browse and manage skills", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .copy, .command = "/copy", .help_entry = "/copy", .completion_description = "copy the last assistant response", .presentation_category = .session },
    .{ .kind = .feedback, .command = "/feedback", .help_entry = "/feedback", .completion_description = "open the fx feedback form", .presentation_category = .product, .show_in_welcome = true },
    .{ .kind = .trace, .command = "/trace", .help_entry = "/trace", .completion_description = "copy a private diagnostic trace", .presentation_category = .product },
    .{ .kind = .compact, .command = "/compact", .help_entry = "/compact", .completion_description = "summarize context into a fresh window", .presentation_category = .session },
    .{ .kind = .settings, .command = "/settings", .help_entry = "/settings [startup-scrollback [on|off]]", .completion_description = "browse and update settings", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .alias, .command = "/alias", .aliases = &.{}, .help_entry = "/alias [name] [command]", .completion_description = "show alias availability", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .credits, .command = "/credits", .aliases = &.{"/balance"}, .help_entry = "/credits (/balance)", .completion_description = "show gateway credits balance", .presentation_category = .account, .requires_prompt_credential = true },
    .{ .kind = .paste, .command = "/paste", .help_entry = "/paste", .completion_description = "attach an image from the clipboard when supported", .presentation_category = .media },
    .{ .kind = .fast, .command = "/fast", .help_entry = "/fast [on|off]", .completion_description = "toggle Fast mode when supported", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .ultrafast, .command = "/ultrafast", .help_entry = "/ultrafast [on|off|status]", .completion_description = "request Ultra mode when supported", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .statusline, .command = "/statusline", .help_entry = "/statusline [context|session|workspace]", .completion_description = "toggle status line segments", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .notifications, .command = "/sound", .help_entry = "/sound [on|off|max]", .completion_description = "toggle sounds and terminal bells", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .workspace, .command = "/workspace", .help_entry = "/workspace [list|add PATH|remove PATH|clear]", .completion_description = "manage additional workspace directories", .presentation_category = .workspace, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
    .{ .kind = .shell, .command = "/shell", .help_entry = "/shell reload", .completion_description = "reload shell startup files for commands", .presentation_category = .workspace, .has_args = true, .accepts_payload = true },
    .{ .kind = .version, .command = "/version", .help_entry = "/version", .completion_description = "show the fx version", .presentation_category = .general },
    .{ .kind = .quit, .command = "/quit", .aliases = &.{"/exit"}, .help_entry = "/quit", .completion_description = "exit the interactive shell", .presentation_category = .general, .show_in_welcome = true },
};

pub const slash_registry = SlashRegistry{ .commands = slash_specs[0..] };

pub fn matchesSlashExact(cmd: []const u8, kind: SlashKind) bool {
    return command_specs.matchesSlashExact(slash_registry, cmd, kind);
}

pub fn isExactSlashCommand(cmd: []const u8) bool {
    return slash_registry.matchExact(cmd) != null;
}

pub fn matchedSlashPrefix(cmd: []const u8, kind: SlashKind) ?[]const u8 {
    return command_specs.matchedSlashPrefix(slash_registry, cmd, kind);
}

pub fn renderSlashHelp(alloc: Allocator) ![]u8 {
    return command_specs.renderSlashHelp(alloc, slash_registry);
}

pub fn firstSlashCompletion(prefix: []const u8) ?[]const u8 {
    return command_specs.firstSlashCompletion(slash_registry, prefix);
}

pub fn slashCompletionCount(prefix: []const u8) usize {
    return command_specs.slashCompletionCount(slash_registry, prefix);
}

pub fn nthSlashCompletion(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletion(slash_registry, prefix, n);
}

pub fn nthSlashCompletionLabel(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletionLabel(slash_registry, prefix, n);
}

pub fn nthSlashCompletionDescription(prefix: []const u8, n: usize) ?[]const u8 {
    return command_specs.nthSlashCompletionDescription(slash_registry, prefix, n);
}

pub fn nthSlashCompletionCategory(prefix: []const u8, n: usize) ?SlashPresentationCategory {
    return command_specs.nthSlashCompletionCategory(slash_registry, prefix, n);
}

pub fn slashCompletionHasArgs(command: []const u8) bool {
    return command_specs.slashCompletionHasArgs(slash_registry, command);
}

pub const argCompletionAnchor = command_specs.argCompletionAnchor;

test "fx config help names settings by their current keys" {
    const settings_keys = @import("../core/config/settings_keys.zig");
    const spec = for (top_level_specs) |spec| {
        if (spec.kind == .config) break spec;
    } else unreachable;
    var checked: usize = 0;
    for (spec.details) |line| {
        var words = std.mem.tokenizeAny(u8, line, " ,;:()");
        while (words.next()) |raw| {
            const word = std.mem.trimEnd(u8, raw, ".");
            const dot = std.mem.findScalar(u8, word, '.') orelse continue;
            const key = settings_keys.find(word[0..dot]) orelse continue;
            try std.testing.expectEqualStrings(settings_keys.currentPath(word), word);
            var known = false;
            for (key.children) |child| known = known or std.mem.eql(u8, child, word[dot + 1 ..]);
            try std.testing.expect(known);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 0);
}

test "built-in slash commands register exact active order" {
    const expected_commands = [_][]const u8{
        "/help",
        "/clear",
        "/new",
        "/reset",
        "/resume",
        "/rename",
        "/fork",
        "/login",
        "/logout",
        "/provider",
        "/stats",
        "/usage",
        "/status",
        "/image",
        "/images",
        "/model",
        "/effort",
        "/permissions",
        "/allowlist",
        "/undo",
        "/mcp",
        "/skills",
        "/copy",
        "/feedback",
        "/trace",
        "/compact",
        "/settings",
        "/alias",
        "/credits",
        "/paste",
        "/fast",
        "/ultrafast",
        "/statusline",
        "/sound",
        "/workspace",
        "/shell",
        "/version",
        "/quit",
    };

    try std.testing.expectEqual(expected_commands.len, slash_specs.len);
    for (expected_commands, slash_specs) |expected, spec| {
        try std.testing.expectEqualStrings(expected, spec.command);
    }
}

test "built-in slash registry resolves primary commands and aliases" {
    const image = slash_registry.lookup("/img") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.image, image.kind);

    const usage = slash_registry.lookup("/usage") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.usage, usage.kind);

    const quit = slash_registry.matchExact("/exit\t") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.quit, quit.command.kind);
    try std.testing.expectEqualStrings("/exit", quit.token);

    const model = command_specs.matchedSlashPrefix(slash_registry, "/model\tmodel-id", .model) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/model", model);

    const credits = slash_registry.lookup("/credits") orelse return error.TestExpectedEqual;
    try std.testing.expect(credits.requires_prompt_credential);

    const model_command = slash_registry.lookup("/model") orelse return error.TestExpectedEqual;
    try std.testing.expect(!model_command.requires_prompt_credential);
    try std.testing.expect(slash_registry.lookup("/models") == null);

    try std.testing.expect(command_specs.matchedSlashPrefix(slash_registry, "/model\nmodel-id", .model) == null);
}

test "retired appearance slash commands are not registered" {
    try std.testing.expect(!isExactSlashCommand("/appearance"));
    try std.testing.expect(!isExactSlashCommand("/input"));
    try std.testing.expect(!isExactSlashCommand("/maxxing\t"));
    try std.testing.expect(!isExactSlashCommand("/input lines"));
    try std.testing.expect(!isExactSlashCommand("/unknown"));
}

test "built-in paste completion describes clipboard image attachment" {
    const completion = nthSlashCompletion("/pas", 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/paste", completion);

    const description = nthSlashCompletionDescription("/pas", 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("attach an image from the clipboard when supported", description);
}

test "built-in statusline help and completion include workspace" {
    const help = try renderSlashHelp(std.testing.allocator);
    defer std.testing.allocator.free(help);
    try std.testing.expect(
        std.mem.find(u8, help, "/statusline [context|session|workspace]") != null,
    );

    try std.testing.expectEqualStrings(
        "/statusline workspace",
        nthSlashCompletion("/statusline w", 0).?,
    );
}

test "every launch flag appears in fx --help" {
    const cli_flags = @import("../core/cli/cli_flags.zig");
    outer: for (launch_options) |doc| {
        const name = cli_flags.flagName(doc);
        if (std.mem.eql(u8, name, "--yolo")) continue;
        for (top_level_flags) |flag| {
            var parts = std.mem.splitSequence(u8, flag.usage, ", ");
            while (parts.next()) |part| {
                const end = std.mem.findScalar(u8, part, ' ') orelse part.len;
                if (std.mem.eql(u8, part[0..end], name)) continue :outer;
            }
        }
        std.debug.print("{s} is parsed but missing from top_level_flags\n", .{name});
        return error.TestExpectedEqual;
    }
    // And the other way: help shows no launch flag the parser doesn't read,
    // apart from the resume words, help, and version, which fx reads first.
    for (top_level_flags) |flag| {
        var parts = std.mem.splitSequence(u8, flag.usage, ", ");
        part: while (parts.next()) |part| {
            const name = part[0 .. std.mem.findScalar(u8, part, ' ') orelse part.len];
            for ([_][]const u8{ "-c", "--continue", "-r", "--resume", "-h", "--help", "-v", "--version" }) |early| {
                if (std.mem.eql(u8, name, early)) continue :part;
            }
            for (launch_options) |doc| {
                if (std.mem.eql(u8, cli_flags.flagName(doc), name)) continue :part;
            }
            std.debug.print("{s} is in top_level_flags but the launch parser doesn't read it\n", .{name});
            return error.TestExpectedEqual;
        }
    }
}

test "the launch usage line pairs each --no- spelling with its flag" {
    try std.testing.expect(std.mem.startsWith(u8, launch_usage, "usage: fx [--context-limit <spec>] [--add-dir <path>] [--no-additional-dirs] "));
    try std.testing.expect(std.mem.find(u8, launch_usage, " [--fast|--no-fast] ") != null);
    try std.testing.expect(std.mem.endsWith(u8, launch_usage, " <command>\n"));
}

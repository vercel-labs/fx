const std = @import("std");
const command_specs = @import("../core/slash_commands/command_specs.zig");

const Allocator = std.mem.Allocator;

pub const TopLevelKind = command_specs.TopLevelKind;
pub const TopLevelSpec = command_specs.TopLevelSpec;
pub const TopLevelHelpEntry = command_specs.TopLevelHelpEntry;
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
        .usage = "ask [--auto|--yolo] [--image PATH] [--json] [--quiet] [--prompt-permissions] [--no-save] [--no-color] [--resume <last|id>|--resume-id <id>] [--continue-recovery] [--] <prompt>",
        .summary = "Run one noninteractive request",
        .options = &.{
            .{ .flag = "--auto", .description = "Automatically review unresolved permission requests" },
            .{ .flag = "--yolo", .description = "Disable fx permission checks" },
            .{ .flag = "--image PATH", .description = "Attach an image file; repeat for multiple images" },
            json_option,
            .{ .flag = "--quiet", .description = "Suppress assistant output" },
            .{ .flag = "--prompt-permissions", .description = "Prompt for Y/N permission approval when stdin is a TTY" },
            .{ .flag = "--no-save", .description = "Do not save the session; incompatible with --resume and --resume-id" },
            .{ .flag = "--no-color", .description = "Render TTY output without colors or hyperlinks" },
            .{ .flag = "--resume <last|id>", .description = "Continue the last session or a session by id" },
            .{ .flag = "--resume-id <id>", .description = "Continue a session by exact id" },
            .{ .flag = "--continue-recovery", .description = "Resume the paused model response in the selected session" },
            .{ .flag = "--", .description = "Treat every following argument as prompt text" },
        },
        .details = &.{
            "The prompt may be passed as arguments or piped on stdin when no prompt args are given.",
            "TTY stdout uses the Minimal transcript presentation; redirected stdout emits raw assistant Markdown.",
            "Operational progress and diagnostics are written to stderr. JSON output keeps raw Markdown in `output`.",
            "With --prompt-permissions, JSON and quiet requests may prompt on stderr only when stdin is a TTY.",
        },
    },
    .{
        .kind = .acp,
        .token = "acp",
        .usage = "acp [--model <id>] [--log-file <path>]",
        .summary = "Start an ACP server over stdio",
        .options = &.{
            .{ .flag = "--model <id>", .description = "Override the default model" },
            .{ .flag = "--log-file <path>", .description = "Write ACP logs to a file" },
        },
    },
    .{
        .kind = .pr,
        .token = "pr",
        .usage = "pr [--auto] [--create] [context]",
        .summary = "Draft or publish a pull request",
        .options = &.{
            .{ .flag = "--auto", .description = "Automatically review unresolved permission requests" },
            .{ .flag = "--create", .description = "Publish the drafted pull request via the GitHub CLI" },
        },
        .details = &.{
            "Must run inside a git repository. Without --create, the drafted PR is printed only.",
        },
    },
    .{
        .kind = .issue,
        .token = "issue",
        .usage = "issue [--auto] [--create] [context]",
        .summary = "Draft or publish a GitHub issue",
        .options = &.{
            .{ .flag = "--auto", .description = "Automatically review unresolved permission requests" },
            .{ .flag = "--create", .description = "Publish the drafted issue via the GitHub CLI" },
        },
    },
    .{
        .kind = .login,
        .token = "login",
        .usage = "login [vercel|codex|grok]",
        .summary = "Sign in to Vercel or a selected provider",
    },
    .{
        .kind = .logout,
        .token = "logout",
        .usage = "logout [vercel|codex|grok]",
        .summary = "Sign out of Vercel or a selected provider session",
    },
    .{
        .kind = .setup,
        .token = "setup",
        .usage = "setup",
        .summary = "Configure an AI Gateway API key",
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
            "  ask    Prompt before sensitive tool calls",
            "  auto   Apply rules, then review unresolved sensitive tool calls (default)",
            "  yolo   Disable fx permission checks",
            "",
            "Change the mode from the interactive shell with `/permissions [ask|auto|yolo|reset]`,",
            "and manage persistent allow rules with `/allowlist`.",
        },
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
        .usage = "provider <gateway|codex|grok>",
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
        .kind = .background,
        .token = "background",
        .usage = "background [last|<id>] [--json]",
        .summary = "List or inspect background commands",
        .options = &.{
            .{ .flag = "last", .description = "Inspect the most recent background command" },
            .{ .flag = "<id>", .description = "Inspect a background command by id" },
            json_option,
        },
        .details = &.{
            "With no target, lists the persisted background command history.",
        },
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
        .usage = "session <last|id>|--id <id> [--json] | session resume [last|<id>] [--record] | session resume --id <id> [--record] | session migrate <id>|--id <id> [--allow-large] [--json] | session recover <id>|--id <id> [--json]",
        .summary = "Inspect, resume, migrate, or recover saved sessions",
        .options = &.{
            .{ .flag = "last", .description = "Inspect the current workspace session" },
            .{ .flag = "--id <id>", .description = "Inspect a saved session by exact id" },
            .{ .flag = "resume [last|<id>]", .description = "Resume the latest workspace session or a session by id" },
            .{ .flag = "migrate <id>", .description = "Migrate a saved session to the current format" },
            .{ .flag = "recover <id>", .description = "Copy a recoverable corrupt session into a new session" },
            .{ .flag = "--allow-large", .description = "Permit migrating an oversized session" },
            json_option,
        },
    },
    .{
        .kind = .sessions,
        .token = "sessions",
        .usage = "sessions [--all] [--limit <1-100>] [--cursor <cursor>] [--json]",
        .summary = "List saved sessions for the current workspace",
        .options = &.{
            .{ .flag = "--all", .description = "List saved sessions across every workspace in this profile" },
            .{ .flag = "--limit <1-100>", .description = "Set the maximum sessions returned per page" },
            .{ .flag = "--cursor <cursor>", .description = "Continue from a prior sessions result" },
            json_option,
        },
    },
    .{
        .kind = .@"resume",
        .token = "resume",
        .aliases = &.{ "--resume", "--resume-last", "--continue", "-c", "-r" },
        .hidden_from_top_level_help = true,
        .usage = "session resume [last|<id>] [--record] | session resume --id <id> [--record] | --resume [last|<id>] [--record] | resume [last|<id>] [--record] | resume --id <id> [--record] | --resume-last | --continue | -c | -r | --resume-<id>",
        .summary = "Continue a saved interactive session",
        .options = &.{
            .{ .flag = "-r", .description = "Choose the session to resume from a picker" },
            .{ .flag = "last", .description = "Resume the most recent session" },
            .{ .flag = "<id>", .description = "Resume a session by id" },
            .{ .flag = "--id <id>", .description = "Resume a session by exact id" },
            .{ .flag = "--record", .description = "Capture visible terminal content while running" },
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
        .usage = "usage [--period <24h|7d|30d>] [--json]",
        .summary = "Show local fx token usage and spend",
        .options = &.{
            .{ .flag = "--period <24h|7d|30d>", .description = "Select a rolling window (default: 30d)" },
            json_option,
        },
        .details = &.{
            "Reports only usage recorded by fx on this machine.",
            "This command reads local state and does not query account-wide Gateway reports.",
        },
    },
    .{
        .kind = .upgrade,
        .token = "upgrade",
        .usage = "upgrade [--channel <stable|dev>] [--json]",
        .summary = "Upgrade 𝒇x on the selected release channel",
        .options = &.{
            .{ .flag = "--channel <stable|dev>", .description = "Select and remember the release channel" },
            json_option,
        },
    },
    .{
        .kind = .replay,
        .token = "replay",
        .usage = "replay <tape> [--frames] [--json] [--golden <path>] [--frames-dir <path>]",
        .summary = "Replay a recorded terminal session",
        .options = &.{
            .{ .flag = "--frames", .description = "Render each captured frame" },
            .{ .flag = "--golden <path>", .description = "Write the final rendered grid to a file" },
            .{ .flag = "--frames-dir <path>", .description = "Write rendered frames to a directory" },
            json_option,
        },
    },
    .{
        .kind = .workspace,
        .token = "workspace",
        .usage = "workspace [list|add PATH|remove PATH|clear] [--json]",
        .summary = "Manage additional workspace directories",
        .options = &.{
            .{ .flag = "list", .description = "List the primary and additional directories (default)" },
            .{ .flag = "add PATH", .description = "Persist an existing additional directory" },
            .{ .flag = "remove PATH", .description = "Remove an additional directory" },
            .{ .flag = "clear", .description = "Remove all additional directories" },
            json_option,
        },
        .details = &.{
            "Additional directories are stored for the current primary workspace.",
        },
    },
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
        .{ .kind = .background, .usage = "background [last|<id>]" },
    } },
    .{ .entries = &.{
        .{ .kind = .sessions, .usage = "sessions" },
        .{ .kind = .session, .usage = "session <last|id>" },
        .{ .usage = "session resume [last|id]", .summary = "Resume the latest workspace session or a session by id" },
        .{ .usage = "session migrate <id>", .summary = "Migrate a saved session to the current format" },
        .{ .usage = "session recover <id>", .summary = "Copy a recoverable corrupt session" },
        .{ .kind = .replay, .usage = "replay <tape>" },
    } },
    .{ .entries = &.{
        .{ .kind = .login, .usage = "login [vercel|codex|grok]" },
        .{ .kind = .logout, .usage = "logout [vercel|codex|grok]" },
        .{ .kind = .provider, .usage = "provider <gateway|codex|grok>" },
        .{ .kind = .setup, .usage = "setup" },
        .{ .kind = .teams, .usage = "teams" },
        .{ .kind = .credits, .usage = "credits|balance" },
        .{ .kind = .usage, .usage = "usage [--period <24h|7d|30d>]" },
    } },
    .{ .entries = &.{
        .{ .kind = .status, .usage = "status" },
        .{ .kind = .doctor, .usage = "doctor" },
        .{ .kind = .models, .usage = "models" },
        .{ .kind = .permissions, .usage = "permissions" },
        .{ .kind = .workspace, .usage = "workspace" },
        .{ .kind = .upgrade, .usage = "upgrade" },
        .{ .kind = .acp, .usage = "acp" },
        .{ .kind = .help, .usage = "help" },
    } },
};

pub const top_level_flags = [_]TopLevelFlag{
    .{
        .usage = "--record",
        .description = "Record terminal output",
    },
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
        .usage = "-c, --continue",
        .description = "Resume the latest workspace session",
    },
    .{
        .usage = "-r",
        .description = "Open the saved-session picker",
    },
    .{
        .usage = "--resume [last|<id>]",
        .description = "Resume the latest workspace session or an exact ID",
    },
    .{
        .usage = "--resume-last",
        .description = "Resume the latest workspace session",
    },
    .{
        .usage = "--resume-<id>",
        .description = "Resume a session by exact ID",
    },
    .{
        .usage = "-h, --help",
        .description = "Display this help and exit",
    },
    .{
        .usage = "-v, --version",
        .description = "Print the 𝒇x version and exit",
    },
};

pub const top_level_examples = [_]TopLevelExample{
    .{ .command = "fx", .description = "Start a fresh interactive session" },
    .{ .command = "fx ask \"Explain the changes in this repository\"", .description = "Run one request and exit" },
    .{ .command = "fx session resume last", .description = "Continue the latest session for this workspace" },
    .{ .command = "fx status --json", .description = "Inspect the current configuration as JSON" },
};

pub const top_level_notes = [_][]const u8{
    "Run `fx <command> --help` for command-specific options and examples.",
    "Run `/help` inside an interactive session for slash commands.",
};

pub const top_level_resources = [_]TopLevelResource{
    .{ .label = "Learn more about 𝒇x:", .value = "https://fx.sh/docs", .link = true },
    .{ .label = "Report a problem:", .value = "run `/feedback` inside 𝒇x" },
};

pub const top_level_registry = TopLevelRegistry{
    .specs = top_level_specs[0..],
    .description = "Fast, native coding agent for the terminal.",
    .interactive_hint = "𝒇x starts an interactive session by default. Use `fx ask` to run one noninteractive request.",
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
    .{ .kind = .clear_screen, .command = "/clear", .help_entry = "/clear", .completion_description = "start a fresh session and keep background processes", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .new_session, .command = "/new", .help_entry = "/new", .completion_description = "start a fresh session", .presentation_category = .session, .show_in_welcome = true },
    .{ .kind = .reset_session, .command = "/reset", .help_entry = "/reset", .completion_description = "reset the current session context", .presentation_category = .session },
    .{ .kind = .resume_session, .command = "/resume", .help_entry = "/resume", .completion_description = "resume a saved session", .presentation_category = .session },
    .{ .kind = .continue_recovery, .command = "/continue", .help_entry = "/continue", .completion_description = "continue a paused model response", .presentation_category = .session, .requires_prompt_credential = true },
    .{ .kind = .rename_session, .command = "/rename", .help_entry = "/rename <title>", .completion_description = "rename the current session", .presentation_category = .session, .has_args = true, .accepts_payload = true },
    .{ .kind = .login, .command = "/login", .help_entry = "/login", .completion_description = "choose Vercel or Codex sign-in", .presentation_category = .account },
    .{ .kind = .logout, .command = "/logout", .help_entry = "/logout [vercel|codex|grok]", .completion_description = "sign out of a provider session", .presentation_category = .account, .has_args = true, .accepts_payload = true },
    .{ .kind = .setup, .command = "/setup", .help_entry = "/setup", .completion_description = "manage accounts and AI Gateway access", .presentation_category = .account },
    .{ .kind = .stats, .command = "/stats", .help_entry = "/stats", .completion_description = "show token and turn statistics", .presentation_category = .account },
    .{ .kind = .usage, .command = "/usage", .aliases = &.{"/cost"}, .help_entry = "/usage (/cost)", .completion_description = "show local fx tokens, models, and spend", .presentation_category = .account },
    .{ .kind = .status, .command = "/status", .help_entry = "/status", .completion_description = "show runtime configuration", .presentation_category = .general, .show_in_welcome = true },
    .{ .kind = .background, .command = "/background", .help_entry = "/background [open|logs|stop <id|last>]", .completion_description = "inspect background command history", .presentation_category = .agents, .show_in_welcome = true, .has_args = true },
    .{ .kind = .background_stop, .command = "/background stop", .accepts_payload = true },
    .{ .kind = .background_open, .command = "/background open", .accepts_payload = true },
    .{ .kind = .background_logs, .command = "/background logs", .accepts_payload = true },
    .{ .kind = .image, .command = "/image", .aliases = &.{"/img"}, .help_entry = "/image <path> (/img)", .completion_description = "attach an image by path", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .images, .command = "/images", .help_entry = "/images [clear]", .completion_description = "manage pending image attachments", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose what model and reasoning effort to use", .presentation_category = .model, .has_args = true, .accepts_payload = true },
    .{ .kind = .models, .command = "/models", .help_entry = "/models", .completion_description = "browse available models", .presentation_category = .model },
    .{ .kind = .permissions, .command = "/permissions", .help_entry = "/permissions [ask|auto|yolo|reset]", .completion_description = "choose what fx is allowed to do", .presentation_category = .security, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
    .{ .kind = .allowlist, .command = "/allowlist", .help_entry = "/allowlist [view [effective|local|user]|[local|user] add|remove|reset ...]", .completion_description = "manage trusted commands, tools, and URLs", .presentation_category = .security, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
    .{ .kind = .undo, .command = "/undo", .help_entry = "/undo", .completion_description = "undo the latest tracked file operation", .presentation_category = .session },
    .{ .kind = .mcp, .command = "/mcp", .help_entry = "/mcp [list|resource|prompt|add|remove|path|reload|auth|logout]", .completion_description = "manage MCP servers, resources, and prompts", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .acp, .command = "/acp", .help_entry = "/acp [list|add|remove|run|path]", .completion_description = "manage ACP agent CLIs and run turns against them", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .skills, .command = "/skills", .help_entry = "/skills [list|add|install|show|create|remove|path] [name|url|path] ($ opens skill search)", .completion_description = "browse and manage skills", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .copy, .command = "/copy", .help_entry = "/copy", .completion_description = "copy the last assistant response", .presentation_category = .session },
    .{ .kind = .feedback, .command = "/feedback", .help_entry = "/feedback", .completion_description = "open the fx feedback form", .presentation_category = .product, .show_in_welcome = true },
    .{ .kind = .trace, .command = "/trace", .help_entry = "/trace", .completion_description = "copy a private diagnostic trace", .presentation_category = .product },
    .{ .kind = .compact, .command = "/compact", .help_entry = "/compact", .completion_description = "compact older conversation turns", .presentation_category = .session },
    .{ .kind = .settings, .command = "/settings", .help_entry = "/settings [startup-scrollback [on|off]]", .completion_description = "browse and update settings", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .alias, .command = "/alias", .aliases = &.{}, .help_entry = "/alias [name] [command]", .completion_description = "show alias availability", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .credits, .command = "/credits", .aliases = &.{"/balance"}, .help_entry = "/credits (/balance)", .completion_description = "show gateway credits balance", .presentation_category = .account, .requires_prompt_credential = true },
    .{ .kind = .paste, .command = "/paste", .help_entry = "/paste", .completion_description = "attach an image from the clipboard when supported", .presentation_category = .media },
    .{ .kind = .fast, .command = "/fast", .help_entry = "/fast", .completion_description = "toggle Fast mode when supported", .presentation_category = .model },
    .{ .kind = .appearance, .command = "/appearance", .aliases = &.{ "/input", "/maxxing" }, .show_aliases_in_completion = false, .help_entry = "/appearance [input lines|tint|presentation normal|minimal]", .completion_description = "choose input and transcript presentation", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .statusline, .command = "/statusline", .help_entry = "/statusline [context|session|workspace]", .completion_description = "toggle status line segments", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .notifications, .command = "/sound", .help_entry = "/sound [on|off|max]", .completion_description = "toggle sounds and terminal bells", .presentation_category = .appearance, .has_args = true, .accepts_payload = true },
    .{ .kind = .workspace, .command = "/workspace", .help_entry = "/workspace [list|add PATH|remove PATH|clear]", .completion_description = "manage additional workspace directories", .presentation_category = .workspace, .show_in_welcome = true, .has_args = true, .accepts_payload = true },
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

pub fn renderSlashWelcome(alloc: Allocator) ![]u8 {
    return command_specs.renderSlashWelcome(alloc, slash_registry);
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
pub const argCompletionIndexForLabel = command_specs.argCompletionIndexForLabel;
pub const allowlistArgCompletionPrefix = command_specs.allowlistArgCompletionPrefix;
pub const appearanceArgCompletionPrefix = command_specs.appearanceArgCompletionPrefix;
pub const inputArgCompletionPrefix = command_specs.inputArgCompletionPrefix;
pub const maxxingArgCompletionPrefix = command_specs.maxxingArgCompletionPrefix;
pub const statuslineArgCompletionPrefix = command_specs.statuslineArgCompletionPrefix;
pub const notificationsArgCompletionPrefix = command_specs.notificationsArgCompletionPrefix;
pub const permissionsArgCompletionPrefix = command_specs.permissionsArgCompletionPrefix;

test "built-in slash commands register exact active order" {
    const expected_commands = [_][]const u8{
        "/help",
        "/clear",
        "/new",
        "/reset",
        "/resume",
        "/continue",
        "/rename",
        "/login",
        "/logout",
        "/setup",
        "/stats",
        "/usage",
        "/status",
        "/background",
        "/background stop",
        "/background open",
        "/background logs",
        "/image",
        "/images",
        "/model",
        "/models",
        "/permissions",
        "/allowlist",
        "/undo",
        "/mcp",
        "/acp",
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
        "/appearance",
        "/statusline",
        "/sound",
        "/workspace",
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

    for ([_][]const u8{ "/model", "/models" }) |command| {
        const catalog_command = slash_registry.lookup(command) orelse return error.TestExpectedEqual;
        try std.testing.expect(!catalog_command.requires_prompt_credential);
    }

    try std.testing.expect(command_specs.matchedSlashPrefix(slash_registry, "/model\nmodel-id", .model) == null);
}

test "exact slash command matching includes hidden completion aliases" {
    try std.testing.expect(isExactSlashCommand("/appearance"));
    try std.testing.expect(isExactSlashCommand("/input"));
    try std.testing.expect(isExactSlashCommand("/maxxing\t"));
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

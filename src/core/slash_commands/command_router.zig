const std = @import("std");
const command_specs = @import("command_specs.zig");

const SlashKind = command_specs.SlashKind;
const SlashRegistry = command_specs.SlashRegistry;
const SlashSpec = command_specs.SlashSpec;

/// A `.custom` command is addressed by its position in the registry that parsed
/// it. An index survives a registry replacement as a value that can be range
/// checked, where a borrowed spec pointer would dangle.
pub const CustomInvocation = struct {
    index: usize,
    args: []const u8,
};

pub const ParsedCommand = union(enum) {
    quit,
    clear_screen,
    new_session,
    reset_session,
    resume_session,
    continue_recovery,
    rename_session: []const u8,
    help,
    login,
    logout: []const u8,
    setup,
    status,
    background,
    background_stop: []const u8,
    background_open: []const u8,
    background_logs: []const u8,
    image: []const u8,
    images: []const u8,
    model: []const u8,
    permissions: []const u8,
    allowlist: []const u8,
    stats,
    usage,
    undo,
    mcp: []const u8,
    skills: []const u8,
    copy,
    feedback,
    trace,
    compact,
    settings: []const u8,
    alias: []const u8,
    credits,
    paste,
    fast,
    statusline: []const u8,
    notifications: []const u8,
    workspace: []const u8,
    version,
    custom: CustomInvocation,
    unknown,
};

pub const CommandHandlers = struct {
    ctx: *anyopaque,
    quit: *const fn (ctx: *anyopaque) anyerror!void,
    clear_screen: *const fn (ctx: *anyopaque) anyerror!void,
    new_session: *const fn (ctx: *anyopaque) anyerror!void,
    reset_session: *const fn (ctx: *anyopaque) anyerror!void,
    resume_session: *const fn (ctx: *anyopaque) anyerror!void,
    continue_recovery: *const fn (ctx: *anyopaque) anyerror!void,
    show_help: *const fn (ctx: *anyopaque) anyerror!void,
    login: *const fn (ctx: *anyopaque) anyerror!void,
    logout: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    setup: *const fn (ctx: *anyopaque) anyerror!void,
    show_status: *const fn (ctx: *anyopaque) anyerror!void,
    show_background: *const fn (ctx: *anyopaque) anyerror!void,
    stop_background: *const fn (ctx: *anyopaque, target: []const u8) anyerror!void,
    open_background: *const fn (ctx: *anyopaque, target: []const u8) anyerror!void,
    show_background_logs: *const fn (ctx: *anyopaque, target: []const u8) anyerror!void,
    attach_image: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    manage_images: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_model: *const fn (ctx: *anyopaque, query: []const u8) anyerror!void,
    handle_permissions: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_allowlist: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_stats: *const fn (ctx: *anyopaque) anyerror!void,
    show_usage: *const fn (ctx: *anyopaque) anyerror!void,
    undo_last: *const fn (ctx: *anyopaque) anyerror!void,
    handle_mcp: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_skills: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    copy_last: *const fn (ctx: *anyopaque) anyerror!void,
    submit_feedback: *const fn (ctx: *anyopaque) anyerror!void,
    create_trace: *const fn (ctx: *anyopaque) anyerror!void,
    compact_history: *const fn (ctx: *anyopaque) anyerror!void,
    handle_settings: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_alias: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_credits: *const fn (ctx: *anyopaque) anyerror!void,
    paste_clipboard: *const fn (ctx: *anyopaque) anyerror!void,
    toggle_fast: *const fn (ctx: *anyopaque) anyerror!void,
    handle_statusline: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    rename_session: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_notifications: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    handle_workspace: *const fn (ctx: *anyopaque, rest: []const u8) anyerror!void,
    show_version: *const fn (ctx: *anyopaque) anyerror!void,
    run_custom: *const fn (ctx: *anyopaque, index: usize, args: []const u8) anyerror!void,
    unknown: *const fn (ctx: *anyopaque, cmd: []const u8) anyerror!void,
};

fn command_payload(cmd: []const u8, prefix: []const u8) []const u8 {
    return std.mem.trim(u8, cmd[prefix.len..], " \t");
}

fn parsedCommand(kind: SlashKind, index: usize, payload: []const u8) ParsedCommand {
    return switch (kind) {
        .quit => .quit,
        .clear_screen => .clear_screen,
        .new_session => .new_session,
        .reset_session => .reset_session,
        .resume_session => .resume_session,
        .continue_recovery => .continue_recovery,
        .rename_session => .{ .rename_session = payload },
        .help => .help,
        .login => .login,
        .logout => .{ .logout = payload },
        .setup => .setup,
        .status => .status,
        .background => .background,
        .background_stop => .{ .background_stop = payload },
        .background_open => .{ .background_open = payload },
        .background_logs => .{ .background_logs = payload },
        .images => .{ .images = payload },
        .image => .{ .image = payload },
        .model => .{ .model = payload },
        .permissions => .{ .permissions = payload },
        .allowlist => .{ .allowlist = payload },
        .stats => .stats,
        .usage => .usage,
        .undo => .undo,
        .mcp => .{ .mcp = payload },
        .skills => .{ .skills = payload },
        .copy => .copy,
        .feedback => .feedback,
        .trace => .trace,
        .compact => .compact,
        .settings => .{ .settings = payload },
        .alias => .{ .alias = payload },
        .credits => .credits,
        .paste => .paste,
        .fast => .fast,
        .statusline => .{ .statusline = payload },
        .notifications => .{ .notifications = payload },
        .workspace => .{ .workspace = payload },
        .version => .version,
        .custom => .{ .custom = .{ .index = index, .args = payload } },
    };
}

/// Exact match anchored on `spec` rather than on its kind. `matchExact` returns
/// the first registry entry carrying the token, so an entry that duplicates an
/// earlier token never wins here.
fn matchesSpecExact(registry: SlashRegistry, cmd: []const u8, spec: *const SlashSpec) bool {
    const matched = registry.matchExact(cmd) orelse return false;
    return matched.command == spec;
}

/// Matches against the entry being iterated, by identity. Resolving a kind back
/// to a spec would collapse every entry sharing a kind onto the first one.
pub fn parse(registry: SlashRegistry, cmd: []const u8) ParsedCommand {
    for (registry.commands, 0..) |*spec, index| {
        if (spec.accepts_payload) {
            if (registry.matchEntryPrefix(cmd, spec)) |prefix| {
                return parsedCommand(spec.kind, index, command_payload(cmd, prefix));
            }
        } else if (matchesSpecExact(registry, cmd, spec)) {
            return parsedCommand(spec.kind, index, "");
        }
    }
    return .unknown;
}

pub fn route(registry: SlashRegistry, handlers: *const CommandHandlers, cmd: []const u8) !void {
    switch (parse(registry, cmd)) {
        .quit => try handlers.quit(handlers.ctx),
        .clear_screen => try handlers.clear_screen(handlers.ctx),
        .new_session => try handlers.new_session(handlers.ctx),
        .reset_session => try handlers.reset_session(handlers.ctx),
        .resume_session => try handlers.resume_session(handlers.ctx),
        .continue_recovery => try handlers.continue_recovery(handlers.ctx),
        .rename_session => |rest| try handlers.rename_session(handlers.ctx, rest),
        .help => try handlers.show_help(handlers.ctx),
        .login => try handlers.login(handlers.ctx),
        .logout => |rest| try handlers.logout(handlers.ctx, rest),
        .setup => try handlers.setup(handlers.ctx),
        .status => try handlers.show_status(handlers.ctx),
        .background => try handlers.show_background(handlers.ctx),
        .background_stop => |target| try handlers.stop_background(handlers.ctx, target),
        .background_open => |target| try handlers.open_background(handlers.ctx, target),
        .background_logs => |target| try handlers.show_background_logs(handlers.ctx, target),
        .image => |path| try handlers.attach_image(handlers.ctx, path),
        .images => |rest| try handlers.manage_images(handlers.ctx, rest),
        .model => |query| try handlers.handle_model(handlers.ctx, query),
        .permissions => |rest| try handlers.handle_permissions(handlers.ctx, rest),
        .allowlist => |rest| try handlers.handle_allowlist(handlers.ctx, rest),
        .stats => try handlers.show_stats(handlers.ctx),
        .usage => try handlers.show_usage(handlers.ctx),
        .undo => try handlers.undo_last(handlers.ctx),
        .mcp => |rest| try handlers.handle_mcp(handlers.ctx, rest),
        .skills => |rest| try handlers.handle_skills(handlers.ctx, rest),
        .copy => try handlers.copy_last(handlers.ctx),
        .feedback => try handlers.submit_feedback(handlers.ctx),
        .trace => try handlers.create_trace(handlers.ctx),
        .compact => try handlers.compact_history(handlers.ctx),
        .settings => |rest| try handlers.handle_settings(handlers.ctx, rest),
        .alias => |rest| try handlers.handle_alias(handlers.ctx, rest),
        .credits => try handlers.show_credits(handlers.ctx),
        .paste => try handlers.paste_clipboard(handlers.ctx),
        .fast => try handlers.toggle_fast(handlers.ctx),
        .statusline => |rest| try handlers.handle_statusline(handlers.ctx, rest),
        .notifications => |rest| try handlers.handle_notifications(handlers.ctx, rest),
        .workspace => |rest| try handlers.handle_workspace(handlers.ctx, rest),
        .version => try handlers.show_version(handlers.ctx),
        .custom => |invocation| try handlers.run_custom(handlers.ctx, invocation.index, invocation.args),
        .unknown => try handlers.unknown(handlers.ctx, cmd),
    }
}

fn testSlashRegistry() SlashRegistry {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.slash_registry;
}

test "parse extracts model command payload" {
    const parsed = parse(testSlashRegistry(), "/model claude-opus");
    switch (parsed) {
        .model => |query| try std.testing.expectEqualStrings("claude-opus", query),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts an optional logout provider" {
    switch (parse(testSlashRegistry(), "/logout chatgpt")) {
        .logout => |provider| try std.testing.expectEqualStrings("chatgpt", provider),
        else => return error.TestExpectedLogoutCommand,
    }
}

test "parse rejects removed plural model command" {
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/models"));
}

test "parse leaves provider selection to setup" {
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/provider codex"));
}

test "parse extracts allowlist command payload" {
    switch (parse(testSlashRegistry(), "/allowlist add command \"git *\"")) {
        .allowlist => |rest| try std.testing.expectEqualStrings("add command \"git *\"", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts sound command payload" {
    switch (parse(testSlashRegistry(), "/sound off")) {
        .notifications => |rest| try std.testing.expectEqualStrings("off", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/sound")) {
        .notifications => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse distinguishes new and reset lifecycle commands" {
    try std.testing.expectEqual(ParsedCommand.new_session, parse(testSlashRegistry(), "/new"));
    try std.testing.expectEqual(ParsedCommand.reset_session, parse(testSlashRegistry(), "/reset"));
}

test "parse recognizes interactive resume" {
    try std.testing.expectEqual(ParsedCommand.resume_session, parse(testSlashRegistry(), "/resume"));
}

test "parse recognizes explicit recovery continuation" {
    try std.testing.expectEqual(ParsedCommand.continue_recovery, parse(testSlashRegistry(), "/continue"));
}

test "parse recognizes logout" {
    switch (parse(testSlashRegistry(), "/logout")) {
        .unknown => return error.TestExpectedLogoutCommand,
        else => {},
    }
}

test "parse rejects removed slash commands" {
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/pr ready for review"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/issue flaky test"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/changes"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/review"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/history"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/rules"));
}

test "parse extracts background stop target" {
    const parsed = parse(testSlashRegistry(), "/background stop last");
    switch (parsed) {
        .background_stop => |target| try std.testing.expectEqualStrings("last", target),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts background open and logs targets" {
    switch (parse(testSlashRegistry(), "/background open 3")) {
        .background_open => |target| try std.testing.expectEqualStrings("3", target),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/background logs last")) {
        .background_logs => |target| try std.testing.expectEqualStrings("last", target),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts image commands" {
    switch (parse(testSlashRegistry(), "/image screenshot.png")) {
        .image => |path| try std.testing.expectEqualStrings("screenshot.png", path),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/img screenshot.png")) {
        .image => |path| try std.testing.expectEqualStrings("screenshot.png", path),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/images clear")) {
        .images => |rest| try std.testing.expectEqualStrings("clear", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts mcp command payload" {
    switch (parse(testSlashRegistry(), "/mcp add everything npx -y @modelcontextprotocol/server-everything")) {
        .mcp => |rest| try std.testing.expectEqualStrings("add everything npx -y @modelcontextprotocol/server-everything", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse recognizes exact no-payload commands" {
    try std.testing.expectEqual(ParsedCommand.copy, parse(testSlashRegistry(), "/copy"));
    try std.testing.expectEqual(ParsedCommand.feedback, parse(testSlashRegistry(), "/feedback"));
    try std.testing.expectEqual(ParsedCommand.trace, parse(testSlashRegistry(), "/trace"));
    try std.testing.expectEqual(ParsedCommand.compact, parse(testSlashRegistry(), "/compact"));
    try std.testing.expectEqual(ParsedCommand.credits, parse(testSlashRegistry(), "/credits"));
    try std.testing.expectEqual(ParsedCommand.credits, parse(testSlashRegistry(), "/balance"));
    try std.testing.expectEqual(ParsedCommand.paste, parse(testSlashRegistry(), "/paste"));
    try std.testing.expectEqual(ParsedCommand.fast, parse(testSlashRegistry(), "/fast"));
    try std.testing.expectEqual(ParsedCommand.version, parse(testSlashRegistry(), "/version"));
}

test "parse extracts settings command payload" {
    switch (parse(testSlashRegistry(), "/settings")) {
        .settings => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/settings startup-scrollback")) {
        .settings => |rest| try std.testing.expectEqualStrings("startup-scrollback", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/settings startup-scrollback off")) {
        .settings => |rest| try std.testing.expectEqualStrings("startup-scrollback off", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse extracts alias payload" {
    switch (parse(testSlashRegistry(), "/alias build zig build")) {
        .alias => |rest| try std.testing.expectEqualStrings("build zig build", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse treats unknown and malformed command inputs as unknown" {
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/wat"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/output"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/output quiet"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/task"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/tasks"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/subagents"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "hello"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/copy extra"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), " /model claude-opus"));
}

test "parse tolerates trailing whitespace on exact-match commands" {
    try std.testing.expectEqual(ParsedCommand.quit, parse(testSlashRegistry(), "/exit "));
    try std.testing.expectEqual(ParsedCommand.quit, parse(testSlashRegistry(), "/quit  "));
    try std.testing.expectEqual(ParsedCommand.quit, parse(testSlashRegistry(), "/exit \t"));
    try std.testing.expectEqual(ParsedCommand.help, parse(testSlashRegistry(), "/help "));
    try std.testing.expectEqual(ParsedCommand.copy, parse(testSlashRegistry(), "/copy "));
    try std.testing.expectEqual(ParsedCommand.clear_screen, parse(testSlashRegistry(), "/clear\t"));
}

test "parse returns empty payload for bare prefix commands" {
    switch (parse(testSlashRegistry(), "/model")) {
        .model => |query| try std.testing.expectEqualStrings("", query),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/mcp")) {
        .mcp => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/allowlist")) {
        .allowlist => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
    switch (parse(testSlashRegistry(), "/skills")) {
        .skills => |rest| try std.testing.expectEqualStrings("", rest),
        else => return error.TestExpectedEqual,
    }
}

test "parse trims only spaces and tabs around payload" {
    switch (parse(testSlashRegistry(), "/model \t claude-opus \t")) {
        .model => |query| try std.testing.expectEqualStrings("claude-opus", query),
        else => return error.TestExpectedEqual,
    }
}

const ParseBaselineCase = struct {
    input: []const u8,
    tag: []const u8,
};

/// Captured from the kind-based parser before it was anchored on spec identity.
/// Two rows per token: bare, and followed by a payload.
const builtin_parse_baseline = [_]ParseBaselineCase{
    .{ .input = "/help", .tag = "help" },
    .{ .input = "/help sample", .tag = "unknown" },
    .{ .input = "/clear", .tag = "clear_screen" },
    .{ .input = "/clear sample", .tag = "unknown" },
    .{ .input = "/new", .tag = "new_session" },
    .{ .input = "/new sample", .tag = "unknown" },
    .{ .input = "/reset", .tag = "reset_session" },
    .{ .input = "/reset sample", .tag = "unknown" },
    .{ .input = "/resume", .tag = "resume_session" },
    .{ .input = "/resume sample", .tag = "unknown" },
    .{ .input = "/continue", .tag = "continue_recovery" },
    .{ .input = "/continue sample", .tag = "unknown" },
    .{ .input = "/rename", .tag = "rename_session" },
    .{ .input = "/rename sample", .tag = "rename_session" },
    .{ .input = "/login", .tag = "login" },
    .{ .input = "/login sample", .tag = "unknown" },
    .{ .input = "/logout", .tag = "logout" },
    .{ .input = "/logout sample", .tag = "logout" },
    .{ .input = "/setup", .tag = "setup" },
    .{ .input = "/setup sample", .tag = "unknown" },
    .{ .input = "/stats", .tag = "stats" },
    .{ .input = "/stats sample", .tag = "unknown" },
    .{ .input = "/usage", .tag = "usage" },
    .{ .input = "/usage sample", .tag = "unknown" },
    .{ .input = "/cost", .tag = "usage" },
    .{ .input = "/cost sample", .tag = "unknown" },
    .{ .input = "/status", .tag = "status" },
    .{ .input = "/status sample", .tag = "unknown" },
    .{ .input = "/background", .tag = "background" },
    .{ .input = "/background sample", .tag = "unknown" },
    .{ .input = "/background stop", .tag = "background_stop" },
    .{ .input = "/background stop sample", .tag = "background_stop" },
    .{ .input = "/background open", .tag = "background_open" },
    .{ .input = "/background open sample", .tag = "background_open" },
    .{ .input = "/background logs", .tag = "background_logs" },
    .{ .input = "/background logs sample", .tag = "background_logs" },
    .{ .input = "/image", .tag = "image" },
    .{ .input = "/image sample", .tag = "image" },
    .{ .input = "/img", .tag = "image" },
    .{ .input = "/img sample", .tag = "image" },
    .{ .input = "/images", .tag = "images" },
    .{ .input = "/images sample", .tag = "images" },
    .{ .input = "/model", .tag = "model" },
    .{ .input = "/model sample", .tag = "model" },
    .{ .input = "/models", .tag = "models" },
    .{ .input = "/models sample", .tag = "unknown" },
    .{ .input = "/permissions", .tag = "permissions" },
    .{ .input = "/permissions sample", .tag = "permissions" },
    .{ .input = "/allowlist", .tag = "allowlist" },
    .{ .input = "/allowlist sample", .tag = "allowlist" },
    .{ .input = "/undo", .tag = "undo" },
    .{ .input = "/undo sample", .tag = "unknown" },
    .{ .input = "/mcp", .tag = "mcp" },
    .{ .input = "/mcp sample", .tag = "mcp" },
    .{ .input = "/skills", .tag = "skills" },
    .{ .input = "/skills sample", .tag = "skills" },
    .{ .input = "/copy", .tag = "copy" },
    .{ .input = "/copy sample", .tag = "unknown" },
    .{ .input = "/feedback", .tag = "feedback" },
    .{ .input = "/feedback sample", .tag = "unknown" },
    .{ .input = "/trace", .tag = "trace" },
    .{ .input = "/trace sample", .tag = "unknown" },
    .{ .input = "/compact", .tag = "compact" },
    .{ .input = "/compact sample", .tag = "unknown" },
    .{ .input = "/settings", .tag = "settings" },
    .{ .input = "/settings sample", .tag = "settings" },
    .{ .input = "/alias", .tag = "alias" },
    .{ .input = "/alias sample", .tag = "alias" },
    .{ .input = "/credits", .tag = "credits" },
    .{ .input = "/credits sample", .tag = "unknown" },
    .{ .input = "/balance", .tag = "credits" },
    .{ .input = "/balance sample", .tag = "unknown" },
    .{ .input = "/paste", .tag = "paste" },
    .{ .input = "/paste sample", .tag = "unknown" },
    .{ .input = "/fast", .tag = "fast" },
    .{ .input = "/fast sample", .tag = "unknown" },
    .{ .input = "/statusline", .tag = "statusline" },
    .{ .input = "/statusline sample", .tag = "statusline" },
    .{ .input = "/sound", .tag = "notifications" },
    .{ .input = "/sound sample", .tag = "notifications" },
    .{ .input = "/workspace", .tag = "workspace" },
    .{ .input = "/workspace sample", .tag = "workspace" },
    .{ .input = "/version", .tag = "version" },
    .{ .input = "/version sample", .tag = "unknown" },
    .{ .input = "/quit", .tag = "quit" },
    .{ .input = "/quit sample", .tag = "unknown" },
    .{ .input = "/exit", .tag = "quit" },
    .{ .input = "/exit sample", .tag = "unknown" },
};

test "parse resolves every builtin token and alias to its pre-refactor variant" {
    const registry = testSlashRegistry();
    for (builtin_parse_baseline) |case| {
        try std.testing.expectEqualStrings(case.tag, @tagName(parse(registry, case.input)));
    }

    var expected_rows: usize = 0;
    for (registry.commands) |spec| expected_rows += 2 * (1 + spec.aliases.len);
    try std.testing.expectEqual(expected_rows, builtin_parse_baseline.len);
}

const same_kind_payload_specs = [_]command_specs.SlashSpec{
    .{ .kind = .custom, .command = "/alpha", .accepts_payload = true },
    .{ .kind = .custom, .command = "/beta", .accepts_payload = true },
    .{ .kind = .custom, .command = "/gamma", .accepts_payload = true },
};

const same_kind_exact_specs = [_]command_specs.SlashSpec{
    .{ .kind = .custom, .command = "/alpha" },
    .{ .kind = .custom, .command = "/beta" },
    .{ .kind = .custom, .command = "/gamma" },
};

fn expectCustomAt(parsed: ParsedCommand, index: usize, args: []const u8) !void {
    switch (parsed) {
        .custom => |invocation| {
            try std.testing.expectEqual(index, invocation.index);
            try std.testing.expectEqualStrings(args, invocation.args);
        },
        else => return error.TestExpectedCustomCommand,
    }
}

test "parse dispatches payload specs sharing one slash kind to their own entry" {
    const registry = SlashRegistry{ .commands = same_kind_payload_specs[0..] };

    try expectCustomAt(parse(registry, "/alpha one"), 0, "one");
    try expectCustomAt(parse(registry, "/beta two"), 1, "two");
    try expectCustomAt(parse(registry, "/gamma three"), 2, "three");
    try expectCustomAt(parse(registry, "/gamma"), 2, "");
    try std.testing.expectEqual(ParsedCommand.unknown, parse(registry, "/delta"));
}

test "parse dispatches non-payload specs sharing one slash kind to their own entry" {
    const registry = SlashRegistry{ .commands = same_kind_exact_specs[0..] };

    try expectCustomAt(parse(registry, "/alpha"), 0, "");
    try expectCustomAt(parse(registry, "/beta"), 1, "");
    try expectCustomAt(parse(registry, "/gamma"), 2, "");
    try std.testing.expectEqual(ParsedCommand.unknown, parse(registry, "/beta payload"));
}

test "parse returns unknown for kinds absent from a filtered registry" {
    var storage: [command_specs.child_chat_slash_command_count]command_specs.SlashSpec = undefined;
    const child = command_specs.childChatSlashRegistry(testSlashRegistry(), &storage);

    try std.testing.expectEqual(ParsedCommand.unknown, parse(child, "/help"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(child, "/model claude-opus"));
    try std.testing.expectEqual(ParsedCommand.unknown, parse(child, "/mcp list"));
    try std.testing.expectEqual(ParsedCommand.quit, parse(child, "/quit"));
}

test "parse keeps the whitespace boundary between a builtin and a longer token" {
    try std.testing.expectEqual(ParsedCommand.unknown, parse(testSlashRegistry(), "/model-review 512"));

    var merged: [2]command_specs.SlashSpec = .{
        (testSlashRegistry().lookup("/model") orelse return error.TestExpectedEqual).*,
        .{ .kind = .custom, .command = "/model-review", .accepts_payload = true },
    };
    const registry = SlashRegistry{ .commands = merged[0..] };

    try expectCustomAt(parse(registry, "/model-review 512"), 1, "512");
    switch (parse(registry, "/model claude-opus")) {
        .model => |query| try std.testing.expectEqualStrings("claude-opus", query),
        else => return error.TestExpectedModelCommand,
    }
}

fn parsedIsUnknown(parsed: ParsedCommand) bool {
    return switch (parsed) {
        .unknown => true,
        else => false,
    };
}

test "parse covers every registered slash command token and alias" {
    for (testSlashRegistry().commands) |spec| {
        try std.testing.expect(!parsedIsUnknown(parse(testSlashRegistry(), spec.command)));
        for (spec.aliases) |alias| {
            try std.testing.expect(!parsedIsUnknown(parse(testSlashRegistry(), alias)));
        }
    }
}

test "parse payload acceptance follows slash spec metadata" {
    var buf: [128]u8 = undefined;
    for (testSlashRegistry().commands) |spec| {
        const command_with_payload = try std.fmt.bufPrint(&buf, "{s} sample", .{spec.command});
        const parsed = parse(testSlashRegistry(), command_with_payload);
        if (spec.accepts_payload) {
            try std.testing.expect(!parsedIsUnknown(parsed));
        } else {
            try std.testing.expect(parsedIsUnknown(parsed));
        }
    }
}

const TestContext = struct {
    called: []const u8 = "",
    payload: []const u8 = "",
    custom_index: usize = std.math.maxInt(usize),
};

fn testContext(ctx: *anyopaque) *TestContext {
    return @ptrCast(@alignCast(ctx));
}

fn unexpectedNoPayload(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    return error.UnexpectedCallback;
}

fn unexpectedPayload(ctx: *anyopaque, value: []const u8) anyerror!void {
    _ = ctx;
    _ = value;
    return error.UnexpectedCallback;
}

fn unexpectedCustom(ctx: *anyopaque, index: usize, args: []const u8) anyerror!void {
    _ = ctx;
    _ = index;
    _ = args;
    return error.UnexpectedCallback;
}

fn recordCopy(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "copy";
}

fn recordResumeSession(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "resume";
}

fn recordContinueRecovery(ctx: *anyopaque) anyerror!void {
    testContext(ctx).called = "continue_recovery";
}

fn recordModel(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "model";
    test_context.payload = value;
}

fn recordAllowlist(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "allowlist";
    test_context.payload = value;
}

fn recordSettings(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "settings";
    test_context.payload = value;
}

fn recordNotifications(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "notifications";
    test_context.payload = value;
}

fn recordUnknown(ctx: *anyopaque, value: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "unknown";
    test_context.payload = value;
}

fn failStatus(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    return error.TestRouteFailure;
}

fn testHandlers(ctx: *TestContext) CommandHandlers {
    return .{
        .ctx = ctx,
        .quit = unexpectedNoPayload,
        .clear_screen = unexpectedNoPayload,
        .new_session = unexpectedNoPayload,
        .reset_session = unexpectedNoPayload,
        .resume_session = unexpectedNoPayload,
        .continue_recovery = unexpectedNoPayload,
        .show_help = unexpectedNoPayload,
        .login = unexpectedNoPayload,
        .logout = unexpectedPayload,
        .setup = unexpectedNoPayload,
        .show_status = unexpectedNoPayload,
        .show_background = unexpectedNoPayload,
        .stop_background = unexpectedPayload,
        .open_background = unexpectedPayload,
        .show_background_logs = unexpectedPayload,
        .attach_image = unexpectedPayload,
        .manage_images = unexpectedPayload,
        .handle_model = unexpectedPayload,
        .handle_permissions = unexpectedPayload,
        .handle_allowlist = unexpectedPayload,
        .show_stats = unexpectedNoPayload,
        .show_usage = unexpectedNoPayload,
        .undo_last = unexpectedNoPayload,
        .handle_mcp = unexpectedPayload,
        .handle_skills = unexpectedPayload,
        .copy_last = unexpectedNoPayload,
        .submit_feedback = unexpectedNoPayload,
        .create_trace = unexpectedNoPayload,
        .compact_history = unexpectedNoPayload,
        .handle_settings = unexpectedPayload,
        .handle_alias = unexpectedPayload,
        .show_credits = unexpectedNoPayload,
        .paste_clipboard = unexpectedNoPayload,
        .toggle_fast = unexpectedNoPayload,
        .handle_statusline = unexpectedPayload,
        .rename_session = unexpectedPayload,
        .handle_notifications = unexpectedPayload,
        .handle_workspace = unexpectedPayload,
        .show_version = unexpectedNoPayload,
        .run_custom = unexpectedCustom,
        .unknown = unexpectedPayload,
    };
}

test "route calls expected no-payload handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.copy_last = recordCopy;

    try route(testSlashRegistry(), &handlers, "/copy");

    try std.testing.expectEqualStrings("copy", ctx.called);
    try std.testing.expectEqualStrings("", ctx.payload);
}

test "route calls interactive resume handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.resume_session = recordResumeSession;

    try route(testSlashRegistry(), &handlers, "/resume");

    try std.testing.expectEqualStrings("resume", ctx.called);
}

test "route calls explicit recovery continuation handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.continue_recovery = recordContinueRecovery;

    try route(testSlashRegistry(), &handlers, "/continue");

    try std.testing.expectEqualStrings("continue_recovery", ctx.called);
}

test "route forwards borrowed payload slice" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_model = recordModel;
    const cmd = "/model claude-opus";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("model", ctx.called);
    try std.testing.expectEqualStrings("claude-opus", ctx.payload);
    try std.testing.expect(ctx.payload.ptr == cmd["/model ".len..].ptr);
}

test "route forwards allowlist payload" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_allowlist = recordAllowlist;
    const cmd = "/allowlist add tool read_file";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("allowlist", ctx.called);
    try std.testing.expectEqualStrings("add tool read_file", ctx.payload);
}

test "route forwards settings payload" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_settings = recordSettings;
    const cmd = "/settings startup-scrollback off";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("settings", ctx.called);
    try std.testing.expectEqualStrings("startup-scrollback off", ctx.payload);
}

test "route forwards notifications payload" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.handle_notifications = recordNotifications;
    const cmd = "/sound off";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("notifications", ctx.called);
    try std.testing.expectEqualStrings("off", ctx.payload);
}

test "route sends original command string to unknown handler" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.unknown = recordUnknown;
    const cmd = " /wat untouched";

    try route(testSlashRegistry(), &handlers, cmd);

    try std.testing.expectEqualStrings("unknown", ctx.called);
    try std.testing.expectEqualStrings(cmd, ctx.payload);
    try std.testing.expect(ctx.payload.ptr == cmd.ptr);
}

fn recordCustom(ctx: *anyopaque, index: usize, args: []const u8) anyerror!void {
    const test_context = testContext(ctx);
    test_context.called = "custom";
    test_context.custom_index = index;
    test_context.payload = args;
}

test "route dispatches each same-kind custom entry to the custom handler" {
    const registry = SlashRegistry{ .commands = same_kind_payload_specs[0..] };

    for ([_][]const u8{ "/alpha", "/beta", "/gamma" }, 0..) |token, expected_index| {
        var ctx: TestContext = .{};
        var handlers = testHandlers(&ctx);
        handlers.run_custom = recordCustom;
        var buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "{s} payload", .{token});

        try route(registry, &handlers, cmd);

        try std.testing.expectEqualStrings("custom", ctx.called);
        try std.testing.expectEqual(expected_index, ctx.custom_index);
        try std.testing.expectEqualStrings("payload", ctx.payload);
    }
}

test "route propagates callback errors" {
    var ctx: TestContext = .{};
    var handlers = testHandlers(&ctx);
    handlers.show_status = failStatus;

    try std.testing.expectError(error.TestRouteFailure, route(testSlashRegistry(), &handlers, "/status"));
}

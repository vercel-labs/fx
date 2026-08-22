const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const list_window = @import("../shared/list_window.zig");
const mod_registry = @import("../mods/registry.zig");

const Allocator = std.mem.Allocator;

pub const TopLevelKind = enum {
    help,
    ask,
    acp,
    pr,
    issue,
    login,
    logout,
    setup,
    status,
    permissions,
    models,
    provider,
    doctor,
    background,
    teams,
    session,
    sessions,
    @"resume",
    credits,
    usage,
    upgrade,
    replay,
    workspace,
};

pub const SlashKind = enum {
    quit,
    clear_screen,
    new_session,
    reset_session,
    resume_session,
    continue_recovery,
    rename_session,
    help,
    login,
    logout,
    setup,
    status,
    background,
    background_stop,
    background_open,
    background_logs,
    image,
    images,
    model,
    models,
    permissions,
    allowlist,
    stats,
    usage,
    undo,
    mcp,
    acp,
    skills,
    copy,
    feedback,
    trace,
    compact,
    settings,
    alias,
    credits,
    paste,
    fast,
    appearance,
    statusline,
    notifications,
    workspace,
    version,
};

pub const OptionDoc = struct {
    flag: []const u8,
    description: []const u8,
};

pub const TopLevelSpec = struct {
    kind: TopLevelKind,
    token: []const u8,
    aliases: []const []const u8 = &.{},
    usage: []const u8,
    summary: []const u8,
    options: []const OptionDoc = &.{},
    details: []const []const u8 = &.{},
    hidden_from_top_level_help: bool = false,
};

pub const TopLevelHelpEntry = struct {
    kind: ?TopLevelKind = null,
    usage: []const u8,
    summary: ?[]const u8 = null,
};

pub const TopLevelHelpGroup = struct {
    entries: []const TopLevelHelpEntry,
};

pub const TopLevelFlag = struct {
    usage: []const u8,
    description: []const u8,
};

pub const TopLevelExample = struct {
    command: []const u8,
    description: []const u8,
};

pub const TopLevelResource = struct {
    label: []const u8,
    value: []const u8,
    link: bool = false,
};

pub const TopLevelRegistry = struct {
    specs: []const TopLevelSpec = &.{},
    description: []const u8,
    interactive_hint: []const u8,
    help_groups: []const TopLevelHelpGroup = &.{},
    flags: []const TopLevelFlag = &.{},
    examples: []const TopLevelExample = &.{},
    notes: []const []const u8 = &.{},
    resources: []const TopLevelResource = &.{},
};

pub const SlashPresentationCategory = enum {
    general,
    session,
    account,
    model,
    appearance,
    security,
    workspace,
    media,
    agents,
    extensions,
    product,

    pub fn label(self: SlashPresentationCategory) []const u8 {
        return switch (self) {
            .general => "General",
            .session => "Session",
            .account => "Account",
            .model => "Model",
            .appearance => "Appearance",
            .security => "Security",
            .workspace => "Workspace",
            .media => "Media",
            .agents => "Agents",
            .extensions => "Extensions",
            .product => "Product",
        };
    }
};

pub const SlashSpec = struct {
    kind: SlashKind,
    command: []const u8,
    aliases: []const []const u8 = &.{},
    show_aliases_in_completion: bool = true,
    help_entry: ?[]const u8 = null,
    completion_description: ?[]const u8 = null,
    presentation_category: ?SlashPresentationCategory = null,
    show_in_welcome: bool = false,
    has_args: bool = false,
    accepts_payload: bool = false,
    requires_prompt_credential: bool = false,
};

pub const SlashRegistry = mod_registry.CommandRegistry(SlashSpec);
pub const child_chat_slash_command_count: usize = 3;

pub fn childChatSlashRegistry(
    registry: SlashRegistry,
    storage: *[child_chat_slash_command_count]SlashSpec,
) SlashRegistry {
    var count: usize = 0;
    for (registry.commands) |spec| {
        switch (spec.kind) {
            .quit, .models, .skills => {
                std.debug.assert(count < storage.len);
                storage[count] = spec;
                count += 1;
            },
            else => {},
        }
    }
    return .{ .commands = storage[0..count] };
}

pub const HelpMenu = struct {
    active: bool = false,
    selected_index: usize = 0,
    window_start: usize = 0,

    pub fn open(self: *HelpMenu) void {
        self.* = .{ .active = true };
    }

    pub fn close(self: *HelpMenu) void {
        self.* = .{};
    }

    pub fn resetForQuery(self: *HelpMenu) void {
        self.selected_index = 0;
        self.window_start = 0;
    }

    pub fn move(self: *HelpMenu, registry: SlashRegistry, query: []const u8, delta: i32, visible_items: u16) bool {
        const item_count = helpCatalogCount(registry, query);
        if (!self.active or item_count == 0) return false;

        const current: i32 = @intCast(self.selected_index % item_count);
        var next = current + delta;
        if (next < 0) next = @as(i32, @intCast(item_count)) - 1;
        if (next >= @as(i32, @intCast(item_count))) next = 0;
        self.selected_index = @intCast(next);
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            @max(visible_items, 1),
        );
        return true;
    }

    pub fn selectedSpec(self: *const HelpMenu, registry: SlashRegistry, query: []const u8) ?*const SlashSpec {
        const item_count = helpCatalogCount(registry, query);
        if (!self.active or item_count == 0) return null;
        return helpCatalogSpecAt(registry, query, self.selected_index % item_count);
    }
};

pub const top_level_help_default_width: usize = 80;

pub const HelpStyle = enum {
    plain,
    ansi,
};

const HelpRole = enum {
    brand,
    heading,
    syntax,
    muted,
    label,
    link,
};

pub fn matchesTopLevel(registry: TopLevelRegistry, token: []const u8, kind: TopLevelKind) bool {
    const spec = topLevelSpec(registry, kind);
    return matchesCommandToken(token, spec.token, spec.aliases);
}

pub fn matchesSlashExact(registry: SlashRegistry, cmd: []const u8, kind: SlashKind) bool {
    const matched = registry.matchExact(cmd) orelse return false;
    return matched.command.kind == kind;
}

pub fn matchedSlashPrefix(registry: SlashRegistry, cmd: []const u8, kind: SlashKind) ?[]const u8 {
    return registry.matchEntryPrefix(cmd, slashSpecPtr(registry, kind));
}

pub fn renderTopLevelHelp(alloc: Allocator, registry: TopLevelRegistry, columns: usize, version: []const u8) ![]u8 {
    return renderTopLevelHelpWithStyle(alloc, registry, columns, version, .plain);
}

pub fn renderTopLevelHelpWithStyle(alloc: Allocator, registry: TopLevelRegistry, columns: usize, version: []const u8, style: HelpStyle) ![]u8 {
    const width = normalizedTopLevelHelpWidth(columns);
    const command_usage_width = maxTopLevelHelpUsageWidth(registry);
    const flag_usage_width = maxTopLevelFlagUsageWidth(registry);
    const resource_label_width = maxTopLevelResourceLabelWidth(registry);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeStyled(&out.writer, style, .brand, "𝒇x");
    try out.writer.writeByte(' ');
    try writeStyleStart(&out.writer, style, .muted);
    try out.writer.writeByte('v');
    try out.writer.writeAll(version);
    try writeStyleEnd(&out.writer, style);
    try out.writer.writeByte('\n');
    try writeWrappedStyledLine(&out.writer, "", "", registry.description, width, style, .muted);
    try out.writer.writeByte('\n');
    try writeWrappedStyledLine(&out.writer, "", "", registry.interactive_hint, width, style, .muted);

    try writeSectionHeading(&out.writer, style, "Usage:");
    try writeWrappedStyledLine(&out.writer, "  ", "  ", "fx [flags]", width, style, .syntax);
    try writeWrappedStyledLine(&out.writer, "  ", "  ", "fx <command> [...flags] [...args]", width, style, .syntax);

    try writeSectionHeading(&out.writer, style, "Commands:");
    for (registry.help_groups, 0..) |group, group_index| {
        if (group_index > 0) try out.writer.writeByte('\n');
        for (group.entries) |entry| {
            try writeTopLevelHelpEntry(&out.writer, registry, entry, command_usage_width, width, style);
        }
    }

    try writeSectionHeading(&out.writer, style, "Flags:");
    for (registry.flags) |flag| {
        try writeTopLevelFlag(&out.writer, flag, flag_usage_width, width, style);
    }
    try out.writer.writeByte('\n');

    try writeStyled(&out.writer, style, .heading, "Examples:");
    try out.writer.writeByte('\n');
    for (registry.examples) |example| {
        try writeTopLevelExample(&out.writer, example, width, style);
    }

    for (registry.notes) |note| {
        try writeWrappedStyledLine(&out.writer, "", "", note, width, style, .muted);
    }

    try out.writer.writeByte('\n');
    for (registry.resources) |resource| {
        try writeTopLevelResource(&out.writer, resource, resource_label_width, width, style);
    }

    return try out.toOwnedSlice();
}

pub fn renderTopLevelCommandHelp(alloc: Allocator, registry: TopLevelRegistry, kind: TopLevelKind) ![]u8 {
    const spec = topLevelSpec(registry, kind);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("fx ");
    try out.writer.writeAll(spec.token);
    try out.writer.writeAll("\n\n");
    try out.writer.writeAll(spec.summary);
    try out.writer.writeAll("\n\nUsage:\n");
    try out.writer.writeAll("  fx ");
    try out.writer.writeAll(spec.usage);
    try out.writer.writeByte('\n');

    if (spec.options.len > 0) {
        var flag_width: usize = 0;
        for (spec.options) |opt| flag_width = @max(flag_width, opt.flag.len);

        try out.writer.writeAll("\nOptions:\n");
        for (spec.options) |opt| {
            try out.writer.writeAll("  ");
            try out.writer.writeAll(opt.flag);
            try writePadding(&out.writer, flag_width - opt.flag.len + 2);
            try out.writer.writeAll(opt.description);
            try out.writer.writeByte('\n');
        }
    }

    if (spec.details.len > 0) {
        try out.writer.writeByte('\n');
        for (spec.details) |line| {
            try out.writer.writeAll(line);
            try out.writer.writeByte('\n');
        }
    }

    return try out.toOwnedSlice();
}

pub fn topLevelKindFromToken(registry: TopLevelRegistry, token: []const u8) ?TopLevelKind {
    for (registry.specs) |spec| {
        if (matchesCommandToken(token, spec.token, spec.aliases)) return spec.kind;
    }
    return null;
}

pub fn renderSlashHelp(alloc: Allocator, registry: SlashRegistry) ![]u8 {
    return renderSlashEntries(alloc, registry, false);
}

pub fn renderSlashWelcome(alloc: Allocator, registry: SlashRegistry) ![]u8 {
    return renderSlashEntries(alloc, registry, true);
}

pub fn helpCatalogCount(registry: SlashRegistry, query: []const u8) usize {
    var count: usize = 0;
    for (std.meta.tags(SlashPresentationCategory)) |category| {
        count += helpCatalogCategoryCount(registry, query, category);
    }
    return count;
}

pub fn helpCatalogCategoryCount(registry: SlashRegistry, query: []const u8, category: SlashPresentationCategory) usize {
    var count: usize = 0;
    for (registry.commands) |spec| {
        if (spec.presentation_category != category or !helpCatalogSpecMatches(spec, query)) continue;
        count += 1;
    }
    return count;
}

pub fn helpCatalogSpecAt(registry: SlashRegistry, query: []const u8, display_index: usize) ?*const SlashSpec {
    var current: usize = 0;
    for (std.meta.tags(SlashPresentationCategory)) |category| {
        for (registry.commands) |*spec| {
            if (spec.presentation_category != category or !helpCatalogSpecMatches(spec.*, query)) continue;
            if (current == display_index) return spec;
            current += 1;
        }
    }
    return null;
}

fn helpCatalogSpecMatches(spec: SlashSpec, query: []const u8) bool {
    if (spec.help_entry == null or spec.completion_description == null or spec.presentation_category == null) return false;

    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (tokens.next()) |token| {
        if (containsIgnoreCase(spec.command, token) or
            containsIgnoreCase(spec.help_entry.?, token) or
            containsIgnoreCase(spec.completion_description.?, token) or
            containsIgnoreCase(spec.presentation_category.?.label(), token))
        {
            continue;
        }
        for (spec.aliases) |alias| {
            if (containsIgnoreCase(alias, token)) break;
        } else return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

pub fn topLevelUsage(registry: TopLevelRegistry, kind: TopLevelKind) []const u8 {
    return topLevelSpec(registry, kind).usage;
}

pub fn firstSlashCompletion(registry: SlashRegistry, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0 or prefix[0] != '/') return null;
    for (registry.commands) |spec| {
        if (spec.help_entry == null) continue;
        if (std.mem.startsWith(u8, spec.command, prefix) and spec.command.len > prefix.len) {
            return spec.command;
        }
        if (spec.show_aliases_in_completion) {
            for (spec.aliases) |alias| {
                if (std.mem.startsWith(u8, alias, prefix) and alias.len > prefix.len) {
                    return alias;
                }
            }
        }
    }
    return null;
}

const slash_completion_match_rank_count: usize = 3;

const SlashCompletionCommandMatch = struct {
    command: []const u8,
    rank: usize,
};

const SlashCompletionMatch = struct {
    spec: *const SlashSpec,
    command: []const u8,
};

fn completionCommandMatchRank(command: []const u8, prefix: []const u8) ?usize {
    if (std.mem.eql(u8, command, prefix)) return 0;
    if (std.mem.startsWith(u8, command, prefix)) return 1;
    if (prefix.len <= 1 or command.len <= 1) return null;
    if (std.mem.find(u8, command[1..], prefix[1..]) != null) return 2;
    return null;
}

fn bestCompletionCommandMatch(spec: SlashSpec, prefix: []const u8) ?SlashCompletionCommandMatch {
    var best: ?SlashCompletionCommandMatch = if (completionCommandMatchRank(spec.command, prefix)) |rank|
        .{ .command = spec.command, .rank = rank }
    else
        null;

    if (spec.show_aliases_in_completion) {
        for (spec.aliases) |alias| {
            const rank = completionCommandMatchRank(alias, prefix) orelse continue;
            if (best == null or rank < best.?.rank) {
                best = .{ .command = alias, .rank = rank };
            }
        }
    }
    return best;
}

pub fn matchedCompletionCommand(spec: SlashSpec, prefix: []const u8) ?[]const u8 {
    return (bestCompletionCommandMatch(spec, prefix) orelse return null).command;
}

fn nthSlashCommandCompletionMatch(registry: SlashRegistry, prefix: []const u8, n: usize) ?SlashCompletionMatch {
    var idx: usize = 0;
    for (0..slash_completion_match_rank_count) |rank| {
        for (registry.commands) |*spec| {
            if (spec.help_entry == null) continue;
            const match = bestCompletionCommandMatch(spec.*, prefix) orelse continue;
            if (match.rank != rank) continue;
            if (idx == n) {
                return .{
                    .spec = spec,
                    .command = match.command,
                };
            }
            idx += 1;
        }
    }
    return null;
}

pub fn slashCompletionPrefix(registry: SlashRegistry, input: []const u8) ?[]const u8 {
    const prefix = std.mem.trimStart(u8, input, " \t\r\n");
    if (prefix.len == 0 or prefix[0] != '/') return null;

    const command_end = std.mem.indexOfAny(u8, prefix, " \t\r\n") orelse return prefix;
    const spec = registry.lookup(prefix[0..command_end]) orelse return prefix;
    if (!spec.has_args) return null;
    return prefix;
}

pub fn slashCompletionCount(registry: SlashRegistry, prefix: []const u8) usize {
    if (allowlistArgCompletionPrefix(prefix)) |query| {
        return allowlistArgCompletionCount(query);
    }
    if (statuslineArgCompletionPrefix(prefix)) |query| {
        return statuslineArgCompletionCount(query);
    }
    if (notificationsArgCompletionPrefix(prefix)) |query| {
        return notificationsArgCompletionCount(query);
    }
    if (permissionsArgCompletionPrefix(prefix)) |query| {
        return permissionsArgCompletionCount(query);
    }
    if (appearanceArgCompletionPrefix(prefix)) |query| {
        return appearanceArgCompletionCount(query);
    }
    if (inputArgCompletionPrefix(prefix)) |query| {
        return inputArgCompletionCount(query);
    }
    if (maxxingArgCompletionPrefix(prefix)) |query| {
        return maxxingArgCompletionCount(query);
    }
    if (workspaceArgCompletionPrefix(prefix)) |query| {
        return workspaceArgCompletionCount(query);
    }
    if (prefix.len == 0 or prefix[0] != '/') return 0;
    var count: usize = 0;
    for (registry.commands) |spec| {
        if (spec.help_entry == null) continue;
        if (matchedCompletionCommand(spec, prefix) != null) count += 1;
    }
    return count;
}

pub fn nthSlashCompletion(registry: SlashRegistry, prefix: []const u8, n: usize) ?[]const u8 {
    if (allowlistArgCompletionPrefix(prefix)) |query| {
        return nthAllowlistArgCompletion(query, n);
    }
    if (statuslineArgCompletionPrefix(prefix)) |query| {
        return nthStatuslineArgCompletion(query, n);
    }
    if (notificationsArgCompletionPrefix(prefix)) |query| {
        return nthNotificationsArgCompletion(query, n);
    }
    if (permissionsArgCompletionPrefix(prefix)) |query| {
        return nthPermissionsArgCompletion(query, n);
    }
    if (appearanceArgCompletionPrefix(prefix)) |query| {
        return nthAppearanceArgCompletion(query, n);
    }
    if (inputArgCompletionPrefix(prefix)) |query| {
        return nthInputArgCompletion(query, n);
    }
    if (maxxingArgCompletionPrefix(prefix)) |query| {
        return nthMaxxingArgCompletion(query, n);
    }
    if (workspaceArgCompletionPrefix(prefix)) |query| {
        return nthWorkspaceArgCompletion(query, n);
    }
    if (prefix.len == 0 or prefix[0] != '/') return null;
    return (nthSlashCommandCompletionMatch(registry, prefix, n) orelse return null).command;
}

/// Returns the byte offset where the argument portion begins for
/// known arg-completion commands. Returns 0 when
/// the prefix is not an arg-completion command.
pub fn argCompletionAnchor(prefix: []const u8) usize {
    if (statuslineArgCompletionPrefix(prefix) != null) return "/statusline ".len;
    if (notificationsArgCompletionPrefix(prefix) != null) return "/sound ".len;
    if (permissionsArgCompletionPrefix(prefix) != null) return "/permissions ".len;
    if (appearanceArgCompletionPrefix(prefix) != null) return "/appearance ".len;
    if (inputArgCompletionPrefix(prefix) != null) return "/input ".len;
    if (maxxingArgCompletionPrefix(prefix) != null) return "/maxxing ".len;
    if (workspaceArgCompletionPrefix(prefix) != null) return "/workspace ".len;
    if (allowlistArgCompletionAnchor(prefix)) |anchor| return anchor;
    return 0;
}

/// Like `nthSlashCompletion` but returns the display label only.
/// For argument completions the command prefix is stripped so the bar
/// shows only the argument. For everything else the
/// full command string is returned unchanged.
pub fn nthSlashCompletionLabel(registry: SlashRegistry, prefix: []const u8, n: usize) ?[]const u8 {
    if (allowlistArgCompletionPrefix(prefix)) |query| {
        return nthAllowlistArgLabel(query, n);
    }
    if (statuslineArgCompletionPrefix(prefix)) |query| {
        return nthStatuslineArgLabel(query, n);
    }
    if (notificationsArgCompletionPrefix(prefix)) |query| {
        return nthNotificationsArgLabel(query, n);
    }
    if (permissionsArgCompletionPrefix(prefix)) |query| {
        return nthPermissionsArgLabel(query, n);
    }
    if (appearanceArgCompletionPrefix(prefix)) |query| {
        return nthAppearanceArgLabel(query, n);
    }
    if (inputArgCompletionPrefix(prefix)) |query| {
        return nthInputArgLabel(query, n);
    }
    if (maxxingArgCompletionPrefix(prefix)) |query| {
        return nthMaxxingArgLabel(query, n);
    }
    if (workspaceArgCompletionPrefix(prefix)) |query| {
        return nthWorkspaceArgLabel(query, n);
    }
    return nthSlashCompletion(registry, prefix, n);
}

pub fn nthSlashCompletionDescription(registry: SlashRegistry, prefix: []const u8, n: usize) ?[]const u8 {
    if (allowlistArgCompletionPrefix(prefix) != null) return null;
    if (statuslineArgCompletionPrefix(prefix) != null) return null;
    if (notificationsArgCompletionPrefix(prefix) != null) return null;
    if (permissionsArgCompletionPrefix(prefix) != null) return null;
    if (appearanceArgCompletionPrefix(prefix) != null) return null;
    if (inputArgCompletionPrefix(prefix) != null) return null;
    if (maxxingArgCompletionPrefix(prefix) != null) return null;
    if (workspaceArgCompletionPrefix(prefix) != null) return null;
    if (prefix.len == 0 or prefix[0] != '/') return null;
    return (nthSlashCommandCompletionMatch(registry, prefix, n) orelse return null).spec.completion_description;
}

pub fn nthSlashCompletionCategory(registry: SlashRegistry, prefix: []const u8, n: usize) ?SlashPresentationCategory {
    if (argCompletionAnchor(prefix) != 0) return null;
    if (prefix.len == 0 or prefix[0] != '/') return null;
    return (nthSlashCommandCompletionMatch(registry, prefix, n) orelse return null).spec.presentation_category;
}

pub fn slashCompletionHasArgs(registry: SlashRegistry, command: []const u8) bool {
    if (allowlistCompletionHasArgs(command)) return true;
    if (std.mem.eql(u8, command, "/workspace add") or
        std.mem.eql(u8, command, "/workspace remove")) return true;
    for (registry.commands) |spec| {
        if (std.mem.eql(u8, spec.command, command)) return spec.has_args;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, alias, command)) return spec.has_args;
        }
    }
    return false;
}

fn allowlistCompletionHasArgs(command: []const u8) bool {
    const completions_with_more_args = [_][]const u8{
        "/allowlist add",
        "/allowlist remove",
        "/allowlist reset",
        "/allowlist view",
        "/allowlist local",
        "/allowlist user",
        "/allowlist local add",
        "/allowlist local remove",
        "/allowlist local reset",
        "/allowlist user add",
        "/allowlist user remove",
        "/allowlist user reset",
        "/allowlist add command",
        "/allowlist add tool",
        "/allowlist add url",
        "/allowlist add web-fetch-domain",
        "/allowlist remove command",
        "/allowlist remove tool",
        "/allowlist remove url",
        "/allowlist remove web-fetch-domain",
        "/allowlist local add command",
        "/allowlist local add tool",
        "/allowlist local add url",
        "/allowlist local add web-fetch-domain",
        "/allowlist local remove command",
        "/allowlist local remove tool",
        "/allowlist local remove url",
        "/allowlist local remove web-fetch-domain",
        "/allowlist user add command",
        "/allowlist user add tool",
        "/allowlist user add url",
        "/allowlist user add web-fetch-domain",
        "/allowlist user remove command",
        "/allowlist user remove tool",
        "/allowlist user remove url",
        "/allowlist user remove web-fetch-domain",
    };
    for (completions_with_more_args) |completion| {
        if (std.mem.eql(u8, command, completion)) return true;
    }
    return false;
}

const statusline_arg_completions = [_][]const u8{
    "/statusline context",
    "/statusline session",
    "/statusline workspace",
};

const notifications_arg_completions = [_][]const u8{
    "/sound on",
    "/sound off",
    "/sound max",
};

const permissions_arg_completions = [_][]const u8{
    "/permissions ask",
    "/permissions auto",
    "/permissions remember",
    "/permissions revoke",
    "/permissions yolo",
    "/permissions reset",
};

const appearance_arg_completions = [_][]const u8{
    "/appearance input lines",
    "/appearance input tint",
    "/appearance presentation normal",
    "/appearance presentation minimal",
};

const input_arg_completions = [_][]const u8{
    "/input lines",
    "/input tint",
};

const maxxing_arg_completions = [_][]const u8{
    "/maxxing minimal",
    "/maxxing legacy",
};

const workspace_arg_completions = [_][]const u8{
    "/workspace list",
    "/workspace add",
    "/workspace remove",
    "/workspace clear",
};

const allowlist_action_completions = [_][]const u8{
    "/allowlist view",
    "/allowlist add",
    "/allowlist remove",
    "/allowlist reset",
    "/allowlist local",
    "/allowlist user",
};

const allowlist_view_completions = [_][]const u8{
    "/allowlist view effective",
    "/allowlist view local",
    "/allowlist view user",
};

const allowlist_scoped_action_suffixes = [_][]const u8{
    "add",
    "remove",
    "reset",
};

const allowlist_add_kind_completions = [_][]const u8{
    "/allowlist add command",
    "/allowlist add tool",
    "/allowlist add url",
    "/allowlist add web-fetch-domain",
};

const allowlist_remove_kind_completions = [_][]const u8{
    "/allowlist remove command",
    "/allowlist remove tool",
    "/allowlist remove url",
    "/allowlist remove web-fetch-domain",
};

const allowlist_reset_scope_completions = [_][]const u8{
    "/allowlist reset commands",
    "/allowlist reset tools",
    "/allowlist reset urls",
    "/allowlist reset web-fetch-domains",
    "/allowlist reset all",
};

const allowlist_add_tool_completions = [_][]const u8{
    "/allowlist add tool read_file",
    "/allowlist add tool write_file",
    "/allowlist add tool edit_file",
    "/allowlist add tool list_files",
    "/allowlist add tool glob_files",
    "/allowlist add tool grep_files",
    "/allowlist add tool open_file",
    "/allowlist add tool create_folder",
    "/allowlist add tool rename_file",
    "/allowlist add tool copy_file",
    "/allowlist add tool skill",
    "/allowlist add tool install_skill",
    "/allowlist add tool subagent",
};

const allowlist_remove_tool_completions = [_][]const u8{
    "/allowlist remove tool read_file",
    "/allowlist remove tool write_file",
    "/allowlist remove tool edit_file",
    "/allowlist remove tool list_files",
    "/allowlist remove tool glob_files",
    "/allowlist remove tool grep_files",
    "/allowlist remove tool open_file",
    "/allowlist remove tool create_folder",
    "/allowlist remove tool rename_file",
    "/allowlist remove tool copy_file",
    "/allowlist remove tool skill",
    "/allowlist remove tool install_skill",
    "/allowlist remove tool subagent",
};

fn scopedAllowlistCompletions(
    comptime scope: []const u8,
    comptime source: anytype,
) [source.len][]const u8 {
    var result: [source.len][]const u8 = undefined;
    inline for (source, 0..) |completion, idx| {
        const suffix = if (std.mem.startsWith(u8, completion, "/allowlist "))
            completion["/allowlist ".len..]
        else
            completion;
        result[idx] = std.fmt.comptimePrint("/allowlist {s} {s}", .{ scope, suffix });
    }
    return result;
}

const allowlist_local_action_completions = scopedAllowlistCompletions("local", allowlist_scoped_action_suffixes);
const allowlist_user_action_completions = scopedAllowlistCompletions("user", allowlist_scoped_action_suffixes);
const allowlist_local_add_kind_completions = scopedAllowlistCompletions("local", allowlist_add_kind_completions);
const allowlist_user_add_kind_completions = scopedAllowlistCompletions("user", allowlist_add_kind_completions);
const allowlist_local_remove_kind_completions = scopedAllowlistCompletions("local", allowlist_remove_kind_completions);
const allowlist_user_remove_kind_completions = scopedAllowlistCompletions("user", allowlist_remove_kind_completions);
const allowlist_local_reset_scope_completions = scopedAllowlistCompletions("local", allowlist_reset_scope_completions);
const allowlist_user_reset_scope_completions = scopedAllowlistCompletions("user", allowlist_reset_scope_completions);
const allowlist_local_add_tool_completions = scopedAllowlistCompletions("local", allowlist_add_tool_completions);
const allowlist_user_add_tool_completions = scopedAllowlistCompletions("user", allowlist_add_tool_completions);
const allowlist_local_remove_tool_completions = scopedAllowlistCompletions("local", allowlist_remove_tool_completions);
const allowlist_user_remove_tool_completions = scopedAllowlistCompletions("user", allowlist_remove_tool_completions);

fn argCompletionPrefix(prefix: []const u8, command: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, prefix, command)) return null;
    if (prefix.len == command.len) return null;
    const boundary = prefix[command.len];
    if (boundary != ' ' and boundary != '\t') return null;
    return std.mem.trim(u8, prefix[command.len..], " \t");
}

fn rawArgCompletionPrefix(prefix: []const u8, command: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, prefix, command)) return null;
    if (prefix.len == command.len) return null;
    const boundary = prefix[command.len];
    if (boundary != ' ' and boundary != '\t') return null;
    return std.mem.trimStart(u8, prefix[command.len..], " \t");
}

pub fn allowlistArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return rawArgCompletionPrefix(prefix, "/allowlist");
}

pub fn statuslineArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/statusline");
}

pub fn notificationsArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/sound");
}

pub fn permissionsArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/permissions");
}

pub fn appearanceArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/appearance");
}

pub fn inputArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/input");
}

pub fn maxxingArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/maxxing");
}

pub fn workspaceArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/workspace");
}

fn argCompletionCount(completions: []const []const u8, command_with_space_len: usize, query: []const u8) usize {
    var count: usize = 0;
    for (completions) |completion| {
        if (argCompletionMatches(completion, command_with_space_len, query)) count += 1;
    }
    return count;
}

fn statuslineArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&statusline_arg_completions, "/statusline ".len, query);
}

fn notificationsArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&notifications_arg_completions, "/sound ".len, query);
}

fn permissionsArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&permissions_arg_completions, "/permissions ".len, query);
}

fn appearanceArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&appearance_arg_completions, "/appearance ".len, query);
}

fn inputArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&input_arg_completions, "/input ".len, query);
}

fn maxxingArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&maxxing_arg_completions, "/maxxing ".len, query);
}

fn workspaceArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&workspace_arg_completions, "/workspace ".len, query);
}

fn allowlistArgCompletionCount(query: []const u8) usize {
    const state = allowlistArgCompletionState(query);
    return argCompletionCount(state.completions, state.label_offset, state.query);
}

fn nthArgCompletion(completions: []const []const u8, command_with_space_len: usize, query: []const u8, n: usize) ?[]const u8 {
    var idx: usize = 0;
    for (completions) |completion| {
        if (!argCompletionMatches(completion, command_with_space_len, query)) continue;
        if (idx == n) return completion;
        idx += 1;
    }
    return null;
}

fn nthStatuslineArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&statusline_arg_completions, "/statusline ".len, query, n);
}

fn nthStatuslineArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthStatuslineArgCompletion(query, n) orelse return null;
    return full["/statusline ".len..];
}

fn nthNotificationsArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&notifications_arg_completions, "/sound ".len, query, n);
}

fn nthNotificationsArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthNotificationsArgCompletion(query, n) orelse return null;
    return full["/sound ".len..];
}

fn nthPermissionsArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&permissions_arg_completions, "/permissions ".len, query, n);
}

fn nthPermissionsArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthPermissionsArgCompletion(query, n) orelse return null;
    return full["/permissions ".len..];
}

fn nthAppearanceArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&appearance_arg_completions, "/appearance ".len, query, n);
}

fn nthAppearanceArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthAppearanceArgCompletion(query, n) orelse return null;
    return full["/appearance ".len..];
}

fn nthInputArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&input_arg_completions, "/input ".len, query, n);
}

fn nthInputArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthInputArgCompletion(query, n) orelse return null;
    return full["/input ".len..];
}

fn nthMaxxingArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&maxxing_arg_completions, "/maxxing ".len, query, n);
}

fn nthMaxxingArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthMaxxingArgCompletion(query, n) orelse return null;
    return full["/maxxing ".len..];
}

fn nthWorkspaceArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&workspace_arg_completions, "/workspace ".len, query, n);
}

fn nthWorkspaceArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthWorkspaceArgCompletion(query, n) orelse return null;
    return full["/workspace ".len..];
}

fn nthAllowlistArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    const state = allowlistArgCompletionState(query);
    return nthArgCompletion(state.completions, state.label_offset, state.query, n);
}

fn nthAllowlistArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const state = allowlistArgCompletionState(query);
    const full = nthArgCompletion(state.completions, state.label_offset, state.query, n) orelse return null;
    return full[state.label_offset..];
}

/// Returns the index of `label` among the matching arg completions for
/// the given prefix, or null if the label is not in the filtered set.
pub fn argCompletionIndexForLabel(prefix: []const u8, label: []const u8) ?usize {
    if (allowlistArgCompletionPrefix(prefix)) |query| {
        const state = allowlistArgCompletionState(query);
        return indexOfArgLabel(state.completions, state.label_offset, state.query, label);
    }
    if (appearanceArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&appearance_arg_completions, "/appearance ".len, query, label);
    }
    if (inputArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&input_arg_completions, "/input ".len, query, label);
    }
    if (maxxingArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&maxxing_arg_completions, "/maxxing ".len, query, label);
    }
    if (statuslineArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&statusline_arg_completions, "/statusline ".len, query, label);
    }
    if (notificationsArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&notifications_arg_completions, "/sound ".len, query, label);
    }
    if (permissionsArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&permissions_arg_completions, "/permissions ".len, query, label);
    }
    if (workspaceArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&workspace_arg_completions, "/workspace ".len, query, label);
    }
    return null;
}

fn indexOfArgLabel(completions: []const []const u8, command_with_space_len: usize, query: []const u8, label: []const u8) ?usize {
    var idx: usize = 0;
    for (completions) |completion| {
        if (!argCompletionMatches(completion, command_with_space_len, query)) continue;
        const arg = completion[command_with_space_len..];
        if (std.mem.eql(u8, arg, label)) return idx;
        idx += 1;
    }
    return null;
}

fn argCompletionMatches(completion: []const u8, command_with_space_len: usize, query: []const u8) bool {
    const arg = completion[command_with_space_len..];
    return query.len == 0 or std.ascii.startsWithIgnoreCase(arg, query);
}

const AllowlistArgCompletionState = struct {
    completions: []const []const u8,
    label_offset: usize,
    query: []const u8,
};

fn allowlistArgCompletionState(query: []const u8) AllowlistArgCompletionState {
    const split = splitAllowlistArgQuery(query);
    if (split.has_rest) {
        if (std.ascii.eqlIgnoreCase(split.word, "view")) {
            return .{
                .completions = &allowlist_view_completions,
                .label_offset = "/allowlist view ".len,
                .query = split.rest,
            };
        }
        if (std.ascii.eqlIgnoreCase(split.word, "local")) {
            return scopedAllowlistArgCompletionState(.local, split.rest);
        }
        if (std.ascii.eqlIgnoreCase(split.word, "user")) {
            return scopedAllowlistArgCompletionState(.user, split.rest);
        }
        if (std.ascii.eqlIgnoreCase(split.word, "add")) {
            if (allowlistToolArgQuery(split.rest)) |tool_query| {
                return .{
                    .completions = &allowlist_add_tool_completions,
                    .label_offset = "/allowlist add tool ".len,
                    .query = tool_query,
                };
            }
            return .{
                .completions = &allowlist_add_kind_completions,
                .label_offset = "/allowlist add ".len,
                .query = split.rest,
            };
        }
        if (std.ascii.eqlIgnoreCase(split.word, "remove")) {
            if (allowlistToolArgQuery(split.rest)) |tool_query| {
                return .{
                    .completions = &allowlist_remove_tool_completions,
                    .label_offset = "/allowlist remove tool ".len,
                    .query = tool_query,
                };
            }
            return .{
                .completions = &allowlist_remove_kind_completions,
                .label_offset = "/allowlist remove ".len,
                .query = split.rest,
            };
        }
        if (std.ascii.eqlIgnoreCase(split.word, "reset")) {
            return .{
                .completions = &allowlist_reset_scope_completions,
                .label_offset = "/allowlist reset ".len,
                .query = split.rest,
            };
        }
        return .{ .completions = &.{}, .label_offset = "/allowlist ".len, .query = "" };
    }

    return .{
        .completions = &allowlist_action_completions,
        .label_offset = "/allowlist ".len,
        .query = split.word,
    };
}

const AllowlistCompletionScope = enum {
    local,
    user,
};

fn scopedAllowlistArgCompletionState(
    scope: AllowlistCompletionScope,
    query: []const u8,
) AllowlistArgCompletionState {
    const scope_label = @tagName(scope);
    const split = splitAllowlistArgQuery(query);
    if (!split.has_rest) {
        return switch (scope) {
            .local => .{
                .completions = &allowlist_local_action_completions,
                .label_offset = "/allowlist local ".len,
                .query = split.word,
            },
            .user => .{
                .completions = &allowlist_user_action_completions,
                .label_offset = "/allowlist user ".len,
                .query = split.word,
            },
        };
    }

    if (std.ascii.eqlIgnoreCase(split.word, "add")) {
        if (allowlistToolArgQuery(split.rest)) |tool_query| {
            return switch (scope) {
                .local => .{
                    .completions = &allowlist_local_add_tool_completions,
                    .label_offset = "/allowlist local add tool ".len,
                    .query = tool_query,
                },
                .user => .{
                    .completions = &allowlist_user_add_tool_completions,
                    .label_offset = "/allowlist user add tool ".len,
                    .query = tool_query,
                },
            };
        }
        return switch (scope) {
            .local => .{
                .completions = &allowlist_local_add_kind_completions,
                .label_offset = "/allowlist local add ".len,
                .query = split.rest,
            },
            .user => .{
                .completions = &allowlist_user_add_kind_completions,
                .label_offset = "/allowlist user add ".len,
                .query = split.rest,
            },
        };
    }
    if (std.ascii.eqlIgnoreCase(split.word, "remove")) {
        if (allowlistToolArgQuery(split.rest)) |tool_query| {
            return switch (scope) {
                .local => .{
                    .completions = &allowlist_local_remove_tool_completions,
                    .label_offset = "/allowlist local remove tool ".len,
                    .query = tool_query,
                },
                .user => .{
                    .completions = &allowlist_user_remove_tool_completions,
                    .label_offset = "/allowlist user remove tool ".len,
                    .query = tool_query,
                },
            };
        }
        return switch (scope) {
            .local => .{
                .completions = &allowlist_local_remove_kind_completions,
                .label_offset = "/allowlist local remove ".len,
                .query = split.rest,
            },
            .user => .{
                .completions = &allowlist_user_remove_kind_completions,
                .label_offset = "/allowlist user remove ".len,
                .query = split.rest,
            },
        };
    }
    if (std.ascii.eqlIgnoreCase(split.word, "reset")) {
        return switch (scope) {
            .local => .{
                .completions = &allowlist_local_reset_scope_completions,
                .label_offset = "/allowlist local reset ".len,
                .query = split.rest,
            },
            .user => .{
                .completions = &allowlist_user_reset_scope_completions,
                .label_offset = "/allowlist user reset ".len,
                .query = split.rest,
            },
        };
    }
    return .{
        .completions = &.{},
        .label_offset = "/allowlist ".len + scope_label.len + 1,
        .query = "",
    };
}

fn allowlistArgCompletionAnchor(prefix: []const u8) ?usize {
    const query = allowlistArgCompletionPrefix(prefix) orelse return null;
    const split = splitAllowlistArgQuery(query);
    if (!split.has_rest) return "/allowlist ".len;
    if (std.ascii.eqlIgnoreCase(split.word, "view")) return "/allowlist view ".len;
    if (std.ascii.eqlIgnoreCase(split.word, "local")) {
        return scopedAllowlistArgCompletionAnchor(.local, split.rest);
    }
    if (std.ascii.eqlIgnoreCase(split.word, "user")) {
        return scopedAllowlistArgCompletionAnchor(.user, split.rest);
    }
    if (std.ascii.eqlIgnoreCase(split.word, "add")) {
        if (allowlistToolArgQuery(split.rest) != null) return "/allowlist add tool ".len;
        return "/allowlist add ".len;
    }
    if (std.ascii.eqlIgnoreCase(split.word, "remove")) {
        if (allowlistToolArgQuery(split.rest) != null) return "/allowlist remove tool ".len;
        return "/allowlist remove ".len;
    }
    if (std.ascii.eqlIgnoreCase(split.word, "reset")) return "/allowlist reset ".len;
    return "/allowlist ".len;
}

fn scopedAllowlistArgCompletionAnchor(
    scope: AllowlistCompletionScope,
    query: []const u8,
) usize {
    const split = splitAllowlistArgQuery(query);
    const base = switch (scope) {
        .local => "/allowlist local ",
        .user => "/allowlist user ",
    };
    if (!split.has_rest) return base.len;
    if (std.ascii.eqlIgnoreCase(split.word, "add")) {
        if (allowlistToolArgQuery(split.rest) != null) return base.len + "add tool ".len;
        return base.len + "add ".len;
    }
    if (std.ascii.eqlIgnoreCase(split.word, "remove")) {
        if (allowlistToolArgQuery(split.rest) != null) return base.len + "remove tool ".len;
        return base.len + "remove ".len;
    }
    if (std.ascii.eqlIgnoreCase(split.word, "reset")) return base.len + "reset ".len;
    return base.len;
}

fn allowlistToolArgQuery(query: []const u8) ?[]const u8 {
    const split = splitAllowlistArgQuery(query);
    if (!split.has_rest) return null;
    if (!std.ascii.eqlIgnoreCase(split.word, "tool")) return null;
    return split.rest;
}

const AllowlistArgQuery = struct {
    word: []const u8,
    rest: []const u8,
    has_rest: bool,
};

fn splitAllowlistArgQuery(query: []const u8) AllowlistArgQuery {
    const trimmed_start = std.mem.trimStart(u8, query, " \t");
    for (trimmed_start, 0..) |c, idx| {
        if (c == ' ' or c == '\t') {
            return .{
                .word = trimmed_start[0..idx],
                .rest = std.mem.trimStart(u8, trimmed_start[idx + 1 ..], " \t"),
                .has_rest = true,
            };
        }
    }
    return .{ .word = trimmed_start, .rest = "", .has_rest = false };
}

fn renderSlashEntries(alloc: Allocator, registry: SlashRegistry, welcome_only: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var first = true;
    for (registry.commands) |spec| {
        if (welcome_only) {
            if (!spec.show_in_welcome) continue;
            if (!first) try out.writer.writeAll("  ");
            first = false;
            try out.writer.writeAll(spec.command);
            continue;
        }

        const entry = spec.help_entry orelse continue;
        if (!first) try out.writer.writeByte(' ');
        first = false;
        try out.writer.writeAll(entry);
    }

    return try out.toOwnedSlice();
}

fn topLevelSpec(registry: TopLevelRegistry, kind: TopLevelKind) TopLevelSpec {
    for (registry.specs) |spec| {
        if (spec.kind == kind) return spec;
    }
    unreachable;
}

fn slashSpec(registry: SlashRegistry, kind: SlashKind) SlashSpec {
    return slashSpecPtr(registry, kind).*;
}

fn slashSpecPtr(registry: SlashRegistry, kind: SlashKind) *const SlashSpec {
    for (registry.commands) |*spec| {
        if (spec.kind == kind) return spec;
    }
    unreachable;
}

fn matchesCommandToken(input: []const u8, primary: []const u8, aliases: []const []const u8) bool {
    if (std.mem.eql(u8, input, primary)) return true;
    for (aliases) |alias| {
        if (std.mem.eql(u8, input, alias)) return true;
    }

    if (input.len == 0) return false;
    const last = input[input.len - 1];
    if (last != ' ' and last != '\t') return false;

    const trimmed = std.mem.trimEnd(u8, input, " \t");
    if (std.mem.eql(u8, trimmed, primary)) return true;
    for (aliases) |alias| {
        if (std.mem.eql(u8, trimmed, alias)) return true;
    }
    return false;
}

fn normalizedTopLevelHelpWidth(columns: usize) usize {
    return if (columns == 0) top_level_help_default_width else columns;
}

fn maxTopLevelHelpUsageWidth(registry: TopLevelRegistry) usize {
    var width: usize = 0;
    for (registry.help_groups) |group| {
        for (group.entries) |entry| {
            if (entry.kind) |kind| {
                if (topLevelSpec(registry, kind).hidden_from_top_level_help) continue;
            }
            width = @max(width, entry.usage.len);
        }
    }
    return width;
}

fn maxTopLevelFlagUsageWidth(registry: TopLevelRegistry) usize {
    var width: usize = 0;
    for (registry.flags) |flag| {
        width = @max(width, flag.usage.len);
    }
    return width;
}

fn maxTopLevelResourceLabelWidth(registry: TopLevelRegistry) usize {
    var width: usize = 0;
    for (registry.resources) |resource| {
        width = @max(width, display_width.visibleWidth(resource.label));
    }
    return width;
}

fn writeTopLevelHelpEntry(writer: *std.Io.Writer, registry: TopLevelRegistry, entry: TopLevelHelpEntry, usage_width: usize, columns: usize, style: HelpStyle) !void {
    const spaces = "                                                                ";
    const summary = entry.summary orelse topLevelSpec(registry, entry.kind.?).summary;
    if (entry.kind) |kind| {
        if (topLevelSpec(registry, kind).hidden_from_top_level_help) return;
    }
    const padding = usage_width - entry.usage.len + 2;
    var prefix_buf: [128]u8 = undefined;
    var continuation_buf: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "  {s}{s}{s}{s}", .{ styleStart(style, .syntax), entry.usage, styleEnd(style), spaces[0..padding] });
    const continuation = try std.fmt.bufPrint(&continuation_buf, "  {s}", .{spaces[0 .. usage_width + 2]});
    try writeWrappedLine(writer, prefix, continuation, summary, columns);
}

fn writeTopLevelFlag(writer: *std.Io.Writer, flag: TopLevelFlag, usage_width: usize, columns: usize, style: HelpStyle) !void {
    const spaces = "                                                                ";
    const padding = usage_width - flag.usage.len + 2;
    var prefix_buf: [160]u8 = undefined;
    var continuation_buf: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "  {s}{s}{s}{s}", .{ styleStart(style, .syntax), flag.usage, styleEnd(style), spaces[0..padding] });
    const continuation = try std.fmt.bufPrint(&continuation_buf, "  {s}", .{spaces[0 .. usage_width + 2]});
    try writeWrappedLine(writer, prefix, continuation, flag.description, columns);
}

fn writeTopLevelExample(writer: *std.Io.Writer, example: TopLevelExample, columns: usize, style: HelpStyle) !void {
    try writeWrappedStyledLine(writer, "  ", "  ", example.command, columns, style, .syntax);
    try writeWrappedStyledLine(writer, "      ", "      ", example.description, columns, style, .muted);
    try writer.writeByte('\n');
}

fn writeTopLevelResource(writer: *std.Io.Writer, resource: TopLevelResource, label_width: usize, columns: usize, style: HelpStyle) !void {
    const spaces = "                                                                ";
    const padding = label_width - display_width.visibleWidth(resource.label) + 2;
    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}{s}{s}{s}", .{ styleStart(style, .label), resource.label, styleEnd(style), spaces[0..padding] });
    const value_role: HelpRole = if (resource.link) .link else .syntax;
    try writeWrappedStyledLine(writer, prefix, "  ", resource.value, columns, style, value_role);
}

fn writeSectionHeading(writer: *std.Io.Writer, style: HelpStyle, heading: []const u8) !void {
    try writer.writeByte('\n');
    try writeStyled(writer, style, .heading, heading);
    try writer.writeByte('\n');
}

fn writeStyled(writer: *std.Io.Writer, style: HelpStyle, role: HelpRole, text: []const u8) !void {
    try writeStyleStart(writer, style, role);
    try writer.writeAll(text);
    try writeStyleEnd(writer, style);
}

fn writeStyleStart(writer: *std.Io.Writer, style: HelpStyle, role: HelpRole) !void {
    try writer.writeAll(styleStart(style, role));
}

fn writeStyleEnd(writer: *std.Io.Writer, style: HelpStyle) !void {
    try writer.writeAll(styleEnd(style));
}

fn styleStart(style: HelpStyle, role: HelpRole) []const u8 {
    if (style == .plain) return "";
    return switch (role) {
        .brand => "\x1b[1m",
        .heading, .label => "\x1b[1m",
        .syntax => "\x1b[39m",
        .muted => "\x1b[38;5;243m",
        .link => "\x1b[4m",
    };
}

fn styleEnd(style: HelpStyle) []const u8 {
    return if (style == .ansi) "\x1b[0m" else "";
}

fn writeWrappedStyledLine(writer: *std.Io.Writer, prefix: []const u8, continuation_prefix: []const u8, text: []const u8, columns: usize, style: HelpStyle, role: HelpRole) !void {
    return writeWrappedLineDecorated(writer, prefix, continuation_prefix, text, columns, styleStart(style, role), styleEnd(style));
}

fn writeWrappedLine(writer: *std.Io.Writer, prefix: []const u8, continuation_prefix: []const u8, text: []const u8, columns: usize) !void {
    return writeWrappedLineDecorated(writer, prefix, continuation_prefix, text, columns, "", "");
}

fn writeWrappedLineDecorated(writer: *std.Io.Writer, prefix: []const u8, continuation_prefix: []const u8, text: []const u8, columns: usize, text_start: []const u8, text_end: []const u8) !void {
    const prefix_width = display_width.visibleWidthIgnoringAnsi(prefix);
    const continuation_width = display_width.visibleWidthIgnoringAnsi(continuation_prefix);
    var budget = if (columns > prefix_width) columns - prefix_width else 1;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var line_width: usize = 0;

    try writer.writeAll(prefix);
    try writer.writeAll(text_start);
    while (words.next()) |word| {
        const word_width = display_width.visibleWidthIgnoringAnsi(word);
        if (line_width == 0) {
            try writer.writeAll(word);
            line_width = word_width;
            continue;
        }

        if (line_width + 1 + word_width <= budget) {
            try writer.writeByte(' ');
            try writer.writeAll(word);
            line_width += 1 + word_width;
            continue;
        }

        try writer.writeAll(text_end);
        try writer.writeByte('\n');
        try writer.writeAll(continuation_prefix);
        try writer.writeAll(text_start);
        budget = if (columns > continuation_width) columns - continuation_width else 1;
        try writer.writeAll(word);
        line_width = word_width;
    }
    try writer.writeAll(text_end);
    try writer.writeByte('\n');
}

fn writePadding(writer: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(' ');
    }
}

fn topLevelTokenOccurrences(registry: TopLevelRegistry, token: []const u8) usize {
    var count: usize = 0;
    for (registry.specs) |spec| {
        if (std.mem.eql(u8, token, spec.token)) count += 1;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, token, alias)) count += 1;
        }
    }
    return count;
}

fn slashTokenOccurrences(registry: SlashRegistry, token: []const u8) usize {
    var count: usize = 0;
    for (registry.commands) |spec| {
        if (std.mem.eql(u8, token, spec.command)) count += 1;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, token, alias)) count += 1;
        }
    }
    return count;
}

fn topLevelIndexOccurrences(registry: TopLevelRegistry, kind: TopLevelKind) usize {
    var count: usize = 0;
    for (registry.help_groups) |group| {
        for (group.entries) |entry| {
            if (entry.kind == kind) count += 1;
        }
    }
    return count;
}

fn topLevelHelpContainsCommandToken(text: []const u8, token: []const u8) bool {
    var index: usize = 0;
    while (std.mem.find(u8, text[index..], token)) |relative| {
        const start = index + relative;
        const end = start + token.len;
        const before_ok = start == 0 or isTopLevelTokenBoundary(text[start - 1]);
        const after_ok = end == text.len or isTopLevelTokenBoundary(text[end]);
        if (before_ok and after_ok) return true;
        index = end;
    }
    return false;
}

fn isTopLevelTokenBoundary(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == ',' or byte == ':' or byte == '<' or byte == '>' or byte == '[' or byte == ']' or byte == '|';
}

fn expectAllLinesFit(text: []const u8, columns: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidth(line) <= columns);
    }
}

fn testSlashRegistry() SlashRegistry {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.slash_registry;
}

fn testTopLevelRegistry() TopLevelRegistry {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.top_level_registry;
}

fn testTopLevelHelpText(alloc: Allocator) ![]u8 {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.renderTopLevelHelp(alloc, top_level_help_default_width, "9.8.7");
}

fn stripAnsiForTest(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            index = display_width.ansiSequenceEnd(text, index);
            continue;
        }
        try out.writer.writeByte(text[index]);
        index += 1;
    }
    return out.toOwnedSlice();
}

fn lineContainsBoth(text: []const u8, first: []const u8, second: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, first) != null and std.mem.find(u8, line, second) != null) return true;
    }
    return false;
}

test "top-level matcher recognizes help aliases" {
    const registry = testTopLevelRegistry();
    try std.testing.expect(matchesTopLevel(registry, "help", .help));
    try std.testing.expect(matchesTopLevel(registry, "--help", .help));
    try std.testing.expect(matchesTopLevel(registry, "-h", .help));
    try std.testing.expect(!matchesTopLevel(registry, "wat", .help));
}

test "slash prefix matcher recognizes aliases and whitespace boundaries" {
    try std.testing.expectEqualStrings("/image", matchedSlashPrefix(testSlashRegistry(), "/image screenshot.png", .image).?);
    try std.testing.expectEqualStrings("/img", matchedSlashPrefix(testSlashRegistry(), "/img screenshot.png", .image).?);
    try std.testing.expect(matchedSlashPrefix(testSlashRegistry(), "/imagesx", .images) == null);
}

test "rendered top-level help is a complete CLI navigation page" {
    const text = try testTopLevelHelpText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "𝒇x v9.8.7\nFast, native coding agent for the terminal."));
    try std.testing.expect(std.mem.find(u8, text, "𝒇x starts an interactive session by default.") != null);
    try std.testing.expect(std.mem.find(u8, text, "fx <command> [...flags] [...args]") != null);
    try std.testing.expect(std.mem.find(u8, text, "Commands:") != null);
    try std.testing.expect(std.mem.find(u8, text, "ask <prompt>") != null);
    try std.testing.expect(std.mem.find(u8, text, "Run one noninteractive request") != null);
    try std.testing.expect(std.mem.find(u8, text, "Draft or publish a GitHub issue") != null);
    try std.testing.expect(std.mem.find(u8, text, "credits|balance") != null);
    try std.testing.expect(std.mem.find(u8, text, "Show the AI Gateway credit balance") != null);
    try std.testing.expect(std.mem.find(u8, text, "Flags:") != null);
    try std.testing.expect(std.mem.find(u8, text, "--context-limit <spec>") != null);
    try std.testing.expect(std.mem.find(u8, text, "Set name=bytes|off; repeatable") != null);
    try std.testing.expect(std.mem.find(u8, text, "--add-dir <path>") != null);
    try std.testing.expect(std.mem.find(u8, text, "-c, --continue") != null);
    try std.testing.expect(std.mem.find(u8, text, "-r") != null);
    try std.testing.expect(std.mem.find(u8, text, "-c, -r, --continue") == null);
    try std.testing.expect(std.mem.find(u8, text, "--resume [last|<id>]") != null);
    try std.testing.expect(std.mem.find(u8, text, "--resume-last") != null);
    try std.testing.expect(std.mem.find(u8, text, "-v, --version") != null);
    try std.testing.expect(std.mem.find(u8, text, "Must appear before the command. Accepted names:") == null);
    try std.testing.expect(std.mem.find(u8, text, "skill_description_bytes, skill_catalog_bytes") == null);
    try std.testing.expect(std.mem.find(u8, text, "FX_EXPERIMENTAL_WORKSPACE_ACCESS=1") == null);
    try std.testing.expect(std.mem.find(u8, text, "Supported for interactive, resume, ask, ACP, PR, and issue launches") == null);
    try std.testing.expect(std.mem.find(u8, text, "Examples:") != null);
    try std.testing.expect(std.mem.find(u8, text, "fx ask \"Explain the changes in this repository\"") != null);
    try std.testing.expect(std.mem.find(u8, text, "fx session resume last") != null);
    try std.testing.expect(std.mem.find(u8, text, "session resume [last|id]") != null);
    try std.testing.expect(std.mem.find(u8, text, "fx status --json") != null);
    try std.testing.expect(std.mem.find(u8, text, "Run `/help` inside an interactive session for slash commands.") != null);
    try std.testing.expect(std.mem.find(u8, text, "Learn more about 𝒇x:  https://fx.sh/docs") != null);
    try std.testing.expect(std.mem.find(u8, text, "\nReport a problem:     run `/feedback` inside 𝒇x\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "\n\n\nRun `fx <command> --help`") == null);
    try std.testing.expect(std.mem.find(u8, text, "Start:") == null);
    try std.testing.expect(std.mem.find(u8, text, "  Work      ") == null);
    try std.testing.expect(std.mem.find(u8, text, "More:") == null);
    try std.testing.expect(std.mem.find(u8, text, "resume [last|<id>] [--record]") == null);
    try std.testing.expect(std.mem.find(u8, text, "session migrate <id>|--id <id>") == null);
}

test "terminal top-level help adds styling without changing visible content" {
    const plain = try renderTopLevelHelp(std.testing.allocator, testTopLevelRegistry(), top_level_help_default_width, "9.8.7");
    defer std.testing.allocator.free(plain);
    const terminal = try renderTopLevelHelpWithStyle(std.testing.allocator, testTopLevelRegistry(), top_level_help_default_width, "9.8.7", .ansi);
    defer std.testing.allocator.free(terminal);
    const stripped = try stripAnsiForTest(std.testing.allocator, terminal);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.find(u8, plain, "\x1b[") == null);
    try std.testing.expect(std.mem.startsWith(u8, terminal, "\x1b[1m𝒇x\x1b[0m"));
    try std.testing.expect(std.mem.find(u8, terminal, "\x1b[1mUsage:\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, terminal, "\x1b[39mask <prompt>\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, terminal, "\x1b[38;5;243mFast, native coding agent") != null);
    try std.testing.expect(std.mem.find(u8, terminal, "\x1b[4mhttps://fx.sh/docs\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, terminal, "\x1b[39mrun `/feedback` inside 𝒇x\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, terminal, "\x1b[38;5;252m") == null);
    try std.testing.expect(std.mem.find(u8, terminal, "\x1b[38;5;245m") == null);
    try std.testing.expectEqualStrings(plain, stripped);
}

test "top-level help renders flags as compact aligned rows" {
    const wide = try renderTopLevelHelp(std.testing.allocator, testTopLevelRegistry(), 120, "9.8.7");
    defer std.testing.allocator.free(wide);
    const narrow = try renderTopLevelHelp(std.testing.allocator, testTopLevelRegistry(), 60, "9.8.7");
    defer std.testing.allocator.free(narrow);

    try std.testing.expect(lineContainsBoth(wide, "--record", "Record terminal output"));
    try std.testing.expect(lineContainsBoth(wide, "--context-limit <spec>", "Set name=bytes|off; repeatable"));
    try std.testing.expect(lineContainsBoth(wide, "--add-dir <path>", "Add a workspace directory; repeatable"));
    try std.testing.expect(lineContainsBoth(wide, "-c, --continue", "Resume the latest workspace session"));
    try std.testing.expect(lineContainsBoth(wide, "-r", "Open the saved-session picker"));
    try std.testing.expect(lineContainsBoth(wide, "--resume [last|<id>]", "Resume the latest workspace session or an exact ID"));
    try std.testing.expect(lineContainsBoth(wide, "--resume-last", "Resume the latest workspace session"));
    try std.testing.expect(std.mem.find(u8, wide, "Record terminal output\n\n  --context-limit") == null);
    try std.testing.expect(std.mem.find(u8, wide, "Print the 𝒇x version and exit\n\nExamples:") != null);
    try expectAllLinesFit(narrow, 60);

    var lines = std.mem.splitScalar(u8, wide, '\n');
    while (lines.next()) |line| {
        const description_start = std.mem.find(u8, line, "Record terminal output") orelse continue;
        try std.testing.expect(display_width.visibleWidth(line[0..description_start]) <= 28);
        break;
    } else {
        return error.TestExpectedEqual;
    }
}

test "default top-level help styles fit the startup buffer" {
    const builtin_commands = @import("../../builtins/commands.zig");
    for ([_]HelpStyle{ .plain, .ansi }) |style| {
        const text = try renderTopLevelHelpWithStyle(std.testing.allocator, testTopLevelRegistry(), top_level_help_default_width, "9.8.7", style);
        defer std.testing.allocator.free(text);

        try std.testing.expect(text.len <= builtin_commands.top_level_help_fast_buffer_bytes);
    }
}

test "per-command help renders header usage options and details" {
    const text = try renderTopLevelCommandHelp(std.testing.allocator, testTopLevelRegistry(), .permissions);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "fx permissions\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "Usage:\n  fx permissions [--json]") != null);
    try std.testing.expect(std.mem.find(u8, text, "Options:") != null);
    try std.testing.expect(std.mem.find(u8, text, "--json") != null);
    try std.testing.expect(std.mem.find(u8, text, "Modes:") != null);
}

test "per-command help preserves long resume usage outside top-level index" {
    const text = try renderTopLevelCommandHelp(std.testing.allocator, testTopLevelRegistry(), .@"resume");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "Usage:\n  fx session resume [last|<id>] [--record] | session resume --id <id> [--record] | --resume [last|<id>] [--record] | resume [last|<id>] [--record] | resume --id <id> [--record] | --resume-last | --continue | -c | -r | --resume-<id>") != null);
    try std.testing.expect(std.mem.find(u8, text, "Options:") != null);
    try std.testing.expect(std.mem.find(u8, text, "--record") != null);
}

test "ACP help documents accepted options" {
    const text = try renderTopLevelCommandHelp(std.testing.allocator, testTopLevelRegistry(), .acp);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "fx acp\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "Usage:\n  fx acp [--model <id>] [--log-file <path>]") != null);
    try std.testing.expect(std.mem.find(u8, text, "--model <id>") != null);
    try std.testing.expect(std.mem.find(u8, text, "--log-file <path>") != null);
}

test "hidden top-level commands do not reserve help usage width" {
    const registry = testTopLevelRegistry();
    var visible_width: usize = 0;
    var all_width: usize = 0;
    for (registry.help_groups) |group| {
        for (group.entries) |entry| {
            all_width = @max(all_width, entry.usage.len);
            if (entry.kind) |kind| {
                if (topLevelSpec(registry, kind).hidden_from_top_level_help) continue;
            }
            visible_width = @max(visible_width, entry.usage.len);
        }
    }
    try std.testing.expectEqual(visible_width, maxTopLevelHelpUsageWidth(registry));
    try std.testing.expect(all_width >= visible_width);
}

test "slash completion matches prefix and aliases" {
    try std.testing.expectEqualStrings("/help", firstSlashCompletion(testSlashRegistry(), "/he").?);
    try std.testing.expectEqualStrings("/clear", firstSlashCompletion(testSlashRegistry(), "/cl").?);
    try std.testing.expectEqualStrings("/reset", firstSlashCompletion(testSlashRegistry(), "/res").?);
    try std.testing.expect(firstSlashCompletion(testSlashRegistry(), "/help") == null);
    try std.testing.expect(firstSlashCompletion(testSlashRegistry(), "hello") == null);
    try std.testing.expect(firstSlashCompletion(testSlashRegistry(), "") == null);
}

test "slash completion ranks exact prefix and substring command matches" {
    const specs = [_]SlashSpec{
        .{ .kind = .models, .command = "/models", .help_entry = "/models", .completion_description = "browse models", .presentation_category = .model },
        .{ .kind = .rename_session, .command = "/rename", .help_entry = "/rename <title>", .completion_description = "rename session", .presentation_category = .session },
        .{ .kind = .model, .command = "/model", .help_entry = "/model <id>", .completion_description = "choose model", .presentation_category = .model },
    };
    const registry = SlashRegistry{ .commands = specs[0..] };

    try std.testing.expectEqual(@as(usize, 2), slashCompletionCount(registry, "/model"));
    try std.testing.expectEqualStrings("/model", nthSlashCompletion(registry, "/model", 0).?);
    try std.testing.expectEqualStrings("choose model", nthSlashCompletionDescription(registry, "/model", 0).?);
    try std.testing.expectEqualStrings("/models", nthSlashCompletion(registry, "/model", 1).?);

    try std.testing.expectEqual(@as(usize, 2), slashCompletionCount(registry, "/mo"));
    try std.testing.expectEqualStrings("/models", nthSlashCompletion(registry, "/mo", 0).?);
    try std.testing.expectEqualStrings("/model", nthSlashCompletion(registry, "/mo", 1).?);

    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(registry, "/name"));
    try std.testing.expectEqualStrings("/rename", nthSlashCompletion(registry, "/name", 0).?);
    try std.testing.expectEqual(SlashPresentationCategory.session, nthSlashCompletionCategory(registry, "/name", 0).?);

    try std.testing.expectEqual(@as(usize, 0), slashCompletionCount(registry, "/missing"));
    try std.testing.expect(nthSlashCompletion(registry, "/missing", 0) == null);
}

test "slash completion exposes interactive resume" {
    try std.testing.expectEqualStrings("/resume", nthSlashCompletion(testSlashRegistry(), "/resume", 0).?);
}

test "top-level slash completion metadata is complete" {
    const registry = testSlashRegistry();
    for (registry.commands) |spec| {
        if (spec.help_entry == null) continue;
        try std.testing.expect(spec.completion_description != null);
        try std.testing.expect(spec.completion_description.?.len > 0);
        try std.testing.expect(spec.presentation_category != null);
    }
}

test "slash completion categories follow canonical entries" {
    const registry = testSlashRegistry();
    try std.testing.expectEqual(SlashPresentationCategory.general, nthSlashCompletionCategory(registry, "/he", 0).?);
    try std.testing.expectEqual(SlashPresentationCategory.account, nthSlashCompletionCategory(registry, "/us", 0).?);
    try std.testing.expectEqualStrings("General", SlashPresentationCategory.general.label());
    try std.testing.expect(nthSlashCompletionCategory(registry, "/permissions ", 0) == null);
}

test "help catalog groups visible commands and searches all command metadata" {
    const registry = testSlashRegistry();

    try std.testing.expectEqual(@as(usize, 38), helpCatalogCount(registry, ""));
    try std.testing.expectEqualStrings("/help", helpCatalogSpecAt(registry, "", 0).?.command);
    try std.testing.expectEqual(@as(usize, 5), helpCatalogCategoryCount(registry, "", .general));
    try std.testing.expectEqual(@as(usize, 4), helpCatalogCount(registry, "appearance"));
    try std.testing.expectEqualStrings("/paste", helpCatalogSpecAt(registry, "clipboard", 0).?.command);
}

test "help menu selection follows the filtered catalog without executing commands" {
    const registry = testSlashRegistry();
    var menu: HelpMenu = .{};

    menu.open();
    try std.testing.expect(menu.active);
    try std.testing.expect(menu.move(registry, "session", 1, 4));
    try std.testing.expectEqual(@as(usize, 1), menu.selected_index);
    try std.testing.expect(menu.selectedSpec(registry, "session") != null);

    menu.resetForQuery();
    try std.testing.expectEqual(@as(usize, 0), menu.selected_index);
    try std.testing.expect(menu.selectedSpec(registry, "no command can match this query") == null);

    menu.close();
    try std.testing.expect(!menu.active);
}

test "completion command matcher returns primary or alias" {
    const help_spec = testSlashRegistry().commands[0];
    try std.testing.expectEqualStrings("/help", matchedCompletionCommand(help_spec, "/").?);
    try std.testing.expectEqualStrings("/help", matchedCompletionCommand(help_spec, "/he").?);
    try std.testing.expect(matchedCompletionCommand(help_spec, "/cl") == null);
}

test "rendered slash summaries include aliases and welcome entries" {
    const help_text = try renderSlashHelp(std.testing.allocator, testSlashRegistry());
    defer std.testing.allocator.free(help_text);
    try std.testing.expect(std.mem.find(u8, help_text, "/image <path> (/img)") != null);

    const welcome_text = try renderSlashWelcome(std.testing.allocator, testSlashRegistry());
    defer std.testing.allocator.free(welcome_text);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/quit") != null);
}

test "top-level specs cover every TopLevelKind" {
    const registry = testTopLevelRegistry();
    var seen = [_]bool{false} ** std.meta.fields(TopLevelKind).len;
    for (registry.specs) |spec| {
        const index = @intFromEnum(spec.kind);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    inline for (std.meta.fields(TopLevelKind)) |field| {
        const kind: TopLevelKind = @enumFromInt(field.value);
        try std.testing.expect(seen[@intFromEnum(kind)]);
        try std.testing.expect(topLevelUsage(registry, kind).len > 0);
    }
}

test "slash specs cover every SlashKind" {
    var seen = [_]bool{false} ** std.meta.fields(SlashKind).len;
    const registry = testSlashRegistry();
    for (registry.commands) |spec| {
        const index = @intFromEnum(spec.kind);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    inline for (std.meta.fields(SlashKind)) |field| {
        const kind: SlashKind = @enumFromInt(field.value);
        try std.testing.expect(seen[@intFromEnum(kind)]);
        _ = slashSpec(registry, kind);
    }
}

test "child chat slash registry exposes only locally handled commands" {
    var storage: [child_chat_slash_command_count]SlashSpec = undefined;
    const child = childChatSlashRegistry(testSlashRegistry(), &storage);

    try std.testing.expectEqual(@as(usize, 3), child.commands.len);
    try std.testing.expect(matchesSlashExact(child, "/quit", .quit));
    try std.testing.expect(matchesSlashExact(child, "/models", .models));
    try std.testing.expect(matchesSlashExact(child, "/skills", .skills));
    try std.testing.expect(child.matchExact("/help") == null);
}

test "default slash registry resolves primary commands and aliases" {
    const registry = testSlashRegistry();
    const image = registry.lookup("/img") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.image, image.kind);

    const quit = registry.matchExact("/exit\t") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SlashKind.quit, quit.command.kind);
    try std.testing.expectEqualStrings("/exit", quit.token);

    const model = registry.matchEntryPrefix("/model\tmodel-id", slashSpecPtr(registry, .model)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/model", model);

    try std.testing.expect(registry.matchEntryPrefix("/model\nmodel-id", slashSpecPtr(registry, .model)) == null);
}

test "top-level specs keep unique tokens and aliases" {
    const registry = testTopLevelRegistry();
    for (registry.specs) |spec| {
        try std.testing.expectEqual(@as(usize, 1), topLevelTokenOccurrences(registry, spec.token));
        for (spec.aliases) |alias| {
            try std.testing.expectEqual(@as(usize, 1), topLevelTokenOccurrences(registry, alias));
        }
    }
}

test "top-level help index covers visible commands once" {
    const registry = testTopLevelRegistry();
    for (registry.specs) |spec| {
        const expected: usize = if (spec.hidden_from_top_level_help) 0 else 1;
        try std.testing.expectEqual(expected, topLevelIndexOccurrences(registry, spec.kind));
    }
}

test "slash specs keep unique commands and aliases" {
    const registry = testSlashRegistry();
    for (registry.commands) |spec| {
        try std.testing.expectEqual(@as(usize, 1), slashTokenOccurrences(registry, spec.command));
        for (spec.aliases) |alias| {
            try std.testing.expectEqual(@as(usize, 1), slashTokenOccurrences(registry, alias));
        }
    }
}

test "slash prefix matcher accepts tab boundary and rejects newline boundary" {
    try std.testing.expectEqualStrings("/image", matchedSlashPrefix(testSlashRegistry(), "/image\tshot.png", .image).?);
    try std.testing.expect(matchedSlashPrefix(testSlashRegistry(), "/image\nshot.png", .image) == null);
}

test "slash completion prefix normalizes leading whitespace and preserves argument queries" {
    const registry = testSlashRegistry();

    try std.testing.expectEqualStrings("/he", slashCompletionPrefix(registry, "\n   /he").?);
    try std.testing.expectEqualStrings("/resume-helper", slashCompletionPrefix(registry, "/resume-helper").?);
    try std.testing.expectEqualStrings("/not-a-command ", slashCompletionPrefix(registry, "/not-a-command ").?);
}

test "slash completion prefix yields to no-argument command submission" {
    const registry = testSlashRegistry();

    try std.testing.expectEqualStrings("/resume", slashCompletionPrefix(registry, "/resume").?);
    try std.testing.expect(slashCompletionPrefix(registry, "/resume ") == null);
    try std.testing.expect(slashCompletionPrefix(registry, "\n\t/resume\nignored") == null);
    try std.testing.expect(slashCompletionPrefix(registry, "/exit\t") == null);
}

test "slash completions skip hidden subcommands" {
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/background"));
    try std.testing.expectEqualStrings("/background", nthSlashCompletion(testSlashRegistry(), "/background", 0).?);
    try std.testing.expect(nthSlashCompletion(testSlashRegistry(), "/background", 1) == null);
    try std.testing.expectEqual(@as(usize, 0), slashCompletionCount(testSlashRegistry(), "/background s"));
    try std.testing.expect(nthSlashCompletion(testSlashRegistry(), "/background s", 0) == null);
}

test "slash completions include allowlist staged arguments" {
    try std.testing.expectEqual(@as(usize, 6), slashCompletionCount(testSlashRegistry(), "/allowlist "));
    try std.testing.expectEqualStrings("/allowlist view", nthSlashCompletion(testSlashRegistry(), "/allowlist ", 0).?);
    try std.testing.expectEqualStrings("/allowlist add", nthSlashCompletion(testSlashRegistry(), "/allowlist ", 1).?);
    try std.testing.expectEqualStrings("/allowlist remove", nthSlashCompletion(testSlashRegistry(), "/allowlist ", 2).?);
    try std.testing.expectEqualStrings("/allowlist reset", nthSlashCompletion(testSlashRegistry(), "/allowlist ", 3).?);
    try std.testing.expectEqualStrings("/allowlist local", nthSlashCompletion(testSlashRegistry(), "/allowlist ", 4).?);
    try std.testing.expectEqualStrings("/allowlist user", nthSlashCompletion(testSlashRegistry(), "/allowlist ", 5).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/allowlist a"));
    try std.testing.expectEqualStrings("/allowlist add", nthSlashCompletion(testSlashRegistry(), "/allowlist a", 0).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/allowlist v"));
    try std.testing.expectEqualStrings("/allowlist view", nthSlashCompletion(testSlashRegistry(), "/allowlist v", 0).?);
    try std.testing.expectEqual(@as(usize, 2), slashCompletionCount(testSlashRegistry(), "/allowlist re"));
    try std.testing.expectEqualStrings("/allowlist remove", nthSlashCompletion(testSlashRegistry(), "/allowlist re", 0).?);
    try std.testing.expectEqualStrings("/allowlist reset", nthSlashCompletion(testSlashRegistry(), "/allowlist re", 1).?);
    try std.testing.expectEqual(@as(usize, 0), slashCompletionCount(testSlashRegistry(), "/allowlist nope "));

    try std.testing.expectEqual(@as(usize, 4), slashCompletionCount(testSlashRegistry(), "/allowlist add "));
    try std.testing.expectEqualStrings("/allowlist add command", nthSlashCompletion(testSlashRegistry(), "/allowlist add ", 0).?);
    try std.testing.expectEqualStrings("/allowlist add tool", nthSlashCompletion(testSlashRegistry(), "/allowlist add ", 1).?);
    try std.testing.expectEqualStrings("/allowlist add url", nthSlashCompletion(testSlashRegistry(), "/allowlist add ", 2).?);
    try std.testing.expectEqualStrings("/allowlist add web-fetch-domain", nthSlashCompletion(testSlashRegistry(), "/allowlist add ", 3).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/allowlist add u"));
    try std.testing.expectEqualStrings("/allowlist add url", nthSlashCompletion(testSlashRegistry(), "/allowlist add u", 0).?);
    try std.testing.expectEqual(@as(usize, allowlist_add_tool_completions.len), slashCompletionCount(testSlashRegistry(), "/allowlist add tool "));
    try std.testing.expectEqualStrings("/allowlist add tool read_file", nthSlashCompletion(testSlashRegistry(), "/allowlist add tool ", 0).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/allowlist add tool write"));
    try std.testing.expectEqualStrings("/allowlist add tool write_file", nthSlashCompletion(testSlashRegistry(), "/allowlist add tool write", 0).?);

    try std.testing.expectEqual(@as(usize, 4), slashCompletionCount(testSlashRegistry(), "/allowlist remove "));
    try std.testing.expectEqualStrings("/allowlist remove command", nthSlashCompletion(testSlashRegistry(), "/allowlist remove ", 0).?);
    try std.testing.expectEqualStrings("/allowlist remove tool", nthSlashCompletion(testSlashRegistry(), "/allowlist remove ", 1).?);
    try std.testing.expectEqualStrings("/allowlist remove url", nthSlashCompletion(testSlashRegistry(), "/allowlist remove ", 2).?);
    try std.testing.expectEqualStrings("/allowlist remove web-fetch-domain", nthSlashCompletion(testSlashRegistry(), "/allowlist remove ", 3).?);
    try std.testing.expectEqual(@as(usize, allowlist_remove_tool_completions.len), slashCompletionCount(testSlashRegistry(), "/allowlist remove tool "));
    try std.testing.expectEqualStrings("/allowlist remove tool read_file", nthSlashCompletion(testSlashRegistry(), "/allowlist remove tool ", 0).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/allowlist remove tool skill"));
    try std.testing.expectEqualStrings("/allowlist remove tool skill", nthSlashCompletion(testSlashRegistry(), "/allowlist remove tool skill", 0).?);

    try std.testing.expectEqual(@as(usize, 5), slashCompletionCount(testSlashRegistry(), "/allowlist reset "));
    try std.testing.expectEqualStrings("/allowlist reset commands", nthSlashCompletion(testSlashRegistry(), "/allowlist reset ", 0).?);
    try std.testing.expectEqualStrings("/allowlist reset tools", nthSlashCompletion(testSlashRegistry(), "/allowlist reset ", 1).?);
    try std.testing.expectEqualStrings("/allowlist reset urls", nthSlashCompletion(testSlashRegistry(), "/allowlist reset ", 2).?);
    try std.testing.expectEqualStrings("/allowlist reset web-fetch-domains", nthSlashCompletion(testSlashRegistry(), "/allowlist reset ", 3).?);
    try std.testing.expectEqualStrings("/allowlist reset all", nthSlashCompletion(testSlashRegistry(), "/allowlist reset ", 4).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/allowlist reset c"));
    try std.testing.expectEqualStrings("/allowlist reset commands", nthSlashCompletion(testSlashRegistry(), "/allowlist reset c", 0).?);

    try std.testing.expectEqual(@as(usize, 3), slashCompletionCount(testSlashRegistry(), "/allowlist view "));
    try std.testing.expectEqualStrings("/allowlist view effective", nthSlashCompletion(testSlashRegistry(), "/allowlist view ", 0).?);
    try std.testing.expectEqualStrings("/allowlist view local", nthSlashCompletion(testSlashRegistry(), "/allowlist view ", 1).?);
    try std.testing.expectEqualStrings("/allowlist view user", nthSlashCompletion(testSlashRegistry(), "/allowlist view ", 2).?);

    try std.testing.expectEqual(@as(usize, 3), slashCompletionCount(testSlashRegistry(), "/allowlist user "));
    try std.testing.expectEqualStrings("/allowlist user add", nthSlashCompletion(testSlashRegistry(), "/allowlist user ", 0).?);
    try std.testing.expectEqualStrings("/allowlist user remove", nthSlashCompletion(testSlashRegistry(), "/allowlist user ", 1).?);
    try std.testing.expectEqualStrings("/allowlist user reset", nthSlashCompletion(testSlashRegistry(), "/allowlist user ", 2).?);
    try std.testing.expectEqual(@as(usize, 4), slashCompletionCount(testSlashRegistry(), "/allowlist user add "));
    try std.testing.expectEqualStrings("/allowlist user add command", nthSlashCompletion(testSlashRegistry(), "/allowlist user add ", 0).?);
    try std.testing.expectEqual(@as(usize, allowlist_user_add_tool_completions.len), slashCompletionCount(testSlashRegistry(), "/allowlist user add tool "));
    try std.testing.expectEqualStrings("/allowlist user add tool read_file", nthSlashCompletion(testSlashRegistry(), "/allowlist user add tool ", 0).?);
    try std.testing.expectEqual(@as(usize, 5), slashCompletionCount(testSlashRegistry(), "/allowlist local reset "));
    try std.testing.expectEqualStrings("/allowlist local reset all", nthSlashCompletion(testSlashRegistry(), "/allowlist local reset ", 4).?);
}

test "slash completions include web_fetch allowlist domain forms" {
    try std.testing.expectEqualStrings("/allowlist add web-fetch-domain", nthSlashCompletion(testSlashRegistry(), "/allowlist add web-", 0).?);
    try std.testing.expectEqualStrings("web-fetch-domain", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist add web-", 0).?);
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist add web-fetch-domain"));

    try std.testing.expectEqualStrings("/allowlist remove web-fetch-domain", nthSlashCompletion(testSlashRegistry(), "/allowlist remove web-", 0).?);
    try std.testing.expectEqualStrings("web-fetch-domain", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist remove web-", 0).?);
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist remove web-fetch-domain"));

    try std.testing.expectEqualStrings("/allowlist reset web-fetch-domains", nthSlashCompletion(testSlashRegistry(), "/allowlist reset web-", 0).?);
    try std.testing.expectEqualStrings("web-fetch-domains", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist reset web-", 0).?);
    try std.testing.expect(!slashCompletionHasArgs(testSlashRegistry(), "/allowlist reset web-fetch-domains"));
}

test "allowlist staged completions with more arguments append space on tab" {
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist add"));
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist remove"));
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist reset"));
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist add command"));
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist remove url"));
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist user"));
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist user add"));
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist local remove tool"));
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/allowlist view"));
    try std.testing.expect(!slashCompletionHasArgs(testSlashRegistry(), "/allowlist view user"));
    try std.testing.expect(!slashCompletionHasArgs(testSlashRegistry(), "/allowlist reset all"));
}

test "workspace completions expose actions and keep path actions open" {
    try std.testing.expectEqual(@as(usize, 4), slashCompletionCount(testSlashRegistry(), "/workspace "));
    try std.testing.expectEqualStrings("/workspace list", nthSlashCompletion(testSlashRegistry(), "/workspace ", 0).?);
    try std.testing.expectEqualStrings("/workspace add", nthSlashCompletion(testSlashRegistry(), "/workspace a", 0).?);
    try std.testing.expectEqualStrings("add", nthSlashCompletionLabel(testSlashRegistry(), "/workspace a", 0).?);
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/workspace add"));
    try std.testing.expect(slashCompletionHasArgs(testSlashRegistry(), "/workspace remove"));
    try std.testing.expect(!slashCompletionHasArgs(testSlashRegistry(), "/workspace clear"));
}

test "slash completions include sound controls" {
    try std.testing.expectEqual(@as(usize, 3), slashCompletionCount(testSlashRegistry(), "/sound "));
    try std.testing.expectEqualStrings("/sound on", nthSlashCompletion(testSlashRegistry(), "/sound ", 0).?);
    try std.testing.expectEqualStrings("/sound off", nthSlashCompletion(testSlashRegistry(), "/sound ", 1).?);
    try std.testing.expectEqualStrings("/sound max", nthSlashCompletion(testSlashRegistry(), "/sound ", 2).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/sound of"));
    try std.testing.expectEqualStrings("off", nthSlashCompletionLabel(testSlashRegistry(), "/sound of", 0).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/sound ma"));
    try std.testing.expectEqualStrings("max", nthSlashCompletionLabel(testSlashRegistry(), "/sound ma", 0).?);
    try std.testing.expectEqual(@as(usize, "/sound ".len), argCompletionAnchor("/sound "));
}

test "slash completions list permission modes and rule management" {
    try std.testing.expectEqual(@as(usize, 6), slashCompletionCount(testSlashRegistry(), "/permissions "));
    try std.testing.expectEqualStrings("/permissions ask", nthSlashCompletion(testSlashRegistry(), "/permissions ", 0).?);
    try std.testing.expectEqualStrings("/permissions auto", nthSlashCompletion(testSlashRegistry(), "/permissions ", 1).?);
    try std.testing.expectEqualStrings("/permissions remember", nthSlashCompletion(testSlashRegistry(), "/permissions ", 2).?);
    try std.testing.expectEqualStrings("/permissions revoke", nthSlashCompletion(testSlashRegistry(), "/permissions ", 3).?);
    try std.testing.expectEqualStrings("/permissions yolo", nthSlashCompletion(testSlashRegistry(), "/permissions ", 4).?);
    try std.testing.expectEqualStrings("/permissions reset", nthSlashCompletion(testSlashRegistry(), "/permissions ", 5).?);
    try std.testing.expectEqual(@as(usize, 2), slashCompletionCount(testSlashRegistry(), "/permissions a"));
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/permissions as"));
    try std.testing.expectEqualStrings("/permissions ask", nthSlashCompletion(testSlashRegistry(), "/permissions as", 0).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/permissions au"));
    try std.testing.expectEqualStrings("/permissions auto", nthSlashCompletion(testSlashRegistry(), "/permissions au", 0).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/permissions y"));
    try std.testing.expectEqualStrings("/permissions yolo", nthSlashCompletion(testSlashRegistry(), "/permissions y", 0).?);
    try std.testing.expectEqual(@as(usize, 3), slashCompletionCount(testSlashRegistry(), "/permissions r"));
    try std.testing.expectEqualStrings("/permissions remember", nthSlashCompletion(testSlashRegistry(), "/permissions r", 0).?);
    try std.testing.expectEqualStrings("/permissions revoke", nthSlashCompletion(testSlashRegistry(), "/permissions r", 1).?);
    try std.testing.expectEqualStrings("/permissions reset", nthSlashCompletion(testSlashRegistry(), "/permissions r", 2).?);
    try std.testing.expectEqual(@as(usize, 0), slashCompletionCount(testSlashRegistry(), "/permissions x"));
}

test "slash completions include input appearance arguments only" {
    try std.testing.expectEqual(@as(usize, 2), slashCompletionCount(testSlashRegistry(), "/input "));
    try std.testing.expectEqualStrings("/input lines", nthSlashCompletion(testSlashRegistry(), "/input ", 0).?);
    try std.testing.expectEqualStrings("/input tint", nthSlashCompletion(testSlashRegistry(), "/input ", 1).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/input l"));
    try std.testing.expectEqualStrings("/input lines", nthSlashCompletion(testSlashRegistry(), "/input l", 0).?);
    try std.testing.expectEqual(@as(usize, 1), slashCompletionCount(testSlashRegistry(), "/input t"));
    try std.testing.expectEqualStrings("/input tint", nthSlashCompletion(testSlashRegistry(), "/input t", 0).?);
    try std.testing.expectEqual(@as(usize, 0), slashCompletionCount(testSlashRegistry(), "/input x"));
    try std.testing.expectEqual(@as(usize, "/input ".len), argCompletionAnchor("/input "));
    try std.testing.expectEqual(@as(?usize, 0), argCompletionIndexForLabel("/input ", "lines"));
    try std.testing.expectEqual(@as(?usize, 1), argCompletionIndexForLabel("/input ", "tint"));
}

test "slash completions include grouped appearance arguments" {
    try std.testing.expectEqual(@as(usize, 4), slashCompletionCount(testSlashRegistry(), "/appearance "));
    try std.testing.expectEqualStrings("/appearance input lines", nthSlashCompletion(testSlashRegistry(), "/appearance ", 0).?);
    try std.testing.expectEqualStrings("/appearance input tint", nthSlashCompletion(testSlashRegistry(), "/appearance ", 1).?);
    try std.testing.expectEqualStrings("/appearance presentation normal", nthSlashCompletion(testSlashRegistry(), "/appearance ", 2).?);
    try std.testing.expectEqualStrings("/appearance presentation minimal", nthSlashCompletion(testSlashRegistry(), "/appearance ", 3).?);
    try std.testing.expectEqualStrings("presentation minimal", nthSlashCompletionLabel(testSlashRegistry(), "/appearance presentation m", 0).?);
    try std.testing.expectEqual(@as(usize, "/appearance ".len), argCompletionAnchor("/appearance "));
}

test "slash completions include maxxing presentation arguments only" {
    try std.testing.expectEqual(@as(usize, 2), slashCompletionCount(testSlashRegistry(), "/maxxing "));
    try std.testing.expectEqualStrings("/maxxing minimal", nthSlashCompletion(testSlashRegistry(), "/maxxing ", 0).?);
    try std.testing.expectEqualStrings("/maxxing legacy", nthSlashCompletion(testSlashRegistry(), "/maxxing ", 1).?);
    try std.testing.expectEqualStrings("minimal", nthSlashCompletionLabel(testSlashRegistry(), "/maxxing m", 0).?);
    try std.testing.expectEqual(@as(usize, "/maxxing ".len), argCompletionAnchor("/maxxing "));
    try std.testing.expectEqual(@as(?usize, 0), argCompletionIndexForLabel("/maxxing ", "minimal"));
    try std.testing.expectEqual(@as(?usize, 1), argCompletionIndexForLabel("/maxxing ", "legacy"));
}

test "slash completion labels strip argument prefixes" {
    try std.testing.expectEqualStrings("lines", nthSlashCompletionLabel(testSlashRegistry(), "/input ", 0).?);
    try std.testing.expectEqualStrings("tint", nthSlashCompletionLabel(testSlashRegistry(), "/input ", 1).?);
    try std.testing.expectEqualStrings("tint", nthSlashCompletionLabel(testSlashRegistry(), "/input t", 0).?);
    try std.testing.expectEqualStrings("ask", nthSlashCompletionLabel(testSlashRegistry(), "/permissions ", 0).?);
    try std.testing.expectEqualStrings("auto", nthSlashCompletionLabel(testSlashRegistry(), "/permissions ", 1).?);
    try std.testing.expectEqualStrings("remember", nthSlashCompletionLabel(testSlashRegistry(), "/permissions ", 2).?);
    try std.testing.expectEqualStrings("revoke", nthSlashCompletionLabel(testSlashRegistry(), "/permissions ", 3).?);
    try std.testing.expectEqualStrings("yolo", nthSlashCompletionLabel(testSlashRegistry(), "/permissions ", 4).?);
    try std.testing.expectEqualStrings("reset", nthSlashCompletionLabel(testSlashRegistry(), "/permissions ", 5).?);
    try std.testing.expectEqualStrings("view", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist ", 0).?);
    try std.testing.expectEqualStrings("add", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist ", 1).?);
    try std.testing.expectEqualStrings("command", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist add ", 0).?);
    try std.testing.expectEqualStrings("write_file", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist add tool write", 0).?);
    try std.testing.expectEqualStrings("url", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist remove u", 0).?);
    try std.testing.expectEqualStrings("read_file", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist remove tool ", 0).?);
    try std.testing.expectEqualStrings("commands", nthSlashCompletionLabel(testSlashRegistry(), "/allowlist reset c", 0).?);
    try std.testing.expectEqualStrings("/help", nthSlashCompletionLabel(testSlashRegistry(), "/he", 0).?);
}

test "slash completion descriptions follow completion matches" {
    try std.testing.expectEqual(@as(usize, 2), slashCompletionCount(testSlashRegistry(), "/mo"));
    try std.testing.expectEqualStrings("/model", nthSlashCompletion(testSlashRegistry(), "/mo", 0).?);
    try std.testing.expectEqualStrings("choose what model and reasoning effort to use", nthSlashCompletionDescription(testSlashRegistry(), "/mo", 0).?);
    try std.testing.expectEqualStrings("/models", nthSlashCompletion(testSlashRegistry(), "/mo", 1).?);
    try std.testing.expectEqualStrings("start a fresh session and keep background processes", nthSlashCompletionDescription(testSlashRegistry(), "/cl", 0).?);
    try std.testing.expectEqualStrings("undo the latest tracked file operation", nthSlashCompletionDescription(testSlashRegistry(), "/un", 0).?);
    try std.testing.expectEqualStrings("open the fx feedback form", nthSlashCompletionDescription(testSlashRegistry(), "/fee", 0).?);
    try std.testing.expectEqualStrings("copy a private diagnostic trace", nthSlashCompletionDescription(testSlashRegistry(), "/tr", 0).?);
    try std.testing.expectEqualStrings("compact older conversation turns", nthSlashCompletionDescription(testSlashRegistry(), "/comp", 0).?);
    try std.testing.expectEqualStrings("show alias availability", nthSlashCompletionDescription(testSlashRegistry(), "/ali", 0).?);
    try std.testing.expectEqualStrings("toggle Fast mode when supported", nthSlashCompletionDescription(testSlashRegistry(), "/fa", 0).?);
}

test "slash completion aliases participate in ranked order" {
    try std.testing.expectEqualStrings("/background", firstSlashCompletion(testSlashRegistry(), "/ba").?);
    try std.testing.expectEqual(@as(usize, 3), slashCompletionCount(testSlashRegistry(), "/ba"));
    try std.testing.expectEqualStrings("/background", nthSlashCompletion(testSlashRegistry(), "/ba", 0).?);
    try std.testing.expectEqualStrings("/balance", nthSlashCompletion(testSlashRegistry(), "/ba", 1).?);
    try std.testing.expectEqualStrings("/feedback", nthSlashCompletion(testSlashRegistry(), "/ba", 2).?);
    try std.testing.expectEqualStrings("/balance", firstSlashCompletion(testSlashRegistry(), "/bal").?);
}

test "rendered slash welcome excludes non-welcome help entries" {
    const welcome_text = try renderSlashWelcome(std.testing.allocator, testSlashRegistry());
    defer std.testing.allocator.free(welcome_text);

    try std.testing.expect(std.mem.find(u8, welcome_text, "/image") == null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/help") != null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/clear") != null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/new") != null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/status") != null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/background") != null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/pr") == null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/issue") == null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/permissions") != null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/allowlist") != null);
    try std.testing.expect(std.mem.find(u8, welcome_text, "/quit") != null);
}

test "top-level help renders every visible command token" {
    const registry = testTopLevelRegistry();
    const text = try testTopLevelHelpText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    for (registry.specs) |spec| {
        if (spec.hidden_from_top_level_help) continue;
        try std.testing.expect(topLevelHelpContainsCommandToken(text, spec.token));
    }
    for (registry.notes) |note| {
        try std.testing.expect(std.mem.find(u8, text, note) != null);
    }
}

test "top-level help lines fit representative terminal widths" {
    const registry = testTopLevelRegistry();
    const widths = [_]usize{ 60, 80, 120 };
    for (widths) |width| {
        const text = try renderTopLevelHelp(std.testing.allocator, registry, width, "9.8.7");
        defer std.testing.allocator.free(text);
        try expectAllLinesFit(text, width);
    }
}

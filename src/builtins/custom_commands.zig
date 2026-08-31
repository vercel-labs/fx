const std = @import("std");

const builtin_commands = @import("commands.zig");
const custom_commands = @import("../core/slash_commands/custom_commands.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const skill_contract = @import("../core/skills/skill_contract.zig");

const RootSpec = skill_contract.RootSpec;

/// Workspace-relative command root, scanned at the workspace root and each
/// ancestor directory below home. The directory name is composed from the
/// single `profile_paths` constant so a rename stays a one-line change.
const workspace_root_path = profile_paths.root_dir_name ++ "/" ++ profile_paths.prompts_dir_name;

const workspace_roots = [_]RootSpec{
    .{ .source = .workspace_fx, .path = workspace_root_path },
};

/// Custom slash commands ship no compatibility roots: fx deliberately does not
/// read another tool's command directories.
pub const root_policy: skill_contract.RootPolicy = .{
    .workspace_roots = &workspace_roots,
    .managed_root_source = .global_fx,
    .global_roots = &.{},
};

test "command root policy orders workspace roots before the user root" {
    try std.testing.expectEqual(@as(usize, 1), root_policy.workspace_roots.len);
    try std.testing.expectEqual(skill_contract.SkillSource.workspace_fx, root_policy.workspace_roots[0].source);
    try std.testing.expectEqualStrings(".fx/prompts", root_policy.workspace_roots[0].path);
    try std.testing.expectEqual(skill_contract.SkillSource.global_fx, root_policy.managed_root_source.?);
    try std.testing.expectEqual(@as(usize, 0), root_policy.global_roots.len);
}

test "command root path is derived from the profile path constants" {
    const expected = profile_paths.root_dir_name ++ "/" ++ profile_paths.prompts_dir_name;
    try std.testing.expectEqualStrings(expected, workspace_root_path);
}

/// Asserts that a file whose stem equals `token` cannot become a command.
/// Multi-word tokens are skipped: no filename stem can derive them.
fn expectBuiltinReserved(token: []const u8) !void {
    try std.testing.expect(token.len > 1 and token[0] == '/');
    const name = token[1..];
    if (!custom_commands.validCommandName(name)) return;
    try std.testing.expect(custom_commands.reservedCollision(builtin_commands.slash_registry, name) != null);
}

test "no builtin token or alias can be claimed by a command file" {
    for (builtin_commands.slash_specs) |spec| {
        try expectBuiltinReserved(spec.command);
        for (spec.aliases) |alias| try expectBuiltinReserved(alias);
    }
}

test "a case-only near miss of a builtin token still collides against the real registry" {
    try std.testing.expectEqualStrings(
        "help",
        custom_commands.reservedCollision(builtin_commands.slash_registry, "HELP").?,
    );
    try std.testing.expectEqualStrings(
        "exit",
        custom_commands.reservedCollision(builtin_commands.slash_registry, "Exit").?,
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        custom_commands.reservedCollision(builtin_commands.slash_registry, "review-pr"),
    );
}

const command_router = @import("../core/slash_commands/command_router.zig");
const command_specs = @import("../core/slash_commands/command_specs.zig");

const Allocator = std.mem.Allocator;

const FixtureCommand = struct {
    name: []const u8,
    description: []const u8,
    has_explicit_description: bool = true,
    source: skill_contract.SkillSource = .workspace_fx,
    source_root: []const u8 = "/tmp/workspace/.fx/prompts",
    argument_hint: ?[]const u8 = null,
    body: []const u8 = "prompt body",
};

/// Merges a literal command table against the real 42 builtin specs, so the
/// assertions below run over the registry production actually serves.
fn fixtureRuntime(
    alloc: Allocator,
    fixtures: []const FixtureCommand,
) !custom_commands.CommandRuntime {
    if (fixtures.len == 0) {
        return custom_commands.buildRuntime(alloc, builtin_commands.slash_registry, .{});
    }

    const commands = try alloc.alloc(custom_commands.CustomCommand, fixtures.len);
    for (fixtures, commands) |fixture, *command| {
        command.* = .{
            .name = try alloc.dupe(u8, fixture.name),
            .description = try alloc.dupe(u8, fixture.description),
            .has_explicit_description = fixture.has_explicit_description,
            .argument_hint = if (fixture.argument_hint) |hint| try alloc.dupe(u8, hint) else null,
            .body = try alloc.dupe(u8, fixture.body),
            .path = try std.fmt.allocPrint(alloc, "{s}/{s}.md", .{ fixture.source_root, fixture.name }),
            .source = fixture.source,
        };
    }

    var discovery: custom_commands.CommandDiscovery = .{ .commands = commands };
    return custom_commands.buildRuntime(
        alloc,
        builtin_commands.slash_registry,
        discovery,
    ) catch |err| {
        discovery.deinit(alloc);
        return err;
    };
}

const merge_fixtures = [_]FixtureCommand{
    .{ .name = "review-pr", .description = "Review a pull request" },
    .{ .name = "model-review", .description = "Review the model choice" },
    .{ .name = "notes", .description = "custom command from /tmp/home/.fx/prompts", .has_explicit_description = false, .source = .global_fx, .source_root = "/tmp/home/.fx/prompts" },
};

test "merged registry preserves the builtin array and keeps every token unique" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &merge_fixtures);
    defer runtime.deinit(alloc);

    const registry = runtime.registry(builtin_commands.slash_registry);
    try std.testing.expectEqual(
        builtin_commands.slash_specs.len + merge_fixtures.len,
        registry.commands.len,
    );
    for (builtin_commands.slash_specs, registry.commands[0..builtin_commands.slash_specs.len]) |expected, actual| {
        try std.testing.expectEqualStrings(expected.command, actual.command);
        try std.testing.expectEqual(expected.kind, actual.kind);
        try std.testing.expectEqual(expected.presentation_category, actual.presentation_category);
    }

    for (registry.commands) |spec| {
        try std.testing.expectEqual(
            @as(usize, 1),
            command_specs.slashTokenOccurrences(registry, spec.command),
        );
        for (spec.aliases) |alias| {
            try std.testing.expectEqual(
                @as(usize, 1),
                command_specs.slashTokenOccurrences(registry, alias),
            );
        }
    }
}

test "a builtin token still resolves to its builtin spec in the merged registry" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &merge_fixtures);
    defer runtime.deinit(alloc);

    const registry = runtime.registry(builtin_commands.slash_registry);
    for (builtin_commands.slash_specs) |spec| {
        try std.testing.expectEqual(spec.kind, registry.lookup(spec.command).?.kind);
    }
    // The whitespace boundary in the prefix matcher keeps a longer custom token
    // from being reached through the shorter builtin one, and the reverse.
    try std.testing.expectEqual(
        command_specs.SlashKind.model,
        registry.lookup("/model").?.kind,
    );
    try std.testing.expectEqual(
        command_specs.SlashKind.custom,
        registry.lookup("/model-review").?.kind,
    );
}

test "a custom command parses to its own merged registry index" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &merge_fixtures);
    defer runtime.deinit(alloc);

    const registry = runtime.registry(builtin_commands.slash_registry);
    for (merge_fixtures, 0..) |fixture, offset| {
        var buf: [64]u8 = undefined;
        const input = try std.fmt.bufPrint(&buf, "/{s} 512", .{fixture.name});
        const parsed = command_router.parse(registry, input);
        try std.testing.expectEqual(
            builtin_commands.slash_specs.len + offset,
            parsed.custom.index,
        );
        try std.testing.expectEqualStrings("512", parsed.custom.args);
    }

    // A builtin sharing the prefix still parses to its own variant, so the
    // index-carrying variant never swallows a builtin token.
    try std.testing.expectEqualStrings("gpt", command_router.parse(registry, "/model gpt").model);
}

test "custom commands render in the extensions help category with their source" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &merge_fixtures);
    defer runtime.deinit(alloc);

    const registry = runtime.registry(builtin_commands.slash_registry);
    const builtin_extensions = command_specs.helpCatalogCategoryCount(
        builtin_commands.slash_registry,
        "",
        .extensions,
    );
    try std.testing.expectEqual(
        builtin_extensions + merge_fixtures.len,
        command_specs.helpCatalogCategoryCount(registry, "", .extensions),
    );

    const help = try command_specs.renderSlashHelp(alloc, registry);
    defer alloc.free(help);
    try std.testing.expect(std.mem.find(u8, help, "/review-pr") != null);

    const spec = registry.lookup("/review-pr").?;
    try std.testing.expectEqualStrings(
        "Review a pull request (/tmp/workspace/.fx/prompts)",
        spec.completion_description.?,
    );
    try std.testing.expectEqualStrings(
        "custom command from /tmp/home/.fx/prompts",
        registry.lookup("/notes").?.completion_description.?,
    );
}

test "completion lists the builtin before a custom command sharing its prefix" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &merge_fixtures);
    defer runtime.deinit(alloc);

    const registry = runtime.registry(builtin_commands.slash_registry);
    try std.testing.expect(command_specs.slashCompletionCount(registry, "/model") >= 2);
    try std.testing.expectEqualStrings(
        "/model",
        command_specs.nthSlashCompletion(registry, "/model", 0).?,
    );
    var saw_custom = false;
    var index: usize = 0;
    while (command_specs.nthSlashCompletion(registry, "/model", index)) |completion| : (index += 1) {
        if (std.mem.eql(u8, completion, "/model-review")) saw_custom = true;
    }
    try std.testing.expect(saw_custom);
}

test "zero discovered commands leave the slash surface byte-identical" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &.{});
    defer runtime.deinit(alloc);

    const registry = runtime.registry(builtin_commands.slash_registry);
    try std.testing.expectEqual(builtin_commands.slash_registry.commands.ptr, registry.commands.ptr);
    try std.testing.expectEqual(builtin_commands.slash_registry.commands.len, registry.commands.len);

    const merged_help = try command_specs.renderSlashHelp(alloc, registry);
    defer alloc.free(merged_help);
    const builtin_help = try command_specs.renderSlashHelp(alloc, builtin_commands.slash_registry);
    defer alloc.free(builtin_help);
    try std.testing.expectEqualStrings(builtin_help, merged_help);
}

const app_commands = @import("../core/app/app_commands.zig");
const types = @import("../core/shared/types.zig");

/// Serves the merged registry and resolves indices exactly as `App` does, so
/// `app_commands.Handlers(...).route` runs the production dispatch path over a
/// real 42-builtin registry.
const RouteFakeApp = struct {
    alloc: Allocator,
    runtime: *const custom_commands.CommandRuntime,
    enqueued: ?[]u8 = null,
    notice_topic: ?[]const u8 = null,
    notice_tone: ?types.NoticeTone = null,
    notice_body: ?[]const u8 = null,

    fn deinit(self: *RouteFakeApp) void {
        if (self.enqueued) |prompt| self.alloc.free(prompt);
        self.enqueued = null;
    }

    pub fn slashRegistry(self: *const RouteFakeApp) command_specs.SlashRegistry {
        return self.runtime.registry(builtin_commands.slash_registry);
    }

    pub fn customCommandBody(self: *const RouteFakeApp, index: usize) ?[]const u8 {
        const command = self.runtime.commandAt(
            builtin_commands.slash_registry,
            index,
        ) orelse return null;
        return command.body;
    }

    pub fn enqueuePrompt(self: *RouteFakeApp, prompt: []const u8) !bool {
        if (self.enqueued) |previous| self.alloc.free(previous);
        self.enqueued = try self.alloc.dupe(u8, prompt);
        return true;
    }

    pub fn writeDomainNotice(self: *RouteFakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_topic = notice.topic;
        self.notice_tone = notice.tone;
        self.notice_body = notice.body;
    }
};

fn unexpectedNoPayload(_: *anyopaque) anyerror!void {
    return error.UnexpectedCallback;
}

fn unexpectedPayload(_: *anyopaque, _: []const u8) anyerror!void {
    return error.UnexpectedCallback;
}

/// Binds the production `run_custom` handler and refuses every other dispatch
/// slot, so a custom command that landed on the wrong branch fails loudly.
/// The full `Handlers(...).commandHandlers` table cannot be built here: it
/// references every App capability, and this fake owns only the four the
/// custom path touches.
fn customOnlyHandlers(app: *RouteFakeApp) command_router.CommandHandlers {
    var handlers: command_router.CommandHandlers = undefined;
    handlers.ctx = @ptrCast(app);
    inline for (@typeInfo(command_router.CommandHandlers).@"struct".fields) |field| {
        if (comptime field.type == @TypeOf(&unexpectedNoPayload)) {
            @field(handlers, field.name) = unexpectedNoPayload;
        } else if (comptime field.type == @TypeOf(&unexpectedPayload)) {
            @field(handlers, field.name) = unexpectedPayload;
        }
    }
    handlers.run_custom = app_commands.Handlers(RouteFakeApp).commandRunCustom;
    return handlers;
}

fn routeCustom(app: *RouteFakeApp, cmd: []const u8) !void {
    const handlers = customOnlyHandlers(app);
    try command_router.route(app.slashRegistry(), &handlers, cmd);
}

const greet_fixtures = [_]FixtureCommand{
    .{
        .name = "greet",
        .description = "Greet someone",
        .argument_hint = "<name>",
        .body = "Hello $1, full input was $ARGUMENTS",
    },
    .{
        .name = "notes",
        .description = "Open the notes",
        .source = .global_fx,
        .body = "Open notes for ${1:-today}",
    },
};

test "typing a custom command routes through dispatch into the prompt queue" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &greet_fixtures);
    defer runtime.deinit(alloc);

    var app = RouteFakeApp{ .alloc = alloc, .runtime = &runtime };
    defer app.deinit();

    try routeCustom(&app, "/greet Ada Lovelace");

    try std.testing.expectEqualStrings(
        "Hello Ada, full input was Ada Lovelace",
        app.enqueued.?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), app.notice_body);
}

test "a custom command routed with no arguments falls back to its default" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &greet_fixtures);
    defer runtime.deinit(alloc);

    var app = RouteFakeApp{ .alloc = alloc, .runtime = &runtime };
    defer app.deinit();

    try routeCustom(&app, "/notes");
    try std.testing.expectEqualStrings("Open notes for today", app.enqueued.?);

    try routeCustom(&app, "/notes tomorrow");
    try std.testing.expectEqualStrings("Open notes for tomorrow", app.enqueued.?);
}

test "an index the registry no longer holds reports an unknown command" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &greet_fixtures);
    defer runtime.deinit(alloc);

    const first_custom = builtin_commands.slash_specs.len;
    try std.testing.expect(runtime.commandAt(builtin_commands.slash_registry, first_custom) != null);
    for ([_]usize{
        0,
        first_custom - 1,
        first_custom + greet_fixtures.len,
        std.math.maxInt(usize),
    }) |index| {
        try std.testing.expectEqual(
            @as(?*const custom_commands.CustomCommand, null),
            runtime.commandAt(builtin_commands.slash_registry, index),
        );
    }

    var app = RouteFakeApp{ .alloc = alloc, .runtime = &runtime };
    defer app.deinit();

    try app_commands.Handlers(RouteFakeApp).commandRunCustom(
        @ptrCast(&app),
        first_custom + greet_fixtures.len,
        "arguments",
    );

    try std.testing.expectEqual(@as(?[]u8, null), app.enqueued);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.notice_tone.?);
    try std.testing.expectEqualStrings("Unknown command. Try /help.", app.notice_body.?);
}

test "an argument hint decorates the picker label without changing insertion" {
    const alloc = std.testing.allocator;
    var runtime = try fixtureRuntime(alloc, &greet_fixtures);
    defer runtime.deinit(alloc);

    const registry = runtime.registry(builtin_commands.slash_registry);
    try std.testing.expectEqualStrings(
        "/greet <name>",
        command_specs.nthSlashCompletionLabel(registry, "/greet", 0).?,
    );
    try std.testing.expectEqualStrings(
        "/greet",
        command_specs.nthSlashCompletion(registry, "/greet", 0).?,
    );

    // No hint means the bare token, so no separator or empty placeholder is
    // ever rendered.
    try std.testing.expectEqualStrings(
        "/notes",
        command_specs.nthSlashCompletionLabel(registry, "/notes", 0).?,
    );
    try std.testing.expectEqualStrings(
        "/notes",
        command_specs.nthSlashCompletion(registry, "/notes", 0).?,
    );

    const help = try command_specs.renderSlashHelp(alloc, registry);
    defer alloc.free(help);
    try std.testing.expect(std.mem.find(u8, help, "/greet <name>") != null);
}

test "a hinted label stays bounded by the sanitized hint length" {
    const alloc = std.testing.allocator;
    const max_argument_hint_bytes: usize = 128;
    const long_hint = "x" ** max_argument_hint_bytes;
    const fixtures = [_]FixtureCommand{
        .{ .name = "wide", .description = "Wide hint", .argument_hint = long_hint },
    };
    var runtime = try fixtureRuntime(alloc, &fixtures);
    defer runtime.deinit(alloc);

    const registry = runtime.registry(builtin_commands.slash_registry);
    const label = command_specs.nthSlashCompletionLabel(registry, "/wide", 0).?;
    try std.testing.expectEqual(
        "/wide ".len + max_argument_hint_bytes,
        label.len,
    );
    for (label) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
}

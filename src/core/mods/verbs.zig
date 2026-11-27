//! Shared mod commands. Both `fx mod` / `fx mods` and `/mods` parse, execute,
//! and format output through this module (`RULES.md` R1.4, R4.6).

const std = @import("std");
const builtin_commands = @import("../../builtins/commands.zig");
const cli_flags = @import("../cli/cli_flags.zig");
const settings_messages = @import("../cli/settings_messages.zig");
const configured_provider = @import("../config/configured_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const text_utils = @import("../shared/text_utils.zig");
const mods = @import("mods.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const OptionDoc = command_specs.OptionDoc;

pub const Surface = enum {
    cli,
    shell,

    fn prog(s: Surface) []const u8 {
        return switch (s) {
            .cli => "fx mod",
            .shell => "/mods",
        };
    }

    fn progWithArticle(s: Surface) []const u8 {
        return switch (s) {
            .cli => "an fx mod",
            .shell => "a /mods",
        };
    }
};

pub const Verb = enum { list, show, add, update, enable, disable, remove };

const verb_names = [_][]const u8{ "list", "show", "add", "update", "enable", "disable", "remove" };
const shell_restart_note = " The change applies the next time fx starts.";

pub const Command = union(enum) {
    help: ?Verb,
    list: struct { json: bool = false },
    show: struct { name: []const u8, json: bool = false },
    add: struct { source: []const u8, yes: bool = false },
    update: struct { name: ?[]const u8 = null },
    enable: []const u8,
    disable: []const u8,
    remove: []const u8,
};

pub const Parsed = union(enum) {
    command: Command,
    usage: struct { verb: ?Verb, message: []const u8 },
};

pub const PromptOps = struct {
    ctx: ?*anyopaque = null,
    is_tty: *const fn (?*anyopaque) bool = defaultIsTty,
    confirm: *const fn (?*anyopaque, *Writer, []const u8) anyerror!bool = defaultConfirm,
};

pub const Context = struct {
    gpa: Allocator,
    out: *Writer,
    err: *Writer,
    surface: Surface,
    home: []const u8,
    cancel: ?*const std.atomic.Value(bool) = null,
    prompt: PromptOps = .{},
};

fn defaultIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stdin().isTty(io_mod.getIo()) catch false;
}

fn defaultConfirm(_: ?*anyopaque, err_writer: *Writer, mod_name: []const u8) anyerror!bool {
    try err_writer.print("\nInstall {f}? [y/N] ", .{text_utils.terminalSafe(mod_name)});
    try err_writer.flush();

    var read_buf: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io_mod.getIo(), &read_buf);
    const line = reader.interface.takeDelimiter('\n') catch return false;
    const answer = std.mem.trim(u8, line orelse "", " \t\r\n");
    return answer.len == 1 and (answer[0] == 'y' or answer[0] == 'Y');
}

fn parseVerbToken(token: []const u8) ?Verb {
    if (std.mem.eql(u8, token, "ls")) return .list;
    if (std.mem.eql(u8, token, "rm")) return .remove;
    if (std.mem.eql(u8, token, "on")) return .enable;
    if (std.mem.eql(u8, token, "off")) return .disable;
    return std.meta.stringToEnum(Verb, token);
}

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help");
}

const Flag = enum { yes, json };
const VerbFlags = struct { docs: []const OptionDoc, ids: []const Flag };

fn verbFlagsFor(comptime docs: []const OptionDoc) VerbFlags {
    const ids = comptime ids: {
        var ids: [docs.len]Flag = undefined;
        for (docs, &ids) |doc, *id| {
            const name = cli_flags.flagName(doc)[2..];
            var field: [name.len]u8 = undefined;
            for (name, &field) |c, *f| f.* = if (c == '-') '_' else c;
            const final = field;
            id.* = @field(Flag, &final);
        }
        break :ids ids;
    };
    return .{ .docs = docs, .ids = &ids };
}

fn verbFlags(verb: Verb, surface: Surface) VerbFlags {
    return switch (verb) {
        .add => verbFlagsFor(&builtin_commands.mod_add_options),
        .list => if (surface == .cli) verbFlagsFor(&builtin_commands.mod_list_options) else verbFlagsFor(&.{}),
        .show => if (surface == .cli) verbFlagsFor(&builtin_commands.mod_show_options) else verbFlagsFor(&.{}),
        .update, .enable, .disable, .remove => verbFlagsFor(&.{}),
    };
}

pub fn parse(arena: Allocator, surface: Surface, args: []const []const u8) Allocator.Error!Parsed {
    const p = surface.prog();
    if (args.len == 0) return .{ .command = .{ .list = .{ .json = false } } };
    if (isHelp(args[0]) or std.mem.eql(u8, args[0], "help")) return .{ .command = .{ .help = null } };

    const verb = parseVerbToken(args[0]) orelse {
        const old = args[0];
        const command = surface.progWithArticle();
        if (settings_messages.closest(old, &verb_names)) |near| {
            return usage(arena, null, "'{f}' isn't {s} command; did you mean {s}?", .{ text_utils.terminalSafe(old), command, near });
        }
        return usage(arena, null, "'{f}' isn't {s} command.", .{ text_utils.terminalSafe(old), command });
    };

    const rest = args[1..];
    for (rest) |a| if (isHelp(a)) return .{ .command = .{ .help = verb } };

    const words = try arena.alloc([:0]const u8, rest.len);
    for (rest, words) |a, *word| word.* = try arena.dupeSentinel(u8, a, 0);
    const flags = verbFlags(verb, surface);
    var parser: cli_flags.Parser = .init(flags.docs, words);
    var positionals: std.ArrayList([]const u8) = .empty;
    var json = false;
    var yes = false;

    while (true) {
        const item = parser.next() catch {
            var text: Writer.Allocating = .init(arena);
            parser.failure.?.write(&text.writer) catch return error.OutOfMemory;
            return usage(arena, verb, "{s} {s}: {s}", .{ p, @tagName(verb), text.written() });
        } orelse break;
        const match = switch (item) {
            .positional => |word| {
                try positionals.append(arena, word);
                continue;
            },
            .option => |match| match,
        };
        switch (flags.ids[match.index]) {
            .json => json = true,
            .yes => yes = true,
        }
    }

    const pos = positionals.items;
    return switch (verb) {
        .list => {
            if (pos.len > 0) return usage(arena, verb, "{s} list takes no arguments.", .{p});
            return .{ .command = .{ .list = .{ .json = json } } };
        },
        .show => {
            if (pos.len != 1) return usage(arena, verb, "{s} show needs one mod NAME.", .{p});
            return .{ .command = .{ .show = .{ .name = pos[0], .json = json } } };
        },
        .add => {
            if (pos.len != 1) return usage(arena, verb, "{s} add needs one folder or git URL.", .{p});
            return .{ .command = .{ .add = .{ .source = pos[0], .yes = yes } } };
        },
        .update => {
            if (pos.len > 1) return usage(arena, verb, "{s} update takes at most one mod NAME.", .{p});
            return .{ .command = .{ .update = .{ .name = if (pos.len == 1) pos[0] else null } } };
        },
        .enable, .disable, .remove => {
            if (pos.len != 1) return usage(arena, verb, "{s} {s} needs one mod NAME.", .{ p, @tagName(verb) });
            return .{ .command = switch (verb) {
                .enable => .{ .enable = pos[0] },
                .disable => .{ .disable = pos[0] },
                .remove => .{ .remove = pos[0] },
                else => unreachable,
            } };
        },
    };
}

fn usage(arena: Allocator, verb: ?Verb, comptime fmt: []const u8, args: anytype) Allocator.Error!Parsed {
    return .{ .usage = .{ .verb = verb, .message = try arena.print(fmt, args) } };
}

pub fn writeUsage(w: *Writer, surface: Surface, verb: ?Verb) Writer.Error!void {
    const p = surface.prog();
    const json = if (surface == .cli) " [--json]" else "";
    const v = verb orelse {
        try w.print(
            \\usage: {s} <command> ...
            \\
            \\  list{s:<24}list installed mods
            \\  show NAME{s:<19}show details for an installed mod
            \\  add SOURCE [--yes]          install from a folder or git URL[@ref]
            \\  update [NAME]               update one mod, or every installed mod
            \\  enable NAME                 enable an installed mod (alias: on)
            \\  disable NAME                disable an installed mod (alias: off)
            \\  remove NAME                 remove an installed mod
            \\
        , .{ p, json, json });
        return;
    };
    switch (v) {
        .list => try w.print("usage: {s} list{s}\n", .{ p, json }),
        .show => try w.print("usage: {s} show NAME{s}\n", .{ p, json }),
        .add => try w.print("usage: {s} add [--yes] <folder|git URL[@ref]>\n", .{p}),
        .update => try w.print("usage: {s} update [NAME]\n", .{p}),
        .enable => try w.print("usage: {s} enable NAME\n", .{p}),
        .disable => try w.print("usage: {s} disable NAME\n", .{p}),
        .remove => try w.print("usage: {s} remove NAME\n", .{p}),
    }
}

pub fn run(c: Context, args: []const []const u8) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const code = runParsed(c, arena, args) catch |err| code: {
        debug_trace.logf("mods", "mod verb failed err={s}", .{@errorName(err)});
        c.err.print("{s}: {s}\n", .{ c.surface.prog(), describeError(err) }) catch {};
        break :code 1;
    };
    c.out.flush() catch {};
    c.err.flush() catch {};
    return code;
}

fn jsonUsageKind(surface: Surface, verb: ?Verb, args: []const []const u8) ?[]const u8 {
    if (surface != .cli or args.len == 0) return null;
    const kind: []const u8 = switch (verb orelse return null) {
        .list => "mod_list",
        .show => "mod_show",
        else => return null,
    };
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return kind;
    }
    return null;
}

fn writeJsonUsage(arena: Allocator, w: *Writer, kind: []const u8, prefix: []const u8, message: []const u8) !void {
    const text = if (std.mem.startsWith(u8, message, prefix)) message[prefix.len..] else message;
    const rendered = try (output_contracts.CommandFailureSnapshot{
        .kind = kind,
        .message = text,
        .code = "InvalidLocalSurfaceArgs",
    }).renderJson(arena);
    try w.writeAll(rendered);
    try w.writeByte('\n');
}

fn runParsed(c: Context, arena: Allocator, args: []const []const u8) !u8 {
    const command = switch (try parse(arena, c.surface, args)) {
        .command => |cmd| cmd,
        .usage => |u| {
            if (jsonUsageKind(c.surface, u.verb, args)) |kind| {
                const prefix = try arena.print("{s} {s}: ", .{ c.surface.prog(), args[0] });
                try writeJsonUsage(arena, c.out, kind, prefix, u.message);
                return 2;
            }
            try c.err.print("{s}\n", .{u.message});
            try writeUsage(c.err, c.surface, u.verb);
            return 2;
        },
    };
    switch (command) {
        .help => |verb| {
            try writeUsage(c.out, c.surface, verb);
            return 0;
        },
        else => if (!std.Io.Dir.path.isAbsolute(c.home)) return error.HomeNotSet,
    }
    const root = try profile_paths.modsDir(arena, c.home);
    return switch (command) {
        .help => unreachable,
        .list => |l| runList(c, arena, root, l.json),
        .show => |s| runShow(c, arena, root, s.name, s.json),
        .add => |a| runAdd(c, arena, root, a.source, a.yes),
        .update => |u| runUpdate(c, arena, root, u.name),
        .enable => |name| runSetOn(c, root, name, true),
        .disable => |name| runSetOn(c, root, name, false),
        .remove => |name| runRemove(c, root, name),
    };
}

fn runList(c: Context, arena: Allocator, root: []const u8, json: bool) !u8 {
    var listing = try mods.list(arena, root);
    defer listing.deinit(arena);

    const entries = try arena.alloc(output_contracts.ModEntrySnapshot, listing.mods.len);
    for (listing.mods, entries) |item, *entry| {
        const record = readOptionalSourceRecord(arena, root, item.name);
        const status: []const u8 = if (item.problem != null) "broken" else if (item.on) "on" else "off";
        entry.* = .{
            .name = item.name,
            .version = item.version,
            .status = status,
            .on = item.on,
            .source = if (record) |r| r.source else null,
            .ref = if (record) |r| r.ref else null,
            .commit = if (record) |r| r.commit else null,
            .pinned = if (record) |r| r.pinned else false,
            .path = item.path,
            .err = if (item.problem) |p| modProblemText(p) else null,
        };
    }

    const snapshot: output_contracts.ModListSnapshot = .{
        .mods = entries,
        .over_limit = listing.over_limit,
        .empty_hint = c.surface.prog(),
    };
    const rendered = try snapshot.render(arena, if (json) .json else .text);
    try c.out.writeAll(rendered);
    if (json) try c.out.writeByte('\n');
    return 0;
}

fn runShow(c: Context, arena: Allocator, root: []const u8, name: []const u8, json: bool) !u8 {
    if (!mods.manifest.validName(name)) {
        return writeShowMissing(c, arena, name, json, "Mod name must use lowercase letters, digits, and hyphens only.");
    }

    var loaded = try mods.load(arena, root, name);
    defer loaded.deinit(arena);

    const record = readOptionalSourceRecord(arena, root, name);

    switch (loaded) {
        .none => return writeShowMissing(c, arena, name, json, null),
        .bad => {
            var listing = try mods.list(arena, root);
            defer listing.deinit(arena);
            var prob_msg: []const u8 = "Mod could not be loaded.";
            var on = false;
            for (listing.mods) |item| {
                if (std.mem.eql(u8, item.name, name)) {
                    on = item.on;
                    if (item.problem) |p| prob_msg = modProblemText(p);
                    break;
                }
            }
            const snapshot: output_contracts.ModShowSnapshot = .{
                .name = name,
                .status = "broken",
                .on = on,
                .source = if (record) |r| r.source else null,
                .ref = if (record) |r| r.ref else null,
                .commit = if (record) |r| r.commit else null,
                .pinned = if (record) |r| r.pinned else false,
                .err = prob_msg,
            };
            const rendered = try snapshot.render(arena, if (json) .json else .text);
            try c.out.writeAll(rendered);
            if (json) try c.out.writeByte('\n');
            return 1;
        },
        .mod => |m| {
            const detail = readModDetails(arena, root, name, m.path);
            const snapshot: output_contracts.ModShowSnapshot = .{
                .name = name,
                .version = m.version,
                .status = if (m.on) "on" else "off",
                .on = m.on,
                .description = detail.description,
                .source = if (record) |r| r.source else null,
                .ref = if (record) |r| r.ref else null,
                .commit = if (record) |r| r.commit else null,
                .pinned = if (record) |r| r.pinned else false,
                .path = m.path,
                .err = detail.err,
                .providers = detail.providers,
            };
            const rendered = try snapshot.render(arena, if (json) .json else .text);
            try c.out.writeAll(rendered);
            if (json) try c.out.writeByte('\n');
            return 0;
        },
    }
}

fn writeShowMissing(c: Context, arena: Allocator, name: []const u8, json: bool, custom_msg: ?[]const u8) !u8 {
    const msg = custom_msg orelse try arena.print("No mod named {f}. Run {s} list to see installed mods.", .{ text_utils.terminalSafe(name), c.surface.prog() });
    if (json) {
        const rendered = try (output_contracts.CommandFailureSnapshot{
            .kind = "mod_show",
            .message = msg,
            .code = "ModNotFound",
        }).renderJson(arena);
        try c.out.writeAll(rendered);
        try c.out.writeByte('\n');
    } else {
        try c.err.print("{s}: {s}\n", .{ c.surface.prog(), msg });
    }
    return 1;
}

fn runAdd(c: Context, arena: Allocator, root: []const u8, arg: []const u8, yes: bool) !u8 {
    var prep = switch (try mods.prepareInstall(arena, root, arg, c.cancel)) {
        .prepared => |p| p,
        .not_a_folder => |path| {
            try c.err.print("{s} add: {f} is not a folder.\n", .{ c.surface.prog(), text_utils.terminalSafe(path) });
            return 1;
        },
        .source_invalid => |problem| {
            try c.err.print("{s} add: {s}\n", .{ c.surface.prog(), sourceProblemText(problem) });
            return 1;
        },
        .fetch_failed => |failed| {
            try writeFetchFailure(c, "add", arg, failed);
            return 1;
        },
        .no_manifest => {
            try c.err.print("{s} add: mod.json is missing.\n", .{c.surface.prog()});
            return 1;
        },
        .bad_manifest => |err| {
            try c.err.print("{s} add: {s}\n", .{ c.surface.prog(), mods.manifest.message(err) });
            return 1;
        },
        .bad_providers => |bad| {
            const advice = configured_provider.mod_failure_advice(bad.err) orelse "could not parse providers";
            if (bad.path.len > 0) {
                try c.err.print("{s} add: providers.{f}: {s}.\n", .{ c.surface.prog(), text_utils.terminalSafe(bad.path), advice });
            } else {
                try c.err.print("{s} add: providers: {s}.\n", .{ c.surface.prog(), advice });
            }
            return 1;
        },
    };
    defer prep.discard(arena);

    const preview = try buildInstallPreview(arena, &prep);
    const preview_text = try preview.renderText(arena);

    if (yes) {
        // `--yes` installs a new fetch, which can differ from an earlier
        // preview when a branch moved, so the screen shows what goes in.
        try (if (c.surface == .shell) c.out else c.err).writeAll(preview_text);
    } else {
        if (c.surface == .shell) {
            try c.out.writeAll(preview_text);
            try c.out.print("\nRun /mods add {f} --yes to install.\n", .{text_utils.terminalSafe(arg)});
            return 0;
        }
        if (!c.prompt.is_tty(c.prompt.ctx)) {
            try c.err.writeAll(preview_text);
            try c.err.writeAll("\nCannot confirm installation without a terminal. Re-run with --yes to install.\n");
            return 1;
        }
        try c.err.writeAll(preview_text);
        const confirmed = try c.prompt.confirm(c.prompt.ctx, c.err, prep.manifest.name);
        if (!confirmed) {
            try c.err.writeAll("Cancelled.\n");
            return 1;
        }
    }

    switch (try mods.commitInstall(arena, root, &prep)) {
        .installed => |inst| {
            try c.out.print("Installed {f} ({f}).{s}\n", .{
                text_utils.terminalSafe(inst.name),
                text_utils.terminalSafe(inst.version),
                if (c.surface == .shell) shell_restart_note else "",
            });
            return 0;
        },
        .refused => |outcome| {
            try writeOutcomeFailure(c, "add", prep.manifest.name, outcome);
            return 1;
        },
        else => unreachable,
    }
}

fn runUpdate(c: Context, arena: Allocator, root: []const u8, maybe_name: ?[]const u8) !u8 {
    if (maybe_name) |name| {
        if (!mods.manifest.validName(name)) {
            try c.err.print("{s} update: invalid mod name '{f}'.\n", .{ c.surface.prog(), text_utils.terminalSafe(name) });
            return 1;
        }
        const res = try mods.refresh(arena, root, name, c.cancel);
        return reportSingleRefresh(c, name, res);
    }

    var listing = try mods.list(arena, root);
    defer listing.deinit(arena);
    if (listing.mods.len == 0) {
        try c.out.print("No mods installed.\n", .{});
        return 0;
    }

    var any_failed = false;
    var any_changed = false;
    for (listing.mods) |item| {
        const res = try mods.refresh(arena, root, item.name, c.cancel);
        switch (res) {
            .updated => |u| {
                any_changed = true;
                try c.out.print("{f}: updated {s} -> {s}\n", .{
                    text_utils.terminalSafe(item.name),
                    shortCommit(u.old_commit),
                    shortCommit(u.new_commit),
                });
            },
            .folder_copied => {
                any_changed = true;
                try c.out.print("{f}: updated from folder\n", .{text_utils.terminalSafe(item.name)});
            },
            .up_to_date => try c.out.print("{f}: already up to date\n", .{text_utils.terminalSafe(item.name)}),
            .pinned => |ref| try c.out.print("{f}: pinned at {f}, skipped\n", .{ text_utils.terminalSafe(item.name), text_utils.terminalSafe(ref) }),
            else => {
                any_failed = true;
                try writeRefreshFailure(c, item.name, res);
            },
        }
    }
    if (c.surface == .shell and any_changed) {
        try c.out.print("The change applies the next time fx starts.\n", .{});
    }
    return if (any_failed) 1 else 0;
}

fn reportSingleRefresh(c: Context, name: []const u8, res: mods.RefreshResult) !u8 {
    switch (res) {
        .updated => |u| {
            try c.out.print("Updated {f}: {s} -> {s}.{s}\n", .{
                text_utils.terminalSafe(name),
                shortCommit(u.old_commit),
                shortCommit(u.new_commit),
                if (c.surface == .shell) shell_restart_note else "",
            });
            return 0;
        },
        .folder_copied => {
            try c.out.print("Updated {f} from folder.{s}\n", .{
                text_utils.terminalSafe(name),
                if (c.surface == .shell) shell_restart_note else "",
            });
            return 0;
        },
        .up_to_date => {
            try c.out.print("{f} is already up to date.\n", .{text_utils.terminalSafe(name)});
            return 0;
        },
        .pinned => |ref| {
            try c.out.print("{f} is pinned at {f}.\n", .{ text_utils.terminalSafe(name), text_utils.terminalSafe(ref) });
            return 0;
        },
        else => {
            try writeRefreshFailure(c, name, res);
            return 1;
        },
    }
}

fn writeRefreshFailure(c: Context, name: []const u8, res: mods.RefreshResult) !void {
    switch (res) {
        .not_installed => try c.err.print("{s} update: mod '{f}' is not installed.\n", .{ c.surface.prog(), text_utils.terminalSafe(name) }),
        .bad_mod => try c.err.print("{s} update: mod '{f}' is broken.\n", .{ c.surface.prog(), text_utils.terminalSafe(name) }),
        .no_record => try c.err.print("{s} update: mod '{f}' has no saved source record.\n", .{ c.surface.prog(), text_utils.terminalSafe(name) }),
        .bad_record => try c.err.print("{s} update: mod '{f}' has an unreadable source record.\n", .{ c.surface.prog(), text_utils.terminalSafe(name) }),
        .source_missing => |path| try c.err.print("{s} update: source folder for '{f}' is missing: {f}.\n", .{ c.surface.prog(), text_utils.terminalSafe(name), text_utils.terminalSafe(path) }),
        .fetch_failed => |failed| try writeFetchFailure(c, "update", name, failed),
        .refused => |outcome| try writeOutcomeFailure(c, "update", name, outcome),
        else => {},
    }
}

fn runSetOn(c: Context, root: []const u8, name: []const u8, on: bool) !u8 {
    const verb_name = if (on) "enable" else "disable";
    const outcome = try mods.setOn(c.gpa, root, name, on);
    if (outcome == .ok) {
        try c.out.print("{s} {f}.{s}\n", .{
            if (on) "Enabled" else "Disabled",
            text_utils.terminalSafe(name),
            if (c.surface == .shell) shell_restart_note else "",
        });
        return 0;
    }
    try writeOutcomeFailure(c, verb_name, name, outcome);
    return 1;
}

fn runRemove(c: Context, root: []const u8, name: []const u8) !u8 {
    const outcome = try mods.remove(c.gpa, root, name);
    if (outcome == .ok) {
        try c.out.print("Removed {f}.{s}\n", .{
            text_utils.terminalSafe(name),
            if (c.surface == .shell) shell_restart_note else "",
        });
        return 0;
    }
    try writeOutcomeFailure(c, "remove", name, outcome);
    return 1;
}

fn buildInstallPreview(arena: Allocator, prep: *const mods.PreparedInstall) !output_contracts.ModInstallPreviewSnapshot {
    const providers = try providerViews(arena, prep.providers);
    return .{
        .name = prep.manifest.name,
        .version = prep.manifest.version,
        .description = prep.manifest.description,
        .source = prep.source,
        .commit = prep.commit,
        .providers = providers,
    };
}

fn providerViews(arena: Allocator, maybe_reg: ?configured_provider.Registry) ![]const output_contracts.ModProviderView {
    const reg = maybe_reg orelse return &.{};
    const views = try arena.alloc(output_contracts.ModProviderView, reg.definitions.len);
    for (reg.definitions, views) |def, *view| {
        view.* = .{
            .name = def.id,
            .protocol = @tagName(def.protocol),
            .base_url = def.base_url,
            .command = switch (def.auth) {
                .command => |argv| argv,
                else => null,
            },
            .sends = try providerSends(arena, def),
        };
    }
    return views;
}

/// Every environment variable whose value `def` sends to its base URL: the
/// bearer token's, then each header's.
fn providerSends(arena: Allocator, def: configured_provider.Definition) ![]const output_contracts.ModProviderSend {
    var sends: std.ArrayList(output_contracts.ModProviderSend) = .empty;
    switch (def.auth) {
        .bearer => |env| try sends.append(arena, .{ .env = env, .header = "Authorization" }),
        .none, .command => {},
    }
    for (def.headers) |header| try sends.append(arena, .{ .env = header.env, .header = header.name });
    return sends.items;
}

fn readOptionalSourceRecord(arena: Allocator, root: []const u8, name: []const u8) ?mods.source.Record {
    const bytes = (mods.readRecord(arena, root, name) catch return null) orelse return null;
    return mods.source.decodeRecord(arena, bytes) catch null;
}

const ModDetails = struct {
    description: []const u8 = "",
    providers: []const output_contracts.ModProviderView = &.{},
    err: ?[]const u8 = null,
};

fn readModDetails(arena: Allocator, root: []const u8, name: []const u8, link_path: []const u8) ModDetails {
    const io = io_mod.getIo();
    var dir = std.Io.Dir.cwd().openDir(io, link_path, .{}) catch return .{};
    defer dir.close(io);
    const bytes = dir.readFileAlloc(io, "mod.json", arena, .limited(mods.manifest.max_bytes + 1)) catch return .{};
    const decoded = mods.manifest.decode(arena, bytes) catch return .{};
    const providers_val = decoded.providers orelse return .{ .description = decoded.description };

    const canonical_link = std.Io.Dir.path.join(arena, &.{ root, name }) catch return .{ .description = decoded.description };
    var at: configured_provider.FailurePath = .{};
    var reg = configured_provider.Registry.parse_located_for_mod(
        arena,
        providers_val,
        &at,
        .{ .name = name, .dir = canonical_link },
    ) catch |err| {
        const advice = configured_provider.mod_failure_advice(err) orelse "could not parse providers";
        const path_text = at.text();
        const msg = if (path_text.len > 0)
            arena.print("providers.{f}: {s}.", .{ text_utils.terminalSafe(path_text), advice }) catch advice
        else
            arena.print("providers: {s}.", .{advice}) catch advice;
        return .{ .description = decoded.description, .err = msg };
    };
    _ = &reg;
    const views = providerViews(arena, reg) catch return .{ .description = decoded.description };
    return .{ .description = decoded.description, .providers = views };
}

fn shortCommit(maybe: ?[]const u8) []const u8 {
    const c = maybe orelse return "unknown";
    return if (c.len >= 7) c[0..7] else c;
}

fn sourceProblemText(problem: mods.source.Problem) []const u8 {
    return switch (problem) {
        .empty => "source path or URL cannot be empty.",
        .too_long => "source path or URL is too long.",
        .bad_characters => "source path or URL has characters fx does not allow.",
        .bad_ref => "git ref is invalid.",
    };
}

fn writeFetchFailure(c: Context, verb_name: []const u8, label: []const u8, failed: mods.source.Failed) !void {
    switch (failed.kind) {
        .timed_out => try c.err.print("{s} {s}: git timed out while fetching '{f}'.\n", .{ c.surface.prog(), verb_name, text_utils.terminalSafe(label) }),
        .cancelled => try c.err.print("{s} {s}: cancelled.\n", .{ c.surface.prog(), verb_name }),
        .signaled => try c.err.print("{s} {s}: git exited on a signal.\n", .{ c.surface.prog(), verb_name }),
        .too_large => try c.err.print("{s} {s}: git output was larger than fx reads.\n", .{ c.surface.prog(), verb_name }),
        .spawn_failed => try c.err.print("{s} {s}: could not start git.\n", .{ c.surface.prog(), verb_name }),
        .bad_commit => try c.err.print("{s} {s}: git returned an invalid commit hash.\n", .{ c.surface.prog(), verb_name }),
        .git_failed => {
            if (failed.detail.len > 0) {
                try c.err.print("{s} {s}: git failed: {f}\n", .{ c.surface.prog(), verb_name, text_utils.terminalSafe(failed.detail) });
            } else {
                try c.err.print("{s} {s}: git failed.\n", .{ c.surface.prog(), verb_name });
            }
        },
    }
}

fn writeOutcomeFailure(c: Context, verb_name: []const u8, name: []const u8, outcome: mods.Outcome) !void {
    const safe_name = text_utils.terminalSafe(name);
    switch (outcome) {
        .ok => {},
        .exists => try c.err.print("{s} {s}: mod '{f}' is already installed.\n", .{ c.surface.prog(), verb_name, safe_name }),
        .missing => try c.err.print("{s} {s}: mod '{f}' is not installed.\n", .{ c.surface.prog(), verb_name, safe_name }),
        .busy => try c.err.print("{s} {s}: another fx is changing mod '{f}'; try again.\n", .{ c.surface.prog(), verb_name, safe_name }),
        .invalid => |inv| try c.err.print("{s} {s}: {s}\n", .{ c.surface.prog(), verb_name, invalidText(inv) }),
    }
}

fn invalidText(inv: mods.Invalid) []const u8 {
    return switch (inv) {
        .bad_name => "mod name must use lowercase letters, digits, and hyphens only.",
        .no_manifest => "mod.json is missing.",
        .bad_manifest => "mod.json is invalid.",
        .name_mismatch => "mod.json names a different mod.",
        .symlink => "mod folder contains a symbolic link, which fx refuses.",
        .special_file => "mod folder contains a special file, which fx refuses.",
        .too_large => "mod exceeds the 4096-file or 64 MiB limit.",
        .ambiguous => "mod has both enabled and disabled links.",
        .reserved_source_record => "mod folder contains a reserved .fx-mod-source.json file.",
    };
}

fn modProblemText(problem: mods.ModProblem) []const u8 {
    return switch (problem) {
        .ambiguous => "mod has both enabled and disabled links.",
        .bad_name => "invalid mod name.",
        .not_symlink => "mod entry is not a symbolic link.",
        .dangling => "mod link is broken.",
        .no_manifest => "mod.json is missing.",
        .bad_manifest => "mod.json is invalid.",
        .name_mismatch => "mod.json names a different mod.",
        .unreadable => "could not read mod.json.",
    };
}

fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.HomeNotSet => io_mod.no_home_dir_reason,
        error.AccessDenied => "permission denied",
        else => "something went wrong",
    };
}

const TestPrompt = struct {
    tty: bool = false,
    answer: bool = false,
    asked: bool = false,

    fn isTty(ctx: ?*anyopaque) bool {
        const self: *TestPrompt = @ptrCast(@alignCast(ctx.?));
        return self.tty;
    }

    fn confirm(ctx: ?*anyopaque, w: *Writer, mod_name: []const u8) anyerror!bool {
        const self: *TestPrompt = @ptrCast(@alignCast(ctx.?));
        self.asked = true;
        try w.print("\nInstall {s}? [y/N] ", .{mod_name});
        return self.answer;
    }

    fn ops(self: *TestPrompt) PromptOps {
        return .{ .ctx = self, .is_tty = isTty, .confirm = confirm };
    }
};

fn runTestVerbs(
    alloc: Allocator,
    surface: Surface,
    home: []const u8,
    args: []const []const u8,
    prompt: *TestPrompt,
    out_buf: *std.ArrayList(u8),
    err_buf: *std.ArrayList(u8),
) !u8 {
    var out_w: Writer.Allocating = .init(alloc);
    defer out_w.deinit();
    var err_w: Writer.Allocating = .init(alloc);
    defer err_w.deinit();

    const code = run(.{
        .gpa = alloc,
        .out = &out_w.writer,
        .err = &err_w.writer,
        .surface = surface,
        .home = home,
        .prompt = prompt.ops(),
    }, args);
    try out_buf.appendSlice(alloc, out_w.written());
    try err_buf.appendSlice(alloc, err_w.written());
    return code;
}

test "parse handles bare invocation, verb aliases, flags, and usage errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(Command{ .list = .{ .json = false } }, (try parse(arena, .cli, &.{})).command);
    try std.testing.expectEqual(Command{ .list = .{ .json = false } }, (try parse(arena, .shell, &.{})).command);
    try std.testing.expectEqual(Command{ .list = .{ .json = true } }, (try parse(arena, .cli, &.{ "ls", "--json" })).command);
    try std.testing.expectEqualStrings("glm", (try parse(arena, .cli, &.{ "rm", "glm" })).command.remove);
    try std.testing.expectEqualStrings("glm", (try parse(arena, .cli, &.{ "on", "glm" })).command.enable);
    try std.testing.expectEqualStrings("glm", (try parse(arena, .cli, &.{ "off", "glm" })).command.disable);
    try std.testing.expectEqualStrings("glm", (try parse(arena, .cli, &.{ "update", "glm" })).command.update.name.?);
    try std.testing.expect((try parse(arena, .cli, &.{"update"})).command.update.name == null);

    try std.testing.expect((try parse(arena, .cli, &.{ "list", "--yes" })) == .usage);
    try std.testing.expect((try parse(arena, .cli, &.{ "add", "--json", "./src" })) == .usage);
    try std.testing.expect((try parse(arena, .cli, &.{ "remove", "--yes", "glm" })) == .usage);
    try std.testing.expect((try parse(arena, .shell, &.{ "list", "--json" })) == .usage);
    try std.testing.expect((try parse(arena, .shell, &.{ "show", "glm", "--json" })) == .usage);
}

test "mods verbs exercise cli and shell add preview, list, show, on/off, update, and remove" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    try tmp.dir.createDirPath(io_mod.getIo(), "src/bin");
    const src = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "src");
    defer alloc.free(src);
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "src/mod.json",
        .data = "{\"name\":\"glm\",\"version\":\"1.0.0\",\"description\":\"Coding plan\",\"providers\":{" ++
            "\"glm\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"command\",\"command\":[\"bin/auth\",\"--ok\"]},\"headers\":{\"X-Team\":{\"env\":\"GLM_TEAM\"}}}," ++
            "\"glm-key\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"bearer\",\"env\":\"GLM_API_KEY\"}}}}",
    });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(alloc);
    var prompt: TestPrompt = .{};

    // CLI without terminal and without --yes is refused with message naming --yes.
    try std.testing.expectEqual(@as(u8, 1), try runTestVerbs(alloc, .cli, home, &.{ "add", src }, &prompt, &out, &err));
    try std.testing.expect(!prompt.asked);
    try std.testing.expect(std.mem.find(u8, err.items, "--yes") != null);
    try std.testing.expect(std.mem.findScalar(u8, err.items, '\x1b') == null);
    try std.testing.expect(std.mem.find(u8, err.items, "runs ") != null);
    try std.testing.expect(std.mem.find(u8, err.items, "sends $GLM_TEAM in header X-Team\n") != null);
    try std.testing.expect(std.mem.find(u8, err.items, "sends $GLM_API_KEY in header Authorization\n") != null);

    // TUI without --yes prints preview in transcript and asks to re-run with --yes, installing nothing.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .shell, home, &.{ "add", src }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "Mod: glm (1.0.0)") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "--yes to install.") != null);
    try std.testing.expect(std.mem.findScalar(u8, out.items, '\x1b') == null);

    // CLI TTY answer `n` cancels without installing.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    prompt = .{ .tty = true, .answer = false };
    try std.testing.expectEqual(@as(u8, 1), try runTestVerbs(alloc, .cli, home, &.{ "add", src }, &prompt, &out, &err));
    try std.testing.expect(prompt.asked);
    try std.testing.expect(std.mem.find(u8, err.items, "Install glm? [y/N]") != null);

    // TUI with --yes shows the screen of what it installs, installs, and includes next-start sentence.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    prompt = .{};
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .shell, home, &.{ "add", src, "--yes" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "Mod: glm (1.0.0)") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "Installed glm (1.0.0).") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "next time fx starts.") != null);

    // CLI list --json and show --json.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "list", "--json" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "\"kind\":\"mod_list\"") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\"name\":\"glm\"") != null);

    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "show", "glm", "--json" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "\"kind\":\"mod_show\"") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\"providers\":[{") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\"sends\":[{\"env\":\"GLM_API_KEY\",\"header\":\"Authorization\"}]") != null);

    // CLI disable / enable / update / remove do NOT print the TUI restart sentence.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "off", "glm" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "Disabled glm.") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "next time fx starts") == null);

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "on", "glm" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "Enabled glm.") != null);

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{"update"}, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "glm: updated from folder") != null);

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "rm", "glm" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "Removed glm.") != null);

    // CLI usage error with --json writes JSON to stdout and exits 2.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), try runTestVerbs(alloc, .cli, home, &.{ "list", "--yes", "--json" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "\"kind\":\"mod_list\"") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\"code\":\"InvalidLocalSurfaceArgs\"") != null);
}

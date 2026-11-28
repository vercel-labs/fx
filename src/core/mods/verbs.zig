//! Shared mod commands. Both `fx mod` / `fx mods` and `/mods` parse, execute,
//! and format output through this module (`RULES.md` R1.4, R4.6).

const std = @import("std");
const builtin_commands = @import("../../builtins/commands.zig");
const cli_flags = @import("../cli/cli_flags.zig");
const settings_messages = @import("../cli/settings_messages.zig");
const configured_provider = @import("../config/configured_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");
const profiles = @import("../profiles/profiles.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const text_utils = @import("../shared/text_utils.zig");
const shared_theme = @import("../shared/theme.zig");
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
const shell_apply_note = " Skills and agent profiles apply now. Model connections and themes apply the next time fx starts.";
const cli_apply_note = " Running fx sessions pick up skills and agent profiles on their next message. Model connections and themes apply when fx starts.";
const max_scanned_assets: usize = 256;

pub const Command = union(enum) {
    help: ?Verb,
    list: struct { json: bool = false },
    show: struct { name: []const u8, json: bool = false },
    add: struct { source: []const u8, yes: bool = false },
    update: struct { name: ?[]const u8 = null, yes: bool = false },
    enable: []const u8,
    disable: []const u8,
    remove: []const u8,
};

pub const Parsed = union(enum) {
    command: Command,
    usage: struct { verb: ?Verb, message: []const u8 },
};

pub const PromptVerb = enum { add, update };

pub const PromptOps = struct {
    ctx: ?*anyopaque = null,
    is_tty: *const fn (?*anyopaque) bool = defaultIsTty,
    confirm: *const fn (?*anyopaque, *Writer, PromptVerb, []const u8) anyerror!bool = defaultConfirm,
};

pub const Context = struct {
    gpa: Allocator,
    out: *Writer,
    err: *Writer,
    surface: Surface,
    home: []const u8,
    cancel: ?*const std.atomic.Value(bool) = null,
    prompt: PromptOps = .{},
    changed: ?*bool = null,

    fn markChanged(self: Context) void {
        if (self.changed) |flag| flag.* = true;
    }
};

fn defaultIsTty(_: ?*anyopaque) bool {
    return std.Io.File.stdin().isTty(io_mod.getIo()) catch false;
}

fn defaultConfirm(_: ?*anyopaque, err_writer: *Writer, verb: PromptVerb, mod_name: []const u8) anyerror!bool {
    const label = switch (verb) {
        .add => "Install ",
        .update => "Update ",
    };
    try err_writer.print("\n{s}{f}? [y/N] ", .{ label, text_utils.terminalSafe(mod_name) });
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
        .add, .update => verbFlagsFor(&builtin_commands.mod_add_options),
        .list => if (surface == .cli) verbFlagsFor(&builtin_commands.mod_list_options) else verbFlagsFor(&.{}),
        .show => if (surface == .cli) verbFlagsFor(&builtin_commands.mod_show_options) else verbFlagsFor(&.{}),
        .enable, .disable, .remove => verbFlagsFor(&.{}),
    };
}

pub noinline fn parse(arena: Allocator, surface: Surface, args: []const []const u8) Allocator.Error!Parsed {
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
            return .{ .command = .{ .update = .{ .name = if (pos.len == 1) pos[0] else null, .yes = yes } } };
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

pub noinline fn writeUsage(w: *Writer, surface: Surface, verb: ?Verb) Writer.Error!void {
    const p = surface.prog();
    const json = if (surface == .cli) " [--json]" else "";
    const v = verb orelse {
        try w.print(
            \\usage: {s} <command> ...
            \\
            \\  list{s:<24}list installed mods
            \\  show NAME{s:<19}show details for an installed mod
            \\  add SOURCE [--yes]          install from a folder or git URL[@ref]
            \\  update [NAME] [--yes]       update one mod, or every installed mod
            \\  enable NAME                 enable an installed mod (alias: on)
            \\  disable NAME                disable an installed mod (alias: off)
            \\  remove NAME                 remove an installed mod
            \\
        , .{ p, json, json });
        return;
    };
    try w.writeAll("usage: ");
    try w.writeAll(p);
    try w.writeByte(' ');
    switch (v) {
        .list => {
            try w.writeAll("list");
            try w.writeAll(json);
        },
        .show => {
            try w.writeAll("show NAME");
            try w.writeAll(json);
        },
        .add => try w.writeAll("add [--yes] <folder|git URL[@ref]>"),
        .update => try w.writeAll("update [--yes] [NAME]"),
        .enable => try w.writeAll("enable NAME"),
        .disable => try w.writeAll("disable NAME"),
        .remove => try w.writeAll("remove NAME"),
    }
    try w.writeByte('\n');
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
        .update => |u| runUpdate(c, arena, root, u.name, u.yes),
        .enable => |name| runSetOn(c, root, name, true),
        .disable => |name| runSetOn(c, root, name, false),
        .remove => |name| runRemove(c, root, name),
    };
}

noinline fn runList(c: Context, arena: Allocator, root: []const u8, json: bool) !u8 {
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

noinline fn runShow(c: Context, arena: Allocator, root: []const u8, name: []const u8, json: bool) !u8 {
    if (!mods.manifest.validName(name)) {
        return writeShowMissing(c, arena, name, json, "Mod name must use lowercase letters, digits, and hyphens only.");
    }

    var loaded = try mods.load(arena, root, name);
    defer loaded.deinit(arena);

    const record = readOptionalSourceRecord(arena, root, name);

    switch (loaded) {
        .none => return writeShowMissing(c, arena, name, json, null),
        .bad => |bad| return writeShowBroken(c, arena, name, bad.on, record, modProblemText(bad.problem), json),
        .mod => |m| {
            var pinned_opt: ?mods.Pin = null;
            defer if (pinned_opt) |*p| p.release(arena, io_mod.getIo());
            const details_dir = if (m.on) blk: {
                switch (try mods.pin(arena, root, name)) {
                    .pinned => |p| {
                        pinned_opt = p;
                        break :blk p.path;
                    },
                    .not_installed => return writeShowMissing(c, arena, name, json, null),
                    .bad_link => return writeShowBroken(c, arena, name, m.on, record, modProblemText(.dangling), json),
                    .busy => {
                        const msg = try arena.print("another fx is changing mod '{f}'; try again.", .{text_utils.terminalSafe(name)});
                        if (json) {
                            const rendered = try (output_contracts.CommandFailureSnapshot{
                                .kind = "mod_show",
                                .message = msg,
                                .code = "ModBusy",
                            }).renderJson(arena);
                            try c.out.writeAll(rendered);
                            try c.out.writeByte('\n');
                        } else {
                            try writeErrLine(c, "show", msg);
                        }
                        return 1;
                    },
                }
            } else m.path;

            const detail = readModDetails(arena, root, name, details_dir);
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
                .assets = detail.assets,
            };
            const rendered = try snapshot.render(arena, if (json) .json else .text);
            try c.out.writeAll(rendered);
            if (json) try c.out.writeByte('\n');
            return 0;
        },
    }
}

noinline fn writeShowBroken(
    c: Context,
    arena: Allocator,
    name: []const u8,
    on: bool,
    record: ?mods.source.Record,
    err_msg: []const u8,
    json: bool,
) !u8 {
    const snapshot: output_contracts.ModShowSnapshot = .{
        .name = name,
        .status = "broken",
        .on = on,
        .source = if (record) |r| r.source else null,
        .ref = if (record) |r| r.ref else null,
        .commit = if (record) |r| r.commit else null,
        .pinned = if (record) |r| r.pinned else false,
        .err = err_msg,
    };
    const rendered = try snapshot.render(arena, if (json) .json else .text);
    try c.out.writeAll(rendered);
    if (json) try c.out.writeByte('\n');
    return 1;
}

noinline fn writeShowMissing(c: Context, arena: Allocator, name: []const u8, json: bool, custom_msg: ?[]const u8) !u8 {
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
        try writeErrLine(c, null, msg);
    }
    return 1;
}

noinline fn runAdd(c: Context, arena: Allocator, root: []const u8, arg: []const u8, yes: bool) !u8 {
    var prep = switch (try mods.prepareInstall(arena, root, arg, c.cancel)) {
        .prepared => |p| p,
        .not_a_folder => |path| {
            try writeErrSafeLine(c, "add", "", path, " is not a folder.");
            return 1;
        },
        .source_invalid => |problem| {
            try writeErrLine(c, "add", sourceProblemText(problem));
            return 1;
        },
        .fetch_failed => |failed| {
            try writeFetchFailure(c, "add", arg, failed);
            return 1;
        },
        .no_manifest => {
            try writeErrLine(c, "add", "mod.json is missing.");
            return 1;
        },
        .bad_manifest => |err| {
            try writeErrLine(c, "add", mods.manifest.message(err));
            return 1;
        },
        .bad_providers => |bad| {
            try writeBadProviders(c, "add", bad.path, bad.err);
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
        const confirmed = try c.prompt.confirm(c.prompt.ctx, c.err, .add, prep.manifest.name);
        if (!confirmed) {
            try c.err.writeAll("Cancelled.\n");
            return 1;
        }
    }

    switch (try mods.commitInstall(arena, root, &prep)) {
        .installed => |inst| {
            c.markChanged();
            try c.out.print("Installed {f} ({f}).", .{
                text_utils.terminalSafe(inst.name),
                text_utils.terminalSafe(inst.version),
            });
            try writeOutRestartEnd(c);
            return 0;
        },
        .refused => |outcome| {
            try writeOutcomeFailure(c, "add", prep.manifest.name, outcome);
            return 1;
        },
        else => unreachable,
    }
}

noinline fn writeBadProviders(c: Context, verb_name: []const u8, path: []const u8, err: anyerror) !void {
    const advice = configured_provider.mod_failure_advice(err) orelse "could not parse providers";
    try writeErrPrefix(c, verb_name);
    if (path.len > 0) {
        try c.err.print("providers.{f}: {s}.\n", .{ text_utils.terminalSafe(path), advice });
    } else {
        try c.err.print("providers: {s}.\n", .{advice});
    }
}

noinline fn runUpdate(c: Context, arena: Allocator, root: []const u8, maybe_name: ?[]const u8, yes: bool) !u8 {
    if (maybe_name) |name| {
        if (!mods.manifest.validName(name)) {
            try writeErrSafeLine(c, "update", "invalid mod name '", name, "'.");
            return 1;
        }
        return switch (try runSingleUpdate(c, arena, root, name, yes, false)) {
            .ok, .changed => 0,
            .shell_pending => 0,
            .failed => 1,
        };
    }

    var listing = try mods.list(arena, root);
    defer listing.deinit(arena);
    if (listing.mods.len == 0) {
        try c.out.writeAll("No mods installed.\n");
        return 0;
    }

    var any_failed = false;
    var any_changed = false;
    for (listing.mods) |item| {
        switch (try runSingleUpdate(c, arena, root, item.name, yes, true)) {
            .ok, .shell_pending => {},
            .changed => any_changed = true,
            .failed => any_failed = true,
        }
    }
    if (any_changed) {
        c.markChanged();
        try writeRestartLine(c);
    }
    return if (any_failed) 1 else 0;
}

const SingleUpdateOutcome = enum { ok, changed, shell_pending, failed };

noinline fn runSingleUpdate(
    c: Context,
    arena: Allocator,
    root: []const u8,
    name: []const u8,
    yes: bool,
    batch: bool,
) !SingleUpdateOutcome {
    const prep_res = try mods.prepareUpdate(arena, root, name, c.cancel);
    switch (prep_res) {
        .prepared => |prep_const| {
            var prep = prep_const;
            defer prep.discard(arena);

            const old_views = try providerViews(arena, prep.old_providers);
            const new_views = try providerViews(arena, prep.install.providers);
            const diff = diffUpdateSafety(old_views, new_views, prep.files_changed);

            if (diff.needsConfirm()) {
                const preview = try buildInstallPreview(arena, &prep.install);
                const preview_text = try preview.renderText(arena);
                if (yes) {
                    const target_w = if (c.surface == .shell) c.out else c.err;
                    try target_w.writeAll(preview_text);
                    try target_w.writeByte('\n');
                    try writeUpdateChanges(target_w, diff);
                } else if (c.surface == .shell) {
                    try c.out.writeAll(preview_text);
                    try c.out.writeByte('\n');
                    try writeUpdateChanges(c.out, diff);
                    try c.out.print("\nRun /mods update {f} --yes to update.\n", .{text_utils.terminalSafe(name)});
                    return .shell_pending;
                } else if (!c.prompt.is_tty(c.prompt.ctx)) {
                    if (batch) {
                        try c.err.print(
                            "{f}: update adds or changes what the mod runs or sends; run fx mod update {f} --yes\n",
                            .{ text_utils.terminalSafe(name), text_utils.terminalSafe(name) },
                        );
                    } else {
                        try c.err.writeAll(preview_text);
                        try c.err.writeByte('\n');
                        try writeUpdateChanges(c.err, diff);
                        try c.err.writeAll("\nCannot confirm update without a terminal. Re-run with --yes to update.\n");
                    }
                    return .failed;
                } else {
                    try c.err.writeAll(preview_text);
                    try c.err.writeByte('\n');
                    try writeUpdateChanges(c.err, diff);
                    const confirmed = try c.prompt.confirm(c.prompt.ctx, c.err, .update, name);
                    if (!confirmed) {
                        if (batch) {
                            try c.err.print("{f}: cancelled\n", .{text_utils.terminalSafe(name)});
                        } else {
                            try c.err.writeAll("Cancelled.\n");
                        }
                        return .failed;
                    }
                }
            }

            const res = try mods.commitUpdate(arena, root, &prep);
            const ok = try writeRefreshResult(c, name, res, batch);
            if (!ok) return .failed;
            if (res == .updated or res == .folder_copied) {
                if (!batch) c.markChanged();
                return .changed;
            }
            return .ok;
        },
        .up_to_date => |commit| {
            _ = try writeRefreshResult(c, name, .{ .up_to_date = commit }, batch);
            return .ok;
        },
        .pinned => |ref| {
            _ = try writeRefreshResult(c, name, .{ .pinned = ref }, batch);
            return .ok;
        },
        .not_installed => {
            try writeRefreshFailure(c, name, .not_installed);
            return .failed;
        },
        .bad_mod => {
            try writeRefreshFailure(c, name, .bad_mod);
            return .failed;
        },
        .no_record => {
            try writeRefreshFailure(c, name, .no_record);
            return .failed;
        },
        .bad_record => {
            try writeRefreshFailure(c, name, .bad_record);
            return .failed;
        },
        .source_missing => |path| {
            try writeRefreshFailure(c, name, .{ .source_missing = path });
            return .failed;
        },
        .fetch_failed => |failed| {
            try writeRefreshFailure(c, name, .{ .fetch_failed = failed });
            return .failed;
        },
        .refused => |outcome| {
            try writeRefreshFailure(c, name, .{ .refused = outcome });
            return .failed;
        },
        .no_manifest => {
            try writeErrLine(c, "update", "mod.json is missing.");
            return .failed;
        },
        .bad_manifest => |err| {
            try writeErrLine(c, "update", mods.manifest.message(err));
            return .failed;
        },
        .bad_providers => |bad| {
            try writeBadProviders(c, "update", bad.path, bad.err);
            return .failed;
        },
    }
}

noinline fn writeRefreshResult(c: Context, name: []const u8, res: mods.RefreshResult, batch: bool) !bool {
    const safe_name = text_utils.terminalSafe(name);
    switch (res) {
        .updated => |u| {
            if (batch) {
                try c.out.print("{f}: updated {s} -> {s}\n", .{ safe_name, shortCommit(u.old_commit), shortCommit(u.new_commit) });
            } else {
                try c.out.print("Updated {f}: {s} -> {s}.", .{ safe_name, shortCommit(u.old_commit), shortCommit(u.new_commit) });
                try writeOutRestartEnd(c);
            }
            return true;
        },
        .folder_copied => {
            if (batch) {
                try c.out.print("{f}: updated from folder\n", .{safe_name});
            } else {
                try c.out.print("Updated {f} from folder.", .{safe_name});
                try writeOutRestartEnd(c);
            }
            return true;
        },
        .up_to_date => {
            if (batch) {
                try c.out.print("{f}: already up to date\n", .{safe_name});
            } else {
                try c.out.print("{f} is already up to date.\n", .{safe_name});
            }
            return true;
        },
        .pinned => |ref| {
            const safe_ref = text_utils.terminalSafe(ref);
            if (batch) {
                try c.out.print("{f}: pinned at {f}, skipped\n", .{ safe_name, safe_ref });
            } else {
                try c.out.print("{f} is pinned at {f}.\n", .{ safe_name, safe_ref });
            }
            return true;
        },
        else => {
            try writeRefreshFailure(c, name, res);
            return false;
        },
    }
}

noinline fn writeRefreshFailure(c: Context, name: []const u8, res: mods.RefreshResult) !void {
    switch (res) {
        .not_installed => try writeErrSafeLine(c, "update", "mod '", name, "' is not installed."),
        .bad_mod => try writeErrSafeLine(c, "update", "mod '", name, "' is broken."),
        .no_record => try writeErrSafeLine(c, "update", "mod '", name, "' has no saved source record."),
        .bad_record => try writeErrSafeLine(c, "update", "mod '", name, "' has an unreadable source record."),
        .source_missing => |path| {
            try writeErrPrefix(c, "update");
            try c.err.print("source folder for '{f}' is missing: {f}.\n", .{ text_utils.terminalSafe(name), text_utils.terminalSafe(path) });
        },
        .fetch_failed => |failed| try writeFetchFailure(c, "update", name, failed),
        .refused => |outcome| try writeOutcomeFailure(c, "update", name, outcome),
        else => {},
    }
}

noinline fn runSetOn(c: Context, root: []const u8, name: []const u8, on: bool) !u8 {
    const verb_name = if (on) "enable" else "disable";
    const outcome = try mods.setOn(c.gpa, root, name, on);
    if (outcome == .ok) {
        c.markChanged();
        try c.out.writeAll(if (on) "Enabled " else "Disabled ");
        try c.out.print("{f}.", .{text_utils.terminalSafe(name)});
        try writeOutRestartEnd(c);
        return 0;
    }
    try writeOutcomeFailure(c, verb_name, name, outcome);
    return 1;
}

noinline fn runRemove(c: Context, root: []const u8, name: []const u8) !u8 {
    const outcome = try mods.remove(c.gpa, root, name);
    if (outcome == .ok) {
        c.markChanged();
        try c.out.print("Removed {f}.", .{text_utils.terminalSafe(name)});
        try writeOutRestartEnd(c);
        return 0;
    }
    try writeOutcomeFailure(c, "remove", name, outcome);
    return 1;
}

fn buildInstallPreview(arena: Allocator, prep: *const mods.PreparedInstall) !output_contracts.ModInstallPreviewSnapshot {
    const providers = try providerViews(arena, prep.providers);
    const assets = scanModAssets(arena, prep.dir);
    return .{
        .name = prep.manifest.name,
        .version = prep.manifest.version,
        .description = prep.manifest.description,
        .source = prep.source,
        .commit = prep.commit,
        .providers = providers,
        .assets = assets,
    };
}

pub const UpdateSafetyDiff = struct {
    command: bool = false,
    files: bool = false,
    sends: bool = false,

    pub fn needsConfirm(self: UpdateSafetyDiff) bool {
        return self.command or self.files or self.sends;
    }
};

pub fn diffUpdateSafety(
    old_providers: []const output_contracts.ModProviderView,
    new_providers: []const output_contracts.ModProviderView,
    files_changed: bool,
) UpdateSafetyDiff {
    var diff: UpdateSafetyDiff = .{};
    var has_any_command = false;
    for (new_providers) |np| {
        const op = findProviderView(old_providers, np.name);
        if (np.command) |new_cmd| {
            has_any_command = true;
            if (op == null or op.?.command == null or !argvEql(op.?.command.?, new_cmd)) {
                diff.command = true;
            }
            if (op) |prev| {
                if (prev.command != null and !std.mem.eql(u8, prev.base_url, np.base_url)) {
                    diff.sends = true;
                }
            }
        }
        for (np.sends) |ns| {
            const known = if (op) |prev|
                std.mem.eql(u8, prev.base_url, np.base_url) and hasSend(prev.sends, ns)
            else
                false;
            if (!known) diff.sends = true;
        }
    }
    if (files_changed and has_any_command) {
        diff.files = true;
    }
    return diff;
}

fn findProviderView(providers: []const output_contracts.ModProviderView, name: []const u8) ?output_contracts.ModProviderView {
    for (providers) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn argvEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn hasSend(sends: []const output_contracts.ModProviderSend, target: output_contracts.ModProviderSend) bool {
    for (sends) |s| {
        if (std.mem.eql(u8, s.env, target.env) and std.mem.eql(u8, s.header, target.header)) return true;
    }
    return false;
}

fn writeUpdateChanges(w: *Writer, diff: UpdateSafetyDiff) !void {
    if (diff.command) try w.writeAll("This update adds or changes a sign-in command.\n");
    if (diff.files) try w.writeAll("This update changes the files of a mod that runs a sign-in command.\n");
    if (diff.sends) try w.writeAll("This update changes what the mod sends, or where it sends it.\n");
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
    assets: output_contracts.ModAssetsView = .{},
    err: ?[]const u8 = null,
};

fn readModDetails(arena: Allocator, root: []const u8, name: []const u8, link_path: []const u8) ModDetails {
    const assets = scanModAssets(arena, link_path);
    const io = io_mod.getIo();
    var dir = std.Io.Dir.cwd().openDir(io, link_path, .{}) catch return .{ .assets = assets };
    defer dir.close(io);
    const bytes = dir.readFileAlloc(io, "mod.json", arena, .limited(mods.manifest.max_bytes + 1)) catch return .{ .assets = assets };
    const decoded = mods.manifest.decode(arena, bytes) catch return .{ .assets = assets };
    const providers_val = decoded.providers orelse return .{ .description = decoded.description, .assets = assets };

    const canonical_link = std.Io.Dir.path.join(arena, &.{ root, name }) catch return .{ .description = decoded.description, .assets = assets };
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
        return .{ .description = decoded.description, .assets = assets, .err = msg };
    };
    _ = &reg;
    const views = providerViews(arena, reg) catch return .{ .description = decoded.description, .assets = assets };
    return .{ .description = decoded.description, .providers = views, .assets = assets };
}

noinline fn scanModAssets(arena: Allocator, mod_dir_path: []const u8) output_contracts.ModAssetsView {
    const io = io_mod.getIo();
    var mod_dir = std.Io.Dir.cwd().openDir(io, mod_dir_path, .{}) catch return .{};
    defer mod_dir.close(io);

    return .{
        .skills = scanModSkills(arena, io, mod_dir),
        .profiles = scanModProfiles(arena, io, mod_dir),
        .themes = scanModThemes(arena, io, mod_dir),
    };
}

fn scanModSkills(arena: Allocator, io: std.Io, mod_dir: std.Io.Dir) []const []const u8 {
    var dir = mod_dir.openDir(io, "skills", .{ .iterate = true, .follow_symlinks = false }) catch return &.{};
    defer dir.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |item| {
        if (item.kind != .directory or item.name.len == 0 or item.name[0] == '.') continue;
        var sub = dir.openDir(io, item.name, .{ .follow_symlinks = false }) catch continue;
        defer sub.close(io);
        const st = sub.statFile(io, "SKILL.md", .{ .follow_symlinks = false }) catch continue;
        if (st.kind != .file) continue;
        if (list.items.len >= max_scanned_assets) break;
        list.append(arena, arena.dupe(u8, item.name) catch continue) catch break;
    }
    sort_utils.sort([]const u8, list.items, {}, nameLessThan);
    return list.items;
}

fn scanModProfiles(arena: Allocator, io: std.Io, mod_dir: std.Io.Dir) []const output_contracts.ModProfileView {
    var dir = mod_dir.openDir(io, "agents", .{ .iterate = true, .follow_symlinks = false }) catch return &.{};
    defer dir.close(io);
    var list: std.ArrayList(output_contracts.ModProfileView) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |item| {
        if (item.kind != .directory or !profiles.validName(item.name)) continue;
        if (std.mem.eql(u8, item.name, profiles.main_name)) continue;
        if (list.items.len >= max_scanned_assets) break;
        const ignores_perm = agentSetsPermissionMode(arena, io, dir, item.name);
        list.append(arena, .{
            .name = arena.dupe(u8, item.name) catch continue,
            .permission_mode_ignored = ignores_perm,
        }) catch break;
    }
    sort_utils.sort(output_contracts.ModProfileView, list.items, {}, struct {
        fn lessThan(_: void, a: output_contracts.ModProfileView, b: output_contracts.ModProfileView) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return list.items;
}

fn agentSetsPermissionMode(arena: Allocator, io: std.Io, agents_dir: std.Io.Dir, name: []const u8) bool {
    var sub = agents_dir.openDir(io, name, .{ .follow_symlinks = false }) catch return false;
    defer sub.close(io);
    const st = sub.statFile(io, profiles.settings_file_name, .{ .follow_symlinks = false }) catch return false;
    if (st.kind != .file) return false;
    var file = sub.openFile(io, profiles.settings_file_name, .{ .mode = .read_only, .follow_symlinks = false }) catch return false;
    defer file.close(io);
    const fstat = file.stat(io) catch return false;
    if (fstat.kind != .file) return false;
    const bytes = io_mod.readFileToEnd(arena, &file, profiles.max_settings_bytes + 1) catch return false;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return false;
    return root == .object and root.object.get("permission_mode") != null;
}

fn scanModThemes(arena: Allocator, io: std.Io, mod_dir: std.Io.Dir) []const []const u8 {
    var dir = mod_dir.openDir(io, "themes", .{ .iterate = true, .follow_symlinks = false }) catch return &.{};
    defer dir.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |item| {
        if (item.kind != .file) continue;
        const st = dir.statFile(io, item.name, .{ .follow_symlinks = false }) catch continue;
        if (st.kind != .file) continue;
        if (!std.mem.endsWith(u8, item.name, ".json")) continue;
        const stem = item.name[0 .. item.name.len - ".json".len];
        if (!shared_theme.validThemeName(stem)) continue;
        if (list.items.len >= max_scanned_assets) break;
        list.append(arena, arena.dupe(u8, stem) catch continue) catch break;
    }
    sort_utils.sort([]const u8, list.items, {}, nameLessThan);
    return list.items;
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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

fn writeErrPrefix(c: Context, verb_name: ?[]const u8) !void {
    try c.err.writeAll(c.surface.prog());
    if (verb_name) |v| {
        try c.err.writeByte(' ');
        try c.err.writeAll(v);
    }
    try c.err.writeAll(": ");
}

fn writeErrLine(c: Context, verb_name: ?[]const u8, msg: []const u8) !void {
    try writeErrPrefix(c, verb_name);
    try c.err.writeAll(msg);
    try c.err.writeByte('\n');
}

fn writeErrSafeLine(c: Context, verb_name: ?[]const u8, prefix: []const u8, raw: []const u8, suffix: []const u8) !void {
    try writeErrPrefix(c, verb_name);
    try c.err.writeAll(prefix);
    try c.err.print("{f}", .{text_utils.terminalSafe(raw)});
    try c.err.writeAll(suffix);
    try c.err.writeByte('\n');
}

fn writeOutRestartEnd(c: Context) !void {
    try c.out.writeAll(if (c.surface == .shell) shell_apply_note else cli_apply_note);
    try c.out.writeByte('\n');
}

fn writeRestartLine(c: Context) !void {
    const note = if (c.surface == .shell) shell_apply_note else cli_apply_note;
    try c.out.writeAll(note[1..]);
    try c.out.writeByte('\n');
}

noinline fn writeFetchFailure(c: Context, verb_name: []const u8, label: []const u8, failed: mods.source.Failed) !void {
    switch (failed.kind) {
        .timed_out => try writeErrSafeLine(c, verb_name, "git timed out while fetching '", label, "'."),
        .cancelled => try writeErrLine(c, verb_name, "cancelled."),
        .signaled => try writeErrLine(c, verb_name, "git exited on a signal."),
        .too_large => try writeErrLine(c, verb_name, "git output was larger than fx reads."),
        .spawn_failed => try writeErrLine(c, verb_name, "could not start git."),
        .bad_commit => try writeErrLine(c, verb_name, "git returned an invalid commit hash."),
        .git_failed => {
            if (failed.detail.len > 0) {
                try writeErrSafeLine(c, verb_name, "git failed: ", failed.detail, "");
            } else {
                try writeErrLine(c, verb_name, "git failed.");
            }
        },
    }
}

noinline fn writeOutcomeFailure(c: Context, verb_name: []const u8, name: []const u8, outcome: mods.Outcome) !void {
    switch (outcome) {
        .ok => {},
        .exists => try writeErrSafeLine(c, verb_name, "mod '", name, "' is already installed."),
        .missing => try writeErrSafeLine(c, verb_name, "mod '", name, "' is not installed."),
        .busy => try writeErrSafeLine(c, verb_name, "another fx is changing mod '", name, "'; try again."),
        .invalid => |inv| try writeErrLine(c, verb_name, invalidText(inv)),
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

    fn confirm(ctx: ?*anyopaque, w: *Writer, verb: PromptVerb, mod_name: []const u8) anyerror!bool {
        const self: *TestPrompt = @ptrCast(@alignCast(ctx.?));
        self.asked = true;
        const label = switch (verb) {
            .add => "Install ",
            .update => "Update ",
        };
        try w.print("\n{s}{s}? [y/N] ", .{ label, mod_name });
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
    try std.testing.expect(!(try parse(arena, .cli, &.{ "update", "glm" })).command.update.yes);
    try std.testing.expect((try parse(arena, .cli, &.{ "update", "--yes" })).command.update.yes);
    try std.testing.expectEqualStrings("glm", (try parse(arena, .cli, &.{ "update", "glm", "--yes" })).command.update.name.?);
    try std.testing.expect((try parse(arena, .cli, &.{"update"})).command.update.name == null);

    try std.testing.expect((try parse(arena, .cli, &.{ "list", "--yes" })) == .usage);
    try std.testing.expect((try parse(arena, .cli, &.{ "add", "--json", "./src" })) == .usage);
    try std.testing.expect((try parse(arena, .cli, &.{ "update", "--json" })) == .usage);
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

    // TUI with --yes shows the screen of what it installs, installs, and includes the apply notice.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    prompt = .{};
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .shell, home, &.{ "add", src, "--yes" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "Mod: glm (1.0.0)") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "Installed glm (1.0.0).") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "Skills and agent profiles apply now. Model connections and themes apply the next time fx starts.") != null);

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

    // CLI disable / enable / update / remove print the CLI apply notice (not the TUI wording).
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "off", "glm" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "Disabled glm.") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "Running fx sessions pick up skills and agent profiles on their next message.") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "next time fx starts") == null);

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "on", "glm" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "Enabled glm.") != null);

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{"update"}, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "glm: updated from folder") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "Running fx sessions pick up skills and agent profiles on their next message.") != null);

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

test "diffUpdateSafety detects command, file, send, and URL additions or changes only" {
    const cmd_a = [_][]const u8{ "/mods/glm/bin/a", "--ok" };
    const cmd_b = [_][]const u8{ "/mods/glm/bin/b", "--ok" };
    const send_a = [_]output_contracts.ModProviderSend{.{ .env = "KEY_A", .header = "Authorization" }};
    const send_ab = [_]output_contracts.ModProviderSend{
        .{ .env = "KEY_A", .header = "Authorization" },
        .{ .env = "KEY_B", .header = "X-Team" },
    };

    const base = [_]output_contracts.ModProviderView{.{
        .name = "p1",
        .protocol = "openai-chat-completions",
        .base_url = "https://a.example/v1",
        .command = &cmd_a,
        .sends = &send_a,
    }};

    // 1. Version-only (identical providers and unchanged files) does not ask.
    try std.testing.expect(!diffUpdateSafety(&base, &base, false).needsConfirm());

    // 2. Changed argv asks.
    const changed_cmd = [_]output_contracts.ModProviderView{.{
        .name = "p1",
        .protocol = "openai-chat-completions",
        .base_url = "https://a.example/v1",
        .command = &cmd_b,
        .sends = &send_a,
    }};
    const d_cmd = diffUpdateSafety(&base, &changed_cmd, false);
    try std.testing.expect(d_cmd.needsConfirm() and d_cmd.command and !d_cmd.files and !d_cmd.sends);

    // 3. New provider with a command asks.
    const new_with_cmd = [_]output_contracts.ModProviderView{
        base[0],
        .{ .name = "p2", .protocol = "openai-chat-completions", .base_url = "https://a.example/v1", .command = &cmd_a },
    };
    try std.testing.expect(diffUpdateSafety(&base, &new_with_cmd, false).command);

    // 4. New sent variable asks.
    const new_send = [_]output_contracts.ModProviderView{.{
        .name = "p1",
        .protocol = "openai-chat-completions",
        .base_url = "https://a.example/v1",
        .command = &cmd_a,
        .sends = &send_ab,
    }};
    const d_send = diffUpdateSafety(&base, &new_send, false);
    try std.testing.expect(d_send.needsConfirm() and !d_send.command and d_send.sends);

    // 5. Changed URL for a sent variable asks.
    const changed_url = [_]output_contracts.ModProviderView{.{
        .name = "p1",
        .protocol = "openai-chat-completions",
        .base_url = "https://evil.example/v1",
        .command = &cmd_a,
        .sends = &send_a,
    }};
    const d_url = diffUpdateSafety(&base, &changed_url, false);
    try std.testing.expect(d_url.needsConfirm() and d_url.sends);

    // 6. Changed URL on a command provider without explicit `sends` asks (token goes to base_url).
    const cmd_only_old = [_]output_contracts.ModProviderView{.{
        .name = "p1",
        .protocol = "openai-chat-completions",
        .base_url = "https://a.example/v1",
        .command = &cmd_a,
    }};
    const cmd_only_new_url = [_]output_contracts.ModProviderView{.{
        .name = "p1",
        .protocol = "openai-chat-completions",
        .base_url = "https://b.example/v1",
        .command = &cmd_a,
    }};
    const d_cmd_url = diffUpdateSafety(&cmd_only_old, &cmd_only_new_url, true);
    try std.testing.expect(d_cmd_url.needsConfirm() and !d_cmd_url.command and d_cmd_url.files and d_cmd_url.sends);

    // 7. Files changed plus a command asks; files changed without any command does not ask.
    try std.testing.expect(diffUpdateSafety(&cmd_only_old, &cmd_only_old, true).files);
    const no_cmd = [_]output_contracts.ModProviderView{.{
        .name = "p1",
        .protocol = "openai-chat-completions",
        .base_url = "https://a.example/v1",
    }};
    try std.testing.expect(!diffUpdateSafety(&no_cmd, &no_cmd, true).needsConfirm());

    // 8. Removed provider does not ask.
    try std.testing.expect(!diffUpdateSafety(&base, &.{}, false).needsConfirm());

    // 9. New provider that sends nothing and runs nothing does not ask.
    const new_harmless = [_]output_contracts.ModProviderView{
        base[0],
        .{ .name = "p2", .protocol = "openai-chat-completions", .base_url = "https://b.example/v1" },
    };
    try std.testing.expect(!diffUpdateSafety(&base, &new_harmless, false).needsConfirm());
}

test "mods update confirmation paths cover no-tty, tty yes/no, --yes, batch skip, and TUI hint" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    try tmp.dir.createDirPath(io_mod.getIo(), "alpha");
    try tmp.dir.createDirPath(io_mod.getIo(), "beta");
    const alpha = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "alpha");
    defer alloc.free(alpha);
    const beta = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "beta");
    defer alloc.free(beta);

    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "alpha/mod.json",
        .data = "{\"name\":\"alpha\",\"version\":\"1.0.0\",\"providers\":{\"p\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://a.example/v1\",\"auth\":{\"type\":\"command\",\"command\":[\"bin/a\"]}}}}",
    });
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "beta/mod.json",
        .data = "{\"name\":\"beta\",\"version\":\"1.0.0\"}",
    });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(alloc);
    var prompt: TestPrompt = .{};

    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "add", "--yes", alpha }, &prompt, &out, &err));
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "add", "--yes", beta }, &prompt, &out, &err));

    // Change alpha's command and bump beta's version only.
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "alpha/mod.json",
        .data = "{\"name\":\"alpha\",\"version\":\"2.0.0\",\"providers\":{\"p\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://a.example/v1\",\"auth\":{\"type\":\"command\",\"command\":[\"bin/b\"]}}}}",
    });
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "beta/mod.json",
        .data = "{\"name\":\"beta\",\"version\":\"2.0.0\"}",
    });

    // 1. CLI single update without TTY and without --yes: refused exit 1, names --yes, keeps 1.0.0.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    prompt = .{};
    try std.testing.expectEqual(@as(u8, 1), try runTestVerbs(alloc, .cli, home, &.{ "update", "alpha" }, &prompt, &out, &err));
    try std.testing.expect(!prompt.asked);
    try std.testing.expect(std.mem.find(u8, err.items, "This update adds or changes a sign-in command.\n") != null);
    try std.testing.expect(std.mem.find(u8, err.items, "This update changes the files of a mod that runs a sign-in command.\n") != null);
    try std.testing.expect(std.mem.find(u8, err.items, "--yes") != null);

    // 2. CLI TTY answer `n`: asks `Update alpha? [y/N]` and cancels, keeping 1.0.0.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    prompt = .{ .tty = true, .answer = false };
    try std.testing.expectEqual(@as(u8, 1), try runTestVerbs(alloc, .cli, home, &.{ "update", "alpha" }, &prompt, &out, &err));
    try std.testing.expect(prompt.asked);
    try std.testing.expect(std.mem.find(u8, err.items, "Update alpha? [y/N]") != null);
    try std.testing.expect(std.mem.find(u8, err.items, "Cancelled.") != null);

    // 3. TUI `/mods update alpha`: prints preview, change lines, and `/mods update alpha --yes`, keeps 1.0.0.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    prompt = .{};
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .shell, home, &.{ "update", "alpha" }, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, out.items, "Mod: alpha (2.0.0)") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "Run /mods update alpha --yes to update.") != null);

    // 4. CLI batch update without TTY: skips alpha naming `fx mod update alpha --yes`, updates beta to 2.0.0, exits 1.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try runTestVerbs(alloc, .cli, home, &.{"update"}, &prompt, &out, &err));
    try std.testing.expect(std.mem.find(u8, err.items, "fx mod update alpha --yes") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "beta: updated from folder") != null);

    // 5. CLI TTY answer `y` updates alpha to 2.0.0.
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    prompt = .{ .tty = true, .answer = true };
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "update", "alpha" }, &prompt, &out, &err));
    try std.testing.expect(prompt.asked);
    try std.testing.expect(std.mem.find(u8, err.items, "Update alpha? [y/N]") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "Updated alpha from folder.") != null);

    // 6. CLI `--yes` skips prompt even when command changes again.
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "alpha/mod.json",
        .data = "{\"name\":\"alpha\",\"version\":\"3.0.0\",\"providers\":{\"p\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://a.example/v1\",\"auth\":{\"type\":\"command\",\"command\":[\"bin/c\"]}}}}",
    });
    out.clearRetainingCapacity();
    err.clearRetainingCapacity();
    prompt = .{};
    try std.testing.expectEqual(@as(u8, 0), try runTestVerbs(alloc, .cli, home, &.{ "update", "alpha", "--yes" }, &prompt, &out, &err));
    try std.testing.expect(!prompt.asked);
    try std.testing.expect(std.mem.find(u8, out.items, "Updated alpha from folder.") != null);
}

test "scanModAssets ignores linked profile.json and links to named pipes without hanging" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{
        .sub_path = "outside/secret-profile.json",
        .data = "{\"description\":\"Secret\",\"permission_mode\":\"yolo\"}",
    });
    const outside_profile = try std.Io.Dir.path.join(arena, &.{
        try io_mod.dirRealpathAlloc(arena, tmp.dir, "outside"),
        "secret-profile.json",
    });

    const fifo_path = try std.Io.Dir.path.join(arena, &.{
        try io_mod.dirRealpathAlloc(arena, tmp.dir, "outside"),
        "pipe-profile.fifo",
    });
    const fifo_z = try arena.dupeSentinel(u8, fifo_path, 0);
    const fifo_c = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
    };
    if (fifo_c.mkfifo(fifo_z.ptr, 0o600) != 0) return error.SkipZigTest;

    try tmp.dir.createDirPath(io, "mod/agents/linked");
    try tmp.dir.createDirPath(io, "mod/agents/piped");
    try tmp.dir.createDirPath(io, "mod/agents/real");
    try tmp.dir.writeFile(io, .{
        .sub_path = "mod/agents/real/profile.json",
        .data = "{\"description\":\"Real\",\"permission_mode\":\"yolo\"}",
    });
    var mod_dir = try tmp.dir.openDir(io, "mod", .{});
    defer mod_dir.close(io);
    try mod_dir.symLink(io, outside_profile, "agents/linked/profile.json", .{});
    try mod_dir.symLink(io, fifo_path, "agents/piped/profile.json", .{});

    const mod_abs = try io_mod.dirRealpathAlloc(arena, tmp.dir, "mod");
    const assets = scanModAssets(arena, mod_abs);
    try std.testing.expectEqual(@as(usize, 3), assets.profiles.len);
    try std.testing.expectEqualStrings("linked", assets.profiles[0].name);
    try std.testing.expect(!assets.profiles[0].permission_mode_ignored);
    try std.testing.expectEqualStrings("piped", assets.profiles[1].name);
    try std.testing.expect(!assets.profiles[1].permission_mode_ignored);
    try std.testing.expectEqualStrings("real", assets.profiles[2].name);
    try std.testing.expect(assets.profiles[2].permission_mode_ignored);
}

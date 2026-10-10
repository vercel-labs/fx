//! The MCP verbs. `fx mcp` and `/mcp`
//! parse, run, and print through here, so both say the same things. They
//! differ only in their surface, which decides `--json`, how `login` waits,
//! and the name hints use, and in the `Hosts` they hand in.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const config_runtime = @import("../config/config_runtime.zig");
const project_config = @import("../mcp/project_config.zig");
const command_provider = @import("../mcp/command_provider.zig");
const config_file = @import("config_file.zig");
const credentials = @import("credentials.zig");
const runtime_mod = @import("runtime.zig");
const Host = @import("host.zig").Host;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Status = runtime_mod.Status;
pub const Notify = runtime_mod.Notify;

pub const Surface = enum {
    cli,
    shell,

    fn prog(s: Surface) []const u8 {
        return switch (s) {
            .cli => "fx mcp",
            .shell => "/mcp",
        };
    }
};

pub const Verb = enum { list, show, add, remove, login, logout, approve, reject };

pub const Command = union(enum) {
    help: ?Verb,
    list: struct { json: bool = false },
    show: struct { name: []const u8, json: bool = false },
    add: struct { name: []const u8, file: config_file.File, entry: config_file.Entry },
    remove: struct { name: []const u8, file: ?config_file.File },
    login: struct { name: []const u8, browser: bool },
    logout: []const u8,
    /// Null approves every project server.
    approve: ?[]const u8,
    reject: []const u8,
};

pub const Parsed = union(enum) {
    command: Command,
    /// A usage mistake: `message`, then the verb's usage; exit 2.
    usage: struct { verb: ?Verb, message: []const u8 },
    /// A verb v1 had: where it went; exit 2.
    moved: []const u8,
};

/// Reads the arguments after `fx mcp` or `/mcp`. Slices point into `args`
/// or `arena`.
pub fn parse(arena: Allocator, surface: Surface, args: []const []const u8) Allocator.Error!Parsed {
    const p = surface.prog();
    if (args.len == 0 or isHelp(args[0]) or std.mem.eql(u8, args[0], "help")) return .{ .command = .{ .help = null } };
    const verb = std.meta.stringToEnum(Verb, args[0]) orelse {
        const old = args[0];
        if (std.mem.eql(u8, old, "auth")) return moved(arena, "{s} auth is now {s} login NAME.", .{ p, p });
        if (std.mem.eql(u8, old, "trust")) return moved(arena, "{s} trust is now {s} approve NAME and {s} reject NAME.", .{ p, p, p });
        if (std.mem.eql(u8, old, "path")) return moved(arena, "{s} path is gone: {s} list shows each server's file.", .{ p, p });
        if (std.mem.eql(u8, old, "reload")) return moved(arena, "{s} reload is gone: fx reloads after add, remove, approve, and reject.", .{p});
        if (std.mem.eql(u8, old, "resource") or std.mem.eql(u8, old, "prompt"))
            return moved(arena, "{s} {s} is gone: fx doesn't support MCP resources and prompts yet.", .{ p, old });
        return usage(arena, null, "'{s}' isn't a {s} command.", .{ old, p });
    };

    // Flags come before `--`; everything after it is a stdio server's command.
    const rest = args[1..];
    const dash = for (rest, 0..) |a, k| {
        if (std.mem.eql(u8, a, "--")) break k;
    } else rest.len;
    var names: std.ArrayList([]const u8) = .empty;
    var pairs: std.ArrayList(config_file.Pair) = .empty;
    var pair_flag: ?[]const u8 = null;
    var json = false;
    var project = false;
    var profile = false;
    var all = false;
    var no_browser = false;
    var i: usize = 0;
    while (i < dash) : (i += 1) {
        const a = rest[i];
        if (isHelp(a)) return .{ .command = .{ .help = verb } };
        if (a.len == 0 or a[0] != '-') {
            try names.append(arena, a);
            continue;
        }
        const allowed = switch (verb) {
            .list, .show => surface == .cli and std.mem.eql(u8, a, "--json"),
            .add => std.mem.eql(u8, a, "--project") or std.mem.eql(u8, a, "--env") or std.mem.eql(u8, a, "--header"),
            .remove => std.mem.eql(u8, a, "--project") or std.mem.eql(u8, a, "--profile"),
            .login => std.mem.eql(u8, a, "--no-browser"),
            .approve => std.mem.eql(u8, a, "--all"),
            .logout, .reject => false,
        };
        if (verb == .list and std.mem.eql(u8, a, "--connect")) return moved(arena, "{s} list --connect is now {s} show NAME.", .{ p, p });
        if (!allowed) return usage(arena, verb, "{s} {s} has no {s} flag.", .{ p, @tagName(verb), a });
        if (std.mem.eql(u8, a, "--env") or std.mem.eql(u8, a, "--header")) {
            if (pair_flag) |f| if (!std.mem.eql(u8, f, a)) return usage(arena, verb, "--env is for stdio servers and --header for HTTP ones.", .{});
            pair_flag = a;
            i += 1;
            const kv = if (i < dash) rest[i] else "";
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse 0;
            if (eq == 0) return usage(arena, verb, "{s} needs KEY=VALUE.", .{a});
            try pairs.append(arena, .{ .key = kv[0..eq], .value = kv[eq + 1 ..] });
            continue;
        }
        if (std.mem.eql(u8, a, "--json")) json = true;
        if (std.mem.eql(u8, a, "--project")) project = true;
        if (std.mem.eql(u8, a, "--profile")) profile = true;
        if (std.mem.eql(u8, a, "--all")) all = true;
        if (std.mem.eql(u8, a, "--no-browser")) no_browser = true;
    }
    if (dash < rest.len and verb != .add) return usage(arena, verb, "{s} {s} takes no command after --.", .{ p, @tagName(verb) });
    const n = names.items;

    switch (verb) {
        .list => {
            if (n.len > 0) return usage(arena, verb, "{s} list takes no server name.", .{p});
            return .{ .command = .{ .list = .{ .json = json } } };
        },
        .add => {
            if (n.len == 0) return usage(arena, verb, "{s} add needs a NAME.", .{p});
            const name = n[0];
            if (!command_provider.isValidServerName(name))
                return usage(arena, verb, "'{s}' can't be a server name: use letters, digits, '-' and '_'.", .{name});
            const file: config_file.File = if (project) .project else .profile;
            if (dash < rest.len) {
                if (n.len > 1) return usage(arena, verb, "{s} add takes a URL or a command after --, not both.", .{p});
                const command = rest[dash + 1 ..];
                if (command.len == 0) return usage(arena, verb, "{s} add needs a command after --.", .{p});
                if (pair_flag != null and std.mem.eql(u8, pair_flag.?, "--header")) return usage(arena, verb, "--header is for HTTP servers; use --env for a command.", .{});
                return .{ .command = .{ .add = .{ .name = name, .file = file, .entry = .{ .stdio = .{ .command = command[0], .args = command[1..], .env = pairs.items } } } } };
            }
            if (n.len != 2) return usage(arena, verb, "{s} add needs a URL, or -- and a command.", .{p});
            const url = n[1];
            if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://"))
                return usage(arena, verb, "'{s}' isn't a URL. A stdio server's command goes after --.", .{url});
            if (pair_flag != null and std.mem.eql(u8, pair_flag.?, "--env")) return usage(arena, verb, "--env is for stdio servers; use --header for HTTP.", .{});
            return .{ .command = .{ .add = .{ .name = name, .file = file, .entry = .{ .http = .{ .url = url, .headers = pairs.items } } } } };
        },
        .approve => {
            if (all and n.len > 0) return usage(arena, verb, "{s} approve takes a NAME or --all, not both.", .{p});
            if (all) return .{ .command = .{ .approve = null } };
        },
        else => {},
    }
    if (n.len != 1) return usage(arena, verb, "{s} {s} needs one server NAME.", .{ p, @tagName(verb) });
    const name = n[0];
    return .{ .command = switch (verb) {
        .show => .{ .show = .{ .name = name, .json = json } },
        .remove => blk: {
            if (project and profile) return usage(arena, verb, "Use --project or --profile, not both.", .{});
            break :blk .{ .remove = .{ .name = name, .file = if (project) .project else if (profile) .profile else null } };
        },
        .login => .{ .login = .{ .name = name, .browser = !no_browser } },
        .logout => .{ .logout = name },
        .approve => .{ .approve = name },
        .reject => .{ .reject = name },
        .list, .add => unreachable,
    } };
}

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help");
}

fn moved(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Parsed {
    return .{ .moved = try std.fmt.allocPrint(arena, fmt, args) };
}

fn usage(arena: Allocator, verb: ?Verb, comptime fmt: []const u8, args: anytype) Allocator.Error!Parsed {
    return .{ .usage = .{ .verb = verb, .message = try std.fmt.allocPrint(arena, fmt, args) } };
}

const overview = [_][2][]const u8{
    .{ "list", "configured servers; never connects" },
    .{ "show NAME", "connect to NAME: status, version, tools" },
    .{ "add NAME URL", "add an HTTP server" },
    .{ "add NAME -- CMD [ARGS...]", "add a stdio server" },
    .{ "remove NAME", "remove a server and its login" },
    .{ "login NAME", "sign in to an HTTP server" },
    .{ "logout NAME", "sign out and delete the login" },
    .{ "approve NAME | --all", "approve project servers from .mcp.json" },
    .{ "reject NAME", "reject a project server" },
};

/// The usage of one verb, or of every verb.
pub fn writeUsage(w: *Writer, surface: Surface, verb: ?Verb) Writer.Error!void {
    const p = surface.prog();
    const json = if (surface == .cli) " [--json]" else "";
    const v = verb orelse {
        try w.print("usage: {s} COMMAND\n\n", .{p});
        for (overview, 0..) |row, k| {
            var buffer: [48]u8 = undefined;
            const left = if (k < 2) std.fmt.bufPrint(&buffer, "{s}{s}", .{ row[0], json }) catch row[0] else row[0];
            try w.print("  {s:<28}{s}\n", .{ left, row[1] });
        }
        return w.print("\nRun '{s} COMMAND -h' for a command's flags.\n", .{p});
    };
    switch (v) {
        .list => try w.print("usage: {s} list{s}\n", .{ p, json }),
        .show => try w.print("usage: {s} show NAME{s}\n", .{ p, json }),
        .add => try w.print(
            \\usage: {s} add [--project] [--header K=V]... NAME URL
            \\       {s} add [--project] [--env K=V]... NAME -- COMMAND [ARGS...]
            \\  --project  write ./.mcp.json instead of ~/.fx/mcp.json
            \\
        , .{ p, p }),
        .remove => try w.print("usage: {s} remove [--project | --profile] NAME\n", .{p}),
        .login => try w.print("usage: {s} login [--no-browser] NAME\n  --no-browser  print the address instead of opening it\n", .{p}),
        .logout => try w.print("usage: {s} logout NAME\n", .{p}),
        .approve => try w.print("usage: {s} approve NAME | --all\n", .{p}),
        .reject => try w.print("usage: {s} reject NAME\n", .{p}),
    }
}

/// What the verbs need from the surface that runs them.
pub const Hosts = struct {
    context: *anyopaque,
    /// This workspace's host, or null when no server is configured. `notify`
    /// gets sign-in notices; the shell's live host already has its own.
    get: *const fn (context: *anyopaque, notify: ?runtime_mod.Notify) anyerror!?*Host,
    /// Done with a host from `get`.
    release: *const fn (context: *anyopaque, host: *Host) void,
    /// Config or trust changed, so a live host should reload.
    changed: *const fn (context: *anyopaque) void,
};

pub const Context = struct {
    /// Thread-safe.
    gpa: Allocator,
    out: *Writer,
    err: *Writer,
    surface: Surface,
    home: []const u8,
    workspace_root: []const u8,
    hosts: Hosts,
    /// Ends a `show` still connecting, such as when fx quits.
    cancel: ?*const std.atomic.Value(bool) = null,
};

/// Runs `fx mcp ARGS` or `/mcp ARGS` and returns the exit code: 0 for
/// success, 1 for a failure, 2 for a usage mistake.
pub fn run(c: Context, args: []const []const u8) u8 {
    var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const code = runParsed(c, arena, args) catch |err| code: {
        debug_trace.logf("mcp", "MCP verb failed args0={s} err={s}", .{ if (args.len > 0) args[0] else "", @errorName(err) });
        c.err.print("{s}: {s}\n", .{ c.surface.prog(), describe(err) }) catch {};
        break :code 1;
    };
    c.out.flush() catch {};
    c.err.flush() catch {};
    return code;
}

fn runParsed(c: Context, arena: Allocator, args: []const []const u8) !u8 {
    const command = switch (try parse(arena, c.surface, args)) {
        .command => |command| command,
        .usage => |u| {
            try c.err.print("{s}\n", .{u.message});
            try writeUsage(c.err, c.surface, u.verb);
            return 2;
        },
        .moved => |message| {
            try c.err.print("{s}\n", .{message});
            return 2;
        },
    };
    return switch (command) {
        .help => |verb| {
            try writeUsage(c.out, c.surface, verb);
            return 0;
        },
        .list => |l| list(c, arena, l.json),
        .show => |s| show(c, arena, s.name, s.json),
        .add => |a| add(c, arena, a.name, a.file, a.entry),
        .remove => |r| remove(c, arena, r.name, r.file),
        .login => |l| login(c, arena, l.name, l.browser),
        .logout => |name| logout(c, arena, name),
        .approve => |name| trust(c, arena, if (name) |n| .{ .approve = n } else .approve_all),
        .reject => |name| trust(c, arena, .{ .reject = name }),
    };
}

/// fx's words for an error, never its name.
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.Exists => "that name is already in the file; remove it first",
        error.BothKeys => "the file has both \"mcp\" and \"mcpServers\"; merge them into one",
        error.Unreadable => "the file isn't valid JSON, or repeats a key; fix it by hand first",
        error.NotAnObject => "the file's servers aren't a JSON object; fix it by hand first",
        error.HomeNotSet => "HOME isn't set",
        error.AccessDenied => "permission denied",
        error.Timeout, error.LockTimeout => "another fx is changing the MCP config; try again",
        error.McpConfigInvalidJson => "~/.fx/mcp.json isn't valid JSON",
        error.McpConfigInvalidHeaders => "a server in ~/.fx/mcp.json has headers fx won't send; put a token in bearer_token_env, or sign in with login",
        else => if (std.mem.startsWith(u8, @errorName(err), "McpConfig")) "~/.fx/mcp.json has a server entry fx can't read" else "something went wrong",
    };
}

const Paths = struct { profile: []const u8, project: []const u8 };

fn paths(c: Context, arena: Allocator) !Paths {
    return .{
        .profile = try profile_paths.mcpConfigPath(arena, c.home),
        .project = try std.fs.path.join(arena, &.{ c.workspace_root, ".mcp.json" }),
    };
}

fn fileLabel(file: config_file.File) []const u8 {
    return switch (file) {
        .profile => "~/.fx/mcp.json",
        .project => ".mcp.json",
    };
}

fn sourceFile(status: Status) config_file.File {
    return if (status.source == .workspace) .project else .profile;
}

fn list(c: Context, arena: Allocator, json: bool) !u8 {
    const host = try c.hosts.get(c.hosts.context, null);
    defer if (host) |h| c.hosts.release(c.hosts.context, h);
    const statuses = if (host) |h| try h.runtime.statuses(arena) else &.{};
    if (host) |h| try writeNotes(c, h);
    const p = try paths(c, arena);
    if (json) {
        try writeListJson(c.out, statuses, p);
        return 0;
    }
    if (statuses.len == 0) {
        try c.out.print("No MCP servers configured. Add one with: {s} add NAME URL\n", .{c.surface.prog()});
        return 0;
    }
    try writeList(c.out, arena, statuses);
    return 0;
}

/// The status in words, as `list`, `show`, and the menu say it.
pub fn statusText(arena: Allocator, s: Status) Allocator.Error![]const u8 {
    return switch (s.state) {
        .disabled => "disabled",
        .waiting_for_approval => "waiting for approval",
        .rejected => "rejected",
        .unsupported => "not supported",
        .missing_env => try std.fmt.allocPrint(arena, "needs ${s}", .{s.missing orelse "a variable"}),
        else => if (s.needs_login) "needs login" else switch (s.state) {
            .ready => try std.fmt.allocPrint(arena, "ready, {d} tool{s}", .{ s.tools, if (s.tools == 1) "" else "s" }),
            .connecting => "connecting",
            .retrying => "retrying",
            .failed => "failed",
            .idle => if (s.signed_in) "signed in" else "not started",
            else => unreachable,
        },
    };
}

fn statusToken(s: Status) []const u8 {
    return switch (s.state) {
        .disabled => "disabled",
        .waiting_for_approval => "waiting_for_approval",
        .rejected => "rejected",
        .unsupported => "not_supported",
        .missing_env => "missing_env",
        else => if (s.needs_login) "needs_login" else switch (s.state) {
            .ready => "ready",
            .connecting => "connecting",
            .retrying => "retrying",
            .failed => "failed",
            .idle => if (s.signed_in) "signed_in" else "not_started",
            else => unreachable,
        },
    };
}

fn writeList(w: *Writer, arena: Allocator, statuses: []const Status) !void {
    const headers = [_][]const u8{ "NAME", "SOURCE", "TRANSPORT", "STATUS" };
    const rows = try arena.alloc([4][]const u8, statuses.len);
    var widths: [3]usize = .{ headers[0].len, headers[1].len, headers[2].len };
    for (statuses, rows) |s, *row| {
        row.* = .{ try safe(arena, s.name), fileLabel(sourceFile(s)), @tagName(s.transport), try statusText(arena, s) };
        for (0..3) |k| widths[k] = @max(widths[k], text_utils.terminalSafeVisibleWidth(row[k]));
    }
    try writeRow(w, headers, widths);
    for (rows) |row| try writeRow(w, row, widths);
}

fn writeRow(w: *Writer, row: [4][]const u8, widths: [3]usize) !void {
    for (0..3) |k| {
        try w.writeAll(row[k]);
        try w.splatByteAll(' ', widths[k] - text_utils.terminalSafeVisibleWidth(row[k]) + 2);
    }
    try w.print("{s}\n", .{row[3]});
}

fn writeListJson(w: *Writer, statuses: []const Status, p: Paths) !void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();
    try jw.objectField("servers");
    try jw.beginArray();
    for (statuses) |s| {
        try jw.beginObject();
        try writeStatusFields(&jw, s, p);
        try jw.objectField("tools");
        try jw.write(if (s.state == .ready) @as(?usize, s.tools) else null);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
    try w.writeByte('\n');
}

fn writeStatusFields(jw: *std.json.Stringify, s: Status, p: Paths) !void {
    const file = sourceFile(s);
    try jw.objectField("name");
    try jw.write(s.name);
    try jw.objectField("source");
    try jw.write(@tagName(file));
    try jw.objectField("file");
    try jw.write(if (file == .project) p.project else p.profile);
    try jw.objectField("transport");
    try jw.write(@tagName(s.transport));
    try jw.objectField("status");
    try jw.write(statusToken(s));
    try jw.objectField("error");
    try jw.write(s.last_error);
}

/// What loading the config skipped, so a server never vanishes without a reason.
fn writeNotes(c: Context, host: *Host) !void {
    for (host.notes) |note| try c.err.print("note: {s}\n", .{note});
}

fn safe(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    return (try text_utils.encodeTerminalSafeInline(arena, raw, 240)).bytes;
}

/// A sign-in address is only useful whole, so it isn't shortened.
fn safeUrl(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    return (try text_utils.encodeTerminalSafeInline(arena, raw, 16 * 1024)).bytes;
}

fn findStatus(statuses: []const Status, name: []const u8) ?Status {
    for (statuses) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn show(c: Context, arena: Allocator, name: []const u8, json: bool) !u8 {
    const host = (try c.hosts.get(c.hosts.context, null)) orelse return missing(c, arena, name);
    defer c.hosts.release(c.hosts.context, host);
    try writeNotes(c, host);
    const server = findServer(host, name) orelse return missing(c, arena, name);
    const tools: []runtime_mod.Tool = switch (host.runtime.tools(arena, name, c.cancel) catch |err| switch (err) {
        error.Held => runtime_mod.ToolsResult{ .tools = &.{} },
        else => return err,
    }) {
        .tools => |t| t,
        .needs_login, .failed => &.{},
        .unknown_server => return missing(c, arena, name),
    };
    const status = findStatus(try host.runtime.statuses(arena), name).?;
    const p = try paths(c, arena);
    if (json) {
        var jw: std.json.Stringify = .{ .writer = c.out };
        try jw.beginObject();
        try writeStatusFields(&jw, status, p);
        try jw.objectField("version");
        try jw.write(status.version);
        try jw.objectField("url");
        try jw.write(server.url);
        try jw.objectField("command");
        try jw.write(server.command);
        try jw.objectField("tools");
        try jw.beginArray();
        for (tools) |t| {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(t.name);
            try jw.objectField("description");
            try jw.write(try toolDescription(arena, t.raw));
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try c.out.writeByte('\n');
    } else {
        const w = c.out;
        try w.print("{s}\n", .{try safe(arena, name)});
        try w.print("  status     {s}\n", .{try statusText(arena, status)});
        if (status.version) |v| try w.print("  version    {s}\n", .{try safe(arena, v)});
        try w.print("  transport  {s}\n", .{@tagName(status.transport)});
        if (server.url) |u| try w.print("  url        {s}\n", .{try safe(arena, u)});
        if (server.command) |cmd| try w.print("  command    {s}\n", .{try safe(arena, cmd)});
        try w.print("  source     {s}\n", .{fileLabel(sourceFile(status))});
        if (status.last_error) |e| try w.print("  error      {s}\n", .{try safe(arena, e)});
        if (status.needs_login) try w.print("  next       {s} login {s}\n", .{ c.surface.prog(), try safe(arena, name) });
        if (status.state == .waiting_for_approval) try w.print("  next       {s} approve {s}\n", .{ c.surface.prog(), try safe(arena, name) });
        if (tools.len > 0) {
            try w.print("  tools      {d}\n", .{tools.len});
            var width: usize = 0;
            const names = try arena.alloc([]const u8, tools.len);
            for (tools, names) |t, *n| {
                n.* = try safe(arena, t.name);
                width = @max(width, text_utils.terminalSafeVisibleWidth(n.*));
            }
            for (tools, names) |t, n| {
                try w.print("    {s}", .{n});
                const d = try toolDescription(arena, t.raw) orelse "";
                if (d.len == 0) {
                    try w.writeByte('\n');
                    continue;
                }
                try w.splatByteAll(' ', width - text_utils.terminalSafeVisibleWidth(n) + 2);
                try w.print("{s}\n", .{try safe(arena, d)});
            }
        }
    }
    return if (status.state == .ready and !status.needs_login) 0 else 1;
}

fn missing(c: Context, arena: Allocator, name: []const u8) !u8 {
    try c.err.print("No MCP server named {s}. {s} list shows them.\n", .{ try safe(arena, name), c.surface.prog() });
    return 1;
}

fn findServer(host: *Host, name: []const u8) ?@import("config.zig").Server {
    for (host.runtime.servers()) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// A tool's description, first line only.
pub fn toolDescription(arena: Allocator, raw: []const u8) !?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return null;
    if (value != .object) return null;
    const d = value.object.get("description") orelse return null;
    if (d != .string) return null;
    const line = std.mem.trim(u8, d.string[0 .. std.mem.indexOfScalar(u8, d.string, '\n') orelse d.string.len], " \t\r");
    return line;
}

fn add(c: Context, arena: Allocator, name: []const u8, file: config_file.File, entry: config_file.Entry) !u8 {
    const p = try paths(c, arena);
    const path = if (file == .project) p.project else p.profile;
    _ = config_file.update(c.gpa, p.profile, file, path, .{ .add = .{ .name = name, .entry = entry } }) catch |err| {
        try c.err.print("Couldn't add {s} to {s}: {s}.\n", .{ name, fileLabel(file), describe(err) });
        return 1;
    };
    c.hosts.changed(c.hosts.context);
    try c.out.print("Added {s} to {s}.\n", .{ name, fileLabel(file) });
    const other: config_file.File = if (file == .project) .profile else .project;
    if (try defines(c, arena, other, if (other == .project) p.project else p.profile, name)) {
        try c.out.print("{s} is also in {s}; the one in ~/.fx/mcp.json is used.\n", .{ name, fileLabel(other) });
    }
    return 0;
}

fn defines(c: Context, arena: Allocator, file: config_file.File, path: []const u8, name: []const u8) !bool {
    _ = c;
    const text = (try config_file.read(arena, path)) orelse return false;
    return config_file.has(arena, file, text, name);
}

fn remove(c: Context, arena: Allocator, name: []const u8, only: ?config_file.File) !u8 {
    const p = try paths(c, arena);
    const in_profile = (only == null or only == .profile) and try defines(c, arena, .profile, p.profile, name);
    const in_project = (only == null or only == .project) and try defines(c, arena, .project, p.project, name);
    if (in_profile and in_project) {
        try c.err.print("{s} is in both ~/.fx/mcp.json and .mcp.json. Add --profile or --project.\n", .{try safe(arena, name)});
        return 2;
    }
    if (!in_profile and !in_project) {
        const where = if (only) |f| fileLabel(f) else "~/.fx/mcp.json or .mcp.json";
        try c.err.print("No MCP server named {s} in {s}.\n", .{ try safe(arena, name), where });
        return 1;
    }
    const file: config_file.File = if (in_profile) .profile else .project;
    const updated = config_file.update(c.gpa, p.profile, file, if (file == .project) p.project else p.profile, .{ .remove = name }) catch |err| {
        try c.err.print("Couldn't remove {s} from {s}: {s}.\n", .{ try safe(arena, name), fileLabel(file), describe(err) });
        return 1;
    };
    const url = switch (updated) {
        .removed => |u| u,
        .added, .missing => null,
    };
    defer if (url) |u| c.gpa.free(u);
    var forgot = false;
    if (url) |u| forgot = credentials.Store.detect(arena, c.home).remove(arena, name, u) catch false;
    c.hosts.changed(c.hosts.context);
    try c.out.print("Removed {s} from {s}{s}.\n", .{ name, fileLabel(file), if (forgot) ", and deleted its login" else "" });
    return 0;
}

fn trust(c: Context, arena: Allocator, action: project_config.ProjectMcpAction) !u8 {
    const host = try c.hosts.get(c.hosts.context, null);
    defer if (host) |h| c.hosts.release(c.hosts.context, h);
    const servers: []const @import("config.zig").Server = if (host) |h| h.runtime.servers() else &.{};
    // The project servers this choice is about, so the user sees what they trust.
    var targets: std.ArrayList(@import("config.zig").Server) = .empty;
    for (servers) |s| {
        if (s.source != .workspace) continue;
        switch (action) {
            .approve, .reject => |name| if (std.mem.eql(u8, s.name, name)) try targets.append(arena, s),
            .approve_all => if (s.held != .rejected) try targets.append(arena, s),
            .reset => {},
        }
    }
    if (targets.items.len == 0) {
        switch (action) {
            .approve, .reject => |name| try c.err.print("No project server named {s} in .mcp.json.\n", .{try safe(arena, name)}),
            else => try c.err.print("No project servers are waiting for approval.\n", .{}),
        }
        return 1;
    }
    var attempt = config_runtime.attemptProjectMcpMutation(arena, c.workspace_root, action);
    defer attempt.deinit(arena);
    switch (attempt) {
        .failure => |f| {
            try c.err.print("Couldn't save that choice: {s}.\n", .{describe(f.err)});
            return 1;
        },
        .outcome => {},
    }
    c.hosts.changed(c.hosts.context);
    for (targets.items) |s| {
        const verb = if (action == .reject) "Rejected" else "Approved";
        const target = s.command orelse s.url orelse "";
        const how = if (s.command != null) "runs" else "connects to";
        if (action == .reject) {
            try c.out.print("{s} {s}. fx won't start it in this project.\n", .{ verb, try safe(arena, s.name) });
        } else {
            try c.out.print("{s} {s}, which {s}: {s}\n", .{ verb, try safe(arena, s.name), how, try safe(arena, target) });
        }
    }
    return 0;
}

fn logout(c: Context, arena: Allocator, name: []const u8) !u8 {
    const host = (try c.hosts.get(c.hosts.context, null)) orelse return missing(c, arena, name);
    defer c.hosts.release(c.hosts.context, host);
    const server = findServer(host, name) orelse return missing(c, arena, name);
    if (server.transport == .stdio) {
        try c.err.print("{s} runs a command, so it has no login.\n", .{try safe(arena, name)});
        return 1;
    }
    const was = findStatus(try host.runtime.statuses(arena), name).?;
    host.runtime.logout(name) catch |err| switch (err) {
        // A held server isn't in the engine; its saved login still goes.
        error.UnknownServer => _ = credentials.Store.detect(arena, c.home).remove(arena, name, server.url.?) catch false,
        else => return err,
    };
    if (was.signed_in or was.needs_login or was.state == .ready) {
        try c.out.print("Signed out of {s}.\n", .{try safe(arena, name)});
    } else {
        try c.out.print("{s} wasn't signed in.\n", .{try safe(arena, name)});
    }
    return 0;
}

/// What a login hears from the runtime, read by the thread that waits.
const Waiter = struct {
    mutex: std.Io.Mutex = .init,
    authorize: ?[]u8 = null,
    shown: bool = false,
    done: ?bool = null,
    reason: ?[]u8 = null,
    gpa: Allocator,
    name: []const u8,

    fn notify(w: *Waiter) runtime_mod.Notify {
        return .{ .context = w, .notice = onNotice };
    }

    fn onNotice(context: *anyopaque, notice: runtime_mod.Notice) void {
        const w: *Waiter = @ptrCast(@alignCast(context));
        const io = io_mod.getIo();
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        switch (notice) {
            .authorize => |a| if (std.mem.eql(u8, a.server, w.name) and w.authorize == null) {
                w.authorize = w.gpa.dupe(u8, a.url) catch null;
            },
            .signed_in => |server| if (std.mem.eql(u8, server, w.name)) {
                w.done = true;
            },
            .sign_in_failed => |f| if (std.mem.eql(u8, f.server, w.name)) {
                w.reason = w.gpa.dupe(u8, f.reason) catch null;
                w.done = false;
            },
            .needs_login => {},
        }
    }

    fn deinit(w: *Waiter) void {
        if (w.authorize) |a| w.gpa.free(a);
        if (w.reason) |r| w.gpa.free(r);
    }
};

fn login(c: Context, arena: Allocator, name: []const u8, browser: bool) !u8 {
    const no_display = io_mod.getenv("FX_NO_OPEN_BROWSER") != null or io_mod.getenv("SSH_CONNECTION") != null or
        (@import("builtin").os.tag != .macos and io_mod.getenv("DISPLAY") == null and io_mod.getenv("WAYLAND_DISPLAY") == null);
    const open = browser and !no_display;
    var waiter: Waiter = .{ .gpa = c.gpa, .name = name };
    defer waiter.deinit();
    const host = (try c.hosts.get(c.hosts.context, if (c.surface == .cli) waiter.notify() else null)) orelse return missing(c, arena, name);
    defer c.hosts.release(c.hosts.context, host);
    const server = findServer(host, name) orelse return missing(c, arena, name);
    if (server.transport == .stdio) {
        try c.err.print("{s} runs a command, so it has no login.\n", .{try safe(arena, name)});
        return 1;
    }
    host.runtime.login(name, open) catch |err| switch (err) {
        error.Held => {
            const status = findStatus(try host.runtime.statuses(arena), name).?;
            try c.err.print("{s} is {s}", .{ try safe(arena, name), try statusText(arena, status) });
            if (status.state == .waiting_for_approval) try c.err.print(": {s} approve {s}", .{ c.surface.prog(), try safe(arena, name) });
            try c.err.writeAll(".\n");
            return 1;
        },
        else => return err,
    };
    // The shell's host reports the address and the outcome in the transcript.
    if (c.surface == .shell) return 0;
    return waitForLogin(c, arena, host, &waiter, open);
}

fn waitForLogin(c: Context, arena: Allocator, host: *Host, waiter: *Waiter, open: bool) !u8 {
    const io = io_mod.getIo();
    const name = waiter.name;
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        var done: ?bool = null;
        var url: ?[]const u8 = null;
        {
            waiter.mutex.lockUncancelable(io);
            defer waiter.mutex.unlock(io);
            done = waiter.done;
            if (!waiter.shown and waiter.authorize != null) {
                waiter.shown = true;
                url = try arena.dupe(u8, waiter.authorize.?);
            }
        }
        if (url) |u| {
            const shown = try safeUrl(arena, u);
            if (open) {
                try c.out.print("Approve in your browser. If it didn't open, go to:\n  {s}\n", .{shown});
            } else {
                try c.out.print("Open this address in a browser and approve:\n  {s}\nThen paste the address the browser ends on here, or wait if it comes back on its own.\n", .{shown});
            }
            try c.out.flush();
        }
        if (done) |ok| {
            if (ok) {
                try c.out.print("Signed in to {s}.\n", .{try safe(arena, name)});
                return 0;
            }
            try c.err.print("Couldn't sign in to {s}: {s}.\n", .{ try safe(arena, name), try safe(arena, waiter.reason orelse "the server refused") });
            return 1;
        }
        if (!open and waiter.shown) {
            if (try readPasted(arena, &line)) |pasted| {
                host.runtime.finishLogin(name, pasted) catch |err| switch (err) {
                    error.NotSigningIn => {},
                    else => return err,
                };
                continue;
            }
        } else io_mod.sleep(100 * std.time.ns_per_ms);
    }
}

/// A complete line from stdin, waiting at most 100 ms for one.
fn readPasted(arena: Allocator, line: *std.ArrayList(u8)) !?[]const u8 {
    var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&fds, 100) == 0) return null;
    var buffer: [1024]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buffer) catch return null;
    if (n == 0) {
        // stdin closed: wait for the browser instead.
        io_mod.sleep(100 * std.time.ns_per_ms);
        return null;
    }
    try line.appendSlice(arena, buffer[0..n]);
    const end = std.mem.indexOfScalar(u8, line.items, '\n') orelse return null;
    const pasted = std.mem.trim(u8, line.items[0..end], " \t\r");
    const copy = try arena.dupe(u8, pasted);
    line.replaceRangeAssumeCapacity(0, end + 1, &.{});
    return if (copy.len == 0) null else copy;
}

const testing = std.testing;

fn parseCli(arena: Allocator, args: []const []const u8) !Parsed {
    return parse(arena, .cli, args);
}

test "parse reads every verb, with flags before --" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expect((try parseCli(a, &.{"list"})).command.list.json == false);
    try testing.expect((try parseCli(a, &.{ "list", "--json" })).command.list.json);
    const s = (try parseCli(a, &.{ "show", "--json", "ctx" })).command.show;
    try testing.expectEqualStrings("ctx", s.name);
    try testing.expect(s.json);

    const http = (try parseCli(a, &.{ "add", "web", "https://w/mcp", "--header", "X-Key=${K}", "--project" })).command.add;
    try testing.expectEqualStrings("web", http.name);
    try testing.expectEqual(config_file.File.project, http.file);
    try testing.expectEqualStrings("https://w/mcp", http.entry.http.url);
    try testing.expectEqualStrings("X-Key", http.entry.http.headers[0].key);
    try testing.expectEqualStrings("${K}", http.entry.http.headers[0].value);

    const stdio = (try parseCli(a, &.{ "add", "--env", "A=1=2", "local", "--", "node", "server.js", "--help", "-h" })).command.add;
    try testing.expectEqual(config_file.File.profile, stdio.file);
    try testing.expectEqualStrings("node", stdio.entry.stdio.command);
    try testing.expectEqual(@as(usize, 3), stdio.entry.stdio.args.len);
    try testing.expectEqualStrings("-h", stdio.entry.stdio.args[2]);
    try testing.expectEqualStrings("1=2", stdio.entry.stdio.env[0].value);

    try testing.expectEqual(@as(?config_file.File, .project), (try parseCli(a, &.{ "remove", "--project", "x" })).command.remove.file);
    try testing.expectEqual(@as(?config_file.File, null), (try parseCli(a, &.{ "remove", "x" })).command.remove.file);
    try testing.expect(!(try parseCli(a, &.{ "login", "--no-browser", "x" })).command.login.browser);
    try testing.expectEqualStrings("x", (try parseCli(a, &.{ "logout", "x" })).command.logout);
    try testing.expect((try parseCli(a, &.{ "approve", "--all" })).command.approve == null);
    try testing.expectEqualStrings("x", (try parseCli(a, &.{ "reject", "x" })).command.reject);
    try testing.expectEqual(@as(?Verb, .add), (try parseCli(a, &.{ "add", "-h" })).command.help);
    try testing.expectEqual(@as(?Verb, null), (try parseCli(a, &.{})).command.help);
}

test "parse turns mistakes into usage, and old verbs into pointers" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cases = [_]struct { args: []const []const u8, message: []const u8 }{
        .{ .args = &.{"nope"}, .message = "'nope' isn't a fx mcp command." },
        .{ .args = &.{"show"}, .message = "fx mcp show needs one server NAME." },
        .{ .args = &.{ "show", "a", "b" }, .message = "fx mcp show needs one server NAME." },
        .{ .args = &.{ "add", "bad name", "https://w" }, .message = "'bad name' can't be a server name: use letters, digits, '-' and '_'." },
        .{ .args = &.{ "add", "web", "w.example" }, .message = "'w.example' isn't a URL. A stdio server's command goes after --." },
        .{ .args = &.{ "add", "web" }, .message = "fx mcp add needs a URL, or -- and a command." },
        .{ .args = &.{ "add", "web", "--" }, .message = "fx mcp add needs a command after --." },
        .{ .args = &.{ "add", "--env", "A=1", "web", "https://w" }, .message = "--env is for stdio servers; use --header for HTTP." },
        .{ .args = &.{ "add", "--header", "A=1", "web", "--", "node" }, .message = "--header is for HTTP servers; use --env for a command." },
        .{ .args = &.{ "add", "--env", "noequals", "web", "--", "node" }, .message = "--env needs KEY=VALUE." },
        .{ .args = &.{ "remove", "--project", "--profile", "x" }, .message = "Use --project or --profile, not both." },
        .{ .args = &.{ "approve", "--all", "x" }, .message = "fx mcp approve takes a NAME or --all, not both." },
        .{ .args = &.{ "logout", "--json", "x" }, .message = "fx mcp logout has no --json flag." },
        .{ .args = &.{ "show", "x", "--", "y" }, .message = "fx mcp show takes no command after --." },
    };
    for (cases) |case| {
        const parsed = try parseCli(a, case.args);
        try testing.expectEqualStrings(case.message, parsed.usage.message);
    }
    try testing.expectEqualStrings("fx mcp auth is now fx mcp login NAME.", (try parseCli(a, &.{ "auth", "x" })).moved);
    try testing.expectEqualStrings("/mcp reload is gone: fx reloads after add, remove, approve, and reject.", (try parse(a, .shell, &.{"reload"})).moved);
    try testing.expectEqualStrings("/mcp list has no --json flag.", (try parse(a, .shell, &.{ "list", "--json" })).usage.message);
}

test "status words follow commands.md, held states first" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base: Status = .{ .name = "x", .source = .profile, .transport = .http, .state = .idle };
    var s = base;
    try testing.expectEqualStrings("not started", try statusText(a, s));
    s.signed_in = true;
    try testing.expectEqualStrings("signed in", try statusText(a, s));
    s = base;
    s.state = .ready;
    s.tools = 1;
    try testing.expectEqualStrings("ready, 1 tool", try statusText(a, s));
    s.needs_login = true;
    try testing.expectEqualStrings("needs login", try statusText(a, s));
    try testing.expectEqualStrings("needs_login", statusToken(s));
    s = base;
    s.state = .missing_env;
    s.missing = "TOKEN";
    s.needs_login = true;
    try testing.expectEqualStrings("needs $TOKEN", try statusText(a, s));
    s.state = .waiting_for_approval;
    try testing.expectEqualStrings("waiting for approval", try statusText(a, s));
}

test "list lines up its columns and keeps hostile names inert" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const statuses = [_]Status{
        .{ .name = "context7", .source = .profile, .transport = .http, .state = .ready, .tools = 2 },
        .{ .name = "x\x1b[2J", .source = .workspace, .transport = .stdio, .state = .waiting_for_approval },
    };
    var out: Writer.Allocating = .init(a);
    try writeList(&out.writer, a, &statuses);
    try testing.expectEqualStrings(
        \\NAME      SOURCE          TRANSPORT  STATUS
        \\context7  ~/.fx/mcp.json  http       ready, 2 tools
        \\x\x1b[2J  .mcp.json       stdio      waiting for approval
        \\
    , out.written());

    var json: Writer.Allocating = .init(a);
    try writeListJson(&json.writer, statuses[0..1], .{ .profile = "/h/.fx/mcp.json", .project = "/w/.mcp.json" });
    try testing.expectEqualStrings(
        \\{"servers":[{"name":"context7","source":"profile","file":"/h/.fx/mcp.json","transport":"http","status":"ready","error":null,"tools":2}]}
        \\
    , json.written());
}

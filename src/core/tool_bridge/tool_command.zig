//! `fx tool edit PATH` and `fx tool write PATH`: how a program that fx's bash
//! or shell tool runs changes a file. The program sends the change on stdin,
//! and the session's bridge applies it under fx's permission rules and review,
//! as an edit the agent makes itself. Exit codes are the bridge clients' table
//! (`client.exit`), the one `fx mcp call` uses.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const capability = @import("capability.zig");
const client = @import("client.zig");
const core = @import("core.zig");
const edit_blocks = @import("edit_blocks.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The most a change may send on stdin: the bridge's request limit, since the
/// change travels in one request line.
pub const max_input_bytes: usize = wire.max_request_bytes;

pub const Command = union(enum) {
    edit: []const u8,
    write: []const u8,
    skill_list,
    skill_open: capability.SkillOpenRequest,
    agent_message: capability.AgentMessageRequest,
    agent_wait,
    agent_status: ?[]const u8,
    agent_stop: []const u8,
    agent_close: []const u8,
    web_fetch: capability.WebFetchRequest,
    web_search: SearchCommand,

    pub fn verb(self: Command) []const u8 {
        return switch (self) {
            .edit => "edit",
            .write => "write",
            .skill_list => "skill list",
            .skill_open => "skill open",
            .agent_message => "agent message",
            .agent_wait => "agent wait",
            .agent_status => "agent status",
            .agent_stop => "agent stop",
            .agent_close => "agent close",
            .web_fetch => "web",
            .web_search => "search",
        };
    }

    fn readsStdin(self: Command) bool {
        return switch (self) {
            .edit, .write => true,
            .skill_list, .skill_open, .agent_message, .agent_wait, .agent_status, .agent_stop, .agent_close, .web_fetch, .web_search => false,
        };
    }
};

/// The most domain filters of one kind that `fx tool search` takes, so the parse
/// needs no allocator. Each entry is a slice of the command's arguments.
const DomainList = struct {
    items: [capability.max_domain_filters][]const u8 = @splat(""),
    len: usize = 0,

    fn push(self: *DomainList, domain: []const u8) ParseError!void {
        if (self.len == capability.max_domain_filters) return error.TooManyDomains;
        self.items[self.len] = domain;
        self.len += 1;
    }

    fn slice(self: *const DomainList) []const []const u8 {
        return self.items[0..self.len];
    }
};

/// `fx tool search QUERY` with its domain filters, before the bridge request copies them.
const SearchCommand = struct {
    query: []const u8,
    allowed: DomainList = .{},
    blocked: DomainList = .{},
};

pub const ParseError = error{
    MissingPath,
    MissingArgument,
    MissingOptionValue,
    UnknownOption,
    InvalidReport,
    TooManyArguments,
    UnknownCommand,
    PathIsOption,
    QueryTooShort,
    InvalidQuery,
    BothDomainKinds,
    TooManyDomains,
};

/// Reads `args`, the words after `fx tool`.
pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.UnknownCommand;
    const verb = args[0];
    if (std.mem.eql(u8, verb, "edit") or std.mem.eql(u8, verb, "write")) {
        if (args.len < 2 or args[1].len == 0) return error.MissingPath;
        if (args.len > 2) return error.TooManyArguments;
        const path = args[1];
        if (path[0] == '-') return error.PathIsOption;
        return if (std.mem.eql(u8, verb, "edit")) .{ .edit = path } else .{ .write = path };
    }
    if (std.mem.eql(u8, verb, "skill")) {
        if (args.len < 2) return error.UnknownCommand;
        const sub = args[1];
        if (std.mem.eql(u8, sub, "list")) {
            if (args.len > 2) return error.TooManyArguments;
            return .skill_list;
        }
        if (std.mem.eql(u8, sub, "open")) {
            if (args.len < 3 or args[2].len == 0) return error.MissingArgument;
            if (args[2][0] == '-') return error.UnknownOption;
            if (args.len == 3) return .{ .skill_open = .{ .name = args[2] } };
            if (args.len == 4) {
                if (args[3].len == 0) return error.MissingArgument;
                if (args[3][0] == '-') return error.UnknownOption;
                return .{ .skill_open = .{ .name = args[2], .resource = args[3] } };
            }
            return error.TooManyArguments;
        }
        return error.UnknownCommand;
    }
    if (std.mem.eql(u8, verb, "agent")) {
        if (args.len < 2) return error.UnknownCommand;
        const sub = args[1];
        if (std.mem.eql(u8, sub, "wait")) {
            if (args.len > 2) return error.TooManyArguments;
            return .agent_wait;
        }
        if (std.mem.eql(u8, sub, "status")) {
            if (args.len == 2) return .{ .agent_status = null };
            if (args.len == 3) {
                if (args[2].len == 0) return error.MissingArgument;
                if (args[2][0] == '-') return error.UnknownOption;
                return .{ .agent_status = args[2] };
            }
            return error.TooManyArguments;
        }
        if (std.mem.eql(u8, sub, "stop")) {
            if (args.len < 3 or args[2].len == 0) return error.MissingArgument;
            if (args[2][0] == '-') return error.UnknownOption;
            if (args.len > 3) return error.TooManyArguments;
            return .{ .agent_stop = args[2] };
        }
        if (std.mem.eql(u8, sub, "close")) {
            if (args.len < 3 or args[2].len == 0) return error.MissingArgument;
            if (args[2][0] == '-') return error.UnknownOption;
            if (args.len > 3) return error.TooManyArguments;
            return .{ .agent_close = args[2] };
        }
        if (std.mem.eql(u8, sub, "message")) {
            return parseAgentMessage(args[2..]);
        }
        return error.UnknownCommand;
    }
    if (std.mem.eql(u8, verb, "web")) return parseWeb(args);
    if (std.mem.eql(u8, verb, "search")) return parseSearch(args);
    return error.UnknownCommand;
}

/// `fx tool web URL`: one URL. A `--` ends the options, so a URL may start with a dash.
fn parseWeb(args: []const []const u8) ParseError!Command {
    var url: ?[]const u8 = null;
    var positional_only = false;
    for (args[1..]) |arg| {
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and arg.len > 0 and arg[0] == '-') return error.UnknownOption;
        if (url != null) return error.TooManyArguments;
        url = arg;
    }
    const value = url orelse return error.MissingArgument;
    if (value.len == 0) return error.MissingArgument;
    return .{ .web_fetch = .{ .url = value } };
}

/// `fx tool search QUERY [--allow-domain D]... [--block-domain D]...`: one query of at
/// least two characters, with at most one kind of domain filter.
fn parseSearch(args: []const []const u8) ParseError!Command {
    var query: ?[]const u8 = null;
    var command: SearchCommand = .{ .query = "" };
    var positional_only = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and arg.len > 0 and arg[0] == '-') {
            if (try matchOptionValue(args, &index, "--allow-domain")) |domain| {
                try command.allowed.push(domain);
            } else if (try matchOptionValue(args, &index, "--block-domain")) |domain| {
                try command.blocked.push(domain);
            } else {
                return error.UnknownOption;
            }
            continue;
        }
        if (query != null) return error.TooManyArguments;
        query = arg;
    }
    const text = query orelse return error.MissingArgument;
    if (text.len == 0) return error.QueryTooShort;
    const characters = std.unicode.utf8CountCodepoints(text) catch return error.InvalidQuery;
    if (characters < 2) return error.QueryTooShort;
    if (command.allowed.len > 0 and command.blocked.len > 0) return error.BothDomainKinds;
    command.query = text;
    return .{ .web_search = command };
}

fn parseAgentMessage(args: []const []const u8) ParseError!Command {
    var agent: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    var instructions: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var effort: ?[]const u8 = null;
    var profile: ?[]const u8 = null;
    var report: ?capability.AgentReport = null;
    var positional_only = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and arg.len > 0 and arg[0] == '-') {
            if (try matchOptionValue(args, &index, "--instructions")) |val| {
                instructions = val;
            } else if (try matchOptionValue(args, &index, "--model")) |val| {
                model = val;
            } else if (try matchOptionValue(args, &index, "--effort")) |val| {
                effort = val;
            } else if (try matchOptionValue(args, &index, "--profile")) |val| {
                profile = val;
            } else if (try matchOptionValue(args, &index, "--report")) |val| {
                report = capability.AgentReport.parse(val) orelse return error.InvalidReport;
            } else {
                return error.UnknownOption;
            }
            continue;
        }
        if (agent == null) {
            agent = arg;
        } else if (message == null) {
            message = arg;
        } else {
            return error.TooManyArguments;
        }
    }
    const name = agent orelse return error.MissingArgument;
    const text = message orelse return error.MissingArgument;
    if (name.len == 0 or text.len == 0) return error.MissingArgument;
    return .{ .agent_message = .{
        .agent = name,
        .message = text,
        .instructions = instructions,
        .model = model,
        .effort = effort,
        .profile = profile,
        .report = report,
    } };
}

fn matchOptionValue(args: []const []const u8, index: *usize, comptime flag: []const u8) ParseError!?[]const u8 {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, flag)) {
        if (index.* + 1 >= args.len) return error.MissingOptionValue;
        const val = args[index.* + 1];
        if (val.len == 0) return error.MissingOptionValue;
        index.* += 1;
        return val;
    }
    const prefix = flag ++ "=";
    if (std.mem.startsWith(u8, arg, prefix)) {
        const val = arg[prefix.len..];
        if (val.len == 0) return error.MissingOptionValue;
        return val;
    }
    return null;
}

/// Writes why `err` refused `args`, in the words of the command line.
pub fn writeUsage(w: *Writer, err: ParseError, args: []const []const u8) Writer.Error!void {
    const verb = if (args.len > 0) args[0] else "";
    const sub = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, verb, "web")) return writeWebUsage(w, err);
    if (std.mem.eql(u8, verb, "search")) return writeSearchUsage(w, err);
    if (std.mem.eql(u8, verb, "skill")) {
        const usage_line = if (std.mem.eql(u8, sub, "list"))
            "Usage: fx tool skill list\n"
        else if (std.mem.eql(u8, sub, "open"))
            "Usage: fx tool skill open NAME [FILE]\n"
        else
            "Usage: fx tool skill list | fx tool skill open NAME [FILE]\n";
        switch (err) {
            error.MissingArgument, error.MissingPath => try w.print("fx tool skill {s}: missing required argument.\n{s}", .{ sub, usage_line }),
            error.TooManyArguments => try w.print("fx tool skill {s}: too many arguments.\n{s}", .{ sub, usage_line }),
            error.UnknownOption, error.PathIsOption => try w.print("fx tool skill {s}: unexpected option.\n{s}", .{ sub, usage_line }),
            else => try w.print("fx tool skill: unknown subcommand {f}.\n{s}", .{ text_utils.terminalSafe(sub), usage_line }),
        }
        return;
    }
    if (std.mem.eql(u8, verb, "agent")) {
        const usage_line = if (std.mem.eql(u8, sub, "message"))
            "Usage: fx tool agent message NAME TEXT [--instructions T] [--model M] [--effort E] [--profile P] [--report final|every_turn|never]\n"
        else if (std.mem.eql(u8, sub, "wait"))
            "Usage: fx tool agent wait\n"
        else if (std.mem.eql(u8, sub, "status"))
            "Usage: fx tool agent status [NAME]\n"
        else if (std.mem.eql(u8, sub, "stop"))
            "Usage: fx tool agent stop NAME\n"
        else if (std.mem.eql(u8, sub, "close"))
            "Usage: fx tool agent close NAME\n"
        else
            "Usage: fx tool agent <message|wait|status|stop|close> ...\n";
        switch (err) {
            error.MissingArgument, error.MissingPath => try w.print("fx tool agent {s}: missing required argument.\n{s}", .{ sub, usage_line }),
            error.MissingOptionValue => try w.print("fx tool agent {s}: option requires a non-empty value.\n{s}", .{ sub, usage_line }),
            error.UnknownOption, error.PathIsOption => try w.print("fx tool agent {s}: unknown or misplaced option.\n{s}", .{ sub, usage_line }),
            error.InvalidReport => try w.print("fx tool agent message: --report must be final, every_turn, or never.\n{s}", .{usage_line}),
            error.TooManyArguments => try w.print("fx tool agent {s}: too many arguments.\n{s}", .{ sub, usage_line }),
            error.UnknownCommand => try w.print("fx tool agent: unknown subcommand {f}.\n{s}", .{ text_utils.terminalSafe(sub), usage_line }),
            error.QueryTooShort, error.InvalidQuery, error.BothDomainKinds, error.TooManyDomains => try w.print("fx tool agent {s}: invalid usage.\n{s}", .{ sub, usage_line }),
        }
        return;
    }
    switch (err) {
        error.MissingPath, error.MissingArgument => try w.print("fx tool {s}: give the file to change, as in fx tool {s} PATH.\n", .{ verb, verb }),
        error.TooManyArguments => try w.print("fx tool {s}: give one file, as in fx tool {s} PATH.\n", .{ verb, verb }),
        error.PathIsOption, error.UnknownOption => try w.print("fx tool {s}: the file must be a path, not an option.\n", .{verb}),
        error.UnknownCommand => try w.print("fx tool: unknown command {f}. Use edit, write, skill, or agent.\n", .{text_utils.terminalSafe(verb)}),
        error.MissingOptionValue, error.InvalidReport => try w.print("fx tool {s}: invalid usage.\n", .{verb}),
        error.QueryTooShort, error.InvalidQuery, error.BothDomainKinds, error.TooManyDomains => try w.print("fx tool {s}: invalid usage.\n", .{verb}),
    }
}

fn writeWebUsage(w: *Writer, err: ParseError) Writer.Error!void {
    const usage_line = "Usage: fx tool web URL\n";
    switch (err) {
        error.MissingArgument, error.MissingPath => try w.print("fx tool web: give the page to fetch, as in fx tool web URL.\n{s}", .{usage_line}),
        error.TooManyArguments => try w.print("fx tool web: give one URL.\n{s}", .{usage_line}),
        error.UnknownOption, error.PathIsOption => try w.print("fx tool web: unexpected option.\n{s}", .{usage_line}),
        else => try w.print("fx tool web: invalid usage.\n{s}", .{usage_line}),
    }
}

fn writeSearchUsage(w: *Writer, err: ParseError) Writer.Error!void {
    const usage_line = "Usage: fx tool search QUERY [--allow-domain D]... [--block-domain D]...\n";
    switch (err) {
        error.MissingArgument, error.MissingPath => try w.print("fx tool search: give a query, as in fx tool search QUERY.\n{s}", .{usage_line}),
        error.QueryTooShort => try w.print("fx tool search: the query needs at least 2 characters.\n{s}", .{usage_line}),
        error.InvalidQuery => try w.print("fx tool search: the query must be valid UTF-8.\n{s}", .{usage_line}),
        error.TooManyArguments => try w.print("fx tool search: give one query; quote a query with spaces.\n{s}", .{usage_line}),
        error.BothDomainKinds => try w.print("fx tool search: give --allow-domain or --block-domain, not both.\n{s}", .{usage_line}),
        error.TooManyDomains => try w.print("fx tool search: give at most {d} domain filters of each kind.\n{s}", .{ capability.max_domain_filters, usage_line }),
        error.MissingOptionValue => try w.print("fx tool search: option requires a non-empty value.\n{s}", .{usage_line}),
        error.UnknownOption, error.PathIsOption => try w.print("fx tool search: unexpected option.\n{s}", .{usage_line}),
        else => try w.print("fx tool search: invalid usage.\n{s}", .{usage_line}),
    }
}

/// Where the bridge of the running shell call is: its socket and its token.
pub const Bridge = struct {
    socket_path: []const u8,
    token: core.Token,
};

/// The socket round trip, as a value, so tests can answer it without a socket.
pub const Caller = struct {
    context: ?*anyopaque,
    call_fn: *const fn (context: ?*anyopaque, arena: Allocator, io: std.Io, socket_path: []const u8, token: core.Token, operation: wire.Operation) anyerror!client.Reply,

    fn call(self: Caller, arena: Allocator, io: std.Io, bridge: Bridge, operation: wire.Operation) anyerror!client.Reply {
        return self.call_fn(self.context, arena, io, bridge.socket_path, bridge.token, operation);
    }
};

/// The caller that talks to the real bridge.
pub const socket_caller: Caller = .{ .context = null, .call_fn = callSocket };

fn callSocket(context: ?*anyopaque, arena: Allocator, io: std.Io, socket_path: []const u8, token: core.Token, operation: wire.Operation) anyerror!client.Reply {
    _ = context;
    return client.call(arena, io, socket_path, token, operation);
}

/// Resolves `path` lexically against `cwd` without following symlinks, so a
/// relative path from a subshell folder arrives as an absolute path and the
/// bridge's admission layer performs the canonical path check.
fn resolveCommandPath(arena: Allocator, cwd: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (std.Io.Dir.path.isAbsolute(path)) {
        return std.Io.Dir.path.resolveAlloc(arena, &.{path});
    }
    return std.Io.Dir.path.resolveAlloc(arena, &.{ cwd, path });
}

/// Runs `fx tool` in the program that runs it, and returns the exit code. It
/// reads stdin only for `edit` and `write`, and only when a bridge is there.
pub fn run(arena: Allocator, io: std.Io, out: *Writer, err: *Writer, command: Command) !u8 {
    const bridge = bridgeFromEnv() orelse return writeUnavailable(err);
    const input: []const u8 = if (command.readsStdin()) blk: {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
        break :blk readLimited(arena, &stdin.interface, max_input_bytes) catch |read_err| switch (read_err) {
            error.InputTooLarge => {
                try writeTooLarge(err, command);
                return client.exit.usage;
            },
            else => return read_err,
        };
    } else "";
    const cwd = try std.process.currentPathAlloc(io, arena);
    const resolved_command: Command = switch (command) {
        .edit => |path| .{ .edit = try resolveCommandPath(arena, cwd, path) },
        .write => |path| .{ .write = try resolveCommandPath(arena, cwd, path) },
        .skill_list, .skill_open, .agent_message, .agent_wait, .agent_status, .agent_stop, .agent_close, .web_fetch, .web_search => command,
    };
    return send(arena, io, out, err, resolved_command, input, bridge, socket_caller);
}

fn bridgeFromEnv() ?Bridge {
    const socket_path = io_mod.getenv(wire.socket_env) orelse return null;
    const token = wire.parseToken(io_mod.getenv(wire.token_env) orelse return null) orelse return null;
    return .{ .socket_path = socket_path, .token = token };
}

/// Reads all of `reader`, up to `limit` bytes. A longer input is `error.InputTooLarge`.
fn readLimited(arena: Allocator, reader: *std.Io.Reader, limit: usize) ![]u8 {
    return reader.allocRemaining(arena, .limited(limit)) catch |read_err| switch (read_err) {
        error.StreamTooLong => error.InputTooLarge,
        else => |other| other,
    };
}

/// Writes the message for an input over `max_input_bytes`.
pub fn writeTooLarge(w: *Writer, command: Command) Writer.Error!void {
    try w.print("fx tool {s}: the change on stdin is larger than {d} bytes. Split the change into several smaller calls.\n", .{ command.verb(), max_input_bytes });
}

/// Writes the message for an encoded request over `wire.max_request_bytes`.
pub fn writeEncodedTooLarge(w: *Writer, command: Command) Writer.Error!void {
    try w.print("fx tool {s}: the encoded change is larger than {d} bytes. Split the change into several smaller calls.\n", .{ command.verb(), wire.max_request_bytes });
}

/// Writes the message for a bridge that is not there, and returns its exit code.
pub fn writeUnavailable(w: *Writer) Writer.Error!u8 {
    try w.print("{s}\n", .{capability.file_tool_unavailable_text});
    return client.exit.unavailable;
}

/// Writes the message for a change fx cannot review, and returns its exit code.
fn writeUnreviewable(w: *Writer) Writer.Error!u8 {
    try w.print("{s}\n", .{capability.file_change_unreviewable_text});
    return client.exit.unavailable;
}

/// Writes the message for a bridge of another fx version, and returns its exit code.
fn writeOtherVersion(w: *Writer, command: Command) Writer.Error!u8 {
    try w.print("fx tool {s}: the running fx session is another fx version. Run the fx that started the session, or restart the session with this one.\n", .{command.verb()});
    return client.exit.unavailable;
}

/// Writes the message for a bridge with too many requests running, and returns its exit code.
fn writeBusy(w: *Writer, command: Command) Writer.Error!u8 {
    try w.print("fx tool {s}: too many fx tool calls are running in this session. Nothing changed; try again when one finishes.\n", .{command.verb()});
    return client.exit.busy;
}

/// Checks `input` for `command`, sends it to the bridge through `caller`, and
/// writes the reply. An input the change refuses is sent nothing, with exit 2.
pub fn send(
    arena: Allocator,
    io: std.Io,
    out: *Writer,
    err: *Writer,
    command: Command,
    input: []const u8,
    bridge: Bridge,
    caller: Caller,
) !u8 {
    const operation: wire.Operation = switch (command) {
        .edit => |path| blk: {
            switch (try edit_blocks.decode(arena, input)) {
                .edits => |edits| break :blk .{ .edit = .{ .path = path, .blocks = edits } },
                .failure => |failure| {
                    try err.writeAll("fx tool edit: ");
                    try edit_blocks.writeFailure(err, failure);
                    try err.writeByte('\n');
                    return client.exit.usage;
                },
            }
        },
        .write => |path| blk: {
            if (!std.unicode.utf8ValidateSlice(input)) {
                try err.writeAll("fx tool write: the content on stdin is not valid UTF-8. fx writes text files only.\n");
                return client.exit.usage;
            }
            break :blk .{ .write = .{ .path = path, .content = input } };
        },
        .skill_list => .skill_list,
        .skill_open => |req| .{ .skill_open = req },
        .agent_message => |req| .{ .agent_message = req },
        .agent_wait => .agent_wait,
        .agent_status => |agent| .{ .agent_status = agent },
        .agent_stop => |agent| .{ .agent_stop = agent },
        .agent_close => |agent| .{ .agent_close = agent },
        .web_fetch => |req| .{ .web_fetch = req },
        .web_search => |req| .{ .web_search = .{
            .query = req.query,
            .allowed_domains = try arena.dupe([]const u8, req.allowed.slice()),
            .blocked_domains = try arena.dupe([]const u8, req.blocked.slice()),
        } },
    };
    _ = client.encodeRequest(arena, bridge.token, operation) catch |encode_err| switch (encode_err) {
        error.RequestTooLarge => {
            try writeEncodedTooLarge(err, command);
            return client.exit.usage;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const reply = caller.call(arena, io, bridge, operation) catch |call_err| return callFailure(err, command, call_err);
    return printReply(arena, out, err, command, reply);
}

fn callFailure(err: *Writer, command: Command, call_err: anyerror) !u8 {
    switch (call_err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RequestTooLarge => {
            try writeEncodedTooLarge(err, command);
            return client.exit.usage;
        },
        error.UnsupportedReply => return writeOtherVersion(err, command),
        // The bridge's socket is removed once its last call has returned.
        error.FileNotFound, error.ConnectionRefused => return if (command.readsStdin()) writeUnreviewable(err) else writeUnavailable(err),
        error.ConnectionLost, error.MalformedReply => {
            if (command.readsStdin()) {
                try err.print("fx tool {s}: the connection to fx was lost ({s}). The change may have run; check the file before you run it again.\n", .{ command.verb(), @errorName(call_err) });
            } else {
                try err.print("fx tool {s}: the connection to fx was lost ({s}).\n", .{ command.verb(), @errorName(call_err) });
            }
            return client.exit.failed;
        },
        else => return writeUnavailable(err),
    }
}

/// Shows the bridge's reply: the data on `out` for a reply that worked, with
/// its notice on `err` after the data, and anything else on `err`, after the
/// command's name. Returns the exit code.
fn printReply(arena: Allocator, out: *Writer, err: *Writer, command: Command, reply: client.Reply) !u8 {
    switch (reply.header.status) {
        .ok => {
            try out.writeAll(reply.bytes);
            // edit and write always end with a newline, as they did before the
            // skill and agent words; those words add one only when it is missing.
            switch (command) {
                .edit, .write => try out.writeByte('\n'),
                else => if (reply.bytes.len > 0 and reply.bytes[reply.bytes.len - 1] != '\n') try out.writeByte('\n'),
            }
            if (reply.header.notice) |notice| try client.writeSafeLine(arena, err, notice);
            return client.exit.ok;
        },
        .tool_error => return refusal(arena, err, command, reply.bytes, client.exit.tool_error),
        .failed => return refusal(arena, err, command, reply.bytes, client.exit.failed),
        .denied => return refusal(arena, err, command, reply.bytes, client.exit.denied),
        .refused => {
            // The reason decides fx tool's text: a call that has returned, or a token
            // the bridge does not hold, cannot be reviewed; a command that is not a bash
            // tool program gets the experimental text.
            if (reply.header.reason) |reason| switch (reason) {
                .closed, .unauthorized => return if (command.readsStdin()) writeUnreviewable(err) else writeUnavailable(err),
                .file_tool_unavailable => return writeUnavailable(err),
                .busy => return writeBusy(err, command),
                .unsupported_version => return writeOtherVersion(err, command),
                else => {},
            };
            return refusal(arena, err, command, reply.bytes, client.refusalExit(reply.header.reason));
        },
    }
}

fn refusal(arena: Allocator, err: *Writer, command: Command, text: []const u8, code: u8) !u8 {
    try err.print("fx tool {s}: ", .{command.verb()});
    try client.writeSafeLine(arena, err, text);
    return code;
}

const test_bridge: Bridge = .{ .socket_path = "/tmp/fx-tool-test.sock", .token = @splat(0x11) };

/// Answers every request with one reply, and counts what it was asked.
const FakeBridge = struct {
    reply: client.Reply,
    calls: usize = 0,
    edit_blocks: usize = 0,
    written: []const u8 = "",
    fetched: capability.WebFetchRequest = .{ .url = "" },
    searched: capability.WebSearchRequest = .{ .query = "" },

    fn caller(self: *FakeBridge) Caller {
        return .{ .context = self, .call_fn = fakeCall };
    }

    fn fakeCall(context: ?*anyopaque, arena: Allocator, io: std.Io, socket_path: []const u8, token: core.Token, operation: wire.Operation) anyerror!client.Reply {
        _ = .{ arena, io, socket_path, token };
        const self: *FakeBridge = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        switch (operation) {
            .edit => |edit| self.edit_blocks = edit.blocks.len,
            .write => |write| self.written = write.content,
            .web_fetch => |value| self.fetched = value,
            .web_search => |value| self.searched = value,
            .call, .list, .search, .help, .skill_list, .skill_open, .agent_message, .agent_wait, .agent_status, .agent_stop, .agent_close => {},
        }
        return self.reply;
    }
};

test "parse reads web and search, with repeated domain filters in either form" {
    try std.testing.expectEqualStrings("https://example.com/a", (try parse(&.{ "web", "https://example.com/a" })).web_fetch.url);
    const found = (try parse(&.{ "search", "zig", "--allow-domain", "ziglang.org", "--allow-domain=example.com" })).web_search;
    try std.testing.expectEqualStrings("zig", found.query);
    try std.testing.expectEqual(@as(usize, 2), found.allowed.len);
    try std.testing.expectEqualStrings("ziglang.org", found.allowed.items[0]);
    try std.testing.expectEqualStrings("example.com", found.allowed.items[1]);
    try std.testing.expectEqual(@as(usize, 0), found.blocked.len);
    const blocked = (try parse(&.{ "search", "zig", "--block-domain=spam.example" })).web_search;
    try std.testing.expectEqual(@as(usize, 1), blocked.blocked.len);
    try std.testing.expectEqual(@as(usize, 0), blocked.allowed.len);
    // A query after -- may start with a dash, and a query counts code points, not bytes.
    try std.testing.expectEqualStrings("-x", (try parse(&.{ "search", "--", "-x" })).web_search.query);
    try std.testing.expectEqualStrings("é!", (try parse(&.{ "search", "é!" })).web_search.query);
}

test "parse refuses an empty URL, a short query, both domain kinds, and an unknown option" {
    try std.testing.expectError(error.MissingArgument, parse(&.{"web"}));
    try std.testing.expectError(error.MissingArgument, parse(&.{ "web", "" }));
    try std.testing.expectError(error.TooManyArguments, parse(&.{ "web", "https://a.example", "https://b.example" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "web", "--raw", "https://a.example" }));
    try std.testing.expectError(error.MissingArgument, parse(&.{"search"}));
    try std.testing.expectError(error.QueryTooShort, parse(&.{ "search", "a" }));
    try std.testing.expectError(error.QueryTooShort, parse(&.{ "search", "" }));
    try std.testing.expectError(error.QueryTooShort, parse(&.{ "search", "é" }));
    try std.testing.expectError(error.BothDomainKinds, parse(&.{ "search", "zig", "--allow-domain", "a.example", "--block-domain", "b.example" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "search", "zig", "--json" }));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{ "search", "zig", "--allow-domain=" }));
    try std.testing.expectError(error.TooManyArguments, parse(&.{ "search", "zig", "rust" }));
}

test "parse caps the domain filters of each kind" {
    var args: [2 + 2 * (capability.max_domain_filters + 1)][]const u8 = undefined;
    args[0] = "search";
    args[1] = "zig";
    for (0..capability.max_domain_filters + 1) |index| {
        args[2 + 2 * index] = "--allow-domain";
        args[3 + 2 * index] = "a.example";
    }
    try std.testing.expectError(error.TooManyDomains, parse(&args));
}

test "fx tool web and search each have their own usage text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var web_out: std.Io.Writer.Allocating = .init(arena);
    try writeUsage(&web_out.writer, error.MissingArgument, &.{"web"});
    try std.testing.expect(std.mem.find(u8, web_out.written(), "Usage: fx tool web URL\n") != null);
    var search_out: std.Io.Writer.Allocating = .init(arena);
    try writeUsage(&search_out.writer, error.QueryTooShort, &.{ "search", "a" });
    try std.testing.expect(std.mem.find(u8, search_out.written(), "Usage: fx tool search QUERY [--allow-domain D]... [--block-domain D]...\n") != null);
    try std.testing.expect(std.mem.find(u8, search_out.written(), "at least 2 characters") != null);
}

test "fx tool web sends a web_fetch request and prints the page on stdout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 10 }, .bytes = "PAGE TEXT\n" } };
    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .web_fetch = .{ .url = "https://example.com/a" } }, "", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.ok, code);
    try std.testing.expectEqualStrings("https://example.com/a", fake.fetched.url);
    try std.testing.expectEqualStrings("PAGE TEXT\n", out.written());
    try std.testing.expectEqualStrings("", err.written());
}

test "fx tool search sends its query and one domain filter, and prints the results on stdout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 8 }, .bytes = "results\n" } };
    var allowed: DomainList = .{};
    try allowed.push("ziglang.org");
    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .web_search = .{ .query = "zig", .allowed = allowed } }, "", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.ok, code);
    try std.testing.expectEqualStrings("zig", fake.searched.query);
    try std.testing.expectEqual(@as(usize, 1), fake.searched.allowed_domains.len);
    try std.testing.expectEqualStrings("ziglang.org", fake.searched.allowed_domains[0]);
    try std.testing.expectEqual(@as(usize, 0), fake.searched.blocked_domains.len);
    try std.testing.expectEqualStrings("results\n", out.written());
}

test "parse reads one verb and one path, and refuses the rest" {
    try std.testing.expectEqualStrings("app.py", (try parse(&.{ "edit", "app.py" })).edit);
    try std.testing.expectEqualStrings("new.txt", (try parse(&.{ "write", "new.txt" })).write);
    try std.testing.expectError(error.MissingPath, parse(&.{"edit"}));
    try std.testing.expectError(error.TooManyArguments, parse(&.{ "edit", "a", "b" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "move", "a" }));
    try std.testing.expectError(error.PathIsOption, parse(&.{ "write", "-x" }));
}

test "the change on stdin is read up to the bridge's limit and no further" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reader: std.Io.Reader = .fixed("abcdef");
    try std.testing.expectEqualStrings("abcdef", try readLimited(arena, &reader, 6));
    var over: std.Io.Reader = .fixed("abcdef");
    try std.testing.expectError(error.InputTooLarge, readLimited(arena, &over, 5));
    try std.testing.expectEqual(max_input_bytes, 1024 * 1024);
}

test "a change too large for the bridge says to split it, and exits 2 without sending" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var err: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try writeTooLarge(&err.writer, .{ .edit = "app.py" });
    try std.testing.expectEqualStrings(
        "fx tool edit: the change on stdin is larger than 1048576 bytes. Split the change into several smaller calls.\n",
        err.written(),
    );
}

test "outside a program fx started, the command says so and exits 3" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var err: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try std.testing.expectEqual(client.exit.unavailable, try writeUnavailable(&err.writer));
    try std.testing.expectEqualStrings(
        "fx tool: it works only inside a program that fx's bash tool started, with experimental.bash_tool on, before that bash call returns.\n",
        err.written(),
    );
}

test "a file change refused because the command is not a bash tool program exits 3 with the bash tool text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .refused, .reason = .file_tool_unavailable, .bytes = 0 }, .bytes = "" } };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .edit = "app.py" }, "<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE\n", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.unavailable, code);
    try std.testing.expectEqualStrings(
        "fx tool: it works only inside a program that fx's bash tool started, with experimental.bash_tool on, before that bash call returns.\n",
        err.written(),
    );
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "a file change refused as closed cannot be reviewed, so it says so and exits 3" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .refused, .reason = .closed, .bytes = 0 }, .bytes = "" } };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .write = "new.txt" }, "x", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.unavailable, code);
    try std.testing.expectEqualStrings("fx tool: fx cannot review this change because the bash call that ran this program has returned, or fx's bash tool did not start this program. Nothing changed.\n", err.written());
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "a file change from a token the bridge does not know cannot be reviewed, and the MCP text is not shown" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const mcp_text = "This command was not started by a running fx shell call, or that call has ended. Run fx mcp call from a command fx's shell tool runs, not from one left running in the background.";
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .refused, .reason = .unauthorized, .bytes = mcp_text.len }, .bytes = mcp_text } };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .write = "new.txt" }, "x", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.unavailable, code);
    try std.testing.expectEqualStrings("fx tool: fx cannot review this change because the bash call that ran this program has returned, or fx's bash tool did not start this program. Nothing changed.\n", err.written());
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "a bridge socket that is gone cannot review a change, and exits 3" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const gone: Bridge = .{ .socket_path = "/tmp/fx-tool-returned-test-no-socket.sock", .token = @splat(0x11) };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .edit = "app.py" }, "<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE\n", gone, socket_caller);
    try std.testing.expectEqual(client.exit.unavailable, code);
    try std.testing.expectEqualStrings("fx tool: fx cannot review this change because the bash call that ran this program has returned, or fx's bash tool did not start this program. Nothing changed.\n", err.written());
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

fn refusedConnection(context: ?*anyopaque, arena: Allocator, io: std.Io, socket_path: []const u8, token: core.Token, operation: wire.Operation) anyerror!client.Reply {
    _ = .{ context, arena, io, socket_path, token, operation };
    return error.ConnectionRefused;
}

test "a bridge socket that refuses the connection cannot review a change, and exits 3" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const refusing: Caller = .{ .context = null, .call_fn = refusedConnection };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .edit = "app.py" }, "<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE\n", test_bridge, refusing);
    try std.testing.expectEqual(client.exit.unavailable, code);
    try std.testing.expectEqualStrings("fx tool: fx cannot review this change because the bash call that ran this program has returned, or fx's bash tool did not start this program. Nothing changed.\n", err.written());
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "a write under the stdin cap whose encoded request exceeds max_request_bytes exits 2 without sending" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 0 }, .bytes = "" } };
    const quotes = try arena.alloc(u8, 700_000);
    @memset(quotes, '"');

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .write = "/tmp/quotes.txt" }, quotes, test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.usage, code);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expectEqualStrings(
        "fx tool write: the encoded change is larger than 1048576 bytes. Split the change into several smaller calls.\n",
        err.written(),
    );
}

test "resolveCommandPath resolves relative paths lexically against cwd without following symlinks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("/w/repo/sub/app.py", try resolveCommandPath(arena, "/w/repo/sub", "app.py"));
    try std.testing.expectEqualStrings("/w/repo/app.py", try resolveCommandPath(arena, "/w/repo/sub", "../app.py"));
    try std.testing.expectEqualStrings("/w/outside.txt", try resolveCommandPath(arena, "/w/repo", "../outside.txt"));
    try std.testing.expectEqualStrings("/tmp/x.txt", try resolveCommandPath(arena, "/w/repo/sub", "/tmp/a/../x.txt"));
}

test "an edit the decoder refuses is refused before anything is sent, with exit 2" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 0 }, .bytes = "" } };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .edit = "app.py" }, "not a block\n", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.usage, code);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expect(std.mem.startsWith(u8, err.written(), "fx tool edit: line 1: "));
}

test "a write whose content is not UTF-8 is refused before anything is sent, with exit 2" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 0 }, .bytes = "" } };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .write = "new.txt" }, "bad \xff byte\n", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.usage, code);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(std.mem.startsWith(u8, err.written(), "fx tool write: the content on stdin is not valid UTF-8"));
}

test "a write sends the whole content as one request, and its reply is the data on stdout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 13 }, .bytes = "wrote new.txt" } };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .write = "new.txt" }, "hello\nworld\n", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.ok, code);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("hello\nworld\n", fake.written);
    try std.testing.expectEqualStrings("wrote new.txt\n", out.written());
    try std.testing.expectEqual(@as(usize, 0), err.written().len);
}

test "a multi-block edit is one request, and each reply status gives its exit code and stream" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input =
        "<<<<<<< SEARCH\none\n=======\ntwo\n>>>>>>> REPLACE\n" ++
        "<<<<<<< SEARCH\nthree\n=======\nfour\n>>>>>>> REPLACE\n";

    const Case = struct { status: wire.Status, reason: ?wire.Reason = null, text: []const u8, code: u8, stdout: []const u8, stderr: []const u8 };
    const cases = [_]Case{
        .{ .status = .ok, .text = "edited app.py +2 -2", .code = client.exit.ok, .stdout = "edited app.py +2 -2\n", .stderr = "" },
        .{ .status = .tool_error, .text = "No match", .code = client.exit.tool_error, .stdout = "", .stderr = "fx tool edit: No match\n" },
        .{ .status = .denied, .text = "Denied by a rule", .code = client.exit.denied, .stdout = "", .stderr = "fx tool edit: Denied by a rule\n" },
        .{ .status = .failed, .text = "boom", .code = client.exit.failed, .stdout = "", .stderr = "fx tool edit: boom\n" },
        .{ .status = .refused, .reason = .busy, .text = "busy", .code = client.exit.busy, .stdout = "", .stderr = "fx tool edit: too many fx tool calls are running in this session. Nothing changed; try again when one finishes.\n" },
        .{ .status = .refused, .reason = .malformed, .text = "bad", .code = client.exit.usage, .stdout = "", .stderr = "fx tool edit: bad\n" },
        .{ .status = .refused, .reason = .closed, .text = "closed", .code = client.exit.unavailable, .stdout = "", .stderr = "fx tool: fx cannot review this change because the bash call that ran this program has returned, or fx's bash tool did not start this program. Nothing changed.\n" },
        .{ .status = .refused, .reason = .unauthorized, .text = "mcp", .code = client.exit.unavailable, .stdout = "", .stderr = "fx tool: fx cannot review this change because the bash call that ran this program has returned, or fx's bash tool did not start this program. Nothing changed.\n" },
        .{ .status = .refused, .reason = .unsupported_version, .text = "other", .code = client.exit.unavailable, .stdout = "", .stderr = "fx tool edit: the running fx session is another fx version. Run the fx that started the session, or restart the session with this one.\n" },
    };
    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = case.status, .reason = case.reason, .bytes = case.text.len }, .bytes = case.text } };

        const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .edit = "app.py" }, input, test_bridge, fake.caller());
        try std.testing.expectEqual(case.code, code);
        try std.testing.expectEqualStrings(case.stdout, out.written());
        try std.testing.expectEqualStrings(case.stderr, err.written());
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expectEqual(@as(usize, 2), fake.edit_blocks);
    }
}

test "fx tool edit ends its reply with a newline, even when the reply already has one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = "<<<<<<< SEARCH\none\n=======\ntwo\n>>>>>>> REPLACE\n";
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 14 }, .bytes = "edited app.py\n" } };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .edit = "app.py" }, input, test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.ok, code);
    try std.testing.expectEqualStrings("edited app.py\n\n", out.written());
    try std.testing.expectEqualStrings("", err.written());
}

test "fx tool write ends its reply with a newline, even when the reply already has one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 14 }, .bytes = "wrote new.txt\n" } };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .write = "new.txt" }, "hello\n", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.ok, code);
    try std.testing.expectEqualStrings("wrote new.txt\n\n", out.written());
    try std.testing.expectEqualStrings("", err.written());
}

test "skill and agent replies end with one newline, and add none when the reply has one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 13 }, .bytes = "zig\tZig help\n" } };
        _ = try send(arena, std.testing.io, &out.writer, &err.writer, .skill_list, "", test_bridge, fake.caller());
        try std.testing.expectEqualStrings("zig\tZig help\n", out.written());
    }
    {
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 4 }, .bytes = "done" } };
        _ = try send(arena, std.testing.io, &out.writer, &err.writer, .agent_wait, "", test_bridge, fake.caller());
        try std.testing.expectEqualStrings("done\n", out.written());
    }
}

test "fx tool prints a reply's notice on stderr, after its data on stdout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 13, .notice = "outside text" }, .bytes = "zig\tZig help\n" } };

    const code = try send(arena, std.testing.io, &out.writer, &err.writer, .skill_list, "", test_bridge, fake.caller());
    try std.testing.expectEqual(client.exit.ok, code);
    try std.testing.expectEqualStrings("zig\tZig help\n", out.written());
    try std.testing.expectEqualStrings("outside text\n", err.written());
}

test "parse reads skill and agent verbs with options, and rejects bad usage" {
    try std.testing.expectEqual(Command.skill_list, try parse(&.{ "skill", "list" }));
    try std.testing.expectEqualDeep(
        Command{ .skill_open = .{ .name = "zig" } },
        try parse(&.{ "skill", "open", "zig" }),
    );
    try std.testing.expectEqualDeep(
        Command{ .skill_open = .{ .name = "zig", .resource = "refs/notes.md" } },
        try parse(&.{ "skill", "open", "zig", "refs/notes.md" }),
    );
    try std.testing.expectEqualDeep(
        Command{ .agent_message = .{
            .agent = "worker",
            .message = "check tests",
            .instructions = "be concise",
            .model = "claude-sonnet",
            .effort = "high",
            .profile = "reviewer",
            .report = .every_turn,
        } },
        try parse(&.{
            "agent",
            "message",
            "worker",
            "check tests",
            "--instructions",
            "be concise",
            "--model=claude-sonnet",
            "--effort",
            "high",
            "--profile=reviewer",
            "--report",
            "every_turn",
        }),
    );
    try std.testing.expectEqual(Command.agent_wait, try parse(&.{ "agent", "wait" }));
    try std.testing.expectEqualDeep(Command{ .agent_status = null }, try parse(&.{ "agent", "status" }));
    try std.testing.expectEqualDeep(Command{ .agent_status = "worker" }, try parse(&.{ "agent", "status", "worker" }));
    try std.testing.expectEqualDeep(Command{ .agent_stop = "worker" }, try parse(&.{ "agent", "stop", "worker" }));
    try std.testing.expectEqualDeep(Command{ .agent_close = "worker" }, try parse(&.{ "agent", "close", "worker" }));

    try std.testing.expectError(error.UnknownCommand, parse(&.{"skill"}));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "skill", "delete", "zig" }));
    try std.testing.expectError(error.TooManyArguments, parse(&.{ "skill", "list", "extra" }));
    try std.testing.expectError(error.MissingArgument, parse(&.{ "skill", "open" }));
    try std.testing.expectError(error.TooManyArguments, parse(&.{ "skill", "open", "zig", "a", "b" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{"agent"}));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "agent", "ping" }));
    try std.testing.expectError(error.MissingArgument, parse(&.{ "agent", "message", "worker" }));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{ "agent", "message", "worker", "hi", "--model" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "agent", "message", "worker", "hi", "--bogus", "1" }));
    try std.testing.expectError(error.InvalidReport, parse(&.{ "agent", "message", "worker", "hi", "--report", "always" }));
    try std.testing.expectError(error.TooManyArguments, parse(&.{ "agent", "wait", "worker" }));
    try std.testing.expectError(error.TooManyArguments, parse(&.{ "agent", "status", "a", "b" }));
    try std.testing.expectError(error.MissingArgument, parse(&.{ "agent", "stop" }));
    try std.testing.expectError(error.MissingArgument, parse(&.{ "agent", "close" }));
}

test "skill and agent commands never read stdin, while edit and write do" {
    try std.testing.expect((Command{ .edit = "a" }).readsStdin());
    try std.testing.expect((Command{ .write = "a" }).readsStdin());
    const list_cmd: Command = .skill_list;
    const wait_cmd: Command = .agent_wait;
    try std.testing.expect(!list_cmd.readsStdin());
    try std.testing.expect(!(Command{ .skill_open = .{ .name = "zig" } }).readsStdin());
    try std.testing.expect(!(Command{ .agent_message = .{ .agent = "w", .message = "hi" } }).readsStdin());
    try std.testing.expect(!wait_cmd.readsStdin());
    try std.testing.expect(!(Command{ .agent_status = null }).readsStdin());
    try std.testing.expect(!(Command{ .agent_stop = "w" }).readsStdin());
    try std.testing.expect(!(Command{ .agent_close = "w" }).readsStdin());
}

test "skill and agent send prints stdout on ok and exits 5 or 6 on denial or tool error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .ok, .bytes = 12 }, .bytes = "zig\tZig help\n" } };
        const code = try send(arena, std.testing.io, &out.writer, &err.writer, .skill_list, "", test_bridge, fake.caller());
        try std.testing.expectEqual(client.exit.ok, code);
        try std.testing.expectEqualStrings("zig\tZig help\n", out.written());
        try std.testing.expectEqualStrings("", err.written());
    }
    {
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .denied, .bytes = 6 }, .bytes = "denied" } };
        const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .agent_stop = "w" }, "", test_bridge, fake.caller());
        try std.testing.expectEqual(client.exit.denied, code);
        try std.testing.expectEqualStrings("", out.written());
        try std.testing.expectEqualStrings("fx tool agent stop: denied\n", err.written());
    }
    {
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        var fake: FakeBridge = .{ .reply = .{ .header = .{ .status = .tool_error, .bytes = 9 }, .bytes = "not found" } };
        const code = try send(arena, std.testing.io, &out.writer, &err.writer, .{ .skill_open = .{ .name = "missing" } }, "", test_bridge, fake.caller());
        try std.testing.expectEqual(client.exit.tool_error, code);
        try std.testing.expectEqualStrings("", out.written());
        try std.testing.expectEqualStrings("fx tool skill open: not found\n", err.written());
    }
}

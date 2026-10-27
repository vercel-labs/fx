//! Host commands the detached fx frontend runs on its session.
//!
//! `fx/command` carries exactly one command from `Command`. The host owns the
//! effect and the result, and the frontend only renders what comes back, so a
//! command's rules live in one process. Unknown commands are rejected instead
//! of ignored: a newer frontend talking to an older host must fail loudly.
//!
//! This is a wire enum, not a command registry. Slash commands, their usage,
//! and their help stay in `src/core/slash_commands/command_specs.zig`; the
//! frontend parses the slash command and names the effect here:
//!
//!   /copy                      last_reply
//!   /compact                   compact
//!   /undo                      undo (on a subagent: rewind its newest turn)
//!   /context                   context
//!   /model, /effort (subagent) model, effort
//!   /shell reload              shell_reload
//!   /workspace [add|remove|clear]  workspace
//!   (after /permissions edits) permissions_reload
//!   /mcp                       mcp_status
//!   /mcp VERB ...              mcp_verb
//!
//! `/kernel` and `/heartbeat` are supervisor requests instead: the
//! supervisor schedules heartbeats across clients and answers kernel status
//! while the host runs a turn.
const std = @import("std");

pub const Command = union(Name) {
    /// The assistant text of the session's latest reply.
    last_reply,
    /// Fold the session's older turns into a summary now.
    compact,
    /// Reverse the last file operation the session recorded.
    undo,
    /// Report how much of the model's context window the session uses.
    context,
    /// Forget the cached shell startup files, so the next command reloads them.
    shell_reload,
    /// Read or change the directories the session may work in.
    workspace: WorkspaceAction,
    /// Reload the configured permission rules into the live session.
    permissions_reload,
    /// Report the MCP servers attached to the session and their state.
    mcp_status,
    /// Run one `/mcp` verb line against this session's MCP host.
    mcp_verb: []const u8,
    /// A subagent's model for its next turns; null reads it. The root's
    /// model is a session config option instead.
    model: ?[]const u8,
    /// A subagent's reasoning effort for its next turns; null reads it.
    effort: ?[]const u8,
    /// Fork a subagent into a new root session (D98). The root forks
    /// through its own picker.
    fork,
};

/// The `command` field of an `fx/command` request and its result.
pub const Name = enum {
    last_reply,
    compact,
    undo,
    context,
    shell_reload,
    workspace,
    permissions_reload,
    mcp_status,
    mcp_verb,
    model,
    effort,
    fork,
};

pub const WorkspaceAction = union(enum) {
    list,
    add: []const u8,
    remove: []const u8,
    clear,
};

/// How an explicit compaction ended.
pub const Compaction = enum {
    compacted,
    nothing_to_compact,
};

/// What undoing the last recorded file operation did.
pub const UndoOutcome = enum {
    restored,
    deleted,
    unavailable,
    nothing_to_undo,
    /// A subagent's newest turn was rewound (D97); `text` says what.
    rewound,
};

pub const Undo = struct {
    outcome: UndoOutcome,
    /// The file the operation touched; empty for `nothing_to_undo` and
    /// `rewound`.
    path: []const u8 = "",
    /// What a rewind dropped, as the host words it.
    text: []const u8 = "",
};

pub const ContextUsage = struct {
    /// Tokens the latest main-model completion reported.
    used: u64,
    /// The active model's context window, null when it advertises none.
    total: ?u32,
    /// Share of the window at which compaction starts.
    auto_compact_percent: u8,
};

/// Why the host will not run something on a node below the root. The host
/// answers with `text()`, which the frontend shows as it is.
pub const NodeRefusal = enum {
    /// The host does not run this on a subagent.
    unsupported,
    unknown_node,
    /// The node, or a node below it, is running or waiting for an approval.
    node_running,
    /// A one-off subagent ran its task and takes no more messages.
    one_off,
    /// Another message from the frontend is still running.
    message_running,
    /// Every run slot of the session's tree is taken.
    capacity,
    /// A rewind of its parent dropped the turn that started it (D97).
    abandoned,
    /// A compaction summarized the turn a rewind would drop.
    rewind_past_compaction,
    invalid_effort,
    /// The node has no turn to fork yet.
    nothing_to_fork,
    /// `/compact` on a subagent: its own turns compact it.
    compact,
    /// Its parent's fleet terminated it (D113).
    terminated,

    pub fn text(self: NodeRefusal) []const u8 {
        return switch (self) {
            .unsupported => "This is not supported in a subagent session. Press Left to return to the parent.",
            .unknown_node => "This subagent is not part of the attached session.",
            .node_running => "This subagent, or one below it, is still working. Try again when it finishes, or press Left to return to the parent.",
            .one_off => "This subagent ran a one-off task and takes no follow-up messages. Ask its parent to start a named subagent instead.",
            .message_running => "Another message to a subagent is still running. Send this one when it finishes.",
            .capacity => "Every subagent run slot of this session is in use. Send your message when one finishes.",
            .abandoned => "This subagent was abandoned when its parent was rewound. You can read it, but it takes no messages or changes.",
            .terminated => "This worker was terminated by its parent. You can read it, but it takes no messages or changes.",
            .rewind_past_compaction => "This subagent's latest turn is covered by a compaction, so it cannot be rewound.",
            .invalid_effort => "usage: /effort auto|minimal|low|medium|high",
            .nothing_to_fork => "This subagent has no turn to fork yet.",
            .compact => "A subagent compacts its own context during its turns. Compact the root session from the root.",
        };
    }
};

pub const ParseError = error{ MissingCommand, UnknownCommand, MissingPath };

/// An `fx/command` request's fields. The request also names its session,
/// which the server checks before this.
pub const Request = struct {
    command: []const u8,
    /// `workspace` only. Absent means `list`.
    action: ?[]const u8 = null,
    /// `workspace` `add` and `remove` only.
    path: ?[]const u8 = null,
    /// `mcp_verb` only.
    line: ?[]const u8 = null,
};

/// Reads an `fx/command` request. `params` is the already-parsed request
/// object. The command's strings are copied into `arena`, which the caller
/// frees with the request.
pub fn parse(arena: std.mem.Allocator, params: std.json.Value) (ParseError || error{OutOfMemory})!Command {
    const request = std.json.parseFromValueLeaky(Request, arena, params, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MissingCommand,
    };
    const name = std.meta.stringToEnum(Name, request.command) orelse return error.UnknownCommand;
    return switch (name) {
        .workspace => .{ .workspace = try parseWorkspaceAction(request) },
        .mcp_verb => .{ .mcp_verb = nonEmpty(request.line) orelse return error.MissingCommand },
        .model => .{ .model = nonEmpty(request.line) },
        .effort => .{ .effort = nonEmpty(request.line) },
        inline else => |tag| tag,
    };
}

/// The request fields that name `command`; `parse` reads them back. The
/// strings borrow `command`.
pub fn requestFields(command: Command) Request {
    return switch (command) {
        .workspace => |action| switch (action) {
            .list => .{ .command = "workspace" },
            .clear => .{ .command = "workspace", .action = "clear" },
            .add => |path| .{ .command = "workspace", .action = "add", .path = path },
            .remove => |path| .{ .command = "workspace", .action = "remove", .path = path },
        },
        .mcp_verb => |line| .{ .command = "mcp_verb", .line = line },
        .model => |value| .{ .command = "model", .line = value },
        .effort => |value| .{ .command = "effort", .line = value },
        inline else => |_, tag| .{ .command = @tagName(tag) },
    };
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

/// Workspace defaults to the listing when no action is named. Add and remove
/// need the path the frontend already parsed.
fn parseWorkspaceAction(request: Request) ParseError!WorkspaceAction {
    const Verb = enum { list, add, remove, clear };
    const raw = request.action orelse return .list;
    const verb = std.meta.stringToEnum(Verb, raw) orelse return error.UnknownCommand;
    return switch (verb) {
        .list => .list,
        .clear => .clear,
        .add => .{ .add = nonEmpty(request.path) orelse return error.MissingPath },
        .remove => .{ .remove = nonEmpty(request.path) orelse return error.MissingPath },
    };
}

/// What a command produced, rendered for the frontend.
pub const Result = union(enum) {
    text: []const u8,
    compaction: Compaction,
    undo: Undo,
    context: ContextUsage,
    /// A fork's new root session (D98) and what it says about it.
    fork: struct { session_id: []const u8, text: []const u8 },
    /// The command needs no payload beyond its name.
    ack,
};

/// The flat object the frontend reads: the command's name and only the
/// fields its result has.
pub const Response = struct {
    command: Name,
    text: ?[]const u8 = null,
    compaction: ?Compaction = null,
    outcome: ?UndoOutcome = null,
    path: ?[]const u8 = null,
    used: ?u64 = null,
    total: ?u32 = null,
    auto_compact_percent: ?u8 = null,
    /// `fork`: the new root session to switch to.
    session_id: ?[]const u8 = null,
};

/// Writes one `fx/command` result object. The daemon wraps it in its own
/// response envelope, so this carries the command name and its payload only.
pub fn writeResult(writer: *std.Io.Writer, command: Command, result: Result) !void {
    var response: Response = .{ .command = std.meta.activeTag(command) };
    switch (result) {
        .text => |text| response.text = text,
        .compaction => |outcome| response.compaction = outcome,
        .undo => |undo| {
            response.outcome = undo.outcome;
            response.path = nonEmpty(undo.path);
            response.text = nonEmpty(undo.text);
        },
        .context => |usage| {
            response.used = usage.used;
            response.total = usage.total;
            response.auto_compact_percent = usage.auto_compact_percent;
        },
        .fork => |fork| {
            response.session_id = fork.session_id;
            response.text = nonEmpty(fork.text);
        },
        .ack => {},
    }
    try std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, writer);
}

test "parse reads known commands and rejects anything else" {
    const alloc = std.testing.allocator;
    const accepted = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"last_reply\"}", .{});
    defer accepted.deinit();
    try std.testing.expectEqual(Command.last_reply, try parse(accepted.arena.allocator(), accepted.value));

    const compact = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"compact\"}", .{});
    defer compact.deinit();
    try std.testing.expectEqual(Command.compact, try parse(compact.arena.allocator(), compact.value));

    const undo = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"undo\"}", .{});
    defer undo.deinit();
    try std.testing.expectEqual(Command.undo, try parse(undo.arena.allocator(), undo.value));

    const unknown = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"rewind\"}", .{});
    defer unknown.deinit();
    try std.testing.expectError(error.UnknownCommand, parse(unknown.arena.allocator(), unknown.value));

    const missing = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer missing.deinit();
    try std.testing.expectError(error.MissingCommand, parse(missing.arena.allocator(), missing.value));

    const not_a_string = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":1}", .{});
    defer not_a_string.deinit();
    try std.testing.expectError(error.MissingCommand, parse(not_a_string.arena.allocator(), not_a_string.value));

    const not_an_object = try std.json.parseFromSlice(std.json.Value, alloc, "[]", .{});
    defer not_an_object.deinit();
    try std.testing.expectError(error.MissingCommand, parse(not_an_object.arena.allocator(), not_an_object.value));
}

test "requestFields names every command the way parse reads it back" {
    const alloc = std.testing.allocator;
    const commands = [_]Command{
        .last_reply,             .compact,                        .undo,                                      .context,                                      .shell_reload,
        .{ .workspace = .list }, .{ .workspace = .clear },        .{ .workspace = .{ .add = "/tmp/extra" } }, .{ .workspace = .{ .remove = "/tmp/extra" } }, .permissions_reload,
        .mcp_status,             .{ .mcp_verb = "login linear" }, .{ .model = "small" },                      .{ .model = null },                            .{ .effort = "high" },
        .fork,
    };
    for (commands) |command| {
        const encoded = try std.json.Stringify.valueAlloc(alloc, requestFields(command), .{ .emit_null_optional_fields = false });
        defer alloc.free(encoded);
        const value = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
        defer value.deinit();
        const decoded = try parse(value.arena.allocator(), value.value);
        try std.testing.expectEqual(std.meta.activeTag(command), std.meta.activeTag(decoded));
        switch (command) {
            .workspace => |action| switch (action) {
                .add, .remove => |path| try std.testing.expectEqualStrings(path, switch (decoded.workspace) {
                    .add, .remove => |decoded_path| decoded_path,
                    else => return error.TestExpectedWorkspacePath,
                }),
                else => try std.testing.expectEqual(std.meta.activeTag(action), std.meta.activeTag(decoded.workspace)),
            },
            .mcp_verb => |line| try std.testing.expectEqualStrings(line, decoded.mcp_verb),
            else => {},
        }
    }
}

test "writeResult renders the command and escapes its text" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeResult(&out.writer, .last_reply, .{ .text = "say \"hi\"\nnow" });

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("last_reply", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("say \"hi\"\nnow", parsed.value.object.get("text").?.string);
}

test "writeResult renders a compaction outcome" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeResult(&out.writer, .compact, .{ .compaction = .nothing_to_compact });

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("compact", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("nothing_to_compact", parsed.value.object.get("compaction").?.string);
}

test "writeResult carries an undo outcome and path" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeResult(&out.writer, .undo, .{ .undo = .{
        .outcome = .restored,
        .path = "/tmp/notes.md",
    } });

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("undo", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("restored", parsed.value.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("/tmp/notes.md", parsed.value.object.get("path").?.string);
}

test "writeResult omits the path when there was nothing to undo" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeResult(&out.writer, .undo, .{ .undo = .{ .outcome = .nothing_to_undo } });

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("path") == null);
}

test "parse reads the context command" {
    const alloc = std.testing.allocator;
    const params = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"context\"}", .{});
    defer params.deinit();
    try std.testing.expectEqual(Command.context, try parse(params.arena.allocator(), params.value));
}

test "writeResult renders context usage with and without a window" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeResult(&out.writer, .context, .{ .context = .{
        .used = 12_345,
        .total = 1_048_576,
        .auto_compact_percent = 80,
    } });
    const bounded = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer bounded.deinit();
    try std.testing.expectEqual(@as(i64, 12_345), bounded.value.object.get("used").?.integer);
    try std.testing.expectEqual(@as(i64, 1_048_576), bounded.value.object.get("total").?.integer);
    try std.testing.expectEqual(@as(i64, 80), bounded.value.object.get("auto_compact_percent").?.integer);

    out.clearRetainingCapacity();
    try writeResult(&out.writer, .context, .{ .context = .{
        .used = 7,
        .total = null,
        .auto_compact_percent = 80,
    } });
    const unbounded = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer unbounded.deinit();
    try std.testing.expect(unbounded.value.object.get("total") == null);
}

test "parse reads shell_reload and writeResult acknowledges it" {
    const alloc = std.testing.allocator;
    const params = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"shell_reload\"}", .{});
    defer params.deinit();
    try std.testing.expectEqual(Command.shell_reload, try parse(params.arena.allocator(), params.value));

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeResult(&out.writer, .shell_reload, .ack);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("shell_reload", parsed.value.object.get("command").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.count());
}

test "parse reads workspace actions" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        json: []const u8,
        action: WorkspaceAction,
    }{
        .{ .json = "{\"command\":\"workspace\"}", .action = .list },
        .{ .json = "{\"command\":\"workspace\",\"action\":\"clear\"}", .action = .clear },
        .{ .json = "{\"command\":\"workspace\",\"action\":\"add\",\"path\":\"/tmp/extra\"}", .action = .{ .add = "/tmp/extra" } },
        .{ .json = "{\"command\":\"workspace\",\"action\":\"remove\",\"path\":\"/tmp/extra\"}", .action = .{ .remove = "/tmp/extra" } },
    };
    for (cases) |case| {
        const params = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer params.deinit();
        const parsed = try parse(params.arena.allocator(), params.value);
        try std.testing.expectEqualDeep(case.action, parsed.workspace);
    }

    const missing = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"workspace\",\"action\":\"add\"}", .{});
    defer missing.deinit();
    try std.testing.expectError(error.MissingPath, parse(missing.arena.allocator(), missing.value));

    const unknown = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"workspace\",\"action\":\"pin\"}", .{});
    defer unknown.deinit();
    try std.testing.expectError(error.UnknownCommand, parse(unknown.arena.allocator(), unknown.value));
}

test "parse reads the permissions_reload command" {
    const alloc = std.testing.allocator;
    const params = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"permissions_reload\"}", .{});
    defer params.deinit();
    try std.testing.expectEqual(Command.permissions_reload, try parse(params.arena.allocator(), params.value));
}

test "parse reads the mcp_status command" {
    const alloc = std.testing.allocator;
    const params = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"mcp_status\"}", .{});
    defer params.deinit();
    try std.testing.expectEqual(Command.mcp_status, try parse(params.arena.allocator(), params.value));
}

test "parse reads an mcp verb line" {
    const alloc = std.testing.allocator;
    const params = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"mcp_verb\",\"line\":\"login linear\"}", .{});
    defer params.deinit();
    const command = try parse(params.arena.allocator(), params.value);
    try std.testing.expectEqualStrings("login linear", command.mcp_verb);

    const empty = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"mcp_verb\",\"line\":\"\"}", .{});
    defer empty.deinit();
    try std.testing.expectError(error.MissingCommand, parse(empty.arena.allocator(), empty.value));
}

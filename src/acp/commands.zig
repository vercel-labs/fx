//! Host commands the detached fx frontend runs on its session.
//!
//! `fx/command` carries exactly one command from `Command`. The host owns the
//! effect and the result, and the frontend only renders what comes back, so a
//! command's rules live in one process. Unknown commands are rejected instead
//! of ignored: a newer frontend talking to an older host must fail loudly.
const std = @import("std");

pub const Command = union(enum) {
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
};

pub const Undo = struct {
    outcome: UndoOutcome,
    /// The file the operation touched; empty only for `nothing_to_undo`.
    path: []const u8 = "",
};

pub const ContextUsage = struct {
    /// Tokens the latest main-model completion reported.
    used: u64,
    /// The active model's context window, null when it advertises none.
    total: ?u32,
    /// Share of the window at which compaction starts.
    auto_compact_percent: u8,
};

pub const ParseError = error{ MissingCommand, UnknownCommand, MissingPath };

/// Reads the `command` field of an `fx/command` request. `params` is the
/// already-parsed request object.
pub fn parse(params: std.json.Value) ParseError!Command {
    const object = switch (params) {
        .object => |value| value,
        else => return error.MissingCommand,
    };
    const raw = object.get("command") orelse return error.MissingCommand;
    const name = switch (raw) {
        .string => |value| value,
        else => return error.MissingCommand,
    };
    if (std.mem.eql(u8, name, "last_reply")) return .last_reply;
    if (std.mem.eql(u8, name, "compact")) return .compact;
    if (std.mem.eql(u8, name, "undo")) return .undo;
    if (std.mem.eql(u8, name, "context")) return .context;
    if (std.mem.eql(u8, name, "shell_reload")) return .shell_reload;
    if (std.mem.eql(u8, name, "workspace")) return .{ .workspace = try parseWorkspaceAction(object) };
    if (std.mem.eql(u8, name, "permissions_reload")) return .permissions_reload;
    if (std.mem.eql(u8, name, "mcp_status")) return .mcp_status;
    if (std.mem.eql(u8, name, "mcp_verb")) {
        const line = switch (object.get("line") orelse return error.MissingCommand) {
            .string => |value| value,
            else => return error.MissingCommand,
        };
        if (line.len == 0) return error.MissingCommand;
        return .{ .mcp_verb = line };
    }
    return error.UnknownCommand;
}

/// Workspace defaults to the listing when no action is named. Add and remove
/// need the path the frontend already parsed.
fn parseWorkspaceAction(object: std.json.ObjectMap) ParseError!WorkspaceAction {
    const raw = object.get("action") orelse return .list;
    const name = switch (raw) {
        .string => |value| value,
        else => return error.UnknownCommand,
    };
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "clear")) return .clear;
    const is_add = std.mem.eql(u8, name, "add");
    if (!is_add and !std.mem.eql(u8, name, "remove")) return error.UnknownCommand;
    const raw_path = object.get("path") orelse return error.MissingPath;
    const path = switch (raw_path) {
        .string => |value| value,
        else => return error.MissingPath,
    };
    if (path.len == 0) return error.MissingPath;
    return if (is_add) .{ .add = path } else .{ .remove = path };
}

/// What a command produced, rendered for the frontend.
pub const Result = union(enum) {
    text: []const u8,
    compaction: Compaction,
    undo: Undo,
    context: ContextUsage,
    /// The command needs no payload beyond its name.
    ack,
};

/// Writes one `fx/command` result object. The daemon wraps it in its own
/// response envelope, so this carries the command name and its payload only.
pub fn writeResult(writer: *std.Io.Writer, command: Command, result: Result) !void {
    try writer.writeAll("{\"command\":");
    try std.json.Stringify.value(@tagName(command), .{}, writer);
    switch (result) {
        .text => |text| {
            try writer.writeAll(",\"text\":");
            try std.json.Stringify.value(text, .{}, writer);
        },
        .compaction => |outcome| {
            try writer.writeAll(",\"compaction\":");
            try std.json.Stringify.value(@tagName(outcome), .{}, writer);
        },
        .undo => |undo| {
            try writer.writeAll(",\"outcome\":");
            try std.json.Stringify.value(@tagName(undo.outcome), .{}, writer);
            if (undo.path.len > 0) {
                try writer.writeAll(",\"path\":");
                try std.json.Stringify.value(undo.path, .{}, writer);
            }
        },
        .context => |usage| {
            try writer.print(",\"used\":{d}", .{usage.used});
            if (usage.total) |total| try writer.print(",\"total\":{d}", .{total});
            try writer.print(",\"auto_compact_percent\":{d}", .{usage.auto_compact_percent});
        },
        .ack => {},
    }
    try writer.writeByte('}');
}

test "parse reads known commands and rejects anything else" {
    const alloc = std.testing.allocator;
    const accepted = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"last_reply\"}", .{});
    defer accepted.deinit();
    try std.testing.expectEqual(Command.last_reply, try parse(accepted.value));

    const compact = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"compact\"}", .{});
    defer compact.deinit();
    try std.testing.expectEqual(Command.compact, try parse(compact.value));

    const undo = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"undo\"}", .{});
    defer undo.deinit();
    try std.testing.expectEqual(Command.undo, try parse(undo.value));

    const unknown = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"rewind\"}", .{});
    defer unknown.deinit();
    try std.testing.expectError(error.UnknownCommand, parse(unknown.value));

    const missing = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer missing.deinit();
    try std.testing.expectError(error.MissingCommand, parse(missing.value));

    const not_a_string = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":1}", .{});
    defer not_a_string.deinit();
    try std.testing.expectError(error.MissingCommand, parse(not_a_string.value));

    const not_an_object = try std.json.parseFromSlice(std.json.Value, alloc, "[]", .{});
    defer not_an_object.deinit();
    try std.testing.expectError(error.MissingCommand, parse(not_an_object.value));
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
    try std.testing.expectEqual(Command.context, try parse(params.value));
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
    try std.testing.expectEqual(Command.shell_reload, try parse(params.value));

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
        const parsed = try parse(params.value);
        try std.testing.expectEqualDeep(case.action, parsed.workspace);
    }

    const missing = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"workspace\",\"action\":\"add\"}", .{});
    defer missing.deinit();
    try std.testing.expectError(error.MissingPath, parse(missing.value));

    const unknown = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"workspace\",\"action\":\"pin\"}", .{});
    defer unknown.deinit();
    try std.testing.expectError(error.UnknownCommand, parse(unknown.value));
}

test "parse reads the permissions_reload command" {
    const alloc = std.testing.allocator;
    const params = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"permissions_reload\"}", .{});
    defer params.deinit();
    try std.testing.expectEqual(Command.permissions_reload, try parse(params.value));
}

test "parse reads the mcp_status command" {
    const alloc = std.testing.allocator;
    const params = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"mcp_status\"}", .{});
    defer params.deinit();
    try std.testing.expectEqual(Command.mcp_status, try parse(params.value));
}

test "parse reads an mcp verb line" {
    const alloc = std.testing.allocator;
    const params = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"mcp_verb\",\"line\":\"login linear\"}", .{});
    defer params.deinit();
    const command = try parse(params.value);
    try std.testing.expectEqualStrings("login linear", command.mcp_verb);

    const empty = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"mcp_verb\",\"line\":\"\"}", .{});
    defer empty.deinit();
    try std.testing.expectError(error.MissingCommand, parse(empty.value));
}

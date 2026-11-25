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

    pub fn verb(self: Command) []const u8 {
        return switch (self) {
            .edit => "edit",
            .write => "write",
        };
    }
};

pub const ParseError = error{ MissingPath, TooManyArguments, UnknownCommand, PathIsOption };

/// Reads `args`, the words after `fx tool`: one verb and one path.
pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.UnknownCommand;
    const verb = args[0];
    const is_edit = std.mem.eql(u8, verb, "edit");
    if (!is_edit and !std.mem.eql(u8, verb, "write")) return error.UnknownCommand;
    if (args.len < 2 or args[1].len == 0) return error.MissingPath;
    if (args.len > 2) return error.TooManyArguments;
    const path = args[1];
    if (path[0] == '-') return error.PathIsOption;
    if (is_edit) return .{ .edit = path };
    return .{ .write = path };
}

/// Writes why `err` refused `args`, in the words of the command line.
pub fn writeUsage(w: *Writer, err: ParseError, args: []const []const u8) Writer.Error!void {
    const verb = if (args.len > 0) args[0] else "";
    switch (err) {
        error.MissingPath => try w.print("fx tool {s}: give the file to change, as in fx tool {s} PATH.\n", .{ verb, verb }),
        error.TooManyArguments => try w.print("fx tool {s}: give one file, as in fx tool {s} PATH.\n", .{ verb, verb }),
        error.PathIsOption => try w.print("fx tool {s}: the file must be a path, not an option.\n", .{verb}),
        error.UnknownCommand => try w.print("fx tool: unknown command {f}. Use fx tool edit PATH or fx tool write PATH.\n", .{text_utils.terminalSafe(verb)}),
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
/// reads the change from stdin only when a bridge is there to receive it.
pub fn run(arena: Allocator, io: std.Io, out: *Writer, err: *Writer, command: Command) !u8 {
    const bridge = bridgeFromEnv() orelse return writeUnavailable(err);
    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
    const input = readLimited(arena, &stdin.interface, max_input_bytes) catch |read_err| switch (read_err) {
        error.InputTooLarge => {
            try writeTooLarge(err, command);
            return client.exit.usage;
        },
        else => return read_err,
    };
    const cwd = try std.process.currentPathAlloc(io, arena);
    const resolved_command: Command = switch (command) {
        .edit => |path| .{ .edit = try resolveCommandPath(arena, cwd, path) },
        .write => |path| .{ .write = try resolveCommandPath(arena, cwd, path) },
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
        error.FileNotFound, error.ConnectionRefused => return writeUnreviewable(err),
        error.ConnectionLost, error.MalformedReply => {
            try err.print("fx tool {s}: the connection to fx was lost ({s}). The change may have run; check the file before you run it again.\n", .{ command.verb(), @errorName(call_err) });
            return client.exit.failed;
        },
        else => return writeUnavailable(err),
    }
}

/// Shows the bridge's reply: the data on `out` for a change that applied, and
/// anything else on `err`, after the command's name. Returns the exit code.
fn printReply(arena: Allocator, out: *Writer, err: *Writer, command: Command, reply: client.Reply) !u8 {
    switch (reply.header.status) {
        .ok => {
            try out.writeAll(reply.bytes);
            try out.writeByte('\n');
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
                .closed, .unauthorized => return writeUnreviewable(err),
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
            .call, .list, .search, .help => {},
        }
        return self.reply;
    }
};

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
        "fx tool: it works only inside a program that fx's bash tool started, with experimental.bash_tool on, while that program runs.\n",
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
        "fx tool: it works only inside a program that fx's bash tool started, with experimental.bash_tool on, while that program runs.\n",
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

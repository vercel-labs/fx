//! Reads OpenCode's own session exports into the turns that
//! `fx sessions import --opencode` saves: `opencode session list --format
//! json` names the project's sessions, and `opencode session export <id>`
//! prints one of them.
//!
//! Each OpenCode user message starts a turn. The assistant messages after it
//! become that turn's single text reply: their text parts as written, each
//! tool call as a short summary of its input and output, and each compaction
//! as its summary. Reasoning, OpenCode's own reminders, and agent or model
//! switches are left out. Everything returned is owned by the caller's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The prefix of an imported session's fx id, followed by OpenCode's id, so
/// a second import of the same session finds it already saved.
pub const id_prefix = "opencode-";
const tool_input_limit = 400;
const tool_output_limit = 1500;

pub const Error = error{ InvalidOpenCodeExport, OutOfMemory };

/// Lists the top-level sessions of the project in the current folder.
pub const list_argv = [_][]const u8{ "opencode", "session", "list", "--format", "json", "--max-count", "100000" };
pub const list_output_limit: usize = 16 << 20;
pub const export_output_limit: usize = 256 << 20;
const stderr_limit: usize = 64 << 10;

pub fn exportArgv(id: []const u8) [4][]const u8 {
    return .{ "opencode", "session", "export", id };
}

/// An id that is safe to pass to `opencode` and to keep in an fx id: ASCII
/// letters, digits, `_` and `-`, starting with neither `-` nor `.`.
pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 200 or id[0] == '-') return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

/// What one `opencode` run printed: its output, or why it failed.
pub const Output = union(enum) {
    stdout: []const u8,
    failed: []const u8,
};

/// Runs `argv` and keeps at most `limit` bytes of its output, in `arena`.
/// The output goes to two private files in `scratch`, removed before this
/// returns, and not to pipes: `opencode` cuts its output to a pipe short,
/// at no fixed size, and still exits 0. `OpenCodeNotFound` when `argv[0]`
/// is not on PATH; every other failure is `.failed` with its reason.
pub fn run(arena: Allocator, io: std.Io, scratch: std.Io.Dir, argv: []const []const u8, limit: usize) error{ OpenCodeNotFound, OutOfMemory }!Output {
    var stdout_name: [32]u8 = undefined;
    var stderr_name: [32]u8 = undefined;
    const stdout_file = createScratch(io, scratch, &stdout_name) catch |err|
        return .{ .failed = try arena.print("fx could not create a scratch file: {s}", .{@errorName(err)}) };
    defer removeScratch(io, scratch, stdout_file, &stdout_name);
    const stderr_file = createScratch(io, scratch, &stderr_name) catch |err|
        return .{ .failed = try arena.print("fx could not create a scratch file: {s}", .{@errorName(err)}) };
    defer removeScratch(io, scratch, stderr_file, &stderr_name);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = stdout_file },
        .stderr = .{ .file = stderr_file },
    }) catch |err| return switch (err) {
        error.FileNotFound => error.OpenCodeNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .failed = try arena.print("it could not run: {s}", .{@errorName(err)}) },
    };
    const term = child.wait(io) catch |err|
        return .{ .failed = try arena.print("fx could not wait for it: {s}", .{@errorName(err)}) };
    switch (term) {
        .exited => |code| if (code == 0) {
            const stdout = readScratch(arena, io, stdout_file, limit) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooLarge => .{ .failed = try arena.print("its output is over the {d}-byte limit", .{limit}) },
                else => .{ .failed = try arena.print("fx could not read its output: {s}", .{@errorName(err)}) },
            };
            return .{ .stdout = stdout };
        } else {
            const said = std.mem.trim(u8, readScratch(arena, io, stderr_file, stderr_limit) catch "", " \t\r\n");
            if (said.len == 0) return .{ .failed = try arena.print("it exited with status {d}", .{code}) };
            return .{ .failed = try arena.print("it exited with status {d}: {s}", .{ code, said }) };
        },
        else => return .{ .failed = "it was stopped by a signal" },
    }
}

/// A new file only this user can read, under a random name in `name`.
fn createScratch(io: std.Io, scratch: std.Io.Dir, name: *[32]u8) !std.Io.File {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    const written = try std.mem.print(name, "fx-opencode-{x:0>16}", .{std.mem.readInt(u64, &bytes, .little)});
    std.debug.assert(written.len == 28);
    return scratch.createFile(io, name[0..28], .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
}

fn removeScratch(io: std.Io, scratch: std.Io.Dir, file: std.Io.File, name: *const [32]u8) void {
    file.close(io);
    scratch.deleteFile(io, name[0..28]) catch {};
}

fn readScratch(arena: Allocator, io: std.Io, file: std.Io.File, limit: usize) ![]u8 {
    const len = try file.length(io);
    if (len > limit) return error.TooLarge;
    const bytes = try arena.alloc(u8, @intCast(len));
    const read = try file.readPositionalAll(io, bytes, 0);
    return bytes[0..read];
}

/// One session that `opencode session list --format json` names.
pub const Listed = struct {
    id: []const u8,
    directory: ?[]const u8 = null,
};

/// One fx turn: a user prompt and the reply OpenCode gave it.
pub const Turn = struct {
    started_ms: u64,
    ended_ms: u64,
    user: []const u8,
    assistant: []const u8,
};

/// One OpenCode session, as `opencode session export <id>` prints it.
pub const Export = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    /// The folder OpenCode ran in, which becomes the fx workspace.
    directory: ?[]const u8 = null,
    created_ms: u64,
    turns: []const Turn,
};

/// The sessions in `opencode session list --format json` output.
pub fn parseList(arena: Allocator, bytes: []const u8) Error![]Listed {
    const root = try parseJson(arena, bytes);
    if (root != .array) return error.InvalidOpenCodeExport;
    var listed: std.ArrayList(Listed) = .empty;
    for (root.array.items) |item| {
        if (item != .object) return error.InvalidOpenCodeExport;
        const id = stringField(item, "id") orelse return error.InvalidOpenCodeExport;
        try listed.append(arena, .{ .id = id, .directory = stringField(item, "directory") });
    }
    return listed.items;
}

/// One session from `opencode session export <id>` output.
pub fn parseExport(arena: Allocator, bytes: []const u8) Error!Export {
    const root = try parseJson(arena, bytes);
    if (root != .object) return error.InvalidOpenCodeExport;
    const info = root.object.get("info") orelse return error.InvalidOpenCodeExport;
    if (info != .object) return error.InvalidOpenCodeExport;
    const id = stringField(info, "id") orelse return error.InvalidOpenCodeExport;
    const messages = root.object.get("messages") orelse return error.InvalidOpenCodeExport;
    if (messages != .array) return error.InvalidOpenCodeExport;
    const created_ms = timeField(info, "created") orelse 0;
    const directory = if (info.object.get("location")) |location| stringField(location, "directory") else null;
    return .{
        .id = id,
        .title = stringField(info, "title"),
        .directory = directory,
        .created_ms = created_ms,
        .turns = try buildTurns(arena, messages.array.items, created_ms),
    };
}

const Building = struct {
    started_ms: u64,
    ended_ms: u64,
    user: []const u8,
    reply: std.ArrayList(u8) = .empty,

    fn add(self: *Building, arena: Allocator, chunk: []const u8) !void {
        if (self.reply.items.len > 0) try self.reply.appendSlice(arena, "\n\n");
        try self.reply.appendSlice(arena, chunk);
    }
};

fn buildTurns(arena: Allocator, messages: []const std.json.Value, created_ms: u64) Error![]Turn {
    var building: std.ArrayList(Building) = .empty;
    for (messages) |message| {
        if (message != .object) continue;
        const kind = stringField(message, "type") orelse continue;
        const time_ms = timeField(message, "created") orelse created_ms;
        if (std.mem.eql(u8, kind, "user")) {
            try building.append(arena, .{ .started_ms = time_ms, .ended_ms = time_ms, .user = try userText(arena, message) });
        } else if (std.mem.eql(u8, kind, "assistant")) {
            if (building.items.len == 0) try building.append(arena, .{
                .started_ms = time_ms,
                .ended_ms = time_ms,
                .user = "(conversation started without a prompt)",
            });
            const turn = &building.items[building.items.len - 1];
            try addAssistant(arena, turn, message);
            const ended = timeField(message, "completed") orelse time_ms;
            turn.ended_ms = @max(turn.ended_ms, ended);
        } else if (std.mem.eql(u8, kind, "compaction")) {
            if (building.items.len == 0) continue;
            const summary = stringField(message, "summary") orelse continue;
            const turn = &building.items[building.items.len - 1];
            try turn.add(arena, try arena.print("[OpenCode compacted the conversation here. Summary:]\n{s}", .{summary}));
        }
    }
    const turns = try arena.alloc(Turn, building.items.len);
    for (building.items, turns) |*from, *to| to.* = .{
        .started_ms = from.started_ms,
        .ended_ms = from.ended_ms,
        .user = from.user,
        .assistant = if (from.reply.items.len == 0) "(no response recorded)" else from.reply.items,
    };
    return turns;
}

fn userText(arena: Allocator, message: std.json.Value) Error![]const u8 {
    const text = stringField(message, "text") orelse "";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, text);
    if (message.object.get("files")) |files| if (files == .array and files.array.items.len > 0) {
        try out.appendSlice(arena, "\n\n[attached files: ");
        for (files.array.items, 0..) |file, index| {
            if (index > 0) try out.appendSlice(arena, ", ");
            const name = switch (file) {
                .string => |value| value,
                // OpenCode names a file by its path in the project and keeps
                // its bytes in `data`, which the import leaves out.
                .object => stringField(file, "name") orelse stringField(file, "path") orelse "file",
                else => "file",
            };
            try out.appendSlice(arena, name);
        }
        try out.append(arena, ']');
    };
    if (out.items.len == 0) return "(empty prompt)";
    return out.items;
}

fn addAssistant(arena: Allocator, turn: *Building, message: std.json.Value) Error!void {
    var parts: usize = 0;
    if (message.object.get("content")) |content| if (content == .array) for (content.array.items) |part| {
        if (part != .object) continue;
        const kind = stringField(part, "type") orelse continue;
        if (std.mem.eql(u8, kind, "text")) {
            const text = stringField(part, "text") orelse continue;
            if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;
            try turn.add(arena, text);
            parts += 1;
        } else if (std.mem.eql(u8, kind, "tool")) {
            try turn.add(arena, try toolSummary(arena, part));
            parts += 1;
        }
    };
    if (parts > 0) return;
    const failure = message.object.get("error") orelse return;
    const text = switch (failure) {
        .string => |value| value,
        .object => stringField(failure, "message") orelse "unknown error",
        else => "unknown error",
    };
    try turn.add(arena, try arena.print("[OpenCode response failed: {s}]", .{text}));
}

/// A tool call as one short block: its name, status, input, and the start
/// of its output.
fn toolSummary(arena: Allocator, part: std.json.Value) Error![]const u8 {
    const name = stringField(part, "name") orelse "tool";
    const state = part.object.get("state");
    const status = if (state) |value| stringField(value, "status") orelse "unknown" else "unknown";
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "[tool `{s}` ({s})]", .{ name, status });
    const value = state orelse return out.items;
    if (value != .object) return out.items;
    if (value.object.get("input")) |input| {
        try out.appendSlice(arena, " input: ");
        try out.appendSlice(arena, try truncate(arena, try stringify(arena, input), tool_input_limit));
    }
    var output: std.ArrayList(u8) = .empty;
    if (value.object.get("content")) |content| if (content == .array) for (content.array.items) |item| {
        if (item != .object) continue;
        const kind = stringField(item, "type") orelse continue;
        if (!std.mem.eql(u8, kind, "text")) continue;
        const text = stringField(item, "text") orelse continue;
        if (output.items.len > 0) try output.append(arena, '\n');
        try output.appendSlice(arena, text);
    };
    if (value.object.get("error")) |failure| {
        if (output.items.len > 0) try output.append(arena, '\n');
        try output.appendSlice(arena, "error: ");
        try output.appendSlice(arena, switch (failure) {
            .string => |text| text,
            else => try stringify(arena, failure),
        });
    }
    if (output.items.len > 0) {
        try out.appendSlice(arena, "\noutput:\n");
        try out.appendSlice(arena, try truncate(arena, output.items, tool_output_limit));
    }
    return out.items;
}

/// `text` cut to at most `limit` bytes on a UTF-8 boundary, with a note of
/// how much was cut.
fn truncate(arena: Allocator, text: []const u8, limit: usize) Error![]const u8 {
    if (text.len <= limit) return text;
    var cut = limit;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return arena.print("{s}\n... [{d} more bytes left out on import]", .{ text[0..cut], text.len - cut });
}

fn stringify(arena: Allocator, value: std.json.Value) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

fn parseJson(arena: Allocator, bytes: []const u8) Error!std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidOpenCodeExport,
    };
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

/// `value.time.<name>` in milliseconds, when it is a non-negative number.
fn timeField(value: std.json.Value, name: []const u8) ?u64 {
    if (value != .object) return null;
    const time = value.object.get("time") orelse return null;
    if (time != .object) return null;
    const field = time.object.get(name) orelse return null;
    return switch (field) {
        .integer => |ms| if (ms >= 0) @intCast(ms) else null,
        .float => |ms| if (ms >= 0 and ms < 1e15) @intFromFloat(ms) else null,
        else => null,
    };
}

const testing = std.testing;

const sample_export =
    \\{"info":{"id":"ses_sample","title":"Track a dotfile","time":{"created":1000,"updated":9000},
    \\  "location":{"directory":"/Users/example/project"}},
    \\ "messages":[
    \\  {"id":"m1","type":"synthetic","time":{"created":1001},"text":"<system-reminder>plan mode</system-reminder>"},
    \\  {"id":"m2","type":"user","time":{"created":1002},"text":"Can we track it?","files":[{"name":"notes.md","mime":"text/plain","data":"aGk="}]},
    \\  {"id":"m3","type":"assistant","time":{"created":1003,"completed":1500},"content":[
    \\    {"type":"reasoning","text":"thinking"},
    \\    {"type":"tool","name":"bash","state":{"status":"completed","input":{"command":"ls"},
    \\      "content":[{"type":"text","text":"a.txt"}]}}]},
    \\  {"id":"m4","type":"assistant","time":{"created":1600,"completed":2000},"content":[{"type":"text","text":"Yes, done."}]},
    \\  {"id":"m5","type":"agent-switched","time":{"created":2100},"agent":"build"},
    \\  {"id":"m6","type":"user","time":{"created":3000},"text":"Thanks"},
    \\  {"id":"m7","type":"assistant","time":{"created":3001},"content":[],"error":{"message":"Missing Authorization header"}}
    \\ ]}
;

test "parseExport makes one turn per user message with its replies folded into one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parseExport(arena.allocator(), sample_export);
    try testing.expectEqualStrings("ses_sample", parsed.id);
    try testing.expectEqualStrings("Track a dotfile", parsed.title.?);
    try testing.expectEqualStrings("/Users/example/project", parsed.directory.?);
    try testing.expectEqual(@as(u64, 1000), parsed.created_ms);
    try testing.expectEqual(@as(usize, 2), parsed.turns.len);

    const first = parsed.turns[0];
    try testing.expectEqualStrings("Can we track it?\n\n[attached files: notes.md]", first.user);
    try testing.expectEqualStrings(
        "[tool `bash` (completed)] input: {\"command\":\"ls\"}\noutput:\na.txt\n\nYes, done.",
        first.assistant,
    );
    try testing.expectEqual(@as(u64, 1002), first.started_ms);
    try testing.expectEqual(@as(u64, 2000), first.ended_ms);

    try testing.expectEqualStrings("Thanks", parsed.turns[1].user);
    try testing.expectEqualStrings("[OpenCode response failed: Missing Authorization header]", parsed.turns[1].assistant);
}

test "parseExport keeps a reply that came before any prompt, and a compaction's summary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try parseExport(arena.allocator(),
        \\{"info":{"id":"ses_x","time":{"created":5}},"messages":[
        \\ {"type":"assistant","time":{"created":6},"content":[{"type":"text","text":"Hello"}]},
        \\ {"type":"compaction","time":{"created":7},"summary":"We said hello."},
        \\ {"type":"user","time":{"created":8},"text":""}]}
    );
    try testing.expect(parsed.title == null);
    try testing.expect(parsed.directory == null);
    try testing.expectEqual(@as(usize, 2), parsed.turns.len);
    try testing.expectEqualStrings("(conversation started without a prompt)", parsed.turns[0].user);
    try testing.expectEqualStrings("Hello\n\n[OpenCode compacted the conversation here. Summary:]\nWe said hello.", parsed.turns[0].assistant);
    try testing.expectEqualStrings("(empty prompt)", parsed.turns[1].user);
    try testing.expectEqualStrings("(no response recorded)", parsed.turns[1].assistant);
}

test "parseExport refuses output that is not an OpenCode export" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidOpenCodeExport, parseExport(a, "not json"));
    try testing.expectError(error.InvalidOpenCodeExport, parseExport(a, "[]"));
    try testing.expectError(error.InvalidOpenCodeExport, parseExport(a, "{\"info\":{\"id\":\"x\"}}"));
    try testing.expectError(error.InvalidOpenCodeExport, parseExport(a, "{\"info\":{},\"messages\":[]}"));
}

test "parseList reads each session's id and folder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const listed = try parseList(arena.allocator(),
        \\[{"id":"ses_a","title":"A","directory":"/Users/example/project"},{"id":"ses_b"}]
    );
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("ses_a", listed[0].id);
    try testing.expectEqualStrings("/Users/example/project", listed[0].directory.?);
    try testing.expect(listed[1].directory == null);
    try testing.expectError(error.InvalidOpenCodeExport, parseList(arena.allocator(), "{}"));
    try testing.expectError(error.InvalidOpenCodeExport, parseList(arena.allocator(), "[{\"title\":\"no id\"}]"));
}

test "validSessionId takes OpenCode's ids and refuses anything that could be an option or a path" {
    try testing.expect(validSessionId("ses_e9bd26cc5ffePUS2685HKl2Cz5"));
    try testing.expect(!validSessionId(""));
    try testing.expect(!validSessionId("--help"));
    try testing.expect(!validSessionId("../x"));
    try testing.expect(!validSessionId("a b"));
}

test "run returns a command's output, or why it failed, and leaves no scratch file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ok = try run(a, testing.io, tmp.dir, &.{ "sh", "-c", "printf '[]'" }, 1024);
    try testing.expectEqualStrings("[]", ok.stdout);
    const failed = try run(a, testing.io, tmp.dir, &.{ "sh", "-c", "echo 'Session not found: ses_x' >&2; exit 1" }, 1024);
    try testing.expectEqualStrings("it exited with status 1: Session not found: ses_x", failed.failed);
    const large = try run(a, testing.io, tmp.dir, &.{ "sh", "-c", "printf '0123456789'" }, 4);
    try testing.expectEqualStrings("its output is over the 4-byte limit", large.failed);
    try testing.expectError(error.OpenCodeNotFound, run(a, testing.io, tmp.dir, &.{"fx-test-no-such-opencode"}, 1024));
    var it = tmp.dir.iterate();
    try testing.expect(try it.next(testing.io) == null);
}

test "run keeps all of a large output that a child writes and exits at once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A megabyte, past any pipe buffer, written before the child exits.
    const out = try run(arena.allocator(), testing.io, tmp.dir, &.{ "sh", "-c", "head -c 1048576 /dev/zero" }, 2 << 20);
    try testing.expectEqual(@as(usize, 1 << 20), out.stdout.len);
}

test "truncate cuts on a UTF-8 boundary and says how much it left out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "é" is two bytes, so a cut after three bytes falls inside the second.
    const cut = try truncate(arena.allocator(), "éé", 3);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expectEqualStrings("é\n... [2 more bytes left out on import]", cut);
    try testing.expectEqualStrings("short", try truncate(arena.allocator(), "short", 10));
}

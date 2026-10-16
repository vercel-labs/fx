const std = @import("std");
const builtin = @import("builtin");
const stream_provider = @import("../core/agent/stream_provider.zig");
const claude_cli_auth = @import("../core/auth/claude_cli_auth.zig");
const claude_cli_models = @import("claude_cli_models.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

/// Claude Code runs the whole turn: it picks the tools, runs them, and writes
/// the answer. fx starts one `claude -p` process per turn, relays its text as it
/// streams, and records each tool Claude ran as a provider-executed call. fx's
/// own tools and permission prompts do not apply to these turns.
pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
    .project_replay_fn = projectReplay,
};

const max_line_bytes: usize = 16 * 1024 * 1024;
const max_tool_result_bytes: usize = 256 * 1024;
const max_session_id_bytes = 64;
const stdout_buffer_bytes: usize = 64 * 1024;
const watch_interval_ms: u64 = 25;
const terminate_grace_ms: u64 = 3000;
const text_separator = "\n\n";

const appended_system_prompt =
    "You are running as the model behind fx, a terminal coding agent. " ++
    "fx shows your replies and the tools you run to the user. " ++
    "Reply concisely and use your own tools to inspect and change the workspace.";

// Prompt construction.

/// What `claude -p` receives: the prompt text and the CLI session to continue.
const Turn = struct {
    prompt: []u8,
    /// Borrowed from the request's replay state.
    resume_session: ?[]const u8,
    completion_only: bool = false,

    pub fn deinit(self: *Turn, alloc: Allocator) void {
        alloc.free(self.prompt);
        self.* = undefined;
    }
};

/// Replay state this provider stores on an assistant message.
const ReplayState = struct {
    claude_session_id: []const u8,
};

fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_session_id_bytes) return false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    }
    return true;
}

/// Reads the CLI session id out of one message's replay state. Returns a slice
/// of `arena`, or null when the message carries none for this provider.
fn sessionFromReplay(arena: Allocator, message: types.ChatMessage, selection: ?[]const u8) Allocator.Error!?[]const u8 {
    const replay = message.provider_replay orelse return null;
    if (replay.source.provider != .claude) return null;
    if (selection) |model| if (!std.mem.eql(u8, replay.source.model, model)) return null;
    const parsed = std.json.parseFromSliceLeaky(ReplayState, arena, replay.parts_json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!validSessionId(parsed.claude_session_id)) return null;
    return parsed.claude_session_id;
}

fn appendMessage(out: *std.Io.Writer.Allocating, label: []const u8, content: []const u8) !void {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return;
    if (out.written().len > 0) try out.writer.writeAll("\n\n");
    try out.writer.print("{s}: {s}", .{ label, trimmed });
}

/// Chooses between continuing the CLI's saved session and replaying the
/// conversation as text. Continuing sends only the user messages that came after
/// the last assistant reply, which keeps Claude's own tool history intact.
/// The returned prompt is owned by `alloc`; `resume_session` borrows `arena`.
fn buildTurn(
    alloc: Allocator,
    arena: Allocator,
    messages: []const types.ChatMessage,
    model: []const u8,
) !Turn {
    var resume_session: ?[]const u8 = null;
    var tail_start: usize = 0;
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        const message = messages[index];
        if (message.role != .assistant) continue;
        if (try sessionFromReplay(arena, message, model)) |session| {
            resume_session = session;
            tail_start = index + 1;
        }
        break;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    if (resume_session != null) {
        // Only user input follows the last assistant reply; send it unlabeled so
        // the CLI sees exactly what the user typed.
        for (messages[tail_start..]) |message| {
            if (message.role != .user) continue;
            const content = message.content orelse continue;
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (out.written().len > 0) try out.writer.writeAll("\n\n");
            try out.writer.writeAll(trimmed);
        }
    } else {
        var latest_user: ?usize = null;
        for (messages, 0..) |message, i| {
            if (message.role == .user and message.content != null) latest_user = i;
        }
        const last = latest_user orelse return error.EmptyClaudePrompt;
        if (last > 0) {
            try out.writer.writeAll("This conversation is already in progress. Earlier messages follow, then the new request.\n\n");
            for (messages[0..last]) |message| {
                const label = switch (message.role) {
                    .user => "User",
                    .assistant => "Assistant",
                    else => continue,
                };
                try appendMessage(&out, label, message.content orelse continue);
            }
            try out.writer.writeAll("\n\nNew request:\n");
        }
        for (messages[last..]) |message| {
            if (message.role != .user) continue;
            const content = message.content orelse continue;
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (trimmed.len == 0) continue;
            try out.writer.writeAll(trimmed);
            try out.writer.writeAll("\n\n");
        }
    }
    const prompt = try out.toOwnedSlice();
    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) {
        alloc.free(prompt);
        return error.EmptyClaudePrompt;
    }
    return .{ .prompt = prompt, .resume_session = resume_session };
}

/// The Claude Code permission mode that matches an fx mode. Nobody can answer a
/// permission prompt in a headless run, so prompts are always denied, which makes
/// `ask` read-only. `auto` uses Claude Code's own reviewed mode, the counterpart
/// of fx's automatic review. `full-access` is the user's explicit choice to run
/// everything without asking.
fn claudePermissionMode(mode: types.PermissionMode) []const u8 {
    return switch (mode) {
        .ask => "manual",
        .auto => "auto",
        .yolo => "bypassPermissions",
    };
}

const ArgvOptions = struct {
    model: []const u8,
    resume_session: ?[]const u8 = null,
    permission_mode: types.PermissionMode = .ask,
    /// A plain text completion, such as a summary: no tools, and no session is
    /// resumed or saved.
    completion_only: bool = false,
};

/// Builds the command line. The prompt travels on stdin, so no user text reaches
/// argv. Claude Code reads no settings files, so repository settings cannot run
/// hooks.
fn buildArgv(
    arena: Allocator,
    binary: []const u8,
    options: ArgvOptions,
) ![]const []const u8 {
    const model = options.model;
    const permission_mode: types.PermissionMode = if (options.completion_only) .ask else options.permission_mode;
    if (!claude_cli_models.validModel(model)) return error.InvalidClaudeModel;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        binary,
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--permission-mode",
        claudePermissionMode(permission_mode),
        "--permission-prompts",
        "none",
        // No settings files: a repository's own settings can name hooks that run
        // commands, and fx never lets repository config start a program. The
        // project's CLAUDE.md still loads.
        "--setting-sources",
        "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--append-system-prompt",
        appended_system_prompt,
    });
    if (!std.mem.eql(u8, model, claude_cli_models.default_model)) {
        try argv.appendSlice(arena, &.{ "--model", model });
    }
    if (options.completion_only) {
        try argv.appendSlice(arena, &.{ "--tools", "", "--no-session-persistence" });
    } else if (options.resume_session) |session| {
        try argv.appendSlice(arena, &.{ "--resume", session });
    }
    return argv.toOwnedSlice(arena);
}

// Stream reduction.

const ToolRecord = struct {
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,
    result: ?[]u8 = null,
    failed: bool = false,
};

const BlockKind = union(enum) {
    text,
    thinking,
    tool: usize,
};

const Outcome = struct {
    session_id: ?[]u8 = null,
    is_error: bool = false,
    error_text: ?[]u8 = null,
    stop_reason: ?[]u8 = null,
    usage: types.Usage = .{},
    saw_result: bool = false,
};

/// Folds the CLI's JSON lines into one completion while relaying text, thinking,
/// and tool starts to `events` as they arrive. Everything it keeps lives in its
/// own arena until `finish` copies the completion out.
const Reducer = struct {
    arena: std.heap.ArenaAllocator,
    events: stream_provider.EventSink,
    content: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(ToolRecord) = .empty,
    block: ?BlockKind = null,
    outcome: Outcome = .{},
    saw_stream_text: bool = false,
    /// A plain completion is not saved by the CLI, so its session id must not
    /// become replay state for the next turn.
    completion_only: bool = false,
    /// Context size of the most recent model call. The final result sums every
    /// call in the turn, which overstates how full the context is.
    last_call_usage: ?types.Usage = null,

    pub fn init(alloc: Allocator, events: stream_provider.EventSink) Reducer {
        return .{ .arena = .init(alloc), .events = events };
    }

    pub fn deinit(self: *Reducer) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn a(self: *Reducer) Allocator {
        return self.arena.allocator();
    }

    fn appendText(self: *Reducer, text: []const u8) !void {
        if (text.len == 0) return;
        try self.content.appendSlice(self.a(), text);
        self.events.emit(.{ .content_delta = text });
        self.saw_stream_text = true;
    }

    /// Feeds one JSON line. A line that is not valid JSON is ignored: the CLI may
    /// print diagnostics in front of its stream.
    pub fn feedLine(self: *Reducer, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '{') return;
        var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer scratch.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), trimmed, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        if (root != .object) return;
        const kind = stringField(root.object, "type") orelse return;
        // Output from Claude's own subagents has its own parent; relaying it
        // would interleave two conversations in one reply.
        if (root.object.get("parent_tool_use_id")) |parent| {
            if (parent == .string) return;
        }
        if (std.mem.eql(u8, kind, "stream_event")) {
            const event = objectField(root.object, "event") orelse return;
            try self.feedStreamEvent(event);
        } else if (std.mem.eql(u8, kind, "user")) {
            try self.feedUser(root.object);
        } else if (std.mem.eql(u8, kind, "system")) {
            if (stringField(root.object, "subtype")) |subtype| {
                if (std.mem.eql(u8, subtype, "init")) try self.rememberSession(root.object);
            }
        } else if (std.mem.eql(u8, kind, "result")) {
            try self.feedResult(root.object);
        }
    }

    fn rememberSession(self: *Reducer, object: std.json.ObjectMap) !void {
        const id = stringField(object, "session_id") orelse return;
        if (!validSessionId(id)) return;
        if (self.outcome.session_id) |previous| self.a().free(previous);
        self.outcome.session_id = try self.a().dupe(u8, id);
    }

    fn feedStreamEvent(self: *Reducer, event: std.json.ObjectMap) !void {
        const kind = stringField(event, "type") orelse return;
        if (std.mem.eql(u8, kind, "content_block_start")) {
            const block = objectField(event, "content_block") orelse return;
            const block_type = stringField(block, "type") orelse return;
            if (std.mem.eql(u8, block_type, "text")) {
                if (self.content.items.len > 0 and !std.mem.endsWith(u8, self.content.items, "\n")) {
                    try self.appendText(text_separator);
                }
                self.block = .text;
            } else if (std.mem.eql(u8, block_type, "thinking")) {
                self.block = .thinking;
            } else if (std.mem.eql(u8, block_type, "tool_use")) {
                const id = stringField(block, "id") orelse return;
                const name = stringField(block, "name") orelse return;
                try self.tools.append(self.a(), .{
                    .id = try self.a().dupe(u8, id),
                    .name = try self.a().dupe(u8, name),
                });
                self.block = .{ .tool = self.tools.items.len - 1 };
            } else {
                self.block = null;
            }
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const delta = objectField(event, "delta") orelse return;
            const delta_type = stringField(delta, "type") orelse return;
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                if (self.block == null or self.block.? != .text) return;
                try self.appendText(stringField(delta, "text") orelse return);
            } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                if (stringField(delta, "thinking")) |thinking| {
                    if (thinking.len > 0) self.events.emit(.{ .reasoning_delta = thinking });
                }
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const block = self.block orelse return;
                if (block != .tool) return;
                const partial = stringField(delta, "partial_json") orelse return;
                try self.tools.items[block.tool].arguments.appendSlice(self.a(), partial);
            }
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            if (objectField(event, "usage")) |usage| {
                self.last_call_usage = .{
                    .input_tokens = unsignedField(usage, "input_tokens"),
                    .cache_read_tokens = unsignedField(usage, "cache_read_input_tokens"),
                    .cache_write_tokens = unsignedField(usage, "cache_creation_input_tokens"),
                };
            }
        } else if (std.mem.eql(u8, kind, "content_block_stop")) {
            const block = self.block orelse return;
            self.block = null;
            if (block != .tool) return;
            const record = &self.tools.items[block.tool];
            const arguments = if (record.arguments.items.len == 0) "{}" else record.arguments.items;
            self.events.emit(.{ .tool_started = .{
                .id = record.id,
                .name = record.name,
                .arguments_json = arguments,
            } });
        }
    }

    fn feedUser(self: *Reducer, root: std.json.ObjectMap) !void {
        const message = objectField(root, "message") orelse return;
        const content = message.get("content") orelse return;
        if (content != .array) return;
        for (content.array.items) |item| {
            if (item != .object) continue;
            const item_type = stringField(item.object, "type") orelse continue;
            if (!std.mem.eql(u8, item_type, "tool_result")) continue;
            const tool_use_id = stringField(item.object, "tool_use_id") orelse continue;
            const record = self.findTool(tool_use_id) orelse continue;
            if (record.result != null) continue;
            var text: std.Io.Writer.Allocating = .init(self.a());
            try appendToolResultText(&text.writer, item.object.get("content"));
            const failed = if (item.object.get("is_error")) |flag| flag == .bool and flag.bool else false;
            record.failed = failed;
            record.result = try text.toOwnedSlice();
        }
    }

    fn findTool(self: *Reducer, id: []const u8) ?*ToolRecord {
        for (self.tools.items) |*record| {
            if (std.mem.eql(u8, record.id, id)) return record;
        }
        return null;
    }

    fn feedResult(self: *Reducer, root: std.json.ObjectMap) !void {
        self.outcome.saw_result = true;
        try self.rememberSession(root);
        if (root.get("is_error")) |flag| self.outcome.is_error = flag == .bool and flag.bool;
        if (stringField(root, "subtype")) |subtype| {
            if (!std.mem.eql(u8, subtype, "success")) self.outcome.is_error = true;
        }
        if (stringField(root, "result")) |text| {
            self.outcome.error_text = try self.a().dupe(u8, text);
        }
        if (stringField(root, "stop_reason")) |reason| {
            self.outcome.stop_reason = try self.a().dupe(u8, reason);
        }
        if (objectField(root, "usage")) |usage| {
            self.outcome.usage = .{
                .input_tokens = unsignedField(usage, "input_tokens"),
                .output_tokens = unsignedField(usage, "output_tokens"),
                .cache_read_tokens = unsignedField(usage, "cache_read_input_tokens"),
                .cache_write_tokens = unsignedField(usage, "cache_creation_input_tokens"),
            };
        }
    }

    /// Builds the owned completion. A turn the CLI ended with an error is turned
    /// into a failure by the caller instead.
    pub fn finish(self: *Reducer, alloc: Allocator) !types.ModelCompletion {
        // The CLI's final `result` text is the answer when no text streamed, for
        // example when the model replied only through tools.
        if (self.content.items.len == 0 and !self.outcome.is_error) {
            if (self.outcome.error_text) |text| try self.appendText(text);
        }

        var calls: std.ArrayList(types.ToolCall) = .empty;
        for (self.tools.items) |record| {
            const result = record.result orelse "";
            const output = if (record.failed)
                try self.a().print("Tool {s} failed: {s}", .{ record.name, result })
            else
                result;
            try calls.append(self.a(), .{
                .id = record.id,
                .name = record.name,
                .arguments_json = if (record.arguments.items.len == 0) "{}" else record.arguments.items,
                .provenance = .provider_executed,
                .provider_result = output,
            });
        }

        const owned_calls = try types.dupeToolCallSlice(alloc, calls.items);
        errdefer types.freeToolCallSlice(alloc, owned_calls);
        const content = try alloc.dupe(u8, self.content.items);
        errdefer alloc.free(content);
        const state: ?[]u8 = blk: {
            if (self.completion_only) break :blk null;
            const session = self.outcome.session_id orelse break :blk null;
            break :blk try alloc.print("{{\"claude_session_id\":\"{s}\"}}", .{session});
        };
        errdefer if (state) |value| alloc.free(value);

        return .{
            .content = content,
            .tool_calls = owned_calls,
            .provider_state_json = state,
            .finish_reason = if (std.mem.eql(u8, self.outcome.stop_reason orelse "", "max_tokens")) .length else .stop,
            .usage = self.turnUsage(),
        };
    }

    /// Output tokens add up over the turn; input and cache describe the last call.
    fn turnUsage(self: *const Reducer) types.Usage {
        var usage = self.outcome.usage;
        if (self.last_call_usage) |last| {
            usage.input_tokens = last.input_tokens orelse usage.input_tokens;
            usage.cache_read_tokens = last.cache_read_tokens orelse usage.cache_read_tokens;
            usage.cache_write_tokens = last.cache_write_tokens orelse usage.cache_write_tokens;
        }
        return usage;
    }

    /// One line naming the tools Claude Code already ran. A failed turn drops its
    /// tool records, so the failure message carries them instead.
    pub fn toolSummary(self: *Reducer, alloc: Allocator) !?[]u8 {
        if (self.tools.items.len == 0) return null;
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const shown = @min(self.tools.items.len, 5);
        try out.writer.writeAll("Before it stopped, Claude Code ran: ");
        for (self.tools.items[0..shown], 0..) |record, index| {
            if (index > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(record.name);
        }
        if (self.tools.items.len > shown) try out.writer.print(", and {d} more", .{self.tools.items.len - shown});
        try out.writer.writeAll(". Check the workspace for changes.");
        return try out.toOwnedSlice();
    }
};

fn appendToolResultText(writer: *std.Io.Writer, value: ?std.json.Value) !void {
    const content = value orelse return;
    switch (content) {
        .string => |text| try writeBounded(writer, text),
        .array => |items| {
            var first = true;
            for (items.items) |item| {
                if (item != .object) continue;
                const item_type = stringField(item.object, "type") orelse continue;
                if (!std.mem.eql(u8, item_type, "text")) continue;
                const text = stringField(item.object, "text") orelse continue;
                if (!first) try writer.writeAll("\n");
                first = false;
                try writeBounded(writer, text);
            }
        },
        else => {},
    }
}

fn writeBounded(writer: *std.Io.Writer, text: []const u8) !void {
    if (text.len <= max_tool_result_bytes) return writer.writeAll(text);
    try writer.writeAll(text[0..max_tool_result_bytes]);
    try writer.print("\n[truncated {d} bytes]", .{text.len - max_tool_result_bytes});
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return if (value == .object) value.object else null;
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

/// One assistant reply carries one CLI session id, so replay never needs slicing.
fn projectReplay(
    _: Allocator,
    replay: ?types.ProviderReplay,
    _: []const types.ToolCall,
    _: bool,
    _: bool,
) anyerror!?types.ProviderReplay {
    return replay;
}

// Failure mapping.

const FailureText = struct {
    kind: stream_provider.FailureKind,
    detail: []const u8,
};

/// Turns a CLI error result into a typed failure with guidance the user can act
/// on. `detail` borrows from `text` or static storage.
///
/// Everything except a missing sign-in is `provider_error`, which fx does not
/// retry. Claude Code has already retried transient failures itself, and a usage
/// limit cannot succeed until its window resets, so another attempt would only
/// repeat the wait. The CLI's own message, which names the reset time, is the
/// detail.
fn classifyFailure(text: []const u8) FailureText {
    const signed_out_needles = [_][]const u8{ "not logged in", "please run /login", "invalid api key", "oauth token has expired", "authentication_error" };
    for (signed_out_needles) |needle| {
        if (std.ascii.findIgnoreCase(text, needle) != null) {
            return .{ .kind = .unauthorized, .detail = "Claude Code is not signed in. Run `fx login claude` in a terminal." };
        }
    }
    return .{ .kind = .provider_error, .detail = text };
}

fn resumeMissing(text: []const u8) bool {
    return std.ascii.findIgnoreCase(text, "no conversation found") != null;
}

// Process execution.

const Watch = struct {
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    process_id: std.atomic.Value(i32) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    interrupted: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// False when the watcher could not start. Windows has no process-group
    /// signals here, so it runs without one.
    fn start(self: *Watch) bool {
        if (comptime builtin.target.os.tag == .windows) return true;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return false;
        return true;
    }

    fn stop(self: *Watch) void {
        self.done.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn deadlinePassed(self: *Watch) bool {
        const deadline = self.deadline orelse return false;
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), deadline.clock);
        return std.Io.Clock.Timestamp.compare(now, .gte, deadline);
    }

    fn run(self: *Watch) void {
        while (!self.done.load(.acquire)) {
            if (self.cancel_flag.load(.seq_cst) or self.deadlinePassed()) {
                self.interrupted.store(true, .release);
                const pid = self.process_id.load(.acquire);
                if (pid > 0) terminateGracefully(self, pid);
                return;
            }
            io_mod.sleep(watch_interval_ms * std.time.ns_per_ms);
        }
    }
};

/// Stops Claude Code and the commands it started. Claude Code puts each command
/// in its own process group, so killing fx's group would leave them running.
/// Asking Claude Code to exit lets it stop its own commands. The group kill is
/// the fallback for a process that ignores the request.
fn terminateGracefully(watch: *Watch, pid: i32) void {
    if (comptime builtin.target.os.tag == .windows) return;
    std.posix.kill(pid, .TERM) catch return;
    var waited: u64 = 0;
    while (waited < terminate_grace_ms) : (waited += watch_interval_ms) {
        // The turn clears the id once it has reaped the process.
        if (watch.process_id.load(.acquire) == 0) return;
        io_mod.sleep(watch_interval_ms * std.time.ns_per_ms);
    }
    if (watch.process_id.load(.acquire) == 0) return;
    std.posix.kill(-pid, .KILL) catch {
        std.posix.kill(pid, .KILL) catch {};
    };
}

const max_stderr_bytes: usize = 8 * 1024;
const max_diagnostic_detail_bytes: usize = 1024;
const stderr_settle_ms: u64 = 200;

/// Keeps the start of the CLI's stderr for error messages. A drain thread reads
/// it so the CLI never blocks on a full pipe. The thread can outlive the turn when
/// a command Claude started still holds the pipe, so the thread and the turn each
/// hold one reference and the last to let go frees it.
const StderrTail = struct {
    file: std.Io.File,
    bytes: [max_stderr_bytes]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),
    finished: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u8) = .init(2),

    fn start(file: std.Io.File) ?*StderrTail {
        const self = std.heap.c_allocator.create(StderrTail) catch {
            file.close(io_mod.getIo());
            return null;
        };
        self.* = .{ .file = file };
        const thread = std.Thread.spawn(.{}, run, .{self}) catch {
            file.close(io_mod.getIo());
            std.heap.c_allocator.destroy(self);
            return null;
        };
        thread.detach();
        return self;
    }

    fn run(self: *StderrTail) void {
        defer {
            self.finished.store(true, .release);
            self.file.close(io_mod.getIo());
            self.release();
        }
        var scratch: [1024]u8 = undefined;
        var reader = self.file.readerStreaming(io_mod.getIo(), &scratch);
        while (true) {
            // Take whatever has arrived rather than waiting to fill a buffer, so
            // text written before a helper keeps the pipe open is still captured.
            const available = reader.interface.peekGreedy(1) catch return;
            const kept = self.len.load(.acquire);
            const room = max_stderr_bytes - kept;
            if (room > 0) {
                const take = @min(room, available.len);
                @memcpy(self.bytes[kept..][0..take], available[0..take]);
                self.len.store(kept + take, .release);
            }
            reader.interface.toss(available.len);
        }
    }

    fn release(self: *StderrTail) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.c_allocator.destroy(self);
    }

    /// The captured text with control bytes replaced, trimmed. The caller owns it.
    fn text(self: *StderrTail, alloc: Allocator) !?[]u8 {
        var waited: u64 = 0;
        while (!self.finished.load(.acquire) and waited < stderr_settle_ms) : (waited += 10) {
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
        const count = self.len.load(.acquire);
        const copy = try alloc.dupe(u8, self.bytes[0..count]);
        for (copy) |*byte| {
            if (byte.* < 0x20 and byte.* != '\n') byte.* = ' ';
            if (byte.* == 0x7f) byte.* = ' ';
        }
        const trimmed = std.mem.trim(u8, copy, " \t\r\n");
        if (trimmed.len == 0) {
            alloc.free(copy);
            return null;
        }
        const owned = try alloc.dupe(u8, trimmed);
        alloc.free(copy);
        return owned;
    }
};

const RunResult = struct {
    completion: ?types.ModelCompletion = null,
    failure: ?stream_provider.Failure = null,
    resume_missing: bool = false,
};

/// Claude Code works in the session's workspace, which is not always the
/// directory fx was started in.
fn workingDirectory(workspace_root: ?[]const u8) std.process.Child.Cwd {
    const root = workspace_root orelse return .inherit;
    if (root.len == 0 or !std.Io.Dir.path.isAbsolute(root)) return .inherit;
    return .{ .path = root };
}

fn runOnce(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    turn: Turn,
    admitted: *bool,
) !RunResult {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), claude_cli_auth.binaryPath(), .{
        .model = request.model,
        .resume_session = turn.resume_session,
        .permission_mode = request.permission_mode,
        .completion_only = turn.completion_only,
    });

    var environment = claude_cli_auth.scrubbedEnvironment(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentUnavailable => return error.ClaudeCliLaunchFailed,
    };
    defer environment.deinit();

    const io = io_mod.getIo();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &environment,
        .cwd = workingDirectory(request.workspace_root),
        .pgid = if (builtin.target.os.tag == .windows) null else 0,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ClaudeCliMissing,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("gateway", "claude cli spawn failed err={s}", .{@errorName(err)});
            return error.ClaudeCliLaunchFailed;
        },
    };
    var child_reaped = false;
    defer if (!child_reaped) child.kill(io);
    const stderr_tail: ?*StderrTail = if (child.stderr) |file| blk: {
        child.stderr = null;
        break :blk StderrTail.start(file);
    } else null;
    defer if (stderr_tail) |tail| tail.release();

    var watch: Watch = .{ .cancel_flag = request.cancel_flag, .deadline = request.deadline };
    if (child.id) |id| {
        if (comptime builtin.target.os.tag != .windows) watch.process_id.store(@intCast(id), .release);
    }
    // Without the watcher a cancel could not stop the turn, so do not run one.
    if (!watch.start()) return error.ClaudeCliLaunchFailed;
    defer watch.stop();

    request.delivery.markPossiblySent();
    // Admission is once per request, and a replay after a missing session is the
    // same request.
    if (!admitted.*) {
        try request.admission.admit();
        admitted.* = true;
    }

    var stdin_file = child.stdin orelse return error.ClaudeCliLaunchFailed;
    child.stdin = null;
    // A command that exits at once, for example on a sign-in failure, closes the
    // pipe before the prompt is written. Its own output explains why, so carry on
    // to read it instead of reporting a bare launch failure.
    stdin_file.writeStreamingAll(io, turn.prompt) catch |err| {
        debug_trace.logf("gateway", "claude cli prompt write failed err={s}", .{@errorName(err)});
    };
    stdin_file.close(io);

    var stdout_file = child.stdout orelse return error.ClaudeCliLaunchFailed;
    var buffer: [stdout_buffer_bytes]u8 = undefined;
    var reader = stdout_file.readerStreaming(io, &buffer);

    var reducer = Reducer.init(alloc, request.events);
    defer reducer.deinit();
    reducer.completion_only = turn.completion_only;

    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    while (true) {
        line.clearRetainingCapacity();
        _ = reader.interface.streamDelimiterLimit(&line.writer, '\n', .limited(max_line_bytes)) catch |err| switch (err) {
            error.StreamTooLong => {
                // Drop the rest of an oversized line rather than the turn.
                _ = reader.interface.discardDelimiterInclusive('\n') catch {};
                continue;
            },
            else => break,
        };
        // The delimiter stays buffered when one was found. Looking at the buffer
        // instead of reading ahead keeps a finished line from waiting for the next.
        const buffered = reader.interface.buffered();
        const at_delimiter = buffered.len > 0 and buffered[0] == '\n';
        try reducer.feedLine(line.written());
        if (!at_delimiter) break;
        reader.interface.toss(1);
    }

    const term = child.wait(io) catch |err| {
        debug_trace.logf("gateway", "claude cli wait failed err={s}", .{@errorName(err)});
        child_reaped = true;
        watch.process_id.store(0, .release);
        return .{ .failure = .{ .kind = .provider_error, .detail = try alloc.dupe(u8, "Claude Code ended unexpectedly."), .ownership = .owned } };
    };
    child_reaped = true;
    // The process id may be reused from here on; the watcher must not signal it.
    watch.process_id.store(0, .release);

    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (watch.interrupted.load(.acquire)) return error.Timeout;

    const exited_cleanly = term == .exited and term.exited == 0;
    if (reducer.outcome.is_error or !reducer.outcome.saw_result or !exited_cleanly) {
        const diagnostics = if (reducer.outcome.error_text == null and stderr_tail != null)
            try stderr_tail.?.text(alloc)
        else
            null;
        defer if (diagnostics) |value| alloc.free(value);
        const text = reducer.outcome.error_text orelse diagnostics orelse "Claude Code ended without a result.";
        if (turn.resume_session != null and resumeMissing(text) and reducer.content.items.len == 0) {
            return .{ .resume_missing = true };
        }
        const classified = classifyFailure(text);
        const base_detail = if (classified.kind == .provider_error and diagnostics != null)
            try alloc.print("Claude Code failed: {s}", .{classified.detail[0..@min(classified.detail.len, max_diagnostic_detail_bytes)]})
        else
            try alloc.dupe(u8, classified.detail);
        errdefer alloc.free(base_detail);
        const detail = if (try reducer.toolSummary(alloc)) |summary| joined: {
            defer alloc.free(summary);
            defer alloc.free(base_detail);
            break :joined try alloc.print("{s} {s}", .{ base_detail, summary });
        } else base_detail;
        return .{ .failure = .{
            .kind = classified.kind,
            .detail = detail,
            .ownership = .owned,
        } };
    }
    return .{ .completion = try reducer.finish(alloc) };
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (request.credential.credentialSource() != .claude_cli and request.credential.credentialSource() != .host_managed) {
        return stream_provider.failResult(error.ClaudeCliCredentialRequired);
    }
    if (!claude_cli_models.validModel(request.model)) return stream_provider.failResult(error.InvalidClaudeModel);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    // A request that allows no tools is a plain text completion, such as a
    // summary: it needs its instructions, no tools, and no saved session.
    const completion_only = request.tool_choice == .none;
    const messages = if (completion_only)
        forgetReplay(arena.allocator(), request.messages) catch return error.OutOfMemory
    else
        request.messages;
    var turn = buildTurn(alloc, arena.allocator(), messages, request.model) catch |err| switch (err) {
        error.EmptyClaudePrompt => return stream_provider.failResult(error.EmptyClaudePrompt),
        else => return err,
    };
    defer turn.deinit(alloc);
    if (completion_only) {
        turn.completion_only = true;
        try prefixInstructions(alloc, &turn, request.instructions, request.response_format);
    }

    var admitted = false;
    var outcome = runOnce(alloc, request, turn, &admitted) catch |err| return mapError(err);
    if (outcome.resume_missing) {
        // The CLI no longer has the saved session, for example after its own
        // cleanup. Replay the conversation as text instead.
        debug_trace.logf("gateway", "claude cli session missing; replaying conversation", .{});
        var replay_turn = try buildTurn(alloc, arena.allocator(), forgetReplay(arena.allocator(), request.messages) catch return error.OutOfMemory, request.model);
        defer replay_turn.deinit(alloc);
        outcome = runOnce(alloc, request, replay_turn, &admitted) catch |err| return mapError(err);
    }
    if (outcome.failure) |failure| return .{ .failed = failure };
    const completion = outcome.completion orelse return stream_provider.failResult(error.ClaudeCliFailed);
    return .{ .completed = .{ .completion = completion, .ownership = .owned } };
}

/// Puts the request's instructions, and the shape of a structured reply, ahead of
/// the prompt. Only plain completions carry them: for a normal turn Claude Code
/// has its own instructions and fx's describe fx's tools, which it does not have.
fn prefixInstructions(
    alloc: Allocator,
    turn: *Turn,
    instructions: []const types.ChatMessage,
    response_format: ?stream_provider.StructuredResponseFormat,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var wrote = false;
    for (instructions) |instruction| {
        const content = std.mem.trim(u8, instruction.content orelse continue, " \t\r\n");
        if (content.len == 0) continue;
        try out.writer.writeAll(content);
        try out.writer.writeAll("\n\n");
        wrote = true;
    }
    if (response_format) |format| {
        try out.writer.print("Reply with only JSON that matches the schema \"{s}\": ", .{format.name});
        try std.json.Stringify.value(format.schema, .{}, &out.writer);
        try out.writer.writeAll("\n\n");
        wrote = true;
    }
    if (!wrote) return;
    try out.writer.writeAll("---\n\n");
    try out.writer.writeAll(turn.prompt);
    const combined = try out.toOwnedSlice();
    alloc.free(turn.prompt);
    turn.prompt = combined;
}

fn forgetReplay(arena: Allocator, messages: []const types.ChatMessage) ![]const types.ChatMessage {
    const copy = try arena.dupe(types.ChatMessage, messages);
    for (copy) |*message| message.provider_replay = null;
    return copy;
}

fn mapError(err: anyerror) anyerror!stream_provider.Result {
    return switch (err) {
        error.ClaudeCliMissing => stream_provider.failResult(error.ClaudeCliMissing),
        error.Cancelled => stream_provider.failResult(error.Cancelled),
        error.Timeout => stream_provider.failResult(error.Timeout),
        else => err,
    };
}

// Tests.

const TestSink = struct {
    text: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_starts: std.ArrayList([]const u8) = .empty,
    tool_args: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *TestSink) void {
        const alloc = std.testing.allocator;
        self.text.deinit(alloc);
        self.reasoning.deinit(alloc);
        for (self.tool_starts.items) |item| alloc.free(item);
        for (self.tool_args.items) |item| alloc.free(item);
        self.tool_starts.deinit(alloc);
        self.tool_args.deinit(alloc);
    }

    fn emit(raw: *anyopaque, event: stream_provider.Event) void {
        const self: *TestSink = @ptrCast(@alignCast(raw));
        const alloc = std.testing.allocator;
        switch (event) {
            .content_delta => |chunk| self.text.appendSlice(alloc, chunk) catch @panic("oom"),
            .reasoning_delta => |chunk| self.reasoning.appendSlice(alloc, chunk) catch @panic("oom"),
            .tool_started => |start| {
                self.tool_starts.append(alloc, alloc.dupe(u8, start.name) catch @panic("oom")) catch @panic("oom");
                self.tool_args.append(alloc, alloc.dupe(u8, start.arguments_json orelse "") catch @panic("oom")) catch @panic("oom");
            },
            .tool_input_delta => {},
        }
    }

    fn sink(self: *TestSink) stream_provider.EventSink {
        return .{ .context = self, .emit_fn = emit };
    }
};

const fixture_tool_turn =
    \\{"type":"system","subtype":"init","session_id":"185939a1-9f95-4b23-8ded-bee33d383353"}
    \\{"type":"stream_event","event":{"type":"message_start","message":{"role":"assistant"}}}
    \\{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}
    \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}}
    \\{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
    \\{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}
    \\{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Looking."}}}
    \\{"type":"stream_event","event":{"type":"content_block_stop","index":1}}
    \\{"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}}}
    \\{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}}
    \\{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"ls\"}"}}}
    \\{"type":"stream_event","event":{"type":"content_block_stop","index":2}}
    \\{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"a.txt\nb.txt","is_error":false}]}}
    \\{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
    \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Two files."}}}
    \\{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
    \\{"type":"result","subtype":"success","is_error":false,"result":"Two files.","stop_reason":"end_turn","session_id":"185939a1-9f95-4b23-8ded-bee33d383353","usage":{"input_tokens":4,"output_tokens":137,"cache_read_input_tokens":35313,"cache_creation_input_tokens":3486}}
;

fn feedAll(reducer: *Reducer, fixture: []const u8) !void {
    var lines = std.mem.splitScalar(u8, fixture, '\n');
    while (lines.next()) |line| try reducer.feedLine(line);
}

test "reducer relays text, thinking, and tool starts and records provider-executed calls" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var reducer = Reducer.init(std.testing.allocator, sink.sink());
    defer reducer.deinit();
    try feedAll(&reducer, fixture_tool_turn);

    const completion = try reducer.finish(std.testing.allocator);
    defer {
        var owned = stream_provider.Result{ .completed = .{ .completion = completion, .ownership = .owned } };
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("Looking.\n\nTwo files.", completion.content.?);
    try std.testing.expectEqualStrings(completion.content.?, sink.text.items);
    try std.testing.expectEqualStrings("plan", sink.reasoning.items);
    try std.testing.expectEqual(@as(usize, 1), sink.tool_starts.items.len);
    try std.testing.expectEqualStrings("Bash", sink.tool_starts.items[0]);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", sink.tool_args.items[0]);

    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    const call = completion.tool_calls[0];
    try std.testing.expectEqualStrings("toolu_1", call.id);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", call.arguments_json);
    try std.testing.expectEqual(types.ToolExecutionProvenance.provider_executed, call.provenance);
    try std.testing.expectEqualStrings("a.txt\nb.txt", call.provider_result.?);

    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 137), completion.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 35313), completion.usage.cache_read_tokens);
    try std.testing.expectEqualStrings(
        "{\"claude_session_id\":\"185939a1-9f95-4b23-8ded-bee33d383353\"}",
        completion.provider_state_json.?,
    );
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expect(types.allToolCallsProviderExecuted(completion.tool_calls));
    try std.testing.expect(types.authoritativeToolAdmission(completion) == .admitted);
}

test "reducer marks a failed tool result so fx records the call as failed" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var reducer = Reducer.init(std.testing.allocator, sink.sink());
    defer reducer.deinit();
    try feedAll(&reducer,
        \\{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"Edit"}}}
        \\{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
        \\{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","is_error":true,"content":[{"type":"text","text":"permission denied"}]}]}}
        \\{"type":"result","subtype":"success","is_error":false,"result":"I could not edit it."}
    );
    const completion = try reducer.finish(std.testing.allocator);
    defer {
        var owned = stream_provider.Result{ .completed = .{ .completion = completion, .ownership = .owned } };
        owned.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("Tool Edit failed: permission denied", completion.tool_calls[0].provider_result.?);
    // With no streamed text, the CLI's final result is the answer.
    try std.testing.expectEqualStrings("I could not edit it.", completion.content.?);
    try std.testing.expectEqualStrings("{}", completion.tool_calls[0].arguments_json);
}

test "reducer ignores subagent output, noise, and unknown events" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var reducer = Reducer.init(std.testing.allocator, sink.sink());
    defer reducer.deinit();
    try feedAll(&reducer,
        \\Warning: something printed before the stream
        \\{"type":"rate_limit_event","rate_limit_info":{}}
        \\{"type":"stream_event","parent_tool_use_id":"toolu_9","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}
        \\{"type":"stream_event","parent_tool_use_id":"toolu_9","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hidden"}}}
        \\{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}
        \\{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"shown"}}}
        \\{not json
    );
    try std.testing.expectEqualStrings("shown", sink.text.items);
}

test "reducer reports a CLI error result and keeps the session for diagnosis" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var reducer = Reducer.init(std.testing.allocator, sink.sink());
    defer reducer.deinit();
    try feedAll(&reducer,
        \\{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in. Please run /login","session_id":"abc-123"}
    );
    try std.testing.expect(reducer.outcome.is_error);
    try std.testing.expect(reducer.outcome.saw_result);
    try std.testing.expectEqualStrings("Not logged in. Please run /login", reducer.outcome.error_text.?);
    const failure = classifyFailure(reducer.outcome.error_text.?);
    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, failure.kind);
    // Limits and overload are not retried by fx; the CLI's message carries the reset time.
    const limit = classifyFailure("Claude usage limit reached. Resets at 5pm.");
    try std.testing.expectEqual(stream_provider.FailureKind.provider_error, limit.kind);
    try std.testing.expectEqualStrings("Claude usage limit reached. Resets at 5pm.", limit.detail);
    try std.testing.expectEqual(stream_provider.FailureKind.provider_error, classifyFailure("API overloaded").kind);
    try std.testing.expectEqual(stream_provider.FailureKind.provider_error, classifyFailure("boom").kind);
}

test "reducer truncates an oversized tool result" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var reducer = Reducer.init(std.testing.allocator, sink.sink());
    defer reducer.deinit();
    const big = try std.testing.allocator.alloc(u8, max_tool_result_bytes + 10);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    const line = try std.testing.allocator.print(
        "{{\"type\":\"user\",\"message\":{{\"content\":[{{\"tool_use_id\":\"t1\",\"type\":\"tool_result\",\"content\":\"{s}\"}}]}}}}",
        .{big},
    );
    defer std.testing.allocator.free(line);
    try reducer.feedLine("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Read\"}}}");
    try reducer.feedLine(line);
    const result = reducer.tools.items[0].result.?;
    try std.testing.expect(std.mem.endsWith(u8, result, "[truncated 10 bytes]"));
}

test "claude reads no settings files, so repository hooks cannot run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), "claude", .{ .model = "opus" });
    try std.testing.expect(containsPair(argv, "--setting-sources", ""));
    try std.testing.expect(contains(argv, "--strict-mcp-config"));
    try std.testing.expect(contains(argv, "--disable-slash-commands"));
}

test "fx permission modes map to Claude Code modes and prompts stay denied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { mode: types.PermissionMode, expected: []const u8 }{
        .{ .mode = .ask, .expected = "manual" },
        .{ .mode = .auto, .expected = "auto" },
        .{ .mode = .yolo, .expected = "bypassPermissions" },
    };
    for (cases) |case| {
        const argv = try buildArgv(arena.allocator(), "claude", .{ .model = "opus", .permission_mode = case.mode });
        try std.testing.expect(containsPair(argv, "--permission-mode", case.expected));
        try std.testing.expect(containsPair(argv, "--permission-prompts", "none"));
        try std.testing.expect(containsPair(argv, "--setting-sources", ""));
    }
}

test "argv carries no user text and denies prompts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), "claude", .{ .model = "opus" });
    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expect(containsPair(argv, "--model", "opus"));
    try std.testing.expect(containsPair(argv, "--permission-prompts", "none"));
    try std.testing.expect(containsPair(argv, "--permission-mode", "manual"));
    try std.testing.expect(!contains(argv, "--resume"));

    const resumed = try buildArgv(arena.allocator(), "claude", .{ .model = claude_cli_models.default_model, .resume_session = "abc-123" });
    try std.testing.expect(!contains(resumed, "--model"));
    try std.testing.expect(containsPair(resumed, "--resume", "abc-123"));

    try std.testing.expectError(error.InvalidClaudeModel, buildArgv(arena.allocator(), "claude", .{ .model = "--dangerously-skip-permissions" }));
}

fn contains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, needle)) return true;
    return false;
}

fn containsPair(argv: []const []const u8, flag: []const u8, value: []const u8) bool {
    for (argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, flag) and i + 1 < argv.len and std.mem.eql(u8, argv[i + 1], value)) return true;
    }
    return false;
}

fn testReplay(session: []const u8, model: []const u8) !types.ProviderReplay {
    const json = try std.testing.allocator.print("{{\"claude_session_id\":\"{s}\"}}", .{session});
    return .{ .source = .{ .provider = .claude, .model = model }, .parts_json = json };
}

test "a first turn sends only the user's request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "  fix the bug  " }};
    var turn = try buildTurn(std.testing.allocator, arena.allocator(), &messages, "opus");
    defer turn.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("fix the bug\n\n", turn.prompt);
    try std.testing.expect(turn.resume_session == null);
}

test "a later turn resumes the saved session and sends only new user input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const replay = try testReplay("sess-1", "opus");
    defer std.testing.allocator.free(replay.parts_json);
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "first" },
        .{ .role = .assistant, .content = "answer", .provider_replay = replay },
        .{ .role = .user, .content = "second" },
    };
    var turn = try buildTurn(std.testing.allocator, arena.allocator(), &messages, "opus");
    defer turn.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second", turn.prompt);
    try std.testing.expectEqualStrings("sess-1", turn.resume_session.?);
}

test "a different model or provider replay is replayed as text instead of resumed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const replay = try testReplay("sess-1", "sonnet");
    defer std.testing.allocator.free(replay.parts_json);
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "first" },
        .{ .role = .assistant, .content = "answer", .provider_replay = replay },
        .{ .role = .user, .content = "second" },
    };
    var turn = try buildTurn(std.testing.allocator, arena.allocator(), &messages, "opus");
    defer turn.deinit(std.testing.allocator);
    try std.testing.expect(turn.resume_session == null);
    try std.testing.expect(std.mem.find(u8, turn.prompt, "User: first") != null);
    try std.testing.expect(std.mem.find(u8, turn.prompt, "Assistant: answer") != null);
    try std.testing.expect(std.mem.endsWith(u8, turn.prompt, "New request:\nsecond\n\n"));
}

test "a malformed saved session id is never passed to the CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const hostile = types.ProviderReplay{
        .source = .{ .provider = .claude, .model = "opus" },
        .parts_json = "{\"claude_session_id\":\"a b; rm\"}",
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "first" },
        .{ .role = .assistant, .content = "answer", .provider_replay = hostile },
        .{ .role = .user, .content = "second" },
    };
    var turn = try buildTurn(std.testing.allocator, arena.allocator(), &messages, "opus");
    defer turn.deinit(std.testing.allocator);
    try std.testing.expect(turn.resume_session == null);
}

test "an empty conversation has nothing to send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "   " }};
    try std.testing.expectError(error.EmptyClaudePrompt, buildTurn(std.testing.allocator, arena.allocator(), &messages, "opus"));
}

test "missing resume sessions are recognised from the CLI message" {
    try std.testing.expect(resumeMissing("No conversation found with session ID: abc"));
    try std.testing.expect(!resumeMissing("Something else"));
}

test "a plain completion runs with no tools, no saved session, and no resume" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try buildArgv(arena.allocator(), "claude", .{
        .model = "opus",
        .resume_session = "abc-123",
        .permission_mode = .yolo,
        .completion_only = true,
    });
    try std.testing.expect(containsPair(argv, "--tools", ""));
    try std.testing.expect(contains(argv, "--no-session-persistence"));
    try std.testing.expect(!contains(argv, "--resume"));
    // Whatever the fx mode, a completion has nothing to approve.
    try std.testing.expect(containsPair(argv, "--permission-mode", "manual"));
}

test "instructions and a reply schema go ahead of a plain completion's prompt" {
    const alloc = std.testing.allocator;
    var turn = Turn{ .prompt = try alloc.dupe(u8, "Summarize this."), .resume_session = null };
    defer turn.deinit(alloc);
    const instructions = [_]types.ChatMessage{
        .{ .role = .system, .content = "You write short summaries." },
        .{ .role = .system, .content = "   " },
    };
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"object\"}", .{});
    defer schema.deinit();
    try prefixInstructions(alloc, &turn, &instructions, .{ .name = "summary", .description = "", .schema = schema.value });
    try std.testing.expect(std.mem.startsWith(u8, turn.prompt, "You write short summaries.\n\n"));
    try std.testing.expect(std.mem.find(u8, turn.prompt, "schema \"summary\": {\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.endsWith(u8, turn.prompt, "---\n\nSummarize this."));

    var plain = Turn{ .prompt = try alloc.dupe(u8, "Just this."), .resume_session = null };
    defer plain.deinit(alloc);
    try prefixInstructions(alloc, &plain, &.{}, null);
    try std.testing.expectEqualStrings("Just this.", plain.prompt);
}

test "only a real sign-in problem is reported as signed out" {
    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, classifyFailure("Invalid API key · Please run /login").kind);
    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, classifyFailure("OAuth token has expired").kind);
    const outage = classifyFailure("API Error: authentication service is unavailable");
    try std.testing.expectEqual(stream_provider.FailureKind.provider_error, outage.kind);
    try std.testing.expectEqualStrings("API Error: authentication service is unavailable", outage.detail);
}

test "usage reports the last call's context and the whole turn's output" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var reducer = Reducer.init(std.testing.allocator, sink.sink());
    defer reducer.deinit();
    try feedAll(&reducer,
        \\{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":10,"output_tokens":20}}}
        \\{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":7,"cache_read_input_tokens":1200,"cache_creation_input_tokens":0,"output_tokens":30}}}
        \\{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"input_tokens":12,"output_tokens":50,"cache_read_input_tokens":2200,"cache_creation_input_tokens":10}}
    );
    const completion = try reducer.finish(std.testing.allocator);
    defer {
        var owned = stream_provider.Result{ .completed = .{ .completion = completion, .ownership = .owned } };
        owned.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 1200), completion.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 50), completion.usage.output_tokens);
}

test "a failed turn names the tools Claude Code already ran" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var reducer = Reducer.init(std.testing.allocator, sink.sink());
    defer reducer.deinit();
    try std.testing.expect((try reducer.toolSummary(std.testing.allocator)) == null);
    for ([_][]const u8{ "Read", "Edit", "Bash", "Write", "Glob", "Grep", "Task" }, 0..) |name, index| {
        const line = try std.testing.allocator.print(
            "{{\"type\":\"stream_event\",\"event\":{{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"t{d}\",\"name\":\"{s}\"}}}}}}",
            .{ index, index, name },
        );
        defer std.testing.allocator.free(line);
        try reducer.feedLine(line);
    }
    const summary = (try reducer.toolSummary(std.testing.allocator)).?;
    defer std.testing.allocator.free(summary);
    try std.testing.expectEqualStrings(
        "Before it stopped, Claude Code ran: Read, Edit, Bash, Write, Glob, and 2 more. Check the workspace for changes.",
        summary,
    );
}

test "the child works in the session's workspace only when the root is absolute" {
    try std.testing.expect(workingDirectory(null) == .inherit);
    try std.testing.expect(workingDirectory("") == .inherit);
    try std.testing.expect(workingDirectory("relative/dir") == .inherit);
    try std.testing.expectEqualStrings("/Users/example/project", workingDirectory("/Users/example/project").path);
}

test "a plain completion never leaves replay state for the next turn" {
    var sink: TestSink = .{};
    defer sink.deinit();
    for ([_]bool{ false, true }) |completion_only| {
        var reducer = Reducer.init(std.testing.allocator, sink.sink());
        defer reducer.deinit();
        reducer.completion_only = completion_only;
        try feedAll(&reducer, textTurnFixture);
        const completion = try reducer.finish(std.testing.allocator);
        var owned = stream_provider.Result{ .completed = .{ .completion = completion, .ownership = .owned } };
        defer owned.deinit(std.testing.allocator);
        try std.testing.expectEqual(!completion_only, completion.provider_state_json != null);
    }
}

const textTurnFixture =
    \\{"type":"system","subtype":"init","session_id":"sess-9"}
    \\{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
    \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}}
    \\{"type":"result","subtype":"success","is_error":false,"result":"hi","session_id":"sess-9"}
;

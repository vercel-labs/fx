//! One turn's rule enforcement, ported from proto's `TtsrCoordinator`.
//!
//! The agent loop feeds it every streamed delta: assistant text, reasoning,
//! and each tool call's arguments. A tool call is matched on what it does,
//! not its JSON: a shell command, the source a heredoc writes (in the target
//! file's language), a written file's content, an edit's new text. When a
//! rule fires it decides, by the rule's `interruptMode`:
//!
//! - interrupt: the stream is cancelled; the loop drops the partial reply
//!   (or keeps it, with `context_mode = keep`), adds the rule as an
//!   interrupt envelope to the turn, and asks again;
//! - a tool call's rule that does not interrupt rides at the head of that
//!   call's result as a reminder;
//! - a prose rule that does not interrupt is added once the reply ends,
//!   and the turn continues so the model can act on it.
//!
//! `ast:` and `llm:` conditions settle once a call's arguments are final,
//! before it runs, and `llm:` prose conditions once the reply ends.
const std = @import("std");
const manager_mod = @import("manager.zig");
const evaluate = @import("evaluate.zig");
const envelope = @import("envelope.zig");
const rule_mod = @import("rule.zig");
const settings_mod = @import("settings.zig");
const shell_code = @import("shell_code.zig");
const preview = @import("../agent/runtime/tool_input_preview.zig");

const Allocator = std.mem.Allocator;
const Manager = manager_mod.Manager;
const Match = manager_mod.Match;
const Source = @import("regions.zig").Source;

const max_history_args = 4096;

pub const NoticeKind = enum { interrupt, reminder, deferred };

pub const Injection = struct {
    /// Envelopes for the model.
    text: []const u8,
    /// For the transcript notice.
    notice: []const u8,
};

const Pending = struct {
    name: []const u8,
    description: ?[]const u8,
    entry: envelope.Entry,
    /// A tool call's id for a reminder.
    tool_id: ?[]const u8 = null,
};

/// How a tool's arguments read as text to match.
const Digest = struct {
    path_key: ?[]const u8 = null,
    body_key: ?[]const u8 = null,
    shell: bool = false,
};

fn digestFor(tool_name: []const u8) Digest {
    if (std.mem.eql(u8, tool_name, "shell")) return .{ .body_key = "command", .shell = true };
    if (std.mem.eql(u8, tool_name, "write_file")) return .{ .path_key = "path", .body_key = "content" };
    if (std.mem.eql(u8, tool_name, "edit_file")) return .{ .path_key = "path", .body_key = "new_string" };
    return .{};
}

const ToolStream = struct {
    id: []const u8,
    name: []const u8,
    digest: Digest,
    extractor: preview.Extractor = .{},
    path: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
};

pub const Coordinator = struct {
    gpa: Allocator,
    /// Turn-lifetime strings: pending injections, history, tool streams.
    arena: std.heap.ArenaAllocator,
    manager: Manager,
    settings: settings_mod.Settings,
    workspace_root: []const u8,
    home: ?[]const u8,
    judge: ?evaluate.Judge = null,
    history: []const evaluate.ToolCallRecord = &.{},
    tools: std.ArrayList(ToolStream) = .empty,
    pending_interrupt: std.ArrayList(Pending) = .empty,
    pending_deferred: std.ArrayList(Pending) = .empty,
    reminders: std.ArrayList(Pending) = .empty,
    /// Set by a stream callback when a rule interrupts; the loop reads it
    /// where it would otherwise see a user cancel.
    abort_requested: bool = false,
    cancel_flag: ?*std.atomic.Value(bool) = null,

    /// Registers `rules`, which must outlive the coordinator.
    pub fn init(gpa: Allocator, settings: settings_mod.Settings, rules: []const rule_mod.Rule, workspace_root: []const u8, home: ?[]const u8) !*Coordinator {
        const self = try gpa.create(Coordinator);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .manager = Manager.init(gpa, settings, workspace_root, home),
            .settings = settings,
            .workspace_root = workspace_root,
            .home = home,
        };
        errdefer self.deinit();
        for (rules) |rule| _ = try self.manager.addRule(rule);
        return self;
    }

    pub fn deinit(self: *Coordinator) void {
        const gpa = self.gpa;
        self.manager.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn active(self: *const Coordinator) bool {
        return self.manager.hasRules();
    }

    /// Rebuilds the repeat ledger and `did:` history from the conversation
    /// the next request carries: history, then the turn so far. Each item
    /// has `role`, optional `content` and `tool_calls` like
    /// `types.ChatMessage`.
    pub fn sync(self: *Coordinator, messages: anytype) !void {
        try self.manager.ledger.seed(messages);
        var records: std.ArrayList(evaluate.ToolCallRecord) = .empty;
        const arena = self.arena.allocator();
        for (messages) |message| for (message.tool_calls) |call| {
            const args = call.arguments_json;
            try records.append(arena, .{
                .name = call.name,
                .paths = try argumentPaths(arena, args),
                .args = args[0..@min(args.len, max_history_args)],
            });
        };
        self.history = records.items;
    }

    /// A response attempt starts: buffers never span two attempts.
    pub fn beginAttempt(self: *Coordinator, cancel_flag: ?*std.atomic.Value(bool)) void {
        self.manager.resetBuffers();
        self.tools.clearRetainingCapacity();
        self.abort_requested = false;
        self.cancel_flag = cancel_flag;
        // Matches from an attempt that did not finish are void.
        self.pending_interrupt.clearRetainingCapacity();
        self.reminders.clearRetainingCapacity();
    }

    pub fn onText(self: *Coordinator, chunk: []const u8) void {
        self.onProse(.text, "text", chunk);
    }

    pub fn onThinking(self: *Coordinator, chunk: []const u8) void {
        self.onProse(.thinking, "thinking", chunk);
    }

    fn onProse(self: *Coordinator, source: Source, key: []const u8, chunk: []const u8) void {
        if (self.abort_requested or !self.active() or chunk.len == 0) return;
        const matches = self.manager.checkDelta(chunk, .{ .source = source, .key = key, .history = self.history }) catch return;
        self.handle(matches, source, null) catch {};
    }

    pub fn onToolStart(self: *Coordinator, id: []const u8, name: []const u8, arguments_json: ?[]const u8) void {
        if (!self.active()) return;
        const arena = self.arena.allocator();
        const stream = self.tools.addOne(arena) catch return;
        stream.* = .{
            .id = arena.dupe(u8, id) catch return,
            .name = arena.dupe(u8, name) catch return,
            .digest = digestFor(name),
        };
        if (arguments_json) |json| self.onToolInput(id, json);
    }

    pub fn onToolInput(self: *Coordinator, id: []const u8, chunk: []const u8) void {
        if (self.abort_requested or !self.active()) return;
        const stream = self.toolStream(id) orelse return;
        const before = stream.body.items.len;
        if (stream.digest.body_key) |body_key| {
            const Sink = struct {
                stream: *ToolStream,
                gpa: Allocator,
                pub fn text(sink: *@This(), field: usize, bytes: []const u8) void {
                    const target = if (field == 0) &sink.stream.body else &sink.stream.path;
                    target.appendSlice(sink.gpa, bytes) catch {};
                }
            };
            var sink: Sink = .{ .stream = stream, .gpa = self.arena.allocator() };
            const keys: []const []const u8 = if (stream.digest.path_key) |path_key| &.{ body_key, path_key } else &.{body_key};
            stream.extractor.feed(chunk, keys, &sink);
        } else {
            stream.body.appendSlice(self.arena.allocator(), chunk) catch return;
        }
        if (stream.body.items.len == before) return;
        self.checkTool(stream, stream.body.items[before..], false) catch {};
    }

    fn toolStream(self: *Coordinator, id: []const u8) ?*ToolStream {
        var index = self.tools.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.tools.items[index].id, id)) return &self.tools.items[index];
        }
        return null;
    }

    fn checkTool(self: *Coordinator, stream: *ToolStream, delta: []const u8, settled: bool) !void {
        const arena = self.arena.allocator();
        const key = try arena.print("toolcall:{s}", .{stream.id});
        var path_list: []const []const u8 = &.{};
        if (stream.path.items.len > 0) {
            const one = try arena.alloc([]const u8, 1);
            one[0] = try arena.dupe(u8, stream.path.items);
            path_list = one;
        }
        const base: manager_mod.StreamContext = .{
            .source = .tool,
            .key = key,
            .tool_name = stream.name,
            .file_paths = path_list,
            .lang = if (stream.digest.shell) "bash" else null,
            .history = self.history,
            .judge = if (settled) self.judge else null,
            .settled = settled,
        };
        const matches = if (settled)
            try self.manager.checkSnapshot(stream.body.items, base)
        else
            try self.manager.checkDelta(delta, base);
        try self.handle(matches, .tool, stream.id);
        if (self.abort_requested or !stream.digest.shell) return;
        if (std.mem.find(u8, stream.body.items, "<<") == null) return;
        // Source a command writes is matched in the target's language.
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const scan = try shell_code.scan(scratch.allocator(), stream.body.items);
        for (scan.writes) |write| {
            var context = base;
            context.key = try arena.print("{s}#{s}", .{ key, write.path });
            const one = try arena.alloc([]const u8, 1);
            one[0] = try arena.dupe(u8, write.path);
            context.file_paths = one;
            context.lang = null;
            const write_matches = try self.manager.checkSnapshot(stream.body.items[write.start..write.end], context);
            try self.handle(write_matches, .tool, stream.id);
            if (self.abort_requested) return;
        }
    }

    /// A tool call's final arguments, before it runs: every condition,
    /// `ast:` and `llm:` included, settles here.
    pub fn settleToolCall(self: *Coordinator, id: []const u8, name: []const u8, arguments_json: []const u8) !void {
        if (!self.active() or self.abort_requested) return;
        const arena = self.arena.allocator();
        var stream: ToolStream = .{ .id = try arena.dupe(u8, id), .name = try arena.dupe(u8, name), .digest = digestFor(name) };
        if (stream.digest.body_key) |body_key| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return;
            if (parsed != .object) return;
            if (parsed.object.get(body_key)) |value| if (value == .string) try stream.body.appendSlice(arena, value.string);
            if (stream.digest.path_key) |path_key| if (parsed.object.get(path_key)) |value| if (value == .string) {
                try stream.path.appendSlice(arena, value.string);
            };
        } else try stream.body.appendSlice(arena, arguments_json);
        try self.checkTool(&stream, "", true);
    }

    /// The finished reply's prose: `llm:` conditions over assistant text
    /// settle here and land as a deferred injection.
    pub fn settleProse(self: *Coordinator, text: []const u8) !void {
        if (!self.active() or self.abort_requested or self.judge == null) return;
        if (!self.manager.hasJudgeRules() or std.mem.trim(u8, text, " \t\r\n").len == 0) return;
        const matches = try self.manager.checkSnapshot(text, .{
            .source = .text,
            .key = "text#settled",
            .history = self.history,
            .judge = self.judge,
            .settled = true,
        });
        try self.handleAs(matches, .deferred, null);
    }

    fn claimed(self: *const Coordinator, name: []const u8) bool {
        for ([_][]const Pending{ self.pending_interrupt.items, self.pending_deferred.items, self.reminders.items }) |list| {
            for (list) |pending| if (std.mem.eql(u8, pending.name, name)) return true;
        }
        return false;
    }

    fn shouldInterrupt(self: *const Coordinator, matches: []const Match, source: Source) bool {
        for (matches) |match| {
            const mode = match.entry.rule.interrupt_mode orelse self.settings.interrupt_mode;
            switch (mode) {
                .never => {},
                .always => return true,
                .prose_only => if (source != .tool) return true,
                .tool_only => if (source == .tool) return true,
            }
        }
        return false;
    }

    fn handle(self: *Coordinator, all: []const Match, source: Source, tool_id: ?[]const u8) !void {
        if (all.len == 0) return;
        var fresh: std.ArrayList(Match) = .empty;
        defer fresh.deinit(self.gpa);
        for (all) |match| if (!self.claimed(match.entry.rule.name)) try fresh.append(self.gpa, match);
        if (fresh.items.len == 0) return;
        if (self.shouldInterrupt(fresh.items, source)) {
            try self.handleAs(fresh.items, .interrupt, null);
            self.abort_requested = true;
            if (self.cancel_flag) |flag| flag.store(true, .seq_cst);
            return;
        }
        try self.handleAs(fresh.items, if (tool_id != null) .reminder else .deferred, tool_id);
    }

    fn handleAs(self: *Coordinator, matches: []const Match, kind: NoticeKind, tool_id: ?[]const u8) !void {
        const arena = self.arena.allocator();
        const list = switch (kind) {
            .interrupt => &self.pending_interrupt,
            .deferred => &self.pending_deferred,
            .reminder => &self.reminders,
        };
        for (matches) |match| {
            const rule = match.entry.rule;
            if (self.claimed(rule.name)) continue;
            var evidence: std.ArrayList(u8) = .empty;
            for (match.evidence.snippets, 0..) |snippet, index| {
                if (index > 0) try evidence.append(arena, '\n');
                try evidence.print(arena, "L{d}: {s}", .{ snippet.line, snippet.text });
            }
            try list.append(arena, .{
                .name = rule.name,
                .description = rule.description,
                .tool_id = if (tool_id) |id| try arena.dupe(u8, id) else null,
                .entry = .{
                    .name = rule.name,
                    .path = try displayPath(arena, rule.path, self.workspace_root, self.home),
                    .content = rule.content,
                    .evidence = evidence.items,
                },
            });
        }
    }

    /// Whether the attempt ended because a rule interrupted it.
    pub fn interruptPending(self: *const Coordinator) bool {
        return self.pending_interrupt.items.len > 0;
    }

    /// The interrupt to add before the retry, clearing the attempt's abort.
    /// The text lives in `alloc`.
    pub fn takeInterrupt(self: *Coordinator, alloc: Allocator) !?Injection {
        defer {
            self.pending_interrupt.clearRetainingCapacity();
            self.reminders.clearRetainingCapacity();
            self.abort_requested = false;
        }
        return self.render(alloc, self.pending_interrupt.items, .interrupt, .interrupt);
    }

    /// Prose rules that did not interrupt, to add after the reply.
    pub fn takeDeferred(self: *Coordinator, alloc: Allocator) !?Injection {
        defer self.pending_deferred.clearRetainingCapacity();
        return self.render(alloc, self.pending_deferred.items, .interrupt, .deferred);
    }

    pub fn hasDeferred(self: *const Coordinator) bool {
        return self.pending_deferred.items.len > 0;
    }

    /// The reminder for one tool call's result, if a rule matched it.
    pub fn takeReminder(self: *Coordinator, alloc: Allocator, tool_id: []const u8) !?Injection {
        var picked: std.ArrayList(Pending) = .empty;
        defer picked.deinit(self.gpa);
        var index: usize = 0;
        while (index < self.reminders.items.len) {
            const pending = self.reminders.items[index];
            if (pending.tool_id != null and std.mem.eql(u8, pending.tool_id.?, tool_id)) {
                try picked.append(self.gpa, pending);
                _ = self.reminders.orderedRemove(index);
            } else index += 1;
        }
        return self.render(alloc, picked.items, .reminder, .reminder);
    }

    fn render(self: *Coordinator, alloc: Allocator, pending: []const Pending, kind: envelope.Kind, notice_kind: NoticeKind) !?Injection {
        _ = self;
        if (pending.len == 0) return null;
        const entries = try alloc.alloc(envelope.Entry, pending.len);
        for (pending, entries) |item, *entry| entry.* = item.entry;
        return .{
            .text = try envelope.renderAll(alloc, kind, entries),
            .notice = try noticeText(alloc, pending, notice_kind),
        };
    }
};

/// The transcript row's body, in proto-fx's notice voice; no ids.
fn noticeText(alloc: Allocator, pending: []const Pending, kind: NoticeKind) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pending, 0..) |item, index| {
        if (index > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, item.name);
    }
    if (pending.len == 1) if (pending[0].description) |description| {
        const first_line = std.mem.sliceTo(description, '\n');
        if (first_line.len > 0) try out.print(alloc, " · {s}", .{first_line[0..@min(first_line.len, 160)]});
    };
    try out.appendSlice(alloc, switch (kind) {
        .interrupt => " · response restarted",
        .reminder => " · added to the tool result",
        .deferred => " · added after the reply",
    });
    return out.items;
}

/// A rule's path as a person reads it.
fn displayPath(arena: Allocator, rule_path: []const u8, workspace_root: []const u8, home: ?[]const u8) ![]const u8 {
    if (workspace_root.len > 0 and std.mem.startsWith(u8, rule_path, workspace_root) and
        rule_path.len > workspace_root.len and rule_path[workspace_root.len] == '/')
        return rule_path[workspace_root.len + 1 ..];
    if (home) |dir| if (dir.len > 0 and std.mem.startsWith(u8, rule_path, dir) and rule_path.len > dir.len and rule_path[dir.len] == '/') {
        return arena.print("~{s}", .{rule_path[dir.len..]});
    };
    return rule_path;
}

/// String arguments whose key is or ends with `path`, and string items of
/// keys that end with `paths`, for `did: { path }`.
pub fn argumentPaths(arena: Allocator, arguments_json: []const u8) ![]const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return &.{};
    if (parsed != .object) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = parsed.object.iterator();
    while (it.next()) |field| {
        var lower_buf: [64]u8 = undefined;
        if (field.key_ptr.len > lower_buf.len) continue;
        const key = std.ascii.lowerString(&lower_buf, field.key_ptr.*);
        switch (field.value_ptr.*) {
            .string => |value| if (std.mem.endsWith(u8, key, "path") and value.len > 0) try out.append(arena, value),
            .array => |items| if (std.mem.endsWith(u8, key, "paths")) for (items.items) |item| {
                if (item == .string and item.string.len > 0) try out.append(arena, item.string);
            },
            else => {},
        }
    }
    return out.items;
}

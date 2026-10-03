//! The labels a child fx reports to the fx that launched it, one JSON
//! object per line on the child's report channel, and the parent's store of
//! them. Both sides are the same fx binary, so the format has no version.
//!
//! The child writes `encode`d events: its state, its session, each message
//! submitted to it, each turn's end with the final reply, and each prompt it
//! shows. The parent applies each line to its `Labels`, which keep the latest
//! of each. The parent's user answers a prompt with an `Answer` line on the
//! same channel; the child's `PromptTracker` says which prompt it is for.

const std = @import("std");
const permission_request = @import("../permissions/permission_request.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const State = enum { starting, idle, working, blocked };
pub const BlockedReason = enum { permission, question, recovery };
/// Ready for input, or busy. A turn end reports working when another
/// message is already queued.
pub const Activity = enum { idle, working };

/// The most text bytes one event carries. JSON escaping grows text by at
/// most six times, so every line stays under sub-engine's line limit.
pub const max_text = 128 * 1024;
/// How many submitted messages `Labels` keeps.
pub const max_messages = 32;

pub const Event = union(enum) {
    session: []const u8,
    state: Activity,
    /// A paste reached the composer. The sender waits for this before it
    /// presses Enter, because fx refuses a paste followed by more input in
    /// the same read.
    pasted,
    /// A message was submitted and queued; the child is working.
    message: []const u8,
    turn_end: struct {
        /// The reply that completed the turn; null when it did not.
        final: ?[]const u8,
        next: Activity,
    },
    /// A permission or question prompt opened; the child is blocked.
    prompt: Prompt,
    /// Prompt `number` closed. The child is `next` again: the activity it
    /// reported last, which includes a turn end reported meanwhile.
    prompt_closed: struct { number: u64, next: Activity },
};

pub const Prompt = struct {
    /// Counts the child's prompts from 1. An answer carries it back.
    number: u64,
    reason: BlockedReason,
    body: union(enum) {
        permission: permission_request.PermissionRequest,
        questions: []const types.QuestionBatchEntry,
    },
};

/// The user's decision on a permission prompt.
pub const Decision = enum { once, always, deny };

/// The parent's answer to a child's prompt, one line on its report channel.
pub const Answer = struct {
    /// The prompt it was shown for.
    prompt: u64,
    reply: union(enum) {
        permission: struct { decision: Decision, feedback: ?[]const u8 = null },
        /// One answer per question, or null to cancel the questions.
        questions: ?[]const []const u8,
    },
};

/// One line for `event`, newline included. Caller owns it. Text is made
/// valid UTF-8 and cut to `max_text` bytes (see `Text`).
pub fn encode(gpa: Allocator, event: Event) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    const written = switch (event) {
        .session => |id| blk: {
            var text = try Text.init(gpa, id);
            defer text.deinit(gpa);
            break :blk std.json.Stringify.value(.{ .event = "session", .id = text.bytes }, options, &out.writer);
        },
        .state => |state| std.json.Stringify.value(.{ .event = "state", .state = @tagName(state) }, options, &out.writer),
        .pasted => std.json.Stringify.value(.{ .event = "pasted" }, options, &out.writer),
        .message => |raw| blk: {
            var text = try Text.init(gpa, raw);
            defer text.deinit(gpa);
            break :blk std.json.Stringify.value(.{
                .event = "message",
                .text = text.bytes,
                .truncated = text.truncated,
            }, options, &out.writer);
        },
        .turn_end => |end| blk: {
            var final: ?Text = if (end.final) |raw| try Text.init(gpa, raw) else null;
            defer if (final) |*text| text.deinit(gpa);
            break :blk std.json.Stringify.value(.{
                .event = "turn_end",
                .final = if (final) |text| text.bytes else null,
                .truncated = if (final) |text| text.truncated else false,
                .next = @tagName(end.next),
            }, options, &out.writer);
        },
        .prompt => |prompt| return encodePrompt(gpa, prompt),
        .prompt_closed => |closed| std.json.Stringify.value(.{
            .event = "prompt_closed",
            .number = closed.number,
            .next = @tagName(closed.next),
        }, options, &out.writer),
    };
    written catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The prompt's line, newline included. Invalid UTF-8 inside strings becomes
/// U+FFFD; JSON's own syntax is ASCII, so the line stays valid JSON.
fn encodePrompt(gpa: Allocator, prompt: Prompt) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    std.json.Stringify.value(.{
        .event = "prompt",
        .number = prompt.number,
        .reason = @tagName(prompt.reason),
        .permission = switch (prompt.body) {
            .permission => |request| request,
            .questions => null,
        },
        .questions = switch (prompt.body) {
            .permission => null,
            .questions => |entries| entries,
        },
    }, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    const json = out.written();
    if (std.unicode.utf8ValidateSlice(json)) return std.fmt.allocPrint(gpa, "{s}\n", .{json});
    return std.fmt.allocPrint(gpa, "{f}\n", .{std.unicode.fmtUtf8(json)});
}

pub const AnswerError = error{ OutOfMemory, AnswerTooLong };

/// One line for `answer`, without its newline. Caller owns it.
pub fn encodeAnswer(gpa: Allocator, answer: Answer, max_line: usize) AnswerError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    const written = switch (answer.reply) {
        .permission => |permission| std.json.Stringify.value(.{
            .kind = "permission",
            .prompt = answer.prompt,
            .decision = @tagName(permission.decision),
            .feedback = permission.feedback,
        }, options, &out.writer),
        .questions => |answers| std.json.Stringify.value(.{
            .kind = "questions",
            .prompt = answer.prompt,
            .answers = answers,
        }, options, &out.writer),
    };
    written catch return error.OutOfMemory;
    return finishLine(gpa, out.written(), max_line);
}

/// One line carrying the parent's root-user context, without its newline.
/// The child reviews its own actions against it, since its prompts come from
/// the parent's model rather than the user. Caller owns it.
pub fn encodeContext(gpa: Allocator, context: []const u8, max_line: usize) AnswerError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    std.json.Stringify.value(.{ .kind = "context", .text = context }, .{}, &out.writer) catch return error.OutOfMemory;
    return finishLine(gpa, out.written(), max_line);
}

/// The context a context line carries, in `arena`. Null for any other line.
pub fn parseContext(arena: Allocator, line: []const u8) error{OutOfMemory}!?[]const u8 {
    const Wire = struct { kind: []const u8, text: ?[]const u8 = null };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!std.mem.eql(u8, wire.kind, "context")) return null;
    return wire.text;
}

/// Copies `json` into a line the parser accepts: valid UTF-8, at most
/// `max_line` bytes.
fn finishLine(gpa: Allocator, json: []const u8, max_line: usize) AnswerError![]u8 {
    const line = if (std.unicode.utf8ValidateSlice(json))
        try gpa.dupe(u8, json)
    else
        try std.fmt.allocPrint(gpa, "{f}", .{std.unicode.fmtUtf8(json)});
    if (line.len > max_line) {
        gpa.free(line);
        return error.AnswerTooLong;
    }
    return line;
}

/// Parses one answer line. Its strings live in `arena`.
pub fn parseAnswer(arena: Allocator, line: []const u8) error{ OutOfMemory, InvalidLine }!Answer {
    const Wire = struct {
        kind: []const u8,
        prompt: u64,
        decision: ?[]const u8 = null,
        feedback: ?[]const u8 = null,
        answers: ?[]const []const u8 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidLine,
    };
    if (std.mem.eql(u8, wire.kind, "permission")) {
        const decision = std.meta.stringToEnum(Decision, wire.decision orelse return error.InvalidLine) orelse
            return error.InvalidLine;
        return .{ .prompt = wire.prompt, .reply = .{ .permission = .{ .decision = decision, .feedback = wire.feedback } } };
    }
    if (std.mem.eql(u8, wire.kind, "questions")) {
        return .{ .prompt = wire.prompt, .reply = .{ .questions = wire.answers } };
    }
    return error.InvalidLine;
}

/// The child's side of its prompts: it numbers each prompt it shows, says
/// what to report when the shown prompt changes, and hands over an answer
/// only for the prompt still open with that number, once.
pub const PromptTracker = struct {
    open: ?Open = null,
    count: u64 = 0,

    /// What tells prompts apart in the child: a permission request's id, or
    /// a hash of the questions, which have no id.
    pub const Key = union(enum) { permission: u64, questions: u64 };

    pub const Open = struct {
        number: u64,
        key: Key,
        answered: bool = false,
    };

    /// What to report, in this order.
    pub const Change = struct { closed: ?u64 = null, opened: ?u64 = null };

    /// The child shows prompt `key` now, or none.
    pub fn observe(self: *PromptTracker, key: ?Key) Change {
        if (self.open) |open| if (key) |now| if (std.meta.eql(open.key, now)) return .{};
        var change: Change = .{};
        if (self.open) |open| change.closed = open.number;
        self.open = null;
        if (key) |now| {
            self.count += 1;
            self.open = .{ .number = self.count, .key = now };
            change.opened = self.count;
        }
        return change;
    }

    /// The prompt an answer for `number` applies to, if it is still open and
    /// unanswered. Marks it answered.
    pub fn take(self: *PromptTracker, number: u64) ?Key {
        const open = &(self.open orelse return null);
        if (open.number != number or open.answered) return null;
        open.answered = true;
        return open.key;
    }
};

/// Text an event carries. The parent's JSON parser rejects invalid UTF-8,
/// which would drop the whole line, so invalid sequences become U+FFFD.
/// Then the text is cut to `max_text` bytes without splitting a character.
const Text = struct {
    bytes: []const u8,
    truncated: bool,
    owned: ?[]u8,

    fn init(gpa: Allocator, raw: []const u8) Allocator.Error!Text {
        var owned: ?[]u8 = null;
        const valid = if (std.unicode.utf8ValidateSlice(raw)) raw else blk: {
            owned = try std.fmt.allocPrint(gpa, "{f}", .{std.unicode.fmtUtf8(raw)});
            break :blk owned.?;
        };
        if (valid.len <= max_text) return .{ .bytes = valid, .truncated = false, .owned = owned };
        var end: usize = max_text;
        while (end > 0 and valid[end] & 0xC0 == 0x80) end -= 1;
        return .{ .bytes = valid[0..end], .truncated = true, .owned = owned };
    }

    fn deinit(self: *Text, gpa: Allocator) void {
        if (self.owned) |bytes| gpa.free(bytes);
    }
};

pub const Message = struct {
    text: []u8,
    truncated: bool,
};

pub const Labels = struct {
    state: State = .starting,
    /// Why the child is blocked; null unless `state` is `.blocked`.
    blocked_reason: ?BlockedReason = null,
    session_id: ?[]u8 = null,
    /// The final reply of the latest turn that ended, null when it did not
    /// complete.
    final: ?[]u8 = null,
    final_truncated: bool = false,
    /// Turns that ended. `final` belongs to the last of them.
    turns_ended: u64 = 0,
    /// The latest `max_messages` submitted messages, oldest first.
    messages: std.ArrayList(Message) = .empty,
    /// Messages submitted in all.
    messages_total: u64 = 0,
    /// Pastes that reached the composer.
    pastes_total: u64 = 0,
    /// The prompt the child shows, if any.
    prompt: ?OpenPrompt = null,

    pub const OpenPrompt = struct {
        arena: std.heap.ArenaAllocator,
        number: u64,
        body: union(enum) {
            /// Checked like any request the parent shows.
            permission: permission_request.OwnedPermissionRequest,
            questions: []const types.QuestionBatchEntry,
        },
    };

    pub fn deinit(self: *Labels, gpa: Allocator) void {
        self.clearPrompt();
        if (self.session_id) |id| gpa.free(id);
        if (self.final) |text| gpa.free(text);
        for (self.messages.items) |message| gpa.free(message.text);
        self.messages.deinit(gpa);
        self.* = .{};
    }

    /// Applies one line (newline excluded). A line that is not a known event
    /// changes nothing and returns `error.InvalidLine`.
    pub fn apply(self: *Labels, gpa: Allocator, line: []const u8) error{ OutOfMemory, InvalidLine }!void {
        const Wire = struct {
            event: []const u8,
            id: ?[]const u8 = null,
            state: ?[]const u8 = null,
            reason: ?[]const u8 = null,
            text: ?[]const u8 = null,
            final: ?[]const u8 = null,
            truncated: bool = false,
            next: ?[]const u8 = null,
            number: ?u64 = null,
        };
        const parsed = std.json.parseFromSlice(Wire, gpa, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidLine,
        };
        defer parsed.deinit();
        const wire = parsed.value;

        if (std.mem.eql(u8, wire.event, "session")) {
            const copy = try gpa.dupe(u8, wire.id orelse return error.InvalidLine);
            if (self.session_id) |old| gpa.free(old);
            self.session_id = copy;
        } else if (std.mem.eql(u8, wire.event, "state")) {
            const state = std.meta.stringToEnum(Activity, wire.state orelse return error.InvalidLine) orelse
                return error.InvalidLine;
            self.setActivity(state);
        } else if (std.mem.eql(u8, wire.event, "prompt")) {
            try self.openPrompt(gpa, line);
        } else if (std.mem.eql(u8, wire.event, "prompt_closed")) {
            const next = std.meta.stringToEnum(Activity, wire.next orelse return error.InvalidLine) orelse
                return error.InvalidLine;
            const number = wire.number orelse return error.InvalidLine;
            if (self.prompt) |prompt| if (prompt.number == number) self.clearPrompt();
            self.setActivity(next);
        } else if (std.mem.eql(u8, wire.event, "pasted")) {
            self.pastes_total += 1;
        } else if (std.mem.eql(u8, wire.event, "message")) {
            const copy = try gpa.dupe(u8, wire.text orelse return error.InvalidLine);
            errdefer gpa.free(copy);
            if (self.messages.items.len == max_messages) gpa.free(self.messages.orderedRemove(0).text);
            try self.messages.append(gpa, .{ .text = copy, .truncated = wire.truncated });
            self.messages_total += 1;
            self.state = .working;
            self.blocked_reason = null;
        } else if (std.mem.eql(u8, wire.event, "turn_end")) {
            const next = std.meta.stringToEnum(Activity, wire.next orelse return error.InvalidLine) orelse
                return error.InvalidLine;
            const copy = if (wire.final) |text| try gpa.dupe(u8, text) else null;
            if (self.final) |old| gpa.free(old);
            self.final = copy;
            self.final_truncated = wire.truncated;
            self.turns_ended += 1;
            self.setActivity(next);
        } else {
            return error.InvalidLine;
        }
    }

    fn setActivity(self: *Labels, activity: Activity) void {
        self.state = switch (activity) {
            .idle => .idle,
            .working => .working,
        };
        self.blocked_reason = null;
    }

    /// Replaces the stored prompt with the one `line` carries.
    fn openPrompt(self: *Labels, gpa: Allocator, line: []const u8) error{ OutOfMemory, InvalidLine }!void {
        const Wire = struct {
            number: u64,
            reason: []const u8,
            permission: ?permission_request.PermissionRequest = null,
            questions: ?[]const types.QuestionBatchEntry = null,
        };
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        // Copies every string: `line` is gone once `apply` returns.
        const wire = std.json.parseFromSliceLeaky(Wire, a, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidLine,
        };
        const reason = std.meta.stringToEnum(BlockedReason, wire.reason) orelse return error.InvalidLine;
        const body: @FieldType(OpenPrompt, "body") = if (wire.permission) |request| blk: {
            if (wire.questions != null) return error.InvalidLine;
            const owned = permission_request.OwnedPermissionRequest.dupe(a, request) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidLine,
            };
            break :blk .{ .permission = owned };
        } else .{ .questions = wire.questions orelse return error.InvalidLine };
        self.clearPrompt();
        self.prompt = .{ .arena = arena, .number = wire.number, .body = body };
        self.state = .blocked;
        self.blocked_reason = reason;
    }

    fn clearPrompt(self: *Labels) void {
        if (self.prompt) |*prompt| prompt.arena.deinit();
        self.prompt = null;
    }
};

const testing = std.testing;

fn applyEvent(labels: *Labels, event: Event) !void {
    const line = try encode(testing.allocator, event);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
    try testing.expectEqual(@as(?usize, line.len - 1), std.mem.findScalar(u8, line, '\n'));
    try labels.apply(testing.allocator, line[0 .. line.len - 1]);
}

test "a child's reports become the parent's labels" {
    var labels: Labels = .{};
    defer labels.deinit(testing.allocator);
    try testing.expectEqual(State.starting, labels.state);

    try applyEvent(&labels, .{ .session = "session-1" });
    try applyEvent(&labels, .{ .state = .idle });
    try testing.expectEqualStrings("session-1", labels.session_id.?);
    try testing.expectEqual(State.idle, labels.state);

    try applyEvent(&labels, .{ .pasted = {} });
    try testing.expectEqual(@as(u64, 1), labels.pastes_total);
    try testing.expectEqual(State.idle, labels.state);
    try applyEvent(&labels, .{ .message = "fix the \"tests\"\nplease" });
    try testing.expectEqual(State.working, labels.state);
    try testing.expectEqualStrings("fix the \"tests\"\nplease", labels.messages.items[0].text);

    try applyEvent(&labels, .{ .prompt = .{ .number = 1, .reason = .permission, .body = .{ .permission = .{
        .id = 7,
        .label = "shell: rm -rf build",
        .command = "rm -rf build",
    } } } });
    try testing.expectEqual(State.blocked, labels.state);
    try testing.expectEqual(BlockedReason.permission, labels.blocked_reason.?);
    try testing.expectEqual(@as(u64, 1), labels.prompt.?.number);
    try testing.expectEqualStrings("rm -rf build", labels.prompt.?.body.permission.command.?);
    try applyEvent(&labels, .{ .prompt_closed = .{ .number = 1, .next = .working } });
    try testing.expect(labels.prompt == null);
    try testing.expectEqual(State.working, labels.state);

    try applyEvent(&labels, .{ .turn_end = .{ .final = "Done.", .next = .idle } });
    try testing.expectEqual(State.idle, labels.state);
    try testing.expect(labels.blocked_reason == null);
    try testing.expectEqualStrings("Done.", labels.final.?);
    try testing.expectEqual(@as(u64, 1), labels.turns_ended);

    // A turn that did not complete leaves no final reply, and a queued
    // message keeps the child working.
    try applyEvent(&labels, .{ .turn_end = .{ .final = null, .next = .working } });
    try testing.expect(labels.final == null);
    try testing.expectEqual(State.working, labels.state);
    try testing.expectEqual(@as(u64, 2), labels.turns_ended);
}

test "a question prompt is stored until it closes, and a close restores the activity" {
    var labels: Labels = .{};
    defer labels.deinit(testing.allocator);
    try applyEvent(&labels, .{ .state = .idle });
    const entries = [_]types.QuestionBatchEntry{.{
        .question = "Which branch?",
        .options = &.{ .{ .label = "main" }, .{ .label = "dev", .description = "unstable" } },
    }};
    try applyEvent(&labels, .{ .prompt = .{ .number = 3, .reason = .question, .body = .{ .questions = &entries } } });
    try testing.expectEqual(State.blocked, labels.state);
    const stored = labels.prompt.?.body.questions;
    try testing.expectEqualStrings("Which branch?", stored[0].question);
    try testing.expectEqualStrings("unstable", stored[0].options[1].description.?);
    // A close for another prompt leaves this one.
    try applyEvent(&labels, .{ .prompt_closed = .{ .number = 2, .next = .idle } });
    try testing.expect(labels.prompt != null);
    try applyEvent(&labels, .{ .prompt_closed = .{ .number = 3, .next = .idle } });
    try testing.expect(labels.prompt == null);
    try testing.expectEqual(State.idle, labels.state);
}

test "answers go to the child and back unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]Answer{
        .{ .prompt = 4, .reply = .{ .permission = .{ .decision = .always, .feedback = "use a temp dir" } } },
        .{ .prompt = 5, .reply = .{ .permission = .{ .decision = .deny } } },
        .{ .prompt = 6, .reply = .{ .questions = &.{ "main", "free text\nwith a newline" } } },
        .{ .prompt = 7, .reply = .{ .questions = null } },
    };
    for (cases) |answer| {
        const line = try encodeAnswer(testing.allocator, answer, 16 * 1024);
        defer testing.allocator.free(line);
        try testing.expect(std.mem.findScalar(u8, line, '\n') == null);
        const back = try parseAnswer(arena, line);
        try testing.expectEqual(answer.prompt, back.prompt);
        switch (answer.reply) {
            .permission => |permission| {
                try testing.expectEqual(permission.decision, back.reply.permission.decision);
                if (permission.feedback) |text| try testing.expectEqualStrings(text, back.reply.permission.feedback.?);
            },
            .questions => |answers| if (answers) |list| {
                for (list, back.reply.questions.?) |want, got| try testing.expectEqualStrings(want, got);
            } else try testing.expect(back.reply.questions == null),
        }
    }
    try testing.expectError(error.AnswerTooLong, encodeAnswer(testing.allocator, cases[0], 16));
    try testing.expectError(error.InvalidLine, parseAnswer(arena, "{\"kind\":\"permission\",\"prompt\":1,\"decision\":\"maybe\"}"));
}

test "a context line reaches the child and is never taken for an answer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const context = "current_request: fix the \"build\"\n";
    const line = try encodeContext(testing.allocator, context, 16 * 1024);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings(context, (try parseContext(arena, line)).?);
    try testing.expectError(error.InvalidLine, parseAnswer(arena, line));

    const answer = try encodeAnswer(testing.allocator, .{ .prompt = 1, .reply = .{ .questions = null } }, 16 * 1024);
    defer testing.allocator.free(answer);
    try testing.expectEqual(@as(?[]const u8, null), try parseContext(arena, answer));
    try testing.expectEqual(@as(?[]const u8, null), try parseContext(arena, "not json"));
    try testing.expectError(error.AnswerTooLong, encodeContext(testing.allocator, context, 8));
}

test "the tracker numbers prompts and takes one answer, for the open prompt only" {
    var tracker: PromptTracker = .{};
    try testing.expectEqual(PromptTracker.Change{ .opened = 1 }, tracker.observe(.{ .permission = 40 }));
    try testing.expectEqual(PromptTracker.Change{}, tracker.observe(.{ .permission = 40 }));
    try testing.expect(tracker.take(2) == null);
    try testing.expectEqual(PromptTracker.Key{ .permission = 40 }, tracker.take(1).?);
    try testing.expect(tracker.take(1) == null);
    // One prompt replaced by another in a single tick: both are reported.
    try testing.expectEqual(PromptTracker.Change{ .closed = 1, .opened = 2 }, tracker.observe(.{ .questions = 9 }));
    try testing.expect(tracker.take(1) == null);
    try testing.expectEqual(PromptTracker.Change{ .closed = 2 }, tracker.observe(null));
    try testing.expect(tracker.take(2) == null);
}

test "long text is cut at a character boundary and marked" {
    var labels: Labels = .{};
    defer labels.deinit(testing.allocator);
    const text = try testing.allocator.alloc(u8, max_text + 2);
    defer testing.allocator.free(text);
    @memset(text, 'a');
    // A two-byte character straddles the limit.
    text[max_text - 1] = 0xC3;
    text[max_text] = 0xA9;
    try applyEvent(&labels, .{ .turn_end = .{ .final = text, .next = .idle } });
    try testing.expect(labels.final_truncated);
    try testing.expectEqual(@as(usize, max_text - 1), labels.final.?.len);
    try testing.expect(std.unicode.utf8ValidateSlice(labels.final.?));
}

test "invalid UTF-8 is replaced so the line still parses" {
    var labels: Labels = .{};
    defer labels.deinit(testing.allocator);
    try applyEvent(&labels, .{ .turn_end = .{ .final = "ok \xff\xfe end", .next = .idle } });
    try testing.expectEqual(State.idle, labels.state);
    try testing.expect(std.unicode.utf8ValidateSlice(labels.final.?));
    try testing.expect(std.mem.startsWith(u8, labels.final.?, "ok "));
    try testing.expect(std.mem.endsWith(u8, labels.final.?, " end"));
    try testing.expect(std.mem.find(u8, labels.final.?, "\u{FFFD}") != null);
}

test "the store keeps the latest messages" {
    var labels: Labels = .{};
    defer labels.deinit(testing.allocator);
    var name: [16]u8 = undefined;
    for (0..max_messages + 3) |i| {
        try applyEvent(&labels, .{ .message = try std.fmt.bufPrint(&name, "m{d}", .{i}) });
    }
    try testing.expectEqual(@as(u64, max_messages + 3), labels.messages_total);
    try testing.expectEqual(@as(usize, max_messages), labels.messages.items.len);
    try testing.expectEqualStrings("m3", labels.messages.items[0].text);
}

test "a line that is not a known event changes nothing" {
    var labels: Labels = .{};
    defer labels.deinit(testing.allocator);
    for ([_][]const u8{
        "",
        "not json",
        "{}",
        "{\"event\":\"nope\"}",
        "{\"event\":\"state\",\"state\":\"starting\"}",
        "{\"event\":\"state\",\"state\":\"blocked\"}",
        "{\"event\":\"prompt\",\"number\":1,\"reason\":\"question\"}",
        "{\"event\":\"prompt\",\"number\":1,\"reason\":\"permission\",\"permission\":{}}",
        "{\"event\":\"prompt_closed\",\"next\":\"idle\"}",
        "{\"event\":\"turn_end\",\"next\":\"later\"}",
        "{\"event\":\"session\"}",
    }) |line| {
        try testing.expectError(error.InvalidLine, labels.apply(testing.allocator, line));
    }
    try testing.expectEqual(State.starting, labels.state);
    try testing.expectEqual(@as(u64, 0), labels.turns_ended);
}

// Random runs drive the store the way a child's two threads and its
// reporter lock do: the UI thread queues and reports messages and reports
// each prompt's opening and closing, the worker begins turns, steers queued
// messages into them and reports each turn end with the state that follows,
// and the parent applies lines in order. Lines are real `encode` output
// applied by `Labels.apply`. After every step the test checks that, once
// every line is applied and no report is midway, the store says idle exactly
// when no turn runs, nothing is queued and no prompt is open, and blocked
// exactly when a prompt is open; that the final reply belongs to the latest
// ended turn; and that messages arrive in order.
//
/// Messages and prompts per run, small so that runs cover many orderings.
const run_messages = 3;
const run_blocks = 2;

const Sim = struct {
    const Ui = enum { none, locked, queued };
    const Worker = enum { none, locked, checked };
    const Lock = enum { free, ui, worker };
    const PromptPhase = enum { none, open, resolved };

    gpa: Allocator,
    queue: std.ArrayList(u64) = .empty,
    sent: u64 = 0,
    ui: Ui = .none,
    running: u64 = 0,
    turns: u64 = 0,
    worker: Worker = .none,
    next: Activity = .idle,
    lock: Lock = .free,
    blocks: u64 = 0,
    prompt: PromptPhase = .none,
    /// The activity the reporter last wrote.
    reported: Activity = .idle,
    pipe: std.ArrayList([]u8) = .empty,
    labels: Labels = .{},

    fn deinit(self: *Sim) void {
        self.queue.deinit(self.gpa);
        for (self.pipe.items) |line| self.gpa.free(line);
        self.pipe.deinit(self.gpa);
        self.labels.deinit(self.gpa);
    }

    fn write(self: *Sim, event: Event) !void {
        try self.pipe.append(self.gpa, try encode(self.gpa, event));
    }

    /// The turn whose reply the store holds, or 0.
    fn finalTurn(self: Sim) !u64 {
        const text = self.labels.final orelse return 0;
        return std.fmt.parseInt(u64, text[1..], 10);
    }

    fn check(self: Sim) !void {
        if (self.pipe.items.len == 0 and self.ui == .none and self.worker == .none and self.prompt != .resolved) {
            const settled = self.running == 0 and self.queue.items.len == 0;
            try testing.expectEqual(settled and self.prompt == .none, self.labels.state == .idle);
            try testing.expectEqual(self.prompt == .open, self.labels.state == .blocked);
        }
        try testing.expectEqual(self.labels.turns_ended, try self.finalTurn());
        var name: [16]u8 = undefined;
        for (self.labels.messages.items, 1..) |message, i| {
            try testing.expectEqualStrings(try std.fmt.bufPrint(&name, "m{d}", .{i}), message.text);
        }
    }
};

fn runRandom(gpa: Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var sim: Sim = .{ .gpa = gpa };
    defer sim.deinit();
    // The child reports idle once it is ready for input.
    try sim.write(.{ .state = .idle });

    var name: [16]u8 = undefined;
    while (true) {
        var choices: Choices(Action) = .{};
        const worker_free = sim.worker == .none and sim.queue.items.len > 0;
        choices.add(sim.ui == .none and sim.sent < run_messages and sim.prompt != .open and sim.lock == .free, .SubmitLock);
        choices.add(sim.ui == .locked, .SubmitQueue);
        choices.add(sim.ui == .queued, .SubmitReport);
        choices.add(sim.ui == .none and sim.prompt == .none and sim.blocks < run_blocks and sim.lock == .free, .Block);
        choices.add(sim.prompt == .open, .Resolve);
        choices.add(sim.prompt == .resolved and sim.ui == .none and sim.lock == .free, .ReportClosed);
        choices.add(worker_free and sim.running == 0 and sim.prompt != .open, .Begin);
        choices.add(worker_free and sim.running != 0, .Steer);
        choices.add(sim.running != 0 and sim.worker == .none and sim.prompt != .open and sim.lock == .free, .TurnEndLock);
        choices.add(sim.worker == .locked, .TurnEndCheck);
        choices.add(sim.worker == .checked, .TurnEndReport);
        choices.add(sim.pipe.items.len > 0, .Apply);
        if (choices.len == 0) break;

        const action = choices.items[random.uintLessThan(usize, choices.len)];
        switch (action) {
            .SubmitLock => {
                sim.lock = .ui;
                sim.ui = .locked;
                sim.sent += 1;
            },
            .SubmitQueue => {
                try sim.queue.append(gpa, sim.sent);
                sim.ui = .queued;
            },
            .SubmitReport => {
                try sim.write(.{ .message = try std.fmt.bufPrint(&name, "m{d}", .{sim.sent}) });
                sim.reported = .working;
                sim.lock = .free;
                sim.ui = .none;
            },
            .Block => {
                sim.blocks += 1;
                try sim.write(.{ .prompt = .{ .number = sim.blocks, .reason = .permission, .body = .{
                    .permission = .{ .id = sim.blocks, .label = "shell" },
                } } });
                sim.prompt = .open;
            },
            .Resolve => sim.prompt = .resolved,
            .ReportClosed => {
                try sim.write(.{ .prompt_closed = .{ .number = sim.blocks, .next = sim.reported } });
                sim.prompt = .none;
            },
            .Begin => {
                _ = sim.queue.orderedRemove(0);
                sim.turns += 1;
                sim.running = sim.turns;
            },
            .Steer => _ = sim.queue.orderedRemove(0),
            .TurnEndLock => {
                sim.lock = .worker;
                sim.worker = .locked;
            },
            .TurnEndCheck => {
                sim.next = if (sim.queue.items.len > 0) .working else .idle;
                sim.worker = .checked;
            },
            .TurnEndReport => {
                const final = try std.fmt.bufPrint(&name, "t{d}", .{sim.running});
                try sim.write(.{ .turn_end = .{ .final = final, .next = sim.next } });
                sim.reported = sim.next;
                sim.running = 0;
                sim.lock = .free;
                sim.worker = .none;
            },
            .Apply => {
                const line = sim.pipe.orderedRemove(0);
                defer gpa.free(line);
                try sim.labels.apply(gpa, line[0 .. line.len - 1]);
            },
        }
        try sim.check();
    }
}

/// The steps a random run chooses from.
const Action = enum {
    SubmitLock,
    SubmitQueue,
    SubmitReport,
    Block,
    Resolve,
    ReportClosed,
    Begin,
    Steer,
    TurnEndLock,
    TurnEndCheck,
    TurnEndReport,
    Apply,
};

fn Choices(comptime A: type) type {
    return struct {
        items: [@typeInfo(A).@"enum".fields.len]A = undefined,
        len: usize = 0,

        fn add(self: *@This(), enabled: bool, action: A) void {
            if (!enabled) return;
            self.items[self.len] = action;
            self.len += 1;
        }
    };
}

test "random runs keep the labels' rules" {
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) try runRandom(testing.allocator, seed);
}

// Random runs drive one child's prompts: the child opens prompts and may
// close one itself or have it answered on its own screen, the parent applies
// the reports in order, and the user answers what main shows. The child's side is the real `PromptTracker`, reports are
// real `encode` lines applied by `Labels.apply`, and answers are real
// `encodeAnswer` lines read back with `parseAnswer`. After every step the
// test checks that no prompt closed twice, that an answer from main closed
// only the prompt it was shown for, and that once every report is applied
// main holds exactly the child's open prompt.

const run_prompts = 3;

const PromptSim = struct {
    gpa: Allocator,
    tracker: PromptTracker = .{},
    /// The prompt the child's UI shows, by the number the tracker gave it.
    showing: ?u64 = null,
    opened: u64 = 0,
    closes: [run_prompts]u64 = @splat(0),
    to_parent: std.ArrayList([]u8) = .empty,
    to_child: std.ArrayList([]u8) = .empty,
    answered: std.ArrayList(u64) = .empty,
    misapplied: bool = false,
    labels: Labels = .{},

    fn deinit(self: *PromptSim) void {
        for (self.to_parent.items) |line| self.gpa.free(line);
        self.to_parent.deinit(self.gpa);
        for (self.to_child.items) |line| self.gpa.free(line);
        self.to_child.deinit(self.gpa);
        self.answered.deinit(self.gpa);
        self.labels.deinit(self.gpa);
    }

    /// The parent's prompt for this child, or 0.
    fn shown(self: PromptSim) u64 {
        const prompt = self.labels.prompt orelse return 0;
        return prompt.number;
    }

    fn isAnswered(self: PromptSim, number: u64) bool {
        return std.mem.findScalar(u64, self.answered.items, number) != null;
    }

    /// The child's UI shows `showing` now; the tracker reports the change.
    fn observe(self: *PromptSim) !void {
        const key: ?PromptTracker.Key = if (self.showing) |number| .{ .permission = number } else null;
        const change = self.tracker.observe(key);
        if (change.closed) |number| try self.write(.{ .prompt_closed = .{ .number = number, .next = .working } });
        if (change.opened) |number| try self.write(.{ .prompt = .{ .number = number, .reason = .permission, .body = .{
            .permission = .{ .id = number, .label = "shell" },
        } } });
    }

    fn write(self: *PromptSim, event: Event) !void {
        try self.to_parent.append(self.gpa, try encode(self.gpa, event));
    }

    /// The open prompt closes, and the child reports it.
    fn close(self: *PromptSim) !void {
        const number = self.showing.?;
        self.closes[number - 1] += 1;
        self.showing = null;
        try self.observe();
    }

    fn check(self: PromptSim) !void {
        for (self.closes) |count| try testing.expect(count <= 1);
        try testing.expect(!self.misapplied);
        if (self.to_parent.items.len == 0) try testing.expectEqual(self.showing orelse 0, self.shown());
    }
};

const PromptAction = enum {
    ChildOpens,
    ChildCancels,
    UserAnswersOnChild,
    ChildReadsAnswer,
    AgentTypes,
    ParentApplies,
    UserAnswersOnMain,
};

fn runPrompts(gpa: Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var sim: PromptSim = .{ .gpa = gpa };
    defer sim.deinit();

    while (true) {
        var choices: Choices(PromptAction) = .{};
        const shown = sim.shown();
        choices.add(sim.showing == null and sim.opened < run_prompts, .ChildOpens);
        choices.add(sim.showing != null, .ChildCancels);
        choices.add(sim.showing != null, .UserAnswersOnChild);
        choices.add(sim.to_child.items.len > 0, .ChildReadsAnswer);
        choices.add(sim.showing != null, .AgentTypes);
        choices.add(sim.to_parent.items.len > 0, .ParentApplies);
        choices.add(shown != 0 and !sim.isAnswered(shown), .UserAnswersOnMain);
        if (choices.len == 0) break;

        const action = choices.items[random.uintLessThan(usize, choices.len)];
        switch (action) {
            .ChildOpens => {
                sim.opened += 1;
                sim.showing = sim.opened;
                try sim.observe();
            },
            .ChildCancels => try sim.close(),
            .UserAnswersOnChild => try sim.close(),
            .ChildReadsAnswer => {
                const line = sim.to_child.orderedRemove(0);
                defer gpa.free(line);
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const answer = try parseAnswer(arena.allocator(), line);
                if (sim.tracker.take(answer.prompt)) |key| {
                    sim.misapplied = sim.misapplied or key.permission != answer.prompt or sim.showing != answer.prompt;
                    try sim.close();
                }
            },
            // Typed text lands in the prompt's draft at most.
            .AgentTypes => {},
            .ParentApplies => {
                const line = sim.to_parent.orderedRemove(0);
                defer gpa.free(line);
                try sim.labels.apply(gpa, line[0 .. line.len - 1]);
            },
            .UserAnswersOnMain => {
                try sim.answered.append(gpa, shown);
                try sim.to_child.append(gpa, try encodeAnswer(gpa, .{
                    .prompt = shown,
                    .reply = .{ .permission = .{ .decision = .once } },
                }, 16 * 1024));
            },
        }
        try sim.check();
    }
}

test "random runs keep the prompts' rules" {
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) try runPrompts(testing.allocator, seed);
}

//! Merges the results of every hook that ran for one event into one outcome.

const std = @import("std");
const event = @import("event.zig");
const answer = @import("answer.zig");
const limits = @import("limits.zig");

/// How much of a failure detail goes into a notice.
const notice_detail_chars: usize = 1_000;

/// One notice before its slices are copied into the outcome. All slices are borrowed.
const PendingNotice = struct { kind: answer.NoticeKind, hook_id: []const u8, text: []const u8 };

/// Collects notices and owns every string it allocates while the merge runs.
const Builder = struct {
    alloc: std.mem.Allocator,
    /// Every string allocated so far, freed when the merge ends.
    scratch: std.ArrayList([]u8) = .empty,
    /// Notices in the order they were added. Their text points into scratch.
    pending: std.ArrayList(PendingNotice) = .empty,

    fn deinit(self: *Builder) void {
        for (self.scratch.items) |text| self.alloc.free(text);
        self.scratch.deinit(self.alloc);
        self.pending.deinit(self.alloc);
    }

    /// Takes ownership of `text` and returns it as a borrowed slice.
    fn keep(self: *Builder, text: []u8) std.mem.Allocator.Error![]const u8 {
        self.scratch.append(self.alloc, text) catch |err| {
            self.alloc.free(text);
            return err;
        };
        return text;
    }

    fn format(self: *Builder, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error![]const u8 {
        return self.keep(try self.alloc.print(fmt, args));
    }

    fn addFormatted(
        self: *Builder,
        kind: answer.NoticeKind,
        hook_id: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) std.mem.Allocator.Error!void {
        const text = try self.format(fmt, args);
        try self.pending.append(self.alloc, .{ .kind = kind, .hook_id = hook_id, .text = text });
    }

    fn cutNotice(self: *Builder, hook_id: []const u8, what: []const u8) std.mem.Allocator.Error!void {
        try self.addFormatted(.cut, hook_id, "{s}: the {s} was cut to {d} characters", .{ hook_id, what, limits.text_chars });
    }

    /// Describes what went wrong, for a failure notice and a blocking reason.
    fn failureWhat(self: *Builder, failure: answer.Failure) std.mem.Allocator.Error![]const u8 {
        const detail = limits.cutChars(failure.detail, notice_detail_chars).text;
        return switch (failure.kind) {
            .spawn_failed => self.format("could not start: {s}", .{detail}),
            .timed_out => self.format("timed out", .{}),
            .cancelled => self.format("was cancelled", .{}),
            .exit_code => self.exitCodeWhat(failure, detail),
            .signaled => self.signaledWhat(failure, detail),
            .invalid_output => self.format("returned output fx could not read: {s}", .{detail}),
            .output_too_large => self.format("wrote more output than fx reads", .{}),
        };
    }

    fn exitCodeWhat(self: *Builder, failure: answer.Failure, detail: []const u8) std.mem.Allocator.Error![]const u8 {
        const code = failure.exit_code.?;
        if (detail.len > 0) return self.format("exited with code {d}: {s}", .{ code, detail });
        return self.format("exited with code {d}", .{code});
    }

    /// A process that a signal stopped did not exit, so its text names the signal, not a code.
    fn signaledWhat(self: *Builder, failure: answer.Failure, detail: []const u8) std.mem.Allocator.Error![]const u8 {
        const signal = failure.signal.?;
        if (detail.len > 0) return self.format("was stopped by signal {d}: {s}", .{ signal, detail });
        return self.format("was stopped by signal {d}", .{signal});
    }
};

/// Whether this event accepts the decision.
fn accepts(caps: event.Capabilities, decision: answer.Decision) bool {
    return switch (decision) {
        .proceed => true,
        .allow => caps.allow,
        .ask => caps.ask,
        .deny => caps.deny,
    };
}

/// The word a dropped decision is named by in a notice.
fn decisionWord(decision: answer.Decision) []const u8 {
    return switch (decision) {
        .proceed => "proceed",
        .allow => "allow",
        .ask => "ask",
        .deny => "deny",
    };
}

/// Copies the pending notices into an owned slice. On error nothing is left allocated.
fn buildNotices(alloc: std.mem.Allocator, pending: []const PendingNotice) std.mem.Allocator.Error![]answer.Notice {
    const notices = try alloc.alloc(answer.Notice, pending.len);
    var filled: usize = 0;
    errdefer {
        for (notices[0..filled]) |notice| {
            alloc.free(notice.hook_id);
            alloc.free(notice.text);
        }
        alloc.free(notices);
    }
    for (pending, 0..) |item, index| {
        const hook_id = try alloc.dupe(u8, item.hook_id);
        errdefer alloc.free(hook_id);
        notices[index] = .{
            .kind = item.kind,
            .hook_id = hook_id,
            .text = try alloc.dupe(u8, item.text),
        };
        filled += 1;
    }
    return notices;
}

/// Merges `results`, which must be in config order, into one outcome for `name`.
/// The outcome owns its memory; the caller frees it with `Outcome.deinit(alloc)`.
/// When both `stop_reason` and `continue_reason` are set, the caller stops.
pub fn merge(
    alloc: std.mem.Allocator,
    name: event.EventName,
    results: []const answer.HandlerResult,
) std.mem.Allocator.Error!answer.Outcome {
    const caps = name.capabilities();
    const file_name = name.fileName();

    var builder: Builder = .{ .alloc = alloc };
    defer builder.deinit();

    // Pass 1: normalize each answer against what the event accepts.
    const effective = try alloc.alloc(answer.Answer, results.len);
    defer alloc.free(effective);

    for (results, 0..) |result, index| {
        effective[index] = .{};
        switch (result.result) {
            .failure => |failure| {
                const what = try builder.failureWhat(failure);
                try builder.addFormatted(.failure, result.hook_id, "{s} failed: {s}", .{ result.hook_id, what });
                if (result.on_failure == .block and caps.deny) {
                    const reason = try builder.format("{s} failed and is set to block on failure: {s}", .{ result.hook_id, what });
                    effective[index] = .{ .decision = .deny, .reason = reason };
                }
            },
            .answer => |given| {
                var eff = given;
                if (given.decision != .proceed and !accepts(caps, given.decision)) {
                    try builder.addFormatted(.dropped, result.hook_id, "{s} returned {s}, which {s} does not accept", .{
                        result.hook_id,
                        decisionWord(given.decision),
                        file_name,
                    });
                    eff.decision = .proceed;
                    eff.reason = null;
                }
                if (given.updated_input != null and !caps.rewrite) {
                    try builder.addFormatted(.dropped, result.hook_id, "{s} returned updated input, which {s} does not accept", .{ result.hook_id, file_name });
                    eff.updated_input = null;
                }
                if (given.additional_context != null and !caps.context) {
                    try builder.addFormatted(.dropped, result.hook_id, "{s} returned added context, which {s} does not accept", .{ result.hook_id, file_name });
                    eff.additional_context = null;
                }
                if (given.continue_reason != null and !caps.continue_turn) {
                    try builder.addFormatted(.dropped, result.hook_id, "{s} returned a continue request, which {s} does not accept", .{ result.hook_id, file_name });
                    eff.continue_reason = null;
                }
                if (given.stop_reason != null and !caps.stop_turn) {
                    try builder.addFormatted(.dropped, result.hook_id, "{s} returned a stop request, which {s} does not accept", .{ result.hook_id, file_name });
                    eff.stop_reason = null;
                }
                if (given.updated_output != null and !caps.replace_output) {
                    try builder.addFormatted(.dropped, result.hook_id, "{s} returned replacement output, which {s} does not accept", .{ result.hook_id, file_name });
                    eff.updated_output = null;
                }
                if (given.retry and !caps.retry) {
                    try builder.addFormatted(.dropped, result.hook_id, "{s} returned a retry request, which {s} does not accept", .{ result.hook_id, file_name });
                    eff.retry = false;
                }
                if (given.system_message) |message| {
                    const cut = limits.cutChars(message, limits.text_chars);
                    try builder.addFormatted(.message, result.hook_id, "{s}", .{cut.text});
                    if (cut.was_cut) try builder.cutNotice(result.hook_id, "message");
                }
                effective[index] = eff;
            },
        }
    }

    var outcome = answer.Outcome{};
    errdefer outcome.deinit(alloc);

    // Pass 2: merge the effective answers in order.

    var strongest: answer.Decision = .proceed;
    for (effective) |eff| {
        if (eff.decision.strictness() > strongest.strictness()) strongest = eff.decision;
    }
    if (strongest != .proceed) {
        var winner: usize = 0;
        while (effective[winner].decision != strongest) winner += 1;
        outcome.decision = strongest;
        outcome.decided_by = try alloc.dupe(u8, results[winner].hook_id);
        if (effective[winner].reason) |reason| {
            const cut = limits.cutChars(reason, limits.text_chars);
            outcome.reason = try alloc.dupe(u8, cut.text);
            if (cut.was_cut) try builder.cutNotice(results[winner].hook_id, "reason");
        }
    }

    if (outcome.decision != .deny) {
        for (effective) |eff| {
            if (eff.updated_input) |text| {
                outcome.updated_input = try alloc.dupe(u8, text);
                break;
            }
        }
    }

    var context: std.ArrayList(u8) = .empty;
    defer context.deinit(alloc);
    var has_context = false;
    for (effective, 0..) |eff, index| {
        if (eff.additional_context) |text| {
            const cut = limits.cutChars(text, limits.text_chars);
            if (cut.was_cut) try builder.cutNotice(results[index].hook_id, "added context");
            if (has_context) try context.appendSlice(alloc, "\n\n");
            try context.appendSlice(alloc, cut.text);
            has_context = true;
        }
    }
    if (has_context) outcome.additional_context = try alloc.dupe(u8, context.items);

    for (effective, 0..) |eff, index| {
        if (eff.continue_reason) |text| {
            const cut = limits.cutChars(text, limits.text_chars);
            outcome.continue_reason = try alloc.dupe(u8, cut.text);
            if (cut.was_cut) try builder.cutNotice(results[index].hook_id, "continue text");
            break;
        }
    }

    for (effective, 0..) |eff, index| {
        if (eff.stop_reason) |text| {
            const cut = limits.cutChars(text, limits.text_chars);
            outcome.stop_reason = try alloc.dupe(u8, cut.text);
            if (cut.was_cut) try builder.cutNotice(results[index].hook_id, "stop reason");
            break;
        }
    }

    for (effective) |eff| {
        if (eff.updated_output) |text| {
            outcome.updated_output = try alloc.dupe(u8, text);
            break;
        }
    }

    for (effective) |eff| {
        if (eff.retry) {
            outcome.retry = true;
            break;
        }
    }

    outcome.ran = results.len;
    if (builder.pending.items.len > 0) outcome.notices = try buildNotices(alloc, builder.pending.items);

    return outcome;
}

test "merge reports a deny that SessionStart does not accept" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        answered("guard", .{ .decision = .deny, .reason = "no" }),
    };
    var outcome = try merge(alloc, .session_start, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.proceed, outcome.decision);
    try std.testing.expect(outcome.reason == null);
    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.dropped, outcome.notices[0].kind);
    try std.testing.expectEqualStrings("guard returned deny, which SessionStart does not accept", outcome.notices[0].text);
}

test "merge names the signal that stopped a hook, with its first stderr line when there is one" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        failed("sig", .proceed, .{ .kind = .signaled, .signal = 9, .detail = "boom" }),
        failed("kill", .proceed, .{ .kind = .signaled, .signal = 15 }),
    };
    var outcome = try merge(alloc, .pre_tool_use, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), outcome.notices.len);
    try std.testing.expectEqualStrings("sig failed: was stopped by signal 9: boom", outcome.notices[0].text);
    try std.testing.expectEqualStrings("kill failed: was stopped by signal 15", outcome.notices[1].text);
}

fn answered(hook_id: []const u8, given: answer.Answer) answer.HandlerResult {
    return .{ .hook_id = hook_id, .result = .{ .answer = given } };
}

fn failed(hook_id: []const u8, on_failure: answer.OnFailure, failure: answer.Failure) answer.HandlerResult {
    return .{ .hook_id = hook_id, .on_failure = on_failure, .result = .{ .failure = failure } };
}

test "merge with no results leaves the defaults" {
    const alloc = std.testing.allocator;
    var outcome = try merge(alloc, .pre_tool_use, &.{});
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.proceed, outcome.decision);
    try std.testing.expect(outcome.reason == null);
    try std.testing.expect(outcome.decided_by == null);
    try std.testing.expect(outcome.updated_input == null);
    try std.testing.expect(outcome.additional_context == null);
    try std.testing.expect(outcome.continue_reason == null);
    try std.testing.expect(outcome.stop_reason == null);
    try std.testing.expect(outcome.updated_output == null);
    try std.testing.expect(!outcome.retry);
    try std.testing.expectEqual(@as(usize, 0), outcome.notices.len);
    try std.testing.expectEqual(@as(usize, 0), outcome.ran);
}

test "merge takes the strictest decision from the first hook that made it" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        answered("A", .{ .decision = .allow }),
        answered("B", .{ .decision = .deny, .reason = "no" }),
        answered("C", .{ .decision = .ask }),
    };
    var outcome = try merge(alloc, .pre_tool_use, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.deny, outcome.decision);
    try std.testing.expectEqualStrings("B", outcome.decided_by.?);
    try std.testing.expectEqualStrings("no", outcome.reason.?);
    try std.testing.expectEqual(@as(usize, 3), outcome.ran);
    try std.testing.expectEqual(@as(usize, 0), outcome.notices.len);
}

test "merge keeps the reason of the first hook at the strongest decision" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        answered("A", .{ .decision = .deny, .reason = "a" }),
        answered("B", .{ .decision = .deny, .reason = "b" }),
    };
    var outcome = try merge(alloc, .pre_tool_use, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.deny, outcome.decision);
    try std.testing.expectEqualStrings("A", outcome.decided_by.?);
    try std.testing.expectEqualStrings("a", outcome.reason.?);
}

test "merge takes the first updated input unless the turn is denied" {
    const alloc = std.testing.allocator;
    const rewrites = [_]answer.HandlerResult{
        answered("A", .{ .updated_input = "{\"x\":1}" }),
        answered("B", .{ .updated_input = "{\"x\":2}" }),
    };
    var rewritten = try merge(alloc, .pre_tool_use, &rewrites);
    defer rewritten.deinit(alloc);
    try std.testing.expectEqualStrings("{\"x\":1}", rewritten.updated_input.?);

    const denied = [_]answer.HandlerResult{
        answered("A", .{ .updated_input = "{\"x\":1}" }),
        answered("B", .{ .updated_input = "{\"x\":2}" }),
        answered("C", .{ .decision = .deny, .reason = "no" }),
    };
    var blocked = try merge(alloc, .pre_tool_use, &denied);
    defer blocked.deinit(alloc);
    try std.testing.expect(blocked.updated_input == null);
}

test "merge joins added context in order" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        answered("A", .{ .additional_context = "one" }),
        answered("B", .{ .additional_context = "two" }),
    };
    var outcome = try merge(alloc, .pre_tool_use, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqualStrings("one\n\ntwo", outcome.additional_context.?);
    try std.testing.expectEqual(@as(usize, 0), outcome.notices.len);
}

test "merge drops what the event does not accept" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        answered("A", .{ .decision = .deny, .reason = "r", .additional_context = "c", .continue_reason = "go" }),
    };
    var outcome = try merge(alloc, .stop, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.proceed, outcome.decision);
    try std.testing.expect(outcome.reason == null);
    try std.testing.expect(outcome.additional_context == null);
    try std.testing.expectEqualStrings("go", outcome.continue_reason.?);
    try std.testing.expectEqual(@as(usize, 2), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.dropped, outcome.notices[0].kind);
    try std.testing.expectEqual(answer.NoticeKind.dropped, outcome.notices[1].kind);
    try std.testing.expectEqualStrings("A returned deny, which Stop does not accept", outcome.notices[0].text);
    try std.testing.expectEqualStrings("A", outcome.notices[0].hook_id);
}

test "merge notes a failure that lets the action run" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        failed("A", .proceed, .{ .kind = .timed_out }),
    };
    var outcome = try merge(alloc, .pre_tool_use, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.proceed, outcome.decision);
    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.failure, outcome.notices[0].kind);
    try std.testing.expectEqualStrings("A failed: timed out", outcome.notices[0].text);
}

test "merge turns a blocking failure into a deny" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        failed("A", .block, .{ .kind = .exit_code, .exit_code = 1, .detail = "boom" }),
    };
    var outcome = try merge(alloc, .pre_tool_use, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.deny, outcome.decision);
    try std.testing.expectEqualStrings("A", outcome.decided_by.?);
    try std.testing.expectEqualStrings("A failed and is set to block on failure: exited with code 1: boom", outcome.reason.?);
    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.failure, outcome.notices[0].kind);
    try std.testing.expectEqualStrings("A failed: exited with code 1: boom", outcome.notices[0].text);
}

test "merge cannot block on an event that does not deny" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        failed("A", .block, .{ .kind = .spawn_failed, .detail = "no such file" }),
    };
    var outcome = try merge(alloc, .post_compact, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.proceed, outcome.decision);
    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.failure, outcome.notices[0].kind);
    try std.testing.expectEqualStrings("A failed: could not start: no such file", outcome.notices[0].text);
}

test "merge drops an ask that the event does not take" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        answered("A", .{ .decision = .ask }),
    };
    var outcome = try merge(alloc, .permission_request, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.proceed, outcome.decision);
    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.dropped, outcome.notices[0].kind);
    try std.testing.expectEqualStrings("A returned ask, which PermissionRequest does not accept", outcome.notices[0].text);
}

test "merge cuts long added context" {
    const alloc = std.testing.allocator;
    const long = try alloc.alloc(u8, 10_005);
    defer alloc.free(long);
    @memset(long, 'a');

    const results = [_]answer.HandlerResult{
        answered("A", .{ .additional_context = long }),
    };
    var outcome = try merge(alloc, .pre_tool_use, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 10_000), outcome.additional_context.?.len);
    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.cut, outcome.notices[0].kind);
    try std.testing.expectEqualStrings("A: the added context was cut to 10000 characters", outcome.notices[0].text);
}

test "merge shows a system message to the user" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        answered("A", .{ .system_message = "hi" }),
    };
    var outcome = try merge(alloc, .notification, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.message, outcome.notices[0].kind);
    try std.testing.expectEqualStrings("A", outcome.notices[0].hook_id);
    try std.testing.expectEqualStrings("hi", outcome.notices[0].text);
}

test "merge keeps a retry only where the event accepts one" {
    const alloc = std.testing.allocator;
    const accepted = [_]answer.HandlerResult{
        answered("A", .{}),
        answered("B", .{ .retry = true }),
    };
    var retried = try merge(alloc, .permission_denied, &accepted);
    defer retried.deinit(alloc);
    try std.testing.expect(retried.retry);

    const rejected = [_]answer.HandlerResult{
        answered("A", .{ .retry = true }),
    };
    var dropped = try merge(alloc, .post_tool_use, &rejected);
    defer dropped.deinit(alloc);
    try std.testing.expect(!dropped.retry);
    try std.testing.expectEqual(@as(usize, 1), dropped.notices.len);
    try std.testing.expectEqualStrings("A returned a retry request, which PostToolUse does not accept", dropped.notices[0].text);
}

test "merge keeps a stop reason and drops a continue request on a prompt submit" {
    const alloc = std.testing.allocator;
    const results = [_]answer.HandlerResult{
        answered("A", .{ .stop_reason = "halt" }),
        answered("B", .{ .continue_reason = "go" }),
    };
    var outcome = try merge(alloc, .user_prompt_submit, &results);
    defer outcome.deinit(alloc);

    try std.testing.expectEqualStrings("halt", outcome.stop_reason.?);
    try std.testing.expect(outcome.continue_reason == null);
    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.dropped, outcome.notices[0].kind);
    try std.testing.expectEqualStrings("B returned a continue request, which UserPromptSubmit does not accept", outcome.notices[0].text);
}

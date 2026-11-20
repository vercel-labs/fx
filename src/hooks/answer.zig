//! What one hook answered, and the outcome fx acts on after it merges every answer.

const std = @import("std");

/// The stance a hook takes on an action. Proceed means the hook has no opinion.
pub const Decision = enum {
    proceed,
    allow,
    ask,
    deny,

    /// The order that decides which stance wins in a merge, from weakest to strongest.
    pub fn strictness(self: Decision) u8 {
        return switch (self) {
            .proceed => 0,
            .allow => 1,
            .ask => 2,
            .deny => 3,
        };
    }
};

/// One hook's normalized answer. Slices are borrowed from the hook's output until the
/// merge copies them.
pub const Answer = struct {
    decision: Decision = .proceed,
    /// Why the hook decided; goes to the model.
    reason: ?[]const u8 = null,
    /// The replacement input: tool input JSON or prompt text.
    updated_input: ?[]const u8 = null,
    /// Text for the model.
    additional_context: ?[]const u8 = null,
    /// Stop and SubagentStop: keep going with this text.
    continue_reason: ?[]const u8 = null,
    /// End the turn now, with this reason.
    stop_reason: ?[]const u8 = null,
    /// Shown to the user, not the model.
    system_message: ?[]const u8 = null,
    /// PostToolUse: the replacement tool output.
    updated_output: ?[]const u8 = null,
    /// PermissionDenied: ask for one retry.
    retry: bool = false,
};

/// What fx does when the hook fails: proceed lets the action run, block stops it on
/// events that can block.
pub const OnFailure = enum { proceed, block };

/// How a hook failed.
pub const FailureKind = enum { spawn_failed, timed_out, cancelled, exit_code, signaled, invalid_output, output_too_large };

/// One hook failure. `exit_code` is set for `exit_code`, and `signal` for `signaled`.
/// `detail` is borrowed.
pub const Failure = struct { kind: FailureKind, exit_code: ?u8 = null, signal: ?u32 = null, detail: []const u8 = "" };

/// What one hook produced.
pub const Result = union(enum) { answer: Answer, failure: Failure };

/// One handler's result, with the policy to apply when it failed. All slices are borrowed.
pub const HandlerResult = struct {
    hook_id: []const u8,
    on_failure: OnFailure = .proceed,
    result: Result,
    duration_ms: u64 = 0,
};

/// What a notice tells the user. Message is a hook's system message; failure is a hook
/// that failed; cut is text fx shortened; dropped is a field the event does not accept.
pub const NoticeKind = enum { message, failure, cut, dropped };

/// One user-facing notice. Owned by the Outcome.
pub const Notice = struct { kind: NoticeKind, hook_id: []u8, text: []u8 };

/// The merged answer of every hook that ran. Owns all its memory, allocated with the
/// allocator passed to the merge.
pub const Outcome = struct {
    decision: Decision = .proceed,
    reason: ?[]u8 = null,
    /// The id of the hook whose decision won.
    decided_by: ?[]u8 = null,
    updated_input: ?[]u8 = null,
    additional_context: ?[]u8 = null,
    continue_reason: ?[]u8 = null,
    stop_reason: ?[]u8 = null,
    updated_output: ?[]u8 = null,
    retry: bool = false,
    notices: []Notice = &.{},
    /// How many hooks ran.
    ran: usize = 0,

    /// Frees every owned slice and the notices. The value is undefined afterwards.
    pub fn deinit(self: *Outcome, alloc: std.mem.Allocator) void {
        if (self.reason) |text| alloc.free(text);
        if (self.decided_by) |text| alloc.free(text);
        if (self.updated_input) |text| alloc.free(text);
        if (self.additional_context) |text| alloc.free(text);
        if (self.continue_reason) |text| alloc.free(text);
        if (self.stop_reason) |text| alloc.free(text);
        if (self.updated_output) |text| alloc.free(text);
        for (self.notices) |notice| {
            alloc.free(notice.hook_id);
            alloc.free(notice.text);
        }
        if (self.notices.len > 0) alloc.free(self.notices);
        self.* = undefined;
    }
};

test "strictness orders deny above ask above allow above proceed" {
    try std.testing.expect(Decision.deny.strictness() > Decision.ask.strictness());
    try std.testing.expect(Decision.ask.strictness() > Decision.allow.strictness());
    try std.testing.expect(Decision.allow.strictness() > Decision.proceed.strictness());
}

test "Outcome.deinit frees every owned slice" {
    const alloc = std.testing.allocator;
    var outcome = Outcome{
        .decision = .deny,
        .reason = try alloc.dupe(u8, "no"),
        .decided_by = try alloc.dupe(u8, "guard"),
        .updated_input = try alloc.dupe(u8, "{\"path\":\"a\"}"),
        .additional_context = try alloc.dupe(u8, "context"),
        .continue_reason = try alloc.dupe(u8, "keep going"),
        .stop_reason = try alloc.dupe(u8, "stop now"),
        .updated_output = try alloc.dupe(u8, "output"),
        .retry = true,
        .notices = try alloc.alloc(Notice, 2),
        .ran = 2,
    };
    outcome.notices[0] = .{
        .kind = .message,
        .hook_id = try alloc.dupe(u8, "first"),
        .text = try alloc.dupe(u8, "note"),
    };
    outcome.notices[1] = .{
        .kind = .failure,
        .hook_id = try alloc.dupe(u8, "second"),
        .text = try alloc.dupe(u8, "timed out"),
    };

    outcome.deinit(alloc);
}

test "Outcome.deinit on a default outcome is safe" {
    var outcome = Outcome{};
    outcome.deinit(std.testing.allocator);
}

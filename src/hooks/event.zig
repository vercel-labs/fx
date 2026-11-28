//! Hook events: their names, what each one may change, and the data fx sends with it.

const std = @import("std");

/// Every point where a hook can run.
pub const EventName = enum {
    session_start,
    session_end,
    user_prompt_submit,
    instructions_loaded,
    pre_model_request,
    post_model_request,
    pre_tool_use,
    permission_request,
    permission_denied,
    post_tool_use,
    post_tool_use_failure,
    post_tool_batch,
    stop,
    stop_failure,
    interrupt,
    subagent_start,
    subagent_stop,
    pre_compact,
    post_compact,
    notification,
    config_change,
    pre_model_switch,
    post_model_switch,
    turn_end,

    /// The event's name in hook files and hook input, such as "PreToolUse".
    pub fn fileName(self: EventName) []const u8 {
        return switch (self) {
            .session_start => "SessionStart",
            .session_end => "SessionEnd",
            .user_prompt_submit => "UserPromptSubmit",
            .instructions_loaded => "InstructionsLoaded",
            .pre_model_request => "PreModelRequest",
            .post_model_request => "PostModelRequest",
            .pre_tool_use => "PreToolUse",
            .permission_request => "PermissionRequest",
            .permission_denied => "PermissionDenied",
            .post_tool_use => "PostToolUse",
            .post_tool_use_failure => "PostToolUseFailure",
            .post_tool_batch => "PostToolBatch",
            .stop => "Stop",
            .stop_failure => "StopFailure",
            .interrupt => "Interrupt",
            .subagent_start => "SubagentStart",
            .subagent_stop => "SubagentStop",
            .pre_compact => "PreCompact",
            .post_compact => "PostCompact",
            .notification => "Notification",
            .config_change => "ConfigChange",
            .pre_model_switch => "PreModelSwitch",
            .post_model_switch => "PostModelSwitch",
            .turn_end => "TurnEnd",
        };
    }

    /// Reads an event from a hook file name. The match is exact and case-sensitive
    /// and never yields an internal event.
    pub fn fromFileName(name: []const u8) ?EventName {
        for (user_events) |tag| {
            if (std.mem.eql(u8, name, tag.fileName())) return tag;
        }
        return null;
    }

    /// What a hook of this event may change.
    pub fn capabilities(self: EventName) Capabilities {
        return switch (self) {
            .session_start => .{ .context = true, .match = .source },
            .session_end => .{ .match = .reason },
            .user_prompt_submit => .{ .deny = true, .rewrite = true, .context = true, .stop_turn = true },
            .instructions_loaded => .{ .deny = true, .match = .load_reason },
            .pre_model_request => .{},
            .post_model_request => .{},
            .pre_tool_use => .{
                .allow = true,
                .ask = true,
                .deny = true,
                .rewrite = true,
                .context = true,
                .stop_turn = true,
                .match = .tool_name,
            },
            .permission_request => .{ .allow = true, .deny = true, .match = .tool_name },
            .permission_denied => .{ .retry = true, .match = .tool_name },
            .post_tool_use => .{ .context = true, .stop_turn = true, .replace_output = true, .match = .tool_name },
            .post_tool_use_failure => .{ .context = true, .stop_turn = true, .match = .tool_name },
            .post_tool_batch => .{ .context = true, .stop_turn = true },
            .stop => .{ .continue_turn = true },
            .stop_failure => .{},
            .interrupt => .{},
            .subagent_start => .{ .context = true },
            .subagent_stop => .{ .continue_turn = true },
            .pre_compact => .{ .deny = true, .context = true, .match = .trigger },
            .post_compact => .{ .match = .trigger },
            .notification => .{ .match = .notification_type },
            .config_change => .{ .deny = true, .match = .source },
            .pre_model_switch => .{ .deny = true },
            .post_model_switch => .{ .context = true },
            .turn_end => .{},
        };
    }
};

/// The user events, in enum order. Internal events are left out.
pub const user_events: [23]EventName = .{
    .session_start,
    .session_end,
    .user_prompt_submit,
    .instructions_loaded,
    .pre_model_request,
    .post_model_request,
    .pre_tool_use,
    .permission_request,
    .permission_denied,
    .post_tool_use,
    .post_tool_use_failure,
    .post_tool_batch,
    .stop,
    .stop_failure,
    .interrupt,
    .subagent_start,
    .subagent_stop,
    .pre_compact,
    .post_compact,
    .notification,
    .config_change,
    .pre_model_switch,
    .post_model_switch,
};

/// What a hook's matcher is compared with for this event.
const MatchKind = enum { none, tool_name, source, reason, load_reason, trigger, notification_type };

/// What one hook of an event may change. Everything is off by default.
pub const Capabilities = struct {
    /// A hook may allow the action.
    allow: bool = false,
    /// A hook may ask the user.
    ask: bool = false,
    /// A hook may block the action.
    deny: bool = false,
    /// A hook may replace the input.
    rewrite: bool = false,
    /// A hook may add text for the model.
    context: bool = false,
    /// A hook may make the agent keep going.
    continue_turn: bool = false,
    /// A hook may end the turn.
    stop_turn: bool = false,
    /// A hook may replace the tool output.
    replace_output: bool = false,
    /// A hook may ask for one retry.
    retry: bool = false,
    /// What a matcher is compared with, or none when the event has no matcher.
    match: MatchKind = .none,
};

/// Which fx front end runs the session.
pub const Surface = enum { interactive, ask, acp, libfx, subagent };

/// Where and when an event happened. Slices are borrowed from the caller for one run.
pub const Scope = struct {
    surface: Surface,
    session_id: ?[]const u8 = null,
    turn_id: ?u64 = null,
    subagent_id: ?u64 = null,
    /// The directory hook processes start in.
    cwd: []const u8,
    /// The workspace root.
    project_dir: []const u8,
    /// One of ask, auto, or full-access.
    permission_mode: []const u8,
    transcript_path: ?[]const u8 = null,
};

/// One field of event data.
pub const Value = union(enum) {
    string: []const u8,
    /// Raw JSON text that the caller guarantees is valid; it is copied into hook input as is.
    json: []const u8,
    boolean: bool,
    integer: i64,
    null_value,
};

/// One key and its value, as sent to a hook.
pub const Field = struct { key: []const u8, value: Value };

/// One event, ready to match hooks against.
pub const Event = struct {
    name: EventName,
    scope: Scope,
    /// What matchers test, such as the tool name; null when the event has no matcher.
    match_value: ?[]const u8 = null,
    /// Event-specific data, such as tool_input; borrowed for one run.
    fields: []const Field = &.{},
};

test "every user event round-trips through its file name" {
    try std.testing.expectEqual(@as(usize, 23), user_events.len);
    for (user_events) |tag| {
        const parsed = EventName.fromFileName(tag.fileName());
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(tag, parsed.?);
    }
}

test "internal and unknown file names do not parse" {
    try std.testing.expect(EventName.fromFileName("TurnEnd") == null);
    try std.testing.expect(EventName.fromFileName("pretooluse") == null);
    try std.testing.expect(EventName.fromFileName("") == null);
}

test "capabilities of key events" {
    const pre = EventName.pre_tool_use.capabilities();
    try std.testing.expect(pre.allow and pre.ask and pre.deny and pre.rewrite and pre.context and pre.stop_turn);
    try std.testing.expect(!pre.continue_turn);
    try std.testing.expectEqual(MatchKind.tool_name, pre.match);

    const permission = EventName.permission_request.capabilities();
    try std.testing.expect(permission.allow and permission.deny);
    try std.testing.expect(!permission.ask);

    const stop = EventName.stop.capabilities();
    try std.testing.expect(stop.continue_turn);
    try std.testing.expect(!stop.deny and !stop.context and !stop.stop_turn);

    const end = EventName.session_end.capabilities();
    try std.testing.expect(!end.allow and !end.ask and !end.deny and !end.rewrite and !end.context);
    try std.testing.expect(!end.continue_turn and !end.stop_turn and !end.replace_output and !end.retry);
    try std.testing.expectEqual(MatchKind.reason, end.match);

    const turn_end_caps = EventName.turn_end.capabilities();
    try std.testing.expect(!turn_end_caps.allow and !turn_end_caps.ask and !turn_end_caps.deny);
    try std.testing.expect(!turn_end_caps.rewrite and !turn_end_caps.context);
    try std.testing.expect(!turn_end_caps.continue_turn and !turn_end_caps.stop_turn);
    try std.testing.expect(!turn_end_caps.replace_output and !turn_end_caps.retry);
}

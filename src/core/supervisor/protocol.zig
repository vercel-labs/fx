//! The local wire contract between the detached supervisor and its clients.
//!
//! One frame is one JSON object on one line. A request names its kind in
//! `command` and carries that kind's fields beside it. Every response has
//! `ok`; a failed one has `error` and nothing else. Both ends parse these
//! types with std.json, so a field changes in one place.
//!
//! Shapes that carry host-produced JSON (saved history, ACP frames) take the
//! JSON type as a parameter: the supervisor writes cached bytes through
//! `RawJson`, and a client reads them as `std.json.Value` or a typed slice.
const std = @import("std");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

/// Bumped whenever a request or response changes shape. A client refuses a
/// supervisor that answers `ping` with another version.
pub const version: u32 = 2;

pub const Heartbeat = struct {
    prompt: []const u8 = "",
    interval_ms: u64 = 0,
    next_run_ms: i64 = 0,
    paused: bool = true,
    run_count: u64 = 0,
};

pub const HeartbeatAction = enum { status, set, pause, @"resume", clear };

/// The answers a person can give a forwarded permission request.
pub const PermissionOption = enum { allow_once, allow_always, reject_once };

pub const Create = struct {
    cwd: []const u8,
    name: []const u8 = "session",
    @"resume": ?[]const u8 = null,
};

pub const Attach = struct {
    session_id: []const u8,
    after_sequence: u64 = 0,
    /// Defaults to true for the first attachment (`after_sequence` 0).
    include_history: ?bool = null,
};

pub const SetMode = struct { session_id: []const u8, mode: []const u8 };
pub const SetModel = struct { session_id: []const u8, model: []const u8 };
pub const SetOption = struct { session_id: []const u8, config_id: []const u8, value: []const u8 };

/// One `fx/command` the host runs; see `acp/commands.zig` for the names.
pub const HostCommand = struct {
    session_id: []const u8,
    name: []const u8,
    action: ?[]const u8 = null,
    path: ?[]const u8 = null,
    line: ?[]const u8 = null,
};

pub const Rename = struct { session_id: []const u8, name: []const u8 };
pub const Kernel = struct { session_id: []const u8, action: []const u8 = "status" };
pub const Prompt = struct { session_id: []const u8, text: []const u8 };
pub const SessionRef = struct { session_id: []const u8 };

pub const Permission = struct {
    session_id: []const u8,
    request_id: i64,
    option: PermissionOption,
};

pub const HeartbeatRequest = struct {
    session_id: []const u8,
    action: HeartbeatAction = .status,
    interval_ms: ?u64 = null,
    prompt: ?[]const u8 = null,
};

pub const History = struct {
    session_id: []const u8,
    child_id: ?[]const u8 = null,
    work_id: ?[]const u8 = null,
    after_live_sequence: u64 = 0,
    live_active: bool = false,
    include_history: bool = true,
};

pub const Request = union(enum) {
    ping,
    shutdown,
    list,
    create: Create,
    attach: Attach,
    mode: SetMode,
    model: SetModel,
    option: SetOption,
    command: HostCommand,
    rename: Rename,
    kernel: Kernel,
    prompt: Prompt,
    cancel: SessionRef,
    permission: Permission,
    stop: SessionRef,
    heartbeat: HeartbeatRequest,
    children: SessionRef,
    history: History,

    pub const Tag = std.meta.Tag(Request);

    /// The session a request addresses, or null for supervisor-wide ones.
    pub fn sessionId(self: Request) ?[]const u8 {
        return switch (self) {
            .ping, .shutdown, .list, .create => null,
            inline else => |payload| payload.session_id,
        };
    }

    pub fn jsonStringify(self: Request, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("command");
        try jw.write(@tagName(self));
        switch (self) {
            inline else => |payload| {
                const Payload = @TypeOf(payload);
                if (Payload != void) {
                    inline for (@typeInfo(Payload).@"struct".field_names) |name| {
                        const value = @field(payload, name);
                        const omit = @typeInfo(@TypeOf(value)) == .optional and value == null;
                        if (!omit) {
                            try jw.objectField(name);
                            try jw.write(value);
                        }
                    }
                }
            },
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(alloc: Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!Request {
        if (source != .object) return error.UnexpectedToken;
        const name = source.object.get("command") orelse return error.MissingField;
        if (name != .string) return error.UnexpectedToken;
        const tag = std.meta.stringToEnum(Tag, name.string) orelse return error.InvalidEnumTag;
        // The payload sits beside `command`, which the payload types do not name.
        var payload_options = options;
        payload_options.ignore_unknown_fields = true;
        switch (tag) {
            inline else => |known| {
                const Payload = @FieldType(Request, @tagName(known));
                if (Payload == void) return @unionInit(Request, @tagName(known), {});
                return @unionInit(Request, @tagName(known), try std.json.innerParseFromValue(Payload, alloc, source, payload_options));
            },
        }
    }

    /// Parses one request frame. Everything returned borrows `arena`.
    pub fn parse(arena: Allocator, bytes: []const u8) !Request {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
        return std.json.parseFromValueLeaky(Request, arena, value, .{});
    }
};

/// Writes already-encoded JSON in place. The supervisor keeps saved history
/// and host frames encoded, so a snapshot copies bytes instead of re-parsing.
pub const RawJson = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: RawJson, jw: anytype) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeAll(self.bytes);
        jw.endWriteRaw();
    }
};

/// How every response starts. A client reads this first, then the shape its
/// request expects.
pub const Outcome = struct {
    ok: bool = true,
    @"error": ?[]const u8 = null,
};

pub const Failure = struct {
    ok: bool = false,
    @"error": []const u8,
};

pub const Ack = struct { ok: bool = true };

pub const Pong = struct {
    ok: bool = true,
    version: u32 = version,
};

pub const Status = enum { saved, idle, running, awaiting_approval, stopped, @"error" };

pub const SessionSummary = struct {
    id: []const u8,
    name: []const u8,
    cwd: []const u8,
    model: []const u8 = "",
    mode: []const u8 = "auto",
    status: Status = .saved,
    heartbeat: Heartbeat = .{},
    error_message: ?[]const u8 = null,
    updated_at_ms: i64 = 0,
};

pub const SessionList = struct {
    ok: bool = true,
    sessions: []const SessionSummary = &.{},
    last_attached_id: ?[]const u8 = null,
};

pub fn Event(comptime Frame: type) type {
    return struct { sequence: u64, frame: Frame };
}

/// What `create` and `attach` return: the session, its saved history when
/// asked for, and the live events after the caller's sequence.
pub fn Snapshot(comptime HistoryJson: type, comptime Frame: type) type {
    return struct {
        ok: bool = true,
        incarnation: []const u8,
        native_presentation: bool = true,
        session_id: []const u8,
        session: SessionSummary,
        history_sequence: ?u64 = null,
        history: ?HistoryJson = null,
        sequence: u64 = 0,
        oldest_sequence: u64 = 0,
        events: []const Event(Frame) = &.{},
        /// Host requests still waiting for an answer, such as permissions.
        pending: []const Frame = &.{},
    };
}

pub const HeartbeatState = struct {
    ok: bool = true,
    heartbeat: Heartbeat = .{},
};

pub const KernelInfo = struct { state: []const u8, diagnostics: []const u8 };

pub const KernelState = struct {
    ok: bool = true,
    kernel: KernelInfo,
};

pub const PromptAdmitted = struct {
    ok: bool = true,
    admitted: bool = true,
    request_id: i64,
};

/// A host answer to `mode`, `model`, or `option`.
pub fn NativeResult(comptime Json: type) type {
    return struct { ok: bool = true, result: Json };
}

pub const CommandAccepted = struct {
    ok: bool = true,
    accepted: bool = true,
};

pub const Child = struct {
    id: []const u8,
    parent_id: []const u8,
    name: []const u8,
    status: []const u8,
    detail: []const u8,
    depth: u8 = 1,
};

pub const Children = struct {
    ok: bool = true,
    children: []const Child = &.{},
};

pub fn RootHistory(comptime HistoryJson: type) type {
    return struct { ok: bool = true, history: HistoryJson };
}

pub fn ChildHistory(comptime LiveJson: type) type {
    return struct {
        ok: bool = true,
        child_id: []const u8,
        work_id: []const u8,
        live_active: bool,
        live_sequence: u64,
        oldest_live_sequence: u64,
        live_reset: bool,
        name: []const u8,
        status: []const u8,
        last_outcome: ?[]const u8 = null,
        last_failure: ?[]const u8 = null,
        active_prompt: ?[]const u8 = null,
        /// Present only when `live_reset` asks the viewer to rebuild.
        history: ?[]const types.HistoryTurn = null,
        live_events: LiveJson,
    };
}

/// The event a host command's answer becomes in the session's stream.
pub const command_result_method = "fx/command_result";

pub fn CommandResult(comptime Json: type) type {
    return struct {
        name: []const u8,
        ok: bool,
        result: ?Json = null,
        @"error": ?[]const u8 = null,
    };
}

pub const replay_gap_method = "proto/replay_gap";
pub const permission_retired_method = "proto/permission_retired";

/// Encodes `value` as one frame body. Caller owns the bytes.
pub fn encode(alloc: Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{ .emit_null_optional_fields = false });
}

test "requests round trip with their command beside the fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const requests = [_]Request{
        .ping,
        .{ .create = .{ .cwd = "/tmp/work", .@"resume" = "abc" } },
        .{ .heartbeat = .{ .session_id = "s", .action = .set, .interval_ms = 5000, .prompt = "check" } },
        .{ .permission = .{ .session_id = "s", .request_id = 7, .option = .allow_always } },
        .{ .history = .{ .session_id = "s", .child_id = "c", .after_live_sequence = 3 } },
    };
    for (requests) |request| {
        const bytes = try encode(arena, request);
        const parsed = try Request.parse(arena, bytes);
        try std.testing.expectEqual(std.meta.activeTag(request), std.meta.activeTag(parsed));
        try std.testing.expectEqualStrings(bytes, try encode(arena, parsed));
    }
    const create = try Request.parse(arena, "{\"command\":\"create\",\"cwd\":\"/w\"}");
    try std.testing.expectEqualStrings("session", create.create.name);
    try std.testing.expect(create.create.@"resume" == null);
    try std.testing.expectEqualStrings("s", (try Request.parse(arena, "{\"command\":\"stop\",\"session_id\":\"s\"}")).sessionId().?);
}

test "unknown and malformed requests are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.InvalidEnumTag, Request.parse(arena, "{\"command\":\"explode\"}"));
    try std.testing.expectError(error.MissingField, Request.parse(arena, "{\"session_id\":\"s\"}"));
    try std.testing.expectError(error.MissingField, Request.parse(arena, "{\"command\":\"prompt\",\"session_id\":\"s\"}"));
    try std.testing.expectError(error.InvalidEnumTag, Request.parse(arena, "{\"command\":\"permission\",\"session_id\":\"s\",\"request_id\":1,\"option\":\"maybe\"}"));
}

test "raw json fields are copied into the encoded response" {
    const alloc = std.testing.allocator;
    const Encoded = Snapshot(RawJson, RawJson);
    const events = [_]Event(RawJson){.{ .sequence = 4, .frame = .{ .bytes = "{\"method\":\"x\"}" } }};
    const bytes = try encode(alloc, Encoded{
        .incarnation = "i",
        .session_id = "s",
        .session = .{ .id = "s", .name = "n", .cwd = "/w" },
        .history = .{ .bytes = "[]" },
        .sequence = 4,
        .events = &events,
    });
    defer alloc.free(bytes);
    const Decoded = Snapshot([]const types.HistoryTurn, std.json.Value);
    const parsed = try std.json.parseFromSlice(Decoded, alloc, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.history.?.len);
    try std.testing.expectEqualStrings("x", parsed.value.events[0].frame.object.get("method").?.string);
}

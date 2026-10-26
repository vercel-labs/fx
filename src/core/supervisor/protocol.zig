//! The local wire contract between the detached supervisor and its clients.
//!
//! One frame is one JSON object on one line. A request names its kind in
//! `command` and carries that kind's fields beside it. Every response has
//! `ok`; a failed one has `error` and nothing else. Both ends parse these
//! types with std.json, so a field changes in one place.
//!
//! A client keeps one connection open (`channel.zig`). Each request travels
//! in a `RequestFrame` with an id its `ReplyFrame` repeats, and the
//! supervisor pushes `UpdateFrame`s for what the connection watches: the
//! session it attached to, and the session list, a session's children, or
//! one child's transcript when it asked with `watch`. A bare request with no
//! id is a one-shot exchange: the supervisor answers it bare and hangs up,
//! which is how `proto-fx daemon` talks to a supervisor of any version.
//!
//! Shapes that carry host-produced JSON (saved history, ACP frames) take the
//! JSON type as a parameter: the supervisor writes cached bytes through
//! `RawJson`, and a client reads them as `std.json.Value` or a typed slice.
const std = @import("std");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

/// Bumped whenever a request or response changes shape. A client refuses a
/// supervisor that answers `ping` with another version.
pub const version: u32 = 8;

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
    /// The node of the session's tree the command acts on; null is the root.
    node_id: ?[]const u8 = null,
    name: []const u8,
    action: ?[]const u8 = null,
    path: ?[]const u8 = null,
    line: ?[]const u8 = null,
};

pub const Rename = struct { session_id: []const u8, name: []const u8 };
pub const Kernel = struct { session_id: []const u8, node_id: ?[]const u8 = null, action: []const u8 = "status" };
/// A prompt for the root, or a user message for the node `node_id` names.
pub const Prompt = struct { session_id: []const u8, node_id: ?[]const u8 = null, text: []const u8 };
pub const SessionRef = struct { session_id: []const u8 };
/// Cancels the root's turn, or the work a user message started on a node.
pub const Cancel = struct { session_id: []const u8, node_id: ?[]const u8 = null };

/// What a connection can watch besides its attached session.
/// `stopped` is not watched: the supervisor sends it to every connection
/// before an intentional stop, so clients stay down instead of restarting it.
pub const Topic = enum { session, list, children, child, stopped };

pub const List = struct { watch: bool = false };
/// The direct children of `node_id`, any node of the session's tree; null
/// is the root.
pub const ChildrenRequest = struct { session_id: []const u8, node_id: ?[]const u8 = null, watch: bool = false };
pub const Unwatch = struct { topic: Topic, session_id: ?[]const u8 = null };

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
    /// The node's parent when the viewer knows it; the supervisor reads it
    /// from the node's log otherwise.
    parent_id: ?[]const u8 = null,
    work_id: ?[]const u8 = null,
    after_live_sequence: u64 = 0,
    live_active: bool = false,
    include_history: bool = true,
    /// Push this child's transcript as it changes, from the returned cursor.
    watch: bool = false,
};

/// One slice of the root session's saved history, which a snapshot defers
/// when the whole transcript would exceed one frame. `offset` counts bytes of
/// the history array's JSON text, so a single oversized turn still travels in
/// bounded frames.
pub const HistoryChunk = struct {
    session_id: []const u8,
    offset: usize = 0,
    max_bytes: usize = 512 * 1024,
};

/// The largest slice a `history_chunk` request may ask for. A JSON string can
/// escape to several times its source length, so this stays well below the
/// frame limit.
pub const history_chunk_max_bytes: usize = 512 * 1024;

pub const Request = union(enum) {
    ping,
    shutdown,
    list: List,
    create: Create,
    attach: Attach,
    mode: SetMode,
    model: SetModel,
    option: SetOption,
    command: HostCommand,
    rename: Rename,
    kernel: Kernel,
    prompt: Prompt,
    cancel: Cancel,
    permission: Permission,
    stop: SessionRef,
    delete: SessionRef,
    heartbeat: HeartbeatRequest,
    children: ChildrenRequest,
    history: History,
    history_chunk: HistoryChunk,
    unwatch: Unwatch,

    pub const Tag = std.meta.Tag(Request);

    /// The session a request addresses, or null for supervisor-wide ones.
    pub fn sessionId(self: Request) ?[]const u8 {
        return switch (self) {
            .ping, .shutdown, .list, .create => null,
            .unwatch => |payload| payload.session_id,
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

/// A request on a kept-open connection.
pub const RequestFrame = struct { id: u64, request: Request };

/// The supervisor's answer to the request with the same id.
pub const ReplyFrame = struct { id: u64, response: RawJson };

/// A change the supervisor pushes to a watching connection. `body` has the
/// shape of the response to the request that started the watch: a
/// `Snapshot` delta for `session`, a `SessionList`, `Children`, or a
/// `ChildHistory`.
pub const UpdateFrame = struct { update: Topic, body: RawJson };

/// What a client reads: a reply or an update.
pub const ServerFrame = struct {
    id: ?u64 = null,
    response: ?std.json.Value = null,
    update: ?Topic = null,
    body: ?std.json.Value = null,
};

/// Parses a request frame or a bare one-shot request. Everything returned
/// borrows `arena`. The id survives a bad request so the reply can name it.
pub fn parseInbound(arena: Allocator, bytes: []const u8, id: *?u64) !Request {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (value == .object) if (value.object.get("request")) |request| {
        const raw_id = value.object.get("id") orelse return error.MissingField;
        if (raw_id != .integer or raw_id.integer < 0) return error.UnexpectedToken;
        id.* = @intCast(raw_id.integer);
        return std.json.parseFromValueLeaky(Request, arena, request, .{});
    };
    return std.json.parseFromValueLeaky(Request, arena, value, .{});
}

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
        session_id: []const u8,
        session: SessionSummary,
        history_sequence: ?u64 = null,
        history: ?HistoryJson = null,
        /// True when `include_history` asked for saved turns but the encoded
        /// history exceeded the snapshot budget. The client then reads
        /// `history_chunk` slices until `total_bytes`.
        history_deferred: bool = false,
        history_turn_count: usize = 0,
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
    /// The node these are the children of; empty from older supervisors.
    node_id: []const u8 = "",
    children: []const Child = &.{},
};

pub fn RootHistory(comptime HistoryJson: type) type {
    return struct { ok: bool = true, history: HistoryJson };
}

/// One byte slice of the saved history array, which the client concatenates
/// before parsing. `history_sequence` names the checkpoint the bytes came
/// from, so a client can restart when a turn commits mid-transfer.
pub const HistoryChunkResponse = struct {
    ok: bool = true,
    session_id: []const u8,
    offset: usize,
    next_offset: usize,
    total_bytes: usize,
    history_sequence: u64,
    chunk: []const u8,
};

pub fn ChildHistory(comptime HistoryJson: type, comptime LiveJson: type) type {
    return struct {
        ok: bool = true,
        child_id: []const u8,
        parent_id: []const u8 = "",
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
        history: ?HistoryJson = null,
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
        // Node-targeted requests name the node beside the root session.
        .{ .prompt = .{ .session_id = "s", .node_id = "grandchild", .text = "follow up" } },
        .{ .children = .{ .session_id = "s", .node_id = "child", .watch = true } },
        .{ .command = .{ .session_id = "s", .node_id = "child", .name = "last_reply" } },
        .{ .cancel = .{ .session_id = "s", .node_id = "child" } },
        .{ .history = .{ .session_id = "s", .child_id = "grandchild", .parent_id = "child" } },
        .{ .history_chunk = .{ .session_id = "s", .offset = 1024, .max_bytes = 4096 } },
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
    // A request without a node addresses the root.
    try std.testing.expect((try Request.parse(arena, "{\"command\":\"prompt\",\"session_id\":\"s\",\"text\":\"x\"}")).prompt.node_id == null);
    try std.testing.expectEqualStrings("s", (try Request.parse(arena, "{\"command\":\"delete\",\"session_id\":\"s\"}")).sessionId().?);
}

test "framed and bare requests parse to the same request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request: Request = .{ .history = .{ .session_id = "s", .child_id = "c", .watch = true } };
    var id: ?u64 = null;
    const framed = try parseInbound(arena, try encode(arena, RequestFrame{ .id = 9, .request = request }), &id);
    try std.testing.expectEqual(@as(?u64, 9), id);
    try std.testing.expect(framed.history.watch);
    var bare_id: ?u64 = null;
    const bare = try parseInbound(arena, try encode(arena, request), &bare_id);
    try std.testing.expect(bare_id == null);
    try std.testing.expectEqualStrings("c", bare.history.child_id.?);
    // A bad request inside a frame still reports its id.
    var bad_id: ?u64 = null;
    try std.testing.expectError(error.InvalidEnumTag, parseInbound(arena, "{\"id\":4,\"request\":{\"command\":\"explode\"}}", &bad_id));
    try std.testing.expectEqual(@as(?u64, 4), bad_id);
    const unwatch = try Request.parse(arena, "{\"command\":\"unwatch\",\"topic\":\"list\"}");
    try std.testing.expect(unwatch.sessionId() == null);
}

test "replies and updates carry their bodies as json" {
    const alloc = std.testing.allocator;
    const bytes = try encode(alloc, UpdateFrame{ .update = .list, .body = .{ .bytes = "{\"ok\":true,\"sessions\":[]}" } });
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice(ServerFrame, alloc, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.id == null);
    try std.testing.expectEqual(Topic.list, parsed.value.update.?);
    try std.testing.expect(parsed.value.body.?.object.get("ok").?.bool);
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

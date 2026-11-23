//! The wire between an fx session and the MCP owner process
//! (`tests/tla/mcp_host/SharedServers.tla`): one Unix socket, length-prefixed
//! JSON frames.
//!
//! A frame is a 4-byte big-endian length, then one JSON object with `"v"` for
//! the wire version and `"t"` naming its type. Server-provided JSON travels
//! inside it as a JSON string, so a message a server may legally send can
//! double in the escaping and still fit (see `max_frame_bytes`).
//!
//! Pure: encoding and decoding work on bytes, with no I/O. The socket shells
//! (`owner.zig`, `owner_client.zig`) read and write the frames.
const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");
const share_key = @import("share_key.zig");
const text_utils = @import("../shared/text_utils.zig");
const json_depth = @import("../shared/json_depth.zig");

const Allocator = std.mem.Allocator;

/// The protocol this build speaks. Another version gets another socket and
/// another lock file, so an older and a newer fx never misread each other.
/// Version 2 carries server-provided JSON as JSON strings, not values.
pub const version: u32 = 2;

/// A frame is at most twice the engine's message limit plus 64 KiB for the
/// envelope and its fields. Server JSON travels as a JSON string, and the
/// only bytes `std.json.Stringify` escapes in one are `"`, `\`, and the
/// control characters, which a JSON string may not hold raw, so the escaped
/// text is at most double the server's message. UTF-8 text is not escaped.
pub const max_frame_bytes: usize = 2 * mcp.limits.max_message_bytes + 64 * 1024;

/// The big-endian length in front of every frame.
pub const header_bytes: usize = 4;

/// A shared server's launch config, as the owner needs it to run the server:
/// the fields `share_key.zig` hashes, so the owner can rebuild the engine's
/// config without reading any of the session's files.
pub const ServerConfig = struct {
    argv: []const []const u8,
    env: []const Entry = &.{},
    cwd: ?[]const u8 = null,
    timeouts: ?Timeouts = null,
    auth: Auth = .{},

    pub const Entry = struct { name: []const u8, value: []const u8 };

    pub const Timeouts = struct {
        start_ms: u32 = 30_000,
        idle_ms: u32 = 60_000,
        hard_ms: u32 = 600_000,
        reset_idle_on_progress: bool = true,
        refresh_ms: u32 = 30_000,
        refused_ms: u32 = 30_000,
    };

    pub const Auth = struct {
        client_id: ?[]const u8 = null,
        client_secret: ?[]const u8 = null,
        client_metadata_url: ?[]const u8 = null,
        resource: ?[]const u8 = null,
        scopes: ?[]const u8 = null,
        client_name: []const u8 = "",
    };
};

/// What a session sends the owner.
pub const ClientMessage = union(enum) {
    /// A new connection, before anything else.
    hello: struct { pid: u32 },
    /// The session needs this key's server; `ask_form` and `ask_url` say
    /// whether it can show the server's questions.
    register: struct { key: share_key.Key, config: ServerConfig, ask_form: bool, ask_url: bool },
    /// The session stops using this key's server: the owner drops it from the
    /// key's slot, and the server stops when no session is left.
    unregister: struct { key: share_key.Key },
    need: struct { key: share_key.Key },
    call: struct { key: share_key.Key, id: u32, tool: []const u8, arguments: ?[]const u8 },
    cancel: struct { id: u32 },
    respond: struct { id: u32, values: []const u8 },
    /// A 2025 question's answer, by its slot and number.
    answer: struct { key: share_key.Key, slot: u8, n: u32, action: mcp.elicitation.Action, content: ?[]const u8 },
    /// The session is leaving; the owner cancels its calls.
    bye,
};

/// Why the owner refused one request, so the session falls back for that one
/// server or call instead of losing the connection.
pub const Refused = enum { unknown_client, not_registered, too_many_keys, too_many_calls };

/// What the owner sends a session.
pub const OwnerMessage = union(enum) {
    welcome: struct { owner: u32 },
    phase: struct { key: share_key.Key, phase: mcp.engine.Phase },
    /// The key's tool list as the engine holds it: a JSON array of raw tool
    /// objects, carried as text.
    tools: struct { key: share_key.Key, ok: bool, fresh: bool, needs_auth: bool, tools: []const u8 = "[]", list_refusal: ?[]const u8 = null },
    /// How one of this client's calls ended; `answer` is the `tools.Call`
    /// JSON text, or null when the call ended without one. `lost_why` says
    /// why a lost call was lost, so the session logs the reason it would log
    /// for its own engine's loss.
    called: struct { id: u32, outcome: mcp.engine.Outcome, maybe_ran: bool, timed_out: bool, oversized: bool = false, answer: ?[]const u8 = null, refused_bytes: u32 = 0, refused_body: bool = false, lost_why: ?mcp.server.LostWhy = null },
    progress: struct { id: u32, progress: f64, total: ?f64 = null, message: ?[]const u8 = null },
    /// The call's 2026 input requests, as the `mrtr.Request` list's JSON text.
    input: struct { id: u32, requests: []const u8 },
    /// A 2025 question, which names no call.
    /// `required`: listed in a call's -32042 error, so nothing is sent back.
    question: struct { key: share_key.Key, slot: u8, n: u32, params: []const u8, version: ?[]const u8 = null, required: bool = false },
    /// The server completed, or withdrew, the 2025 question in `slot`.
    elicitation_complete: struct { key: share_key.Key, slot: u8 },
    elicit_withdrawn: struct { key: share_key.Key, slot: u8 },
    stopped_idle: struct { key: share_key.Key },
    /// The owner refused one request. `key` names the server it was about when
    /// it named one, and `call` the call's id when it was a call: the session
    /// falls back for that server, or ends that call as one that never went
    /// out, and every other key on the connection keeps working.
    refused: struct { reason: Refused, key: ?share_key.Key = null, call: ?u32 = null },
    status: struct { key: share_key.Key, phase: mcp.engine.Phase, version: ?[]const u8 = null, last_error: ?[]const u8 = null, stderr_tail: ?[]const u8 = null, instructions: ?[]const u8 = null, exit_code: ?u8 = null, exit_signal: ?u8 = null, stray_line: ?[]const u8 = null, list_refusal: ?[]const u8 = null },
};

pub const Message = union(enum) {
    client: ClientMessage,
    owner: OwnerMessage,
};

pub const DecodeError = error{ Malformed, UnsupportedVersion, OutOfMemory };

/// Writes the length of a frame, refusing one over the cap.
pub fn writeLength(out: *[header_bytes]u8, len: usize) error{TooLarge}!void {
    if (len > max_frame_bytes) return error.TooLarge;
    std.mem.writeInt(u32, out, @intCast(len), .big);
}

/// The length a frame's header announces, refusing one over the cap.
pub fn readLength(header: *const [header_bytes]u8) error{TooLarge}!usize {
    const len = std.mem.readInt(u32, header, .big);
    if (len > max_frame_bytes) return error.TooLarge;
    return len;
}

/// One whole frame: the length, then the JSON object. Owned by `alloc`.
pub fn encode(alloc: Allocator, message: anytype) (Allocator.Error || error{TooLarge})![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeObject(&out.writer, message) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    const json = out.written();
    var header: [header_bytes]u8 = undefined;
    try writeLength(&header, json.len);
    const frame = try alloc.alloc(u8, header_bytes + json.len);
    @memcpy(frame[0..header_bytes], &header);
    @memcpy(frame[header_bytes..], json);
    return frame;
}

/// A frame's JSON object, without its length header. Bounds are checked
/// against the arena; every text borrows from it. A frame deeper than the
/// nesting limit is refused before it is parsed: the owner reads bytes from a
/// socket any same-user process can reach, and `std.json` would walk them on
/// the owner's stack (`json_depth.zig`).
pub fn decode(arena: Allocator, json: []const u8) DecodeError!Message {
    if (json_depth.exceeds(json)) return error.Malformed;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    if (value != .object) return error.Malformed;
    const object = value.object;
    const wire_version = object.get("v") orelse return error.Malformed;
    if (wire_version != .integer) return error.Malformed;
    if (wire_version.integer != version) return error.UnsupportedVersion;
    const kind = try text(object, "t");
    if (std.meta.stringToEnum(std.meta.Tag(ClientMessage), kind)) |tag| {
        return .{ .client = try clientMessage(arena, object, tag) };
    }
    if (std.meta.stringToEnum(std.meta.Tag(OwnerMessage), kind)) |tag| {
        return .{ .owner = try ownerMessage(object, tag) };
    }
    return error.Malformed;
}

fn writeObject(writer: *std.Io.Writer, message: anytype) std.Io.Writer.Error!void {
    try writer.writeAll("{\"v\":");
    try std.json.Stringify.value(version, .{}, writer);
    switch (message) {
        inline else => |m, tag| {
            try writer.writeAll(",\"t\":\"" ++ @tagName(tag) ++ "\"");
            if (comptime @TypeOf(message) == ClientMessage) {
                try writeClientFields(writer, tag, m);
            } else {
                try writeOwnerFields(writer, tag, m);
            }
        },
    }
    try writer.writeByte('}');
}

fn writeClientFields(writer: *std.Io.Writer, comptime tag: std.meta.Tag(ClientMessage), m: anytype) std.Io.Writer.Error!void {
    switch (tag) {
        .hello => try uint(writer, "pid", m.pid),
        .register => {
            try bytes(writer, "key", &m.key);
            try writer.writeAll(",\"config\":");
            try writeServerConfig(writer, m.config);
            try boolean(writer, "ask_form", m.ask_form);
            try boolean(writer, "ask_url", m.ask_url);
        },
        .need => try bytes(writer, "key", &m.key),
        .unregister => try bytes(writer, "key", &m.key),
        .call => {
            try bytes(writer, "key", &m.key);
            try uint(writer, "id", m.id);
            try textField(writer, "tool", m.tool);
            if (m.arguments) |arguments| try raw(writer, "arguments", arguments);
        },
        .cancel => try uint(writer, "id", m.id),
        .respond => {
            try uint(writer, "id", m.id);
            try raw(writer, "values", m.values);
        },
        .answer => {
            try bytes(writer, "key", &m.key);
            try uint(writer, "slot", m.slot);
            try uint(writer, "n", m.n);
            try textField(writer, "action", @tagName(m.action));
            if (m.content) |content| try raw(writer, "content", content);
        },
        .bye => {},
    }
}

fn writeOwnerFields(writer: *std.Io.Writer, comptime tag: std.meta.Tag(OwnerMessage), m: anytype) std.Io.Writer.Error!void {
    switch (tag) {
        .welcome => try uint(writer, "owner", m.owner),
        .phase => {
            try bytes(writer, "key", &m.key);
            try textField(writer, "phase", @tagName(m.phase));
        },
        .tools => {
            try bytes(writer, "key", &m.key);
            try boolean(writer, "ok", m.ok);
            try boolean(writer, "fresh", m.fresh);
            try boolean(writer, "needs_auth", m.needs_auth);
            // Why fx refused the list, when it did: the words the owner's
            // status has, for a session that only reads its own slot.
            if (m.list_refusal) |words| try textField(writer, "list_refusal", words);
            try raw(writer, "tools", m.tools);
        },
        .called => {
            try uint(writer, "id", m.id);
            try textField(writer, "outcome", @tagName(m.outcome));
            try boolean(writer, "maybe_ran", m.maybe_ran);
            try boolean(writer, "timed_out", m.timed_out);
            try boolean(writer, "oversized", m.oversized);
            if (m.answer) |answer| try raw(writer, "answer", answer);
            try uint(writer, "refused_bytes", m.refused_bytes);
            try boolean(writer, "refused_body", m.refused_body);
            if (m.lost_why) |why| try textField(writer, "lost_why", @tagName(why));
        },
        .progress => {
            try uint(writer, "id", m.id);
            try writer.writeAll(",\"progress\":");
            try std.json.Stringify.value(m.progress, .{}, writer);
            if (m.total) |total| {
                try writer.writeAll(",\"total\":");
                try std.json.Stringify.value(total, .{}, writer);
            }
            if (m.message) |message| try textField(writer, "message", message);
        },
        .input => {
            try uint(writer, "id", m.id);
            try raw(writer, "requests", m.requests);
        },
        .question => {
            try bytes(writer, "key", &m.key);
            try uint(writer, "slot", m.slot);
            try uint(writer, "n", m.n);
            try raw(writer, "params", m.params);
            if (m.version) |version_text| try textField(writer, "version", version_text);
            try boolean(writer, "required", m.required);
        },
        .elicitation_complete => {
            try bytes(writer, "key", &m.key);
            try uint(writer, "slot", m.slot);
        },
        .elicit_withdrawn => {
            try bytes(writer, "key", &m.key);
            try uint(writer, "slot", m.slot);
        },
        .stopped_idle => try bytes(writer, "key", &m.key),
        .refused => {
            try textField(writer, "reason", @tagName(m.reason));
            if (m.key) |key| try bytes(writer, "key", &key);
            if (m.call) |id| try uint(writer, "call", id);
        },
        .status => {
            try bytes(writer, "key", &m.key);
            try textField(writer, "phase", @tagName(m.phase));
            if (m.version) |value| try textField(writer, "version", value);
            if (m.last_error) |value| try textField(writer, "last_error", value);
            if (m.stderr_tail) |value| try textField(writer, "stderr_tail", value);
            if (m.instructions) |value| try textField(writer, "instructions", value);
            if (m.exit_code) |value| try uint(writer, "exit_code", value);
            if (m.exit_signal) |value| try uint(writer, "exit_signal", value);
            if (m.stray_line) |value| try textField(writer, "stray_line", value);
            if (m.list_refusal) |value| try textField(writer, "list_refusal", value);
        },
    }
}
fn writeServerConfig(writer: *std.Io.Writer, config: ServerConfig) std.Io.Writer.Error!void {
    try writer.writeAll("{\"argv\":[");
    for (config.argv, 0..) |arg, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.value(arg, .{}, writer);
    }
    try writer.writeAll("],\"env\":[");
    for (config.env, 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try std.json.Stringify.value(entry.name, .{}, writer);
        try writer.writeAll(",\"value\":");
        try std.json.Stringify.value(entry.value, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    if (config.cwd) |cwd| try textField(writer, "cwd", cwd);
    if (config.timeouts) |t| {
        try writer.print(",\"timeouts\":{{\"start_ms\":{d},\"idle_ms\":{d},\"hard_ms\":{d},\"reset_idle_on_progress\":{s},\"refresh_ms\":{d},\"refused_ms\":{d}}}", .{ t.start_ms, t.idle_ms, t.hard_ms, if (t.reset_idle_on_progress) "true" else "false", t.refresh_ms, t.refused_ms });
    }
    const auth = config.auth;
    inline for (.{ "client_id", "client_secret", "client_metadata_url", "resource", "scopes" }) |field| {
        if (@field(auth, field)) |value| try textField(writer, field, value);
    }
    if (auth.client_name.len > 0) try textField(writer, "client_name", auth.client_name);
    try writer.writeByte('}');
}

fn clientMessage(arena: Allocator, object: std.json.ObjectMap, tag: std.meta.Tag(ClientMessage)) DecodeError!ClientMessage {
    return switch (tag) {
        .hello => .{ .hello = .{ .pid = try u32Field(object, "pid") } },
        .register => .{ .register = .{
            .key = try keyField(object, "key"),
            .config = try serverConfig(arena, object.get("config") orelse return error.Malformed),
            .ask_form = try boolField(object, "ask_form"),
            .ask_url = try boolField(object, "ask_url"),
        } },
        .need => .{ .need = .{ .key = try keyField(object, "key") } },
        .unregister => .{ .unregister = .{ .key = try keyField(object, "key") } },
        .call => .{ .call = .{
            .key = try keyField(object, "key"),
            .id = try u32Field(object, "id"),
            .tool = try text(object, "tool"),
            .arguments = try optionalRaw(object, "arguments"),
        } },
        .cancel => .{ .cancel = .{ .id = try u32Field(object, "id") } },
        .respond => .{ .respond = .{ .id = try u32Field(object, "id"), .values = try rawField(object, "values") } },
        .answer => .{ .answer = .{
            .key = try keyField(object, "key"),
            .slot = try u8Field(object, "slot"),
            .n = try u32Field(object, "n"),
            .action = std.meta.stringToEnum(mcp.elicitation.Action, try text(object, "action")) orelse return error.Malformed,
            .content = try optionalRaw(object, "content"),
        } },
        .bye => .bye,
    };
}

fn ownerMessage(object: std.json.ObjectMap, tag: std.meta.Tag(OwnerMessage)) DecodeError!OwnerMessage {
    return switch (tag) {
        .welcome => .{ .welcome = .{ .owner = try u32Field(object, "owner") } },
        .phase => .{ .phase = .{ .key = try keyField(object, "key"), .phase = try enumField(mcp.engine.Phase, object, "phase") } },
        .tools => .{
            .tools = .{
                .key = try keyField(object, "key"),
                .ok = try boolField(object, "ok"),
                .fresh = try boolField(object, "fresh"),
                .needs_auth = try boolField(object, "needs_auth"),
                .tools = try rawField(object, "tools"),
                // Absent from an owner that ran before fx reported a refusal.
                .list_refusal = try optionalText(object, "list_refusal"),
            },
        },
        .called => .{
            .called = .{
                .id = try u32Field(object, "id"),
                .outcome = try enumField(mcp.engine.Outcome, object, "outcome"),
                .maybe_ran = try boolField(object, "maybe_ran"),
                .timed_out = try boolField(object, "timed_out"),
                .oversized = try boolField(object, "oversized"),
                .answer = try optionalRaw(object, "answer"),
                .refused_bytes = try u32FieldDefault(object, "refused_bytes", 0),
                .refused_body = try boolFieldDefault(object, "refused_body", false),
                // Absent from an owner that ran before the reason crossed the wire.
                .lost_why = try optionalEnumField(mcp.server.LostWhy, object, "lost_why"),
            },
        },
        .progress => .{ .progress = .{
            .id = try u32Field(object, "id"),
            .progress = try floatField(object, "progress"),
            .total = try optionalFloatField(object, "total"),
            .message = try optionalText(object, "message"),
        } },
        .input => .{ .input = .{ .id = try u32Field(object, "id"), .requests = try rawField(object, "requests") } },
        .question => .{ .question = .{
            .key = try keyField(object, "key"),
            .slot = try u8Field(object, "slot"),
            .n = try u32Field(object, "n"),
            .params = try rawField(object, "params"),
            .version = try optionalText(object, "version"),
            .required = try boolFieldDefault(object, "required", false),
        } },
        .refused => .{ .refused = .{
            .reason = try enumField(Refused, object, "reason"),
            .key = try optionalKey(object, "key"),
            .call = try optionalU32(object, "call"),
        } },
        .elicitation_complete => .{ .elicitation_complete = .{
            .key = try keyField(object, "key"),
            .slot = try u8Field(object, "slot"),
        } },
        .elicit_withdrawn => .{ .elicit_withdrawn = .{
            .key = try keyField(object, "key"),
            .slot = try u8Field(object, "slot"),
        } },
        .stopped_idle => .{ .stopped_idle = .{ .key = try keyField(object, "key") } },
        .status => .{ .status = .{
            .key = try keyField(object, "key"),
            .phase = try enumField(mcp.engine.Phase, object, "phase"),
            .version = try optionalText(object, "version"),
            .last_error = try optionalText(object, "last_error"),
            .stderr_tail = try optionalText(object, "stderr_tail"),
            .instructions = try optionalText(object, "instructions"),
            .exit_code = try optionalU8(object, "exit_code"),
            .exit_signal = try optionalU8(object, "exit_signal"),
            .stray_line = try optionalText(object, "stray_line"),
            .list_refusal = try optionalText(object, "list_refusal"),
        } },
    };
}

fn serverConfig(arena: Allocator, value: std.json.Value) DecodeError!ServerConfig {
    if (value != .object) return error.Malformed;
    const object = value.object;
    const argv_value = object.get("argv") orelse return error.Malformed;
    if (argv_value != .array) return error.Malformed;
    const argv = try arena.alloc([]const u8, argv_value.array.items.len);
    for (argv_value.array.items, argv) |item, *out| {
        if (item != .string) return error.Malformed;
        out.* = item.string;
    }
    const env_value = object.get("env") orelse return error.Malformed;
    if (env_value != .array) return error.Malformed;
    const env = try arena.alloc(ServerConfig.Entry, env_value.array.items.len);
    for (env_value.array.items, env) |item, *out| {
        if (item != .object) return error.Malformed;
        const name = item.object.get("name") orelse return error.Malformed;
        const entry_value = item.object.get("value") orelse return error.Malformed;
        if (name != .string or entry_value != .string) return error.Malformed;
        out.* = .{ .name = name.string, .value = entry_value.string };
    }
    var config: ServerConfig = .{ .argv = argv, .env = env };
    if (object.get("cwd")) |cwd| {
        if (cwd != .string) return error.Malformed;
        config.cwd = cwd.string;
    }
    if (object.get("timeouts")) |timeouts| {
        if (timeouts != .object) return error.Malformed;
        const t = timeouts.object;
        config.timeouts = .{
            .start_ms = try u32Field(t, "start_ms"),
            .idle_ms = try u32Field(t, "idle_ms"),
            .hard_ms = try u32Field(t, "hard_ms"),
            .reset_idle_on_progress = try boolField(t, "reset_idle_on_progress"),
            .refresh_ms = try u32Field(t, "refresh_ms"),
            .refused_ms = try u32Field(t, "refused_ms"),
        };
    }
    inline for (.{ "client_id", "client_secret", "client_metadata_url", "resource", "scopes" }) |field| {
        if (object.get(field)) |text_value| {
            if (text_value != .string) return error.Malformed;
            @field(config.auth, field) = text_value.string;
        }
    }
    if (object.get("client_name")) |client_name| {
        if (client_name != .string) return error.Malformed;
        config.auth.client_name = client_name.string;
    }
    return config;
}

fn text(object: std.json.ObjectMap, key: []const u8) DecodeError![]const u8 {
    const value = object.get(key) orelse return error.Malformed;
    if (value != .string) return error.Malformed;
    return value.string;
}

fn optionalText(object: std.json.ObjectMap, key: []const u8) DecodeError!?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.Malformed;
    return value.string;
}

fn optionalU8(object: std.json.ObjectMap, key: []const u8) DecodeError!?u8 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u8)) return error.Malformed;
    return @intCast(value.integer);
}

/// A `u8` field, refused above 255 rather than cast: the value comes from
/// another process.
fn u8Field(object: std.json.ObjectMap, key: []const u8) DecodeError!u8 {
    return (try optionalU8(object, key)) orelse error.Malformed;
}

fn u32Field(object: std.json.ObjectMap, key: []const u8) DecodeError!u32 {
    const value = object.get(key) orelse return error.Malformed;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.Malformed;
    return @intCast(value.integer);
}

fn optionalU32(object: std.json.ObjectMap, key: []const u8) DecodeError!?u32 {
    if (object.get(key) == null) return null;
    return try u32Field(object, key);
}

fn u32FieldDefault(object: std.json.ObjectMap, key: []const u8, default: u32) DecodeError!u32 {
    const value = object.get(key) orelse return default;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.Malformed;
    return @intCast(value.integer);
}

fn boolFieldDefault(object: std.json.ObjectMap, key: []const u8, default: bool) DecodeError!bool {
    const value = object.get(key) orelse return default;
    if (value != .bool) return error.Malformed;
    return value.bool;
}

fn boolField(object: std.json.ObjectMap, key: []const u8) DecodeError!bool {
    const value = object.get(key) orelse return error.Malformed;
    if (value != .bool) return error.Malformed;
    return value.bool;
}

fn floatField(object: std.json.ObjectMap, key: []const u8) DecodeError!f64 {
    const value = object.get(key) orelse return error.Malformed;
    if (value != .float and value != .integer) return error.Malformed;
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => unreachable,
    };
}

fn optionalFloatField(object: std.json.ObjectMap, key: []const u8) DecodeError!?f64 {
    if (object.get(key) == null) return null;
    return try floatField(object, key);
}

fn enumField(comptime E: type, object: std.json.ObjectMap, key: []const u8) DecodeError!E {
    return std.meta.stringToEnum(E, try text(object, key)) orelse error.Malformed;
}

/// An enum field a frame may leave out, as `lost_why` is left out of a call
/// that did not end as lost.
fn optionalEnumField(comptime E: type, object: std.json.ObjectMap, key: []const u8) DecodeError!?E {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.Malformed;
    return std.meta.stringToEnum(E, value.string) orelse error.Malformed;
}

fn optionalKey(object: std.json.ObjectMap, key: []const u8) DecodeError!?share_key.Key {
    if (object.get(key) == null) return null;
    return try keyField(object, key);
}

fn keyField(object: std.json.ObjectMap, key: []const u8) DecodeError!share_key.Key {
    const value = try text(object, key);
    if (value.len != @sizeOf(share_key.Key)) return error.Malformed;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.Malformed;
    var out: share_key.Key = undefined;
    @memcpy(&out, value);
    return out;
}

/// A field that holds server-provided JSON, which the frame carries as text.
fn rawField(object: std.json.ObjectMap, key: []const u8) DecodeError![]const u8 {
    return text(object, key);
}

fn optionalRaw(object: std.json.ObjectMap, key: []const u8) DecodeError!?[]const u8 {
    return optionalText(object, key);
}

fn textField(writer: *std.Io.Writer, comptime key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(",\"" ++ key ++ "\":");
    try std.json.Stringify.value(value, .{}, writer);
}

/// Server-provided JSON travels as a JSON string, never as a value, so a
/// deeply nested tool or answer is copied and never walked by whatever reads
/// the frame (`src/core/mcp/server_json_depth.zig`).
fn raw(writer: *std.Io.Writer, comptime key: []const u8, json: []const u8) std.Io.Writer.Error!void {
    try textField(writer, key, json);
}

fn bytes(writer: *std.Io.Writer, comptime key: []const u8, value: *const share_key.Key) std.Io.Writer.Error!void {
    try writer.writeAll(",\"" ++ key ++ "\":\"");
    try writer.writeAll(value);
    try writer.writeByte('"');
}

fn uint(writer: *std.Io.Writer, comptime key: []const u8, value: u32) std.Io.Writer.Error!void {
    try writer.print(",\"" ++ key ++ "\":{d}", .{value});
}

fn boolean(writer: *std.Io.Writer, comptime key: []const u8, value: bool) std.Io.Writer.Error!void {
    try writer.print(",\"" ++ key ++ "\":{s}", .{if (value) "true" else "false"});
}

const testing = std.testing;

fn expectClient(arena: Allocator, message: ClientMessage) !ClientMessage {
    const frame = try encode(arena, message);
    return (try decode(arena, frame[header_bytes..])).client;
}

test "a refused request round-trips with its key and its call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: share_key.Key = "00112233445566778899aabbccddeeff".*;
    const keyed = try expectOwner(a, .{ .refused = .{ .reason = .too_many_keys, .key = key } });
    try testing.expectEqual(Refused.too_many_keys, keyed.refused.reason);
    try testing.expectEqual(key, keyed.refused.key.?);
    try testing.expectEqual(@as(?u32, null), keyed.refused.call);
    const called = try expectOwner(a, .{ .refused = .{ .reason = .too_many_calls, .key = key, .call = 9 } });
    try testing.expectEqual(Refused.too_many_calls, called.refused.reason);
    try testing.expectEqual(key, called.refused.key.?);
    try testing.expectEqual(@as(?u32, 9), called.refused.call);
    const bare = try expectOwner(a, .{ .refused = .{ .reason = .unknown_client } });
    try testing.expectEqual(Refused.unknown_client, bare.refused.reason);
    try testing.expectEqual(@as(?share_key.Key, null), bare.refused.key);
}

fn expectOwner(arena: Allocator, message: OwnerMessage) !OwnerMessage {
    const frame = try encode(arena, message);
    return (try decode(arena, frame[header_bytes..])).owner;
}

test "every client message round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: share_key.Key = "00112233445566778899aabbccddeeff".*;
    try testing.expectEqual(@as(u32, 42), (try expectClient(a, .{ .hello = .{ .pid = 42 } })).hello.pid);

    const r = try expectClient(a, .{ .register = .{
        .key = key,
        .config = .{ .argv = &.{ "node", "s.js" }, .env = &.{.{ .name = "A", .value = "1" }}, .cwd = "/w", .timeouts = .{ .start_ms = 1_000, .refused_ms = 2_000 }, .auth = .{ .client_id = "c1", .scopes = "s", .client_name = "fx" } },
        .ask_form = true,
        .ask_url = false,
    } });
    try testing.expectEqual(key, r.register.key);
    try testing.expectEqualStrings("node", r.register.config.argv[0]);
    try testing.expectEqualStrings("1", r.register.config.env[0].value);
    try testing.expectEqualStrings("/w", r.register.config.cwd.?);
    try testing.expectEqual(@as(u32, 2_000), r.register.config.timeouts.?.refused_ms);
    try testing.expectEqualStrings("fx", r.register.config.auth.client_name);
    try testing.expect(r.register.ask_form and !r.register.ask_url);

    try testing.expectEqual(key, (try expectClient(a, .{ .need = .{ .key = key } })).need.key);
    try testing.expectEqual(key, (try expectClient(a, .{ .unregister = .{ .key = key } })).unregister.key);

    const call = try expectClient(a, .{ .call = .{ .key = key, .id = 7, .tool = "echo", .arguments = "{\"x\":1}" } });
    try testing.expectEqual(@as(u32, 7), call.call.id);
    try testing.expectEqualStrings("echo", call.call.tool);
    try testing.expectEqualStrings("{\"x\":1}", call.call.arguments.?);

    try testing.expectEqual(@as(u32, 9), (try expectClient(a, .{ .cancel = .{ .id = 9 } })).cancel.id);
    try testing.expectEqualStrings("{}", (try expectClient(a, .{ .respond = .{ .id = 1, .values = "{}" } })).respond.values);

    const answer = try expectClient(a, .{ .answer = .{ .key = key, .slot = 2, .n = 3, .action = .accept, .content = "{\"name\":\"Ada\"}" } });
    try testing.expectEqual(@as(u8, 2), answer.answer.slot);
    try testing.expectEqual(mcp.elicitation.Action.accept, answer.answer.action);
    try testing.expectEqualStrings("{\"name\":\"Ada\"}", answer.answer.content.?);

    try testing.expect((try expectClient(a, .bye)) == .bye);
}

test "every owner message round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: share_key.Key = "ffeeddccbbaa99887766554433221100".*;

    try testing.expectEqual(@as(u32, 5), (try expectOwner(a, .{ .welcome = .{ .owner = 5 } })).welcome.owner);

    const phase = try expectOwner(a, .{ .phase = .{ .key = key, .phase = .backoff } });
    try testing.expectEqual(mcp.engine.Phase.backoff, phase.phase.phase);

    const tools = try expectOwner(a, .{ .tools = .{ .key = key, .ok = true, .fresh = false, .needs_auth = false, .tools = "[{\"name\":\"echo\"}]" } });
    try testing.expectEqualStrings("[{\"name\":\"echo\"}]", tools.tools.tools);
    try testing.expect(tools.tools.ok);

    const called = try expectOwner(a, .{ .called = .{ .id = 4, .outcome = .result, .maybe_ran = true, .timed_out = false, .oversized = true, .answer = "{\"content\":[]}", .refused_bytes = 12, .refused_body = true } });
    try testing.expectEqual(@as(u32, 12), called.called.refused_bytes);
    try testing.expect(called.called.refused_body);
    try testing.expectEqual(mcp.engine.Outcome.result, called.called.outcome);
    try testing.expect(called.called.maybe_ran and called.called.oversized);
    try testing.expectEqualStrings("{\"content\":[]}", called.called.answer.?);

    const progress = try expectOwner(a, .{ .progress = .{ .id = 1, .progress = 0.5, .total = 2.0, .message = "half" } });
    try testing.expectEqual(@as(f64, 0.5), progress.progress.progress);
    try testing.expectEqual(@as(f64, 2.0), progress.progress.total.?);
    try testing.expectEqualStrings("half", progress.progress.message.?);

    const input = try expectOwner(a, .{ .input = .{ .id = 3, .requests = "[{\"key\":\"k\",\"raw\":{}}]" } });
    try testing.expectEqualStrings("[{\"key\":\"k\",\"raw\":{}}]", input.input.requests);

    const question = try expectOwner(a, .{ .question = .{ .key = key, .slot = 1, .n = 2, .params = "{\"mode\":\"form\"}", .version = "2025-11-25", .required = true } });
    try testing.expectEqual(@as(u8, 1), question.question.slot);
    try testing.expectEqualStrings("2025-11-25", question.question.version.?);
    try testing.expect(question.question.required);

    try testing.expectEqual(key, (try expectOwner(a, .{ .stopped_idle = .{ .key = key } })).stopped_idle.key);
    const complete = try expectOwner(a, .{ .elicitation_complete = .{ .key = key, .slot = 3 } });
    try testing.expectEqual(@as(u8, 3), complete.elicitation_complete.slot);
    try testing.expectEqual(@as(u8, 4), (try expectOwner(a, .{ .elicit_withdrawn = .{ .key = key, .slot = 4 } })).elicit_withdrawn.slot);

    const status = try expectOwner(a, .{ .status = .{ .key = key, .phase = .failed, .version = "2026-07-28", .last_error = "process", .stderr_tail = "npm error", .instructions = "be nice", .exit_code = 7, .stray_line = "Server started on stdio" } });
    try testing.expectEqual(mcp.engine.Phase.failed, status.status.phase);
    try testing.expectEqualStrings("npm error", status.status.stderr_tail.?);
    try testing.expectEqualStrings("be nice", status.status.instructions.?);
    try testing.expectEqual(@as(?u8, 7), status.status.exit_code);
    try testing.expectEqual(@as(?u8, null), status.status.exit_signal);
    try testing.expectEqualStrings("Server started on stdio", status.status.stray_line.?);
    const signalled = try expectOwner(a, .{ .status = .{ .key = key, .phase = .failed, .exit_signal = 15 } });
    try testing.expectEqual(@as(?u8, 15), signalled.status.exit_signal);
    try testing.expectEqual(@as(?u8, null), signalled.status.exit_code);
    try testing.expectEqual(@as(?[]const u8, null), signalled.status.list_refusal);

    // A refused list's words cross the wire with the list and in a status, so
    // a session that runs the server elsewhere can say why fx refused it.
    const refused = try expectOwner(a, .{ .tools = .{ .key = key, .ok = false, .fresh = false, .needs_auth = false, .list_refusal = "\"tools\" is not a list" } });
    try testing.expectEqualStrings("\"tools\" is not a list", refused.tools.list_refusal.?);
    const refusing = try expectOwner(a, .{ .status = .{ .key = key, .phase = .ready, .list_refusal = "a field is written twice" } });
    try testing.expectEqualStrings("a field is written twice", refusing.status.list_refusal.?);

    // Why a call was lost crosses with its end, so a shared call logs as
    // detailed a reason as one this session ran itself.
    const lost_call = try expectOwner(a, .{ .called = .{ .id = 5, .outcome = .lost, .maybe_ran = true, .timed_out = false, .lost_why = .link_down } });
    try testing.expectEqual(mcp.server.LostWhy.link_down, lost_call.called.lost_why.?);
    const answered = try expectOwner(a, .{ .called = .{ .id = 6, .outcome = .result, .maybe_ran = false, .timed_out = false } });
    try testing.expectEqual(@as(?mcp.server.LostWhy, null), answered.called.lost_why);
}

test "server JSON nested 3000 levels deep crosses the wire as text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: share_key.Key = "ffeeddccbbaa99887766554433221100".*;
    // A server may list a tool, answer a call, or ask a question with JSON
    // nested past any limit fx keeps. The frame copies it, so reading the
    // frame never walks its levels; no writer here aborts on its depth
    // (`src/core/mcp/server_json_depth.zig`).
    const nested = text_utils.repeat("[", 3000) ++ text_utils.repeat("]", 3000);
    const deep = try a.print("{{\"name\":\"deep\",\"_meta\":{s}}}", .{nested[0..]});
    const page = try a.print("[{s}]", .{deep});

    const tools = try expectOwner(a, .{ .tools = .{ .key = key, .ok = true, .fresh = true, .needs_auth = false, .tools = page } });
    try testing.expectEqualStrings(page, tools.tools.tools);
    try testing.expectEqual(@as(?[]const u8, null), tools.tools.list_refusal);

    const called = try expectOwner(a, .{ .called = .{ .id = 4, .outcome = .result, .maybe_ran = false, .timed_out = false, .answer = deep } });
    try testing.expectEqualStrings(deep, called.called.answer.?);

    const question = try expectOwner(a, .{ .question = .{ .key = key, .slot = 1, .n = 2, .params = deep } });
    try testing.expectEqualStrings(deep, question.question.params);

    // A session's own JSON, sent the other way, is text too.
    const call = try expectClient(a, .{ .call = .{ .key = key, .id = 9, .tool = "echo", .arguments = deep } });
    try testing.expectEqualStrings(deep, call.call.arguments.?);
}

test "a truncated frame, an overlong length, bad JSON, an unknown type, and another version are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var header: [header_bytes]u8 = undefined;
    try writeLength(&header, max_frame_bytes);
    try testing.expectEqual(max_frame_bytes, try readLength(&header));
    var too_big: [header_bytes]u8 = undefined;
    std.mem.writeInt(u32, &too_big, @intCast(max_frame_bytes + 1), .big);
    try testing.expectError(error.TooLarge, readLength(&too_big));
    try testing.expectError(error.TooLarge, writeLength(&header, max_frame_bytes + 1));

    try testing.expectError(error.Malformed, decode(a, ""));
    try testing.expectError(error.Malformed, decode(a, "not json"));
    try testing.expectError(error.Malformed, decode(a, "[]"));
    try testing.expectError(error.Malformed, decode(a, try a.print("{{\"v\":{d}}}", .{version})));
    try testing.expectError(error.Malformed, decode(a, try a.print("{{\"v\":{d},\"t\":\"nope\"}}", .{version})));
    try testing.expectError(error.UnsupportedVersion, decode(a, try a.print("{{\"v\":{d},\"t\":\"bye\"}}", .{version + 1})));
    try testing.expectError(error.Malformed, decode(a, try a.print("{{\"v\":{d},\"t\":\"call\",\"key\":\"short\",\"id\":1,\"tool\":\"t\"}}", .{version})));
    try testing.expectError(error.Malformed, decode(a, try a.print("{{\"v\":{d},\"t\":\"call\",\"key\":\"00112233445566778899aabbccddeeff\",\"id\":-1,\"tool\":\"t\"}}", .{version})));
    try testing.expectError(error.Malformed, decode(a, try a.print("{{\"v\":{d},\"t\":\"phase\",\"key\":\"00112233445566778899aabbccddeeff\",\"phase\":\"sleeping\"}}", .{version})));
}

test "a slot above 255 is refused on every message that carries one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = "00112233445566778899aabbccddeeff";
    // A same-user process can write any frame to the socket. The slot is a
    // `u8`, so one above 255 is a malformed frame, never a cast.
    for (256..258) |slot| {
        const frames = [_][]const u8{
            try a.print("{{\"v\":{d},\"t\":\"answer\",\"key\":\"{s}\",\"slot\":{d},\"n\":1,\"action\":\"accept\"}}", .{ version, key, slot }),
            try a.print("{{\"v\":{d},\"t\":\"question\",\"key\":\"{s}\",\"slot\":{d},\"n\":1,\"params\":\"{{}}\"}}", .{ version, key, slot }),
            try a.print("{{\"v\":{d},\"t\":\"elicitation_complete\",\"key\":\"{s}\",\"slot\":{d}}}", .{ version, key, slot }),
            try a.print("{{\"v\":{d},\"t\":\"elicit_withdrawn\",\"key\":\"{s}\",\"slot\":{d}}}", .{ version, key, slot }),
        };
        for (frames) |frame| try testing.expectError(error.Malformed, decode(a, frame));
    }
    // 255 is the last slot a frame may name.
    try testing.expect((try decode(a, try a.print("{{\"v\":{d},\"t\":\"elicitation_complete\",\"key\":\"{s}\",\"slot\":255}}", .{ version, key }))) == .owner);
}

test "a frame nested past the limit is refused before it is parsed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 100,000 levels is 200 KB, far under the frame cap, and would overflow
    // the owner's stack in `std.json` if it were parsed.
    const nested = text_utils.repeat("[", 100_000) ++ text_utils.repeat("]", 100_000);
    const frame = try a.print("{{\"v\":{d},\"t\":\"bye\",\"x\":{s}}}", .{ version, nested[0..] });
    try testing.expectError(error.Malformed, decode(a, frame));
    // One level under the limit still reads.
    const at_limit = text_utils.repeat("[", json_depth.max_depth - 2) ++ text_utils.repeat("]", json_depth.max_depth - 2);
    try testing.expect((try decode(a, try a.print("{{\"v\":{d},\"t\":\"bye\",\"x\":{s}}}", .{ version, at_limit[0..] }))) == .client);
}

test "a tool page of nearly the message limit, dense in quotes, fits the frame cap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: share_key.Key = "00112233445566778899aabbccddeeff".*;
    // The server's JSON is at most the engine's message limit, and every one
    // of these quotes is escaped again in the frame.
    const escaped_quotes = mcp.limits.max_message_bytes / 2 - 8 * 1024;
    var page: std.ArrayList(u8) = .empty;
    try page.appendSlice(a, "[\"");
    for (0..escaped_quotes) |_| try page.appendSlice(a, "\\\"");
    try page.appendSlice(a, "\"]");
    try testing.expect(page.items.len <= mcp.limits.max_message_bytes);

    const frame = try encode(a, OwnerMessage{ .tools = .{ .key = key, .ok = true, .fresh = true, .needs_auth = false, .tools = page.items } });
    try testing.expect(frame.len > mcp.limits.max_message_bytes);
    const back = try decode(a, frame[header_bytes..]);
    try testing.expectEqualStrings(page.items, back.owner.tools.tools);
}

test "an owner wire frame decodes or is refused on fuzzed bytes, and what decodes writes back the same" {
    try std.testing.fuzz({}, fuzzDecode, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"v\":2,\"t\":\"hello\",\"pid\":42}",
            "{\"v\":2,\"t\":\"call\",\"key\":\"00112233445566778899aabbccddeeff\",\"id\":7,\"tool\":\"echo\",\"arguments\":\"{\\\"x\\\":1}\"}",
            "{\"v\":2,\"t\":\"welcome\",\"owner\":5}",
            "{\"v\":2,\"t\":\"tools\",\"key\":\"00112233445566778899aabbccddeeff\",\"ok\":true,\"fresh\":false,\"needs_auth\":false,\"tools\":\"[{\\\"name\\\":\\\"echo\\\"}]\"}",
            "{\"v\":2,\"t\":\"called\",\"id\":4,\"outcome\":\"result\",\"maybe_ran\":false,\"timed_out\":false,\"oversized\":false}",
            "{\"v\":2,\"t\":\"question\",\"key\":\"00112233445566778899aabbccddeeff\",\"slot\":256,\"n\":1,\"params\":\"{}\"}",
            "{\"v\":2,\"t\":\"status\",\"key\":\"00112233445566778899aabbccddeeff\",\"phase\":\"ready\",\"exit_code\":256}",
            "{\"v\":2,\"t\":\"refused\",\"reason\":\"too_many_keys\",\"key\":\"00112233445566778899aabbccddeeff\"}",
            "{\"v\":2,\"t\":\"refused\",\"reason\":\"too_many_calls\",\"key\":\"00112233445566778899aabbccddeeff\",\"call\":9}",
            "[]",
        }) ++ @import("fuzz_corpus").mcp_owner_wire.*),
    });
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [64 * 1024]u8 = undefined;
    const frame_bytes = buffer[0..@intCast(smith.slice(&buffer))];
    const message = decode(arena, frame_bytes) catch return;
    // A frame that decodes is one this build writes: it encodes again and
    // reads back as the same kind of message.
    const reencoded = switch (message) {
        .client => |m| try encode(arena, m),
        .owner => |m| try encode(arena, m),
    };
    const again = try decode(arena, reencoded[header_bytes..]);
    switch (again) {
        .client => |m| try testing.expect(message == .client and std.meta.activeTag(message.client) == std.meta.activeTag(m)),
        .owner => |m| try testing.expect(message == .owner and std.meta.activeTag(message.owner) == std.meta.activeTag(m)),
    }
}

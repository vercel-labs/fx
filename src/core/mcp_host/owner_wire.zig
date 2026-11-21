//! The wire between an fx session and the MCP owner process
//! (`tests/tla/mcp_host/SharedServers.tla`): one Unix socket, length-prefixed
//! JSON frames.
//!
//! A frame is a 4-byte big-endian length, then one JSON object with `"v"` for
//! the wire version and `"t"` naming its type. A frame is capped at the
//! engine's message limit plus room for the envelope, so anything a server can
//! answer fits.
//!
//! Pure: encoding and decoding work on bytes, with no I/O. The socket shells
//! (`owner.zig`, `owner_client.zig`) read and write the frames.
const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");
const share_key = @import("share_key.zig");

const Allocator = std.mem.Allocator;

/// The protocol this build speaks. Another version gets another socket and
/// another lock file, so an older and a newer fx never misread each other.
pub const version: u32 = 1;

/// A frame is at most the engine's message limit plus 64 KiB for the envelope
/// and its fields.
pub const max_frame_bytes: usize = 16 * 1024 * 1024 + 64 * 1024;

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

/// What the owner sends a session.
pub const OwnerMessage = union(enum) {
    welcome: struct { owner: u32 },
    phase: struct { key: share_key.Key, phase: mcp.engine.Phase },
    /// The key's tool list as the engine holds it: raw tool JSON objects.
    tools: struct { key: share_key.Key, ok: bool, fresh: bool, needs_auth: bool, tools: []const u8 = "[]" },
    /// How one of this client's calls ended; `answer` is the `tools.Call`
    /// JSON, or null when the call ended without one.
    called: struct { id: u32, outcome: mcp.engine.Outcome, maybe_ran: bool, timed_out: bool, oversized: bool = false, answer: ?[]const u8 = null, refused_bytes: u32 = 0, refused_body: bool = false },
    progress: struct { id: u32, progress: f64, total: ?f64 = null, message: ?[]const u8 = null },
    /// The call's 2026 input requests, as the `mrtr.Request` list JSON.
    input: struct { id: u32, requests: []const u8 },
    /// A 2025 question, which names no call.
    /// `required`: listed in a call's -32042 error, so nothing is sent back.
    question: struct { key: share_key.Key, slot: u8, n: u32, params: []const u8, version: ?[]const u8 = null, required: bool = false },
    /// The server completed, or withdrew, the 2025 question in `slot`.
    elicitation_complete: struct { key: share_key.Key, slot: u8 },
    elicit_withdrawn: struct { key: share_key.Key, slot: u8 },
    declined: struct { id: u32, why: []const u8 },
    stopped_idle: struct { key: share_key.Key },
    status: struct { key: share_key.Key, phase: mcp.engine.Phase, version: ?[]const u8 = null, last_error: ?[]const u8 = null, stderr_tail: ?[]const u8 = null, instructions: ?[]const u8 = null, exit_code: ?u8 = null, exit_signal: ?u8 = null, stray_line: ?[]const u8 = null },
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
/// against the arena; every text borrows from it.
pub fn decode(arena: Allocator, json: []const u8) DecodeError!Message {
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
        return .{ .owner = try ownerMessage(arena, object, tag) };
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
        .declined => {
            try uint(writer, "id", m.id);
            try textField(writer, "why", m.why);
        },
        .stopped_idle => try bytes(writer, "key", &m.key),
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
            .arguments = try optionalRaw(arena, object, "arguments"),
        } },
        .cancel => .{ .cancel = .{ .id = try u32Field(object, "id") } },
        .respond => .{ .respond = .{ .id = try u32Field(object, "id"), .values = try rawField(arena, object, "values") } },
        .answer => .{ .answer = .{
            .key = try keyField(object, "key"),
            .slot = @intCast(try u32Field(object, "slot")),
            .n = try u32Field(object, "n"),
            .action = std.meta.stringToEnum(mcp.elicitation.Action, try text(object, "action")) orelse return error.Malformed,
            .content = try optionalRaw(arena, object, "content"),
        } },
        .bye => .bye,
    };
}

fn ownerMessage(arena: Allocator, object: std.json.ObjectMap, tag: std.meta.Tag(OwnerMessage)) DecodeError!OwnerMessage {
    return switch (tag) {
        .welcome => .{ .welcome = .{ .owner = try u32Field(object, "owner") } },
        .phase => .{ .phase = .{ .key = try keyField(object, "key"), .phase = try enumField(mcp.engine.Phase, object, "phase") } },
        .tools => .{ .tools = .{
            .key = try keyField(object, "key"),
            .ok = try boolField(object, "ok"),
            .fresh = try boolField(object, "fresh"),
            .needs_auth = try boolField(object, "needs_auth"),
            .tools = try rawField(arena, object, "tools"),
        } },
        .called => .{ .called = .{
            .id = try u32Field(object, "id"),
            .outcome = try enumField(mcp.engine.Outcome, object, "outcome"),
            .maybe_ran = try boolField(object, "maybe_ran"),
            .timed_out = try boolField(object, "timed_out"),
            .oversized = try boolField(object, "oversized"),
            .answer = try optionalRaw(arena, object, "answer"),
            .refused_bytes = try u32FieldDefault(object, "refused_bytes", 0),
            .refused_body = try boolFieldDefault(object, "refused_body", false),
        } },
        .progress => .{ .progress = .{
            .id = try u32Field(object, "id"),
            .progress = try floatField(object, "progress"),
            .total = try optionalFloatField(object, "total"),
            .message = try optionalText(object, "message"),
        } },
        .input => .{ .input = .{ .id = try u32Field(object, "id"), .requests = try rawField(arena, object, "requests") } },
        .question => .{ .question = .{
            .key = try keyField(object, "key"),
            .slot = @intCast(try u32Field(object, "slot")),
            .n = try u32Field(object, "n"),
            .params = try rawField(arena, object, "params"),
            .version = try optionalText(object, "version"),
            .required = try boolFieldDefault(object, "required", false),
        } },
        .elicitation_complete => .{ .elicitation_complete = .{
            .key = try keyField(object, "key"),
            .slot = @intCast(try u32Field(object, "slot")),
        } },
        .elicit_withdrawn => .{ .elicit_withdrawn = .{
            .key = try keyField(object, "key"),
            .slot = @intCast(try u32Field(object, "slot")),
        } },
        .declined => .{ .declined = .{ .id = try u32Field(object, "id"), .why = try text(object, "why") } },
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

fn u32Field(object: std.json.ObjectMap, key: []const u8) DecodeError!u32 {
    const value = object.get(key) orelse return error.Malformed;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.Malformed;
    return @intCast(value.integer);
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

fn keyField(object: std.json.ObjectMap, key: []const u8) DecodeError!share_key.Key {
    const value = try text(object, key);
    if (value.len != @sizeOf(share_key.Key)) return error.Malformed;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.Malformed;
    var out: share_key.Key = undefined;
    @memcpy(&out, value);
    return out;
}

fn rawField(arena: Allocator, object: std.json.ObjectMap, key: []const u8) DecodeError![]const u8 {
    const value = object.get(key) orelse return error.Malformed;
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

fn optionalRaw(arena: Allocator, object: std.json.ObjectMap, key: []const u8) DecodeError!?[]const u8 {
    if (object.get(key) == null) return null;
    return try rawField(arena, object, key);
}

fn textField(writer: *std.Io.Writer, comptime key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(",\"" ++ key ++ "\":");
    try std.json.Stringify.value(value, .{}, writer);
}

fn raw(writer: *std.Io.Writer, comptime key: []const u8, json: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(",\"" ++ key ++ "\":");
    try writer.writeAll(json);
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

    try testing.expectEqualStrings("two callers", (try expectOwner(a, .{ .declined = .{ .id = 2, .why = "two callers" } })).declined.why);
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
    try testing.expectError(error.Malformed, decode(a, "{\"v\":1}"));
    try testing.expectError(error.Malformed, decode(a, "{\"v\":1,\"t\":\"nope\"}"));
    try testing.expectError(error.UnsupportedVersion, decode(a, "{\"v\":2,\"t\":\"bye\"}"));
    try testing.expectError(error.Malformed, decode(a, "{\"v\":1,\"t\":\"call\",\"key\":\"short\",\"id\":1,\"tool\":\"t\"}"));
    try testing.expectError(error.Malformed, decode(a, "{\"v\":1,\"t\":\"call\",\"key\":\"00112233445566778899aabbccddeeff\",\"id\":-1,\"tool\":\"t\"}"));
    try testing.expectError(error.Malformed, decode(a, "{\"v\":1,\"t\":\"phase\",\"key\":\"00112233445566778899aabbccddeeff\",\"phase\":\"sleeping\"}"));
}

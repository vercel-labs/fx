const std = @import("std");

pub const max_frame_bytes: usize = 1024 * 1024;

pub const FrameError = error{
    FrameTooLarge,
    TruncatedFrame,
    InvalidUtf8,
};

pub const protocol_version: u8 = 1;

pub const FailureKind = enum {
    syntax,
    runtime,
    limit,
    approval_required,
    indeterminate,
    protocol,
};

pub const ToolCall = struct {
    id: u8,
    batch_index: u8,
    batch_size: u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const Failure = struct {
    kind: FailureKind,
    message: []const u8,
};

pub const HostMessage = union(enum) {
    ready,
    tool_call: ToolCall,
    completed: []const u8,
    failed: Failure,
};

pub const ToolResultStatus = enum {
    success,
    failure,
};

pub const ToolResult = struct {
    id: u8,
    status: ToolResultStatus,
    value_json: []const u8,
};

pub const ParentMessage = union(enum) {
    execute: []const u8,
    tool_result: ToolResult,
};

pub const ParseError = error{
    MalformedFrame,
    UnsupportedVersion,
    UnknownMessageType,
    UnknownFailureKind,
    UnexpectedField,
    InvalidField,
    FrameTooLarge,
} || std.mem.Allocator.Error;

pub fn encodeFrameHeader(payload_len: usize) FrameError![4]u8 {
    if (payload_len > max_frame_bytes) return error.FrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload_len), .big);
    return header;
}

pub fn decodeFrameHeader(header: [4]u8) FrameError!usize {
    const payload_len = std.mem.readInt(u32, &header, .big);
    if (payload_len > max_frame_bytes) return error.FrameTooLarge;
    return payload_len;
}

pub fn readPayload(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
) (FrameError || std.mem.Allocator.Error || std.Io.Reader.Error)![]u8 {
    var header: [4]u8 = undefined;
    reader.readSliceAll(&header) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedFrame,
        else => return err,
    };
    const payload_len = try decodeFrameHeader(header);
    const payload = try alloc.alloc(u8, payload_len);
    errdefer alloc.free(payload);
    reader.readSliceAll(payload) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedFrame,
        else => return err,
    };
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;
    return payload;
}

pub fn writePayload(
    writer: *std.Io.Writer,
    payload: []const u8,
) (FrameError || std.Io.Writer.Error)!void {
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;
    const header = try encodeFrameHeader(payload.len);
    try writer.writeAll(&header);
    try writer.writeAll(payload);
    try writer.flush();
}

pub fn parseHostMessage(alloc: std.mem.Allocator, bytes: []const u8) ParseError!HostMessage {
    if (bytes.len > max_frame_bytes) return error.FrameTooLarge;
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        bytes,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedFrame,
    };
    if (parsed != .object) return error.MalformedFrame;
    const object = parsed.object;
    try validateVersion(object);
    const type_value = object.get("type") orelse return error.InvalidField;
    if (type_value != .string) return error.InvalidField;

    if (std.mem.eql(u8, type_value.string, "ready")) {
        try ensureAllowedFields(object, &.{ "version", "type" });
        return .ready;
    }
    if (std.mem.eql(u8, type_value.string, "tool_call")) {
        try ensureAllowedFields(
            object,
            &.{ "version", "type", "id", "batch_index", "batch_size", "name", "arguments_json" },
        );
        const id_value = object.get("id") orelse return error.InvalidField;
        const batch_index = object.get("batch_index") orelse return error.InvalidField;
        const batch_size = object.get("batch_size") orelse return error.InvalidField;
        const name_value = object.get("name") orelse return error.InvalidField;
        const arguments_value = object.get("arguments_json") orelse
            return error.InvalidField;
        if (id_value != .integer or
            id_value.integer < 0 or
            id_value.integer > std.math.maxInt(u8) or
            batch_index != .integer or
            batch_index.integer < 0 or
            batch_index.integer > std.math.maxInt(u8) or
            batch_size != .integer or
            batch_size.integer < 1 or
            batch_size.integer > 8 or
            batch_index.integer >= batch_size.integer or
            name_value != .string or
            name_value.string.len == 0 or
            arguments_value != .string)
        {
            return error.InvalidField;
        }
        return .{ .tool_call = .{
            .id = @intCast(id_value.integer),
            .batch_index = @intCast(batch_index.integer),
            .batch_size = @intCast(batch_size.integer),
            .name = name_value.string,
            .arguments_json = arguments_value.string,
        } };
    }
    if (std.mem.eql(u8, type_value.string, "completed")) {
        try ensureAllowedFields(object, &.{ "version", "type", "result_json" });
        const result = object.get("result_json") orelse return error.InvalidField;
        if (result != .string) return error.InvalidField;
        return .{ .completed = result.string };
    }
    if (std.mem.eql(u8, type_value.string, "failed")) {
        try ensureAllowedFields(
            object,
            &.{ "version", "type", "kind", "message" },
        );
        const kind_value = object.get("kind") orelse return error.InvalidField;
        const message = object.get("message") orelse return error.InvalidField;
        if (kind_value != .string or message != .string) return error.InvalidField;
        return .{ .failed = .{
            .kind = failureKind(kind_value.string) orelse
                return error.UnknownFailureKind,
            .message = message.string,
        } };
    }
    return error.UnknownMessageType;
}

pub fn parseParentMessage(
    alloc: std.mem.Allocator,
    bytes: []const u8,
) ParseError!ParentMessage {
    if (bytes.len > max_frame_bytes) return error.FrameTooLarge;
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        bytes,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedFrame,
    };
    if (parsed != .object) return error.MalformedFrame;
    const object = parsed.object;
    try validateVersion(object);
    const type_value = object.get("type") orelse return error.InvalidField;
    if (type_value != .string) return error.InvalidField;

    if (std.mem.eql(u8, type_value.string, "execute")) {
        try ensureAllowedFields(object, &.{ "version", "type", "source" });
        const source = object.get("source") orelse return error.InvalidField;
        if (source != .string or source.string.len > 64 * 1024) {
            return error.InvalidField;
        }
        return .{ .execute = source.string };
    }
    if (std.mem.eql(u8, type_value.string, "tool_result")) {
        try ensureAllowedFields(
            object,
            &.{ "version", "type", "id", "status", "value_json" },
        );
        const id = object.get("id") orelse return error.InvalidField;
        const status = object.get("status") orelse return error.InvalidField;
        const value = object.get("value_json") orelse return error.InvalidField;
        if (id != .integer or
            id.integer < 0 or
            id.integer > std.math.maxInt(u8) or
            status != .string or
            value != .string)
        {
            return error.InvalidField;
        }
        return .{ .tool_result = .{
            .id = @intCast(id.integer),
            .status = std.meta.stringToEnum(
                ToolResultStatus,
                status.string,
            ) orelse return error.InvalidField,
            .value_json = value.string,
        } };
    }
    return error.UnknownMessageType;
}

pub fn encodeHostMessage(
    alloc: std.mem.Allocator,
    message: HostMessage,
) (std.mem.Allocator.Error || error{WriteFailed})![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"version\":{d},\"type\":", .{protocol_version});
    switch (message) {
        .ready => try out.writer.writeAll("\"ready\"}"),
        .tool_call => |call| {
            try out.writer.writeAll("\"tool_call\",\"id\":");
            try out.writer.print(
                "{d},\"batch_index\":{d},\"batch_size\":{d},\"name\":",
                .{ call.id, call.batch_index, call.batch_size },
            );
            try std.json.Stringify.value(call.name, .{}, &out.writer);
            try out.writer.writeAll(",\"arguments_json\":");
            try std.json.Stringify.value(
                call.arguments_json,
                .{},
                &out.writer,
            );
            try out.writer.writeByte('}');
        },
        .completed => |result| {
            try out.writer.writeAll("\"completed\",\"result_json\":");
            try std.json.Stringify.value(result, .{}, &out.writer);
            try out.writer.writeByte('}');
        },
        .failed => |failure| {
            try out.writer.writeAll("\"failed\",\"kind\":");
            try std.json.Stringify.value(
                @tagName(failure.kind),
                .{},
                &out.writer,
            );
            try out.writer.writeAll(",\"message\":");
            try std.json.Stringify.value(failure.message, .{}, &out.writer);
            try out.writer.writeByte('}');
        },
    }
    return out.toOwnedSlice();
}

pub fn encodeParentMessage(
    alloc: std.mem.Allocator,
    message: ParentMessage,
) (std.mem.Allocator.Error || error{WriteFailed})![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"version\":{d},\"type\":", .{protocol_version});
    switch (message) {
        .execute => |source| {
            try out.writer.writeAll("\"execute\",\"source\":");
            try std.json.Stringify.value(source, .{}, &out.writer);
            try out.writer.writeByte('}');
        },
        .tool_result => |result| {
            try out.writer.writeAll("\"tool_result\",\"id\":");
            try out.writer.print("{d},\"status\":", .{result.id});
            try std.json.Stringify.value(
                @tagName(result.status),
                .{},
                &out.writer,
            );
            try out.writer.writeAll(",\"value_json\":");
            try std.json.Stringify.value(
                result.value_json,
                .{},
                &out.writer,
            );
            try out.writer.writeByte('}');
        },
    }
    return out.toOwnedSlice();
}

fn validateVersion(object: std.json.ObjectMap) ParseError!void {
    const version_value = object.get("version") orelse return error.InvalidField;
    if (version_value != .integer or
        version_value.integer != protocol_version)
    {
        return error.UnsupportedVersion;
    }
}

fn ensureAllowedFields(
    object: std.json.ObjectMap,
    allowed: []const []const u8,
) ParseError!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var matched = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                matched = true;
                break;
            }
        }
        if (!matched) return error.UnexpectedField;
    }
}

fn failureKind(value: []const u8) ?FailureKind {
    inline for (std.meta.tags(FailureKind)) |kind| {
        if (std.mem.eql(u8, value, @tagName(kind))) return kind;
    }
    return null;
}

test "frame header round trips the maximum payload and rejects one over" {
    const header = try encodeFrameHeader(max_frame_bytes);
    try std.testing.expectEqual(max_frame_bytes, try decodeFrameHeader(header));
    try std.testing.expectError(
        error.FrameTooLarge,
        encodeFrameHeader(max_frame_bytes + 1),
    );
}

test "host tool call preserves version identity and serialized arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const message = try parseHostMessage(
        arena_state.allocator(),
        "{\"version\":1,\"type\":\"tool_call\",\"id\":7,\"batch_index\":0,\"batch_size\":1,\"name\":\"read_file\",\"arguments_json\":\"{\\\"path\\\":\\\"README.md\\\"}\"}",
    );
    try std.testing.expect(message == .tool_call);
    try std.testing.expectEqual(@as(u8, 7), message.tool_call.id);
    try std.testing.expectEqual(@as(u8, 0), message.tool_call.batch_index);
    try std.testing.expectEqual(@as(u8, 1), message.tool_call.batch_size);
    try std.testing.expectEqualStrings("read_file", message.tool_call.name);
    try std.testing.expectEqualStrings(
        "{\"path\":\"README.md\"}",
        message.tool_call.arguments_json,
    );

    try std.testing.expectError(
        error.UnknownMessageType,
        parseHostMessage(
            arena_state.allocator(),
            "{\"version\":1,\"type\":\"future\"}",
        ),
    );
}

test "parent execute and host completion preserve opaque JSON payloads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parent = try parseParentMessage(
        arena,
        "{\"version\":1,\"type\":\"execute\",\"source\":\"return 42;\"}",
    );
    try std.testing.expect(parent == .execute);
    try std.testing.expectEqualStrings("return 42;", parent.execute);

    const encoded = try encodeHostMessage(arena, .{
        .completed = "{\"answer\":42}",
    });
    const host = try parseHostMessage(arena, encoded);
    try std.testing.expect(host == .completed);
    try std.testing.expectEqualStrings("{\"answer\":42}", host.completed);
}

test "framed payload writes and reads one exact message" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writePayload(&output.writer, "{\"version\":1,\"type\":\"ready\"}");

    var input = std.Io.Reader.fixed(output.written());
    const payload = try readPayload(std.testing.allocator, &input);
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings(
        "{\"version\":1,\"type\":\"ready\"}",
        payload,
    );
}

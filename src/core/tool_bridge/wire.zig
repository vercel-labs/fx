//! The `fx mcp call` wire format between the client a shell command runs
//! and the session's bridge (`bridge.zig`), over one Unix socket
//! connection per call.
//!
//! The client sends one request line, a call or a lookup:
//!
//!   {"v":1,"token":"<64 hex digits>","op":"call","tool":"mcp_linear_list_issues","arguments":{...}}
//!   {"v":1,"token":"<64 hex digits>","op":"list","server":"linear"}
//!   {"v":1,"token":"<64 hex digits>","op":"search","query":"open issues"}
//!   {"v":1,"token":"<64 hex digits>","op":"help","tool":"mcp_linear_list_issues"}
//!   {"v":1,"token":"<64 hex digits>","op":"edit","path":"f.txt","blocks":[{"search":"a\n","replace":"b\n"}]}
//!   {"v":1,"token":"<64 hex digits>","op":"write","path":"f.txt","content":"..."}
//!
//! and the bridge answers with one header line and the bytes it announces:
//!
//!   {"v":1,"status":"ok","bytes":1234}\n<1234 bytes>
//!
//! `status` is `ok` (the bytes are the tool's data), `tool_error` (the
//! tool's error), `failed` or `denied` (what went wrong), or `refused`, with
//! `reason` naming the refusal. Pure: no I/O, so it is tested on bytes.
const std = @import("std");
const capability_mod = @import("capability.zig");
const edit_blocks = @import("edit_blocks.zig");
const mcp_call = @import("core.zig");

const Allocator = std.mem.Allocator;

/// The bridge's socket, for commands the session's shell tool runs.
pub const socket_env = "FX_MCP_CALL_SOCKET";
/// The token of the shell call that ran the command.
pub const token_env = "FX_MCP_CALL_TOKEN";

/// The longest request line the bridge reads.
pub const max_request_bytes: usize = 1024 * 1024;
/// The longest reply header line the client reads.
pub const max_header_bytes: usize = 4 * 1024;

pub const token_hex_len = 2 * @sizeOf(mcp_call.Token);

pub fn tokenHex(token: mcp_call.Token) [token_hex_len]u8 {
    return std.fmt.bytesToHex(token, .lower);
}

/// The token a hex string names, or null when it names none.
pub fn parseToken(hex: []const u8) ?mcp_call.Token {
    if (hex.len != token_hex_len) return null;
    var token: mcp_call.Token = undefined;
    _ = std.fmt.hexToBytes(&token, hex) catch return null;
    return token;
}

/// What a request asks for.
pub const Operation = union(enum) {
    /// Run `tool` with the arguments object, as JSON text.
    call: struct { tool: []const u8, arguments_json: []const u8 },
    list: []const u8,
    search: []const u8,
    help: []const u8,
    /// `fx tool edit PATH`: one or more blocks, applied in order.
    edit: capability_mod.EditRequest,
    /// `fx tool write PATH`: the whole content of a file.
    write: capability_mod.WriteRequest,

    /// The lookup this operation is, or null for a change or a call.
    pub fn lookup(self: Operation) ?capability_mod.Lookup {
        return switch (self) {
            .call, .edit, .write => null,
            .list => |server| .{ .list = server },
            .search => |query| .{ .search = query },
            .help => |tool| .{ .help = tool },
        };
    }

    /// What the request names, for logs and messages.
    pub fn subject(self: Operation) []const u8 {
        return switch (self) {
            .call => |value| value.tool,
            .edit => |value| value.path,
            .write => |value| value.path,
            .list, .search, .help => |text| text,
        };
    }
};

pub const Request = struct {
    version: u32,
    /// Null when the client sent no well-formed token.
    token: ?mcp_call.Token,
    operation: Operation,
};

pub const RequestError = error{ MalformedRequest, OutOfMemory };

/// Parses one request line. The result borrows from `arena`.
pub fn parseRequest(arena: Allocator, line: []const u8) RequestError!Request {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedRequest,
    };
    if (value != .object) return error.MalformedRequest;
    const object = value.object;
    const version = object.get("v") orelse return error.MalformedRequest;
    if (version != .integer or version.integer < 0 or version.integer > std.math.maxInt(u32)) return error.MalformedRequest;
    const token = object.get("token") orelse return error.MalformedRequest;
    if (token != .string) return error.MalformedRequest;
    const op = object.get("op") orelse return error.MalformedRequest;
    if (op != .string) return error.MalformedRequest;
    const kind = std.meta.stringToEnum(std.meta.Tag(Operation), op.string) orelse return error.MalformedRequest;
    const operation: Operation = switch (kind) {
        .call => blk: {
            const arguments = object.get("arguments") orelse return error.MalformedRequest;
            if (arguments != .object) return error.MalformedRequest;
            var out: std.Io.Writer.Allocating = .init(arena);
            std.json.Stringify.value(arguments, .{}, &out.writer) catch return error.OutOfMemory;
            break :blk .{ .call = .{ .tool = try nonEmptyString(object, "tool"), .arguments_json = out.written() } };
        },
        .list => .{ .list = try nonEmptyString(object, "server") },
        .search => .{ .search = try nonEmptyString(object, "query") },
        .help => .{ .help = try nonEmptyString(object, "tool") },
        .edit => .{ .edit = .{ .path = try nonEmptyString(object, "path"), .blocks = try parseEditBlocks(arena, object) } },
        .write => .{ .write = .{ .path = try nonEmptyString(object, "path"), .content = try stringField(object, "content") } },
    };
    return .{
        .version = @intCast(version.integer),
        .token = parseToken(token.string),
        .operation = operation,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) RequestError![]const u8 {
    const value = object.get(key) orelse return error.MalformedRequest;
    if (value != .string) return error.MalformedRequest;
    return value.string;
}

fn nonEmptyString(object: std.json.ObjectMap, key: []const u8) RequestError![]const u8 {
    const text = try stringField(object, key);
    if (text.len == 0) return error.MalformedRequest;
    return text;
}

/// The blocks of an edit line: one to `edit_blocks.max_blocks`, each with a
/// non-empty search and a replace, which may be empty to delete the search text.
fn parseEditBlocks(arena: Allocator, object: std.json.ObjectMap) RequestError![]const edit_blocks.Edit {
    const value = object.get("blocks") orelse return error.MalformedRequest;
    if (value != .array) return error.MalformedRequest;
    const items = value.array.items;
    if (items.len == 0 or items.len > edit_blocks.max_blocks) return error.MalformedRequest;
    const blocks = try arena.alloc(edit_blocks.Edit, items.len);
    for (items, blocks) |item, *block| {
        if (item != .object) return error.MalformedRequest;
        const search = try stringField(item.object, "search");
        if (search.len == 0) return error.MalformedRequest;
        block.* = .{ .search = search, .replace = try stringField(item.object, "replace") };
    }
    return blocks;
}

/// Writes one request line. A call's `arguments_json` must be a JSON object.
pub fn writeRequest(writer: *std.Io.Writer, token: mcp_call.Token, operation: Operation) std.Io.Writer.Error!void {
    const hex = tokenHex(token);
    try writer.print("{{\"v\":{d},\"token\":\"{s}\",\"op\":\"{s}\"", .{ mcp_call.protocol_version, &hex, @tagName(operation) });
    switch (operation) {
        .call => |value| {
            try writer.writeAll(",\"tool\":");
            try std.json.Stringify.value(value.tool, .{}, writer);
            try writer.writeAll(",\"arguments\":");
            try writer.writeAll(value.arguments_json);
        },
        .list => |server| try writeField(writer, "server", server),
        .search => |query| try writeField(writer, "query", query),
        .help => |tool| try writeField(writer, "tool", tool),
        .edit => |value| {
            try writeField(writer, "path", value.path);
            try writer.writeAll(",\"blocks\":[");
            for (value.blocks, 0..) |block, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeAll("{\"search\":");
                try std.json.Stringify.value(block.search, .{}, writer);
                try writer.writeAll(",\"replace\":");
                try std.json.Stringify.value(block.replace, .{}, writer);
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
        },
        .write => |value| {
            try writeField(writer, "path", value.path);
            try writeField(writer, "content", value.content);
        },
    }
    try writer.writeAll("}\n");
}

fn writeField(writer: *std.Io.Writer, comptime key: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(",\"" ++ key ++ "\":");
    try std.json.Stringify.value(text, .{}, writer);
}

pub const Status = enum { ok, tool_error, failed, denied, refused };

/// Why the bridge refused a request: the core's refusals, and the two the
/// shell decides before the core sees a request.
pub const Reason = enum {
    closed,
    unauthorized,
    unsupported_version,
    busy,
    /// The request line was not a request.
    malformed,
    /// The request line was longer than `max_request_bytes`.
    too_large,
    /// A file change from a command that is not a bash tool program. Only the
    /// bash tool's programs get `fx tool`'s file changes.
    file_tool_unavailable,

    pub fn fromRefusal(refusal: mcp_call.Refusal) Reason {
        return switch (refusal) {
            .closed => .closed,
            .unauthorized => .unauthorized,
            .unsupported_version => .unsupported_version,
            .busy => .busy,
        };
    }
};

pub const Header = struct {
    status: Status,
    reason: ?Reason = null,
    bytes: u64,
};

pub fn writeHeader(writer: *std.Io.Writer, header: Header) std.Io.Writer.Error!void {
    try writer.print("{{\"v\":{d},\"status\":\"{s}\"", .{ mcp_call.protocol_version, @tagName(header.status) });
    if (header.reason) |reason| try writer.print(",\"reason\":\"{s}\"", .{@tagName(reason)});
    try writer.print(",\"bytes\":{d}}}\n", .{header.bytes});
}

pub const HeaderError = error{ MalformedReply, UnsupportedReply, OutOfMemory };

/// Parses a reply header line, without its newline.
pub fn parseHeader(arena: Allocator, line: []const u8) HeaderError!Header {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedReply,
    };
    if (value != .object) return error.MalformedReply;
    const version = value.object.get("v") orelse return error.MalformedReply;
    if (version != .integer) return error.MalformedReply;
    if (version.integer != mcp_call.protocol_version) return error.UnsupportedReply;
    const status = value.object.get("status") orelse return error.MalformedReply;
    if (status != .string) return error.MalformedReply;
    const bytes = value.object.get("bytes") orelse return error.MalformedReply;
    if (bytes != .integer or bytes.integer < 0) return error.MalformedReply;
    const reason: ?Reason = if (value.object.get("reason")) |raw| blk: {
        if (raw != .string) return error.MalformedReply;
        break :blk std.meta.stringToEnum(Reason, raw.string) orelse return error.MalformedReply;
    } else null;
    return .{
        .status = std.meta.stringToEnum(Status, status.string) orelse return error.MalformedReply,
        .reason = reason,
        .bytes = @intCast(bytes.integer),
    };
}

test "a request line round-trips, and a bad token parses as no token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token: mcp_call.Token = @splat(0xab);
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeRequest(&out.writer, token, .{ .call = .{ .tool = "mcp_linear_list_issues", .arguments_json = "{\"team\":\"ENG\"}" } });
    const line = out.written();
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
    const parsed = try parseRequest(arena, line[0 .. line.len - 1]);
    try std.testing.expectEqual(@as(u32, 1), parsed.version);
    try std.testing.expectEqualSlices(u8, &token, &parsed.token.?);
    try std.testing.expectEqualStrings("mcp_linear_list_issues", parsed.operation.call.tool);
    try std.testing.expectEqualStrings("{\"team\":\"ENG\"}", parsed.operation.call.arguments_json);

    const forged = try parseRequest(arena, "{\"v\":1,\"token\":\"nothex\",\"op\":\"call\",\"tool\":\"t\",\"arguments\":{}}");
    try std.testing.expect(forged.token == null);
}

test "each lookup round-trips with its text, quotes included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token: mcp_call.Token = @splat(0x01);
    for ([_]Operation{
        .{ .list = "linear" },
        .{ .search = "open \"issues\" for me" },
        .{ .help = "mcp_linear_list_issues" },
    }) |operation| {
        var out: std.Io.Writer.Allocating = .init(arena);
        try writeRequest(&out.writer, token, operation);
        const line = out.written();
        const parsed = try parseRequest(arena, line[0 .. line.len - 1]);
        try std.testing.expectEqual(std.meta.activeTag(operation), std.meta.activeTag(parsed.operation));
        try std.testing.expectEqualStrings(operation.subject(), parsed.operation.subject());
        try std.testing.expect(parsed.operation.lookup() != null);
    }
}

test "garbage request lines are malformed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "",
        "not json",
        "[]",
        "{\"v\":1,\"token\":\"\",\"tool\":\"t\",\"arguments\":{}}",
        "{\"v\":1,\"token\":\"\",\"op\":\"run\",\"tool\":\"t\",\"arguments\":{}}",
        "{\"v\":1,\"token\":\"\",\"op\":\"call\",\"tool\":\"t\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"call\",\"tool\":\"t\",\"arguments\":[]}",
        "{\"v\":-1,\"token\":\"\",\"op\":\"call\",\"tool\":\"t\",\"arguments\":{}}",
        "{\"v\":1,\"token\":7,\"op\":\"call\",\"tool\":\"t\",\"arguments\":{}}",
        "{\"v\":1,\"token\":\"\",\"op\":\"call\",\"tool\":\"\",\"arguments\":{}}",
        "{\"v\":1,\"token\":\"\",\"op\":\"list\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"search\",\"query\":\"\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"help\",\"tool\":7}",
    }) |line| try std.testing.expectError(error.MalformedRequest, parseRequest(arena, line));
}

test "a reply header round-trips and rejects another version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeHeader(&out.writer, .{ .status = .refused, .reason = .busy, .bytes = 12 });
    const line = out.written();
    const header = try parseHeader(arena, line[0 .. line.len - 1]);
    try std.testing.expectEqual(Status.refused, header.status);
    try std.testing.expectEqual(Reason.busy, header.reason.?);
    try std.testing.expectEqual(@as(u64, 12), header.bytes);
    try std.testing.expectError(error.UnsupportedReply, parseHeader(arena, "{\"v\":2,\"status\":\"ok\",\"bytes\":0}"));
    try std.testing.expectError(error.MalformedReply, parseHeader(arena, "{\"v\":1,\"status\":\"maybe\",\"bytes\":0}"));
}

test "an edit line keeps its path and its blocks in order, quotes and newlines included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token: mcp_call.Token = @splat(0x02);
    const blocks = [_]edit_blocks.Edit{
        .{ .search = "old \"quoted\"\n", .replace = "new\n" },
        .{ .search = "gone\n", .replace = "" },
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeRequest(&out.writer, token, .{ .edit = .{ .path = "a/b.txt", .blocks = &blocks } });
    const line = out.written();
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
    const parsed = try parseRequest(arena, line[0 .. line.len - 1]);
    try std.testing.expectEqual(Operation.edit, std.meta.activeTag(parsed.operation));
    try std.testing.expectEqualStrings("a/b.txt", parsed.operation.edit.path);
    try std.testing.expectEqual(@as(usize, 2), parsed.operation.edit.blocks.len);
    try std.testing.expectEqualStrings("old \"quoted\"\n", parsed.operation.edit.blocks[0].search);
    try std.testing.expectEqualStrings("new\n", parsed.operation.edit.blocks[0].replace);
    try std.testing.expectEqualStrings("gone\n", parsed.operation.edit.blocks[1].search);
    try std.testing.expectEqualStrings("", parsed.operation.edit.blocks[1].replace);
    try std.testing.expect(parsed.operation.lookup() == null);
    try std.testing.expectEqualStrings("a/b.txt", parsed.operation.subject());
}

test "a write line keeps its path and content, and an empty content is a write" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token: mcp_call.Token = @splat(0x03);
    for ([_][]const u8{ "first\nsecond \"line\"\n", "" }) |content| {
        var out: std.Io.Writer.Allocating = .init(arena);
        try writeRequest(&out.writer, token, .{ .write = .{ .path = "notes.txt", .content = content } });
        const line = out.written();
        const parsed = try parseRequest(arena, line[0 .. line.len - 1]);
        try std.testing.expectEqual(Operation.write, std.meta.activeTag(parsed.operation));
        try std.testing.expectEqualStrings("notes.txt", parsed.operation.write.path);
        try std.testing.expectEqualStrings(content, parsed.operation.write.content);
    }
}

test "an edit line with no blocks, an empty search, a missing field, or too many blocks is malformed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "{\"v\":1,\"token\":\"\",\"op\":\"edit\",\"path\":\"f\",\"blocks\":[]}",
        "{\"v\":1,\"token\":\"\",\"op\":\"edit\",\"path\":\"f\",\"blocks\":[{\"search\":\"\",\"replace\":\"x\"}]}",
        "{\"v\":1,\"token\":\"\",\"op\":\"edit\",\"path\":\"f\",\"blocks\":[{\"search\":\"a\"}]}",
        "{\"v\":1,\"token\":\"\",\"op\":\"edit\",\"path\":\"f\",\"blocks\":{}}",
        "{\"v\":1,\"token\":\"\",\"op\":\"edit\",\"path\":\"\",\"blocks\":[{\"search\":\"a\",\"replace\":\"b\"}]}",
        "{\"v\":1,\"token\":\"\",\"op\":\"edit\",\"path\":\"f\"}",
    }) |line| try std.testing.expectError(error.MalformedRequest, parseRequest(arena, line));

    const full = try editLineWithBlocks(arena, edit_blocks.max_blocks);
    const parsed = try parseRequest(arena, full);
    try std.testing.expectEqual(edit_blocks.max_blocks, parsed.operation.edit.blocks.len);
    const over = try editLineWithBlocks(arena, edit_blocks.max_blocks + 1);
    try std.testing.expectError(error.MalformedRequest, parseRequest(arena, over));
}

fn editLineWithBlocks(arena: Allocator, count: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"v\":1,\"token\":\"\",\"op\":\"edit\",\"path\":\"f\",\"blocks\":[");
    for (0..count) |index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"search\":\"a\",\"replace\":\"b\"}");
    }
    try out.writer.writeAll("]}");
    return out.written();
}

test "a write line needs its content field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "{\"v\":1,\"token\":\"\",\"op\":\"write\",\"path\":\"f\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"write\",\"path\":\"f\",\"content\":3}",
        "{\"v\":1,\"token\":\"\",\"op\":\"write\",\"content\":\"x\"}",
    }) |line| try std.testing.expectError(error.MalformedRequest, parseRequest(arena, line));
}

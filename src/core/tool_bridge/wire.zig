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
const json_depth = @import("../shared/json_depth.zig");
const text_utils = @import("../shared/text_utils.zig");
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
/// The longest reply notice the bridge sends, after it is encoded as one terminal-safe line.
pub const max_notice_bytes: usize = 1024;
/// Deepest nesting a request line may have, counted on its raw text once the
/// line has parsed, before any field is read or written back. The envelope
/// object is level 1, so `arguments` keeps the depth `json_depth.max_depth`
/// allows when it is counted from its own object.
const max_line_depth: usize = json_depth.max_depth + 1;

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
    skill_list,
    skill_open: capability_mod.SkillOpenRequest,
    agent_message: capability_mod.AgentMessageRequest,
    agent_wait,
    agent_status: ?[]const u8,
    agent_stop: []const u8,
    agent_close: []const u8,

    /// The lookup this operation is, or null for a change or a call.
    pub fn lookup(self: Operation) ?capability_mod.Lookup {
        return switch (self) {
            .call, .edit, .write, .skill_list, .skill_open, .agent_message, .agent_wait, .agent_status, .agent_stop, .agent_close => null,
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
            .skill_list => "skill list",
            .skill_open => |value| value.name,
            .agent_message => |value| value.agent,
            .agent_wait => "agent wait",
            .agent_status => |agent| agent orelse "agent status",
            .agent_stop => |agent| agent,
            .agent_close => |agent| agent,
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
    if (line.len > max_request_bytes) return error.MalformedRequest;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedRequest,
    };
    if (json_depth.exceedsDepth(line, max_line_depth)) return error.MalformedRequest;
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
        .skill_list => .skill_list,
        .skill_open => .{ .skill_open = .{
            .name = try nonEmptyString(object, "name"),
            .resource = try optionalNonEmptyString(object, "resource"),
        } },
        .agent_message => .{ .agent_message = .{
            .agent = try nonEmptyString(object, "agent"),
            .message = try nonEmptyString(object, "message"),
            .instructions = try optionalNonEmptyString(object, "instructions"),
            .model = try optionalNonEmptyString(object, "model"),
            .effort = try optionalNonEmptyString(object, "effort"),
            .profile = try optionalNonEmptyString(object, "profile"),
            .report = try optionalReport(object),
        } },
        .agent_wait => .agent_wait,
        .agent_status => .{ .agent_status = try optionalNonEmptyString(object, "agent") },
        .agent_stop => .{ .agent_stop = try nonEmptyString(object, "agent") },
        .agent_close => .{ .agent_close = try nonEmptyString(object, "agent") },
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

fn optionalNonEmptyString(object: std.json.ObjectMap, key: []const u8) RequestError!?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return error.MalformedRequest;
    return value.string;
}

fn optionalReport(object: std.json.ObjectMap) RequestError!?capability_mod.AgentReport {
    const raw = (try optionalNonEmptyString(object, "report")) orelse return null;
    return capability_mod.AgentReport.parse(raw) orelse error.MalformedRequest;
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
        .skill_list, .agent_wait => {},
        .skill_open => |value| {
            try writeField(writer, "name", value.name);
            if (value.resource) |resource| try writeField(writer, "resource", resource);
        },
        .agent_message => |value| {
            try writeField(writer, "agent", value.agent);
            try writeField(writer, "message", value.message);
            if (value.instructions) |instructions| try writeField(writer, "instructions", instructions);
            if (value.model) |model| try writeField(writer, "model", model);
            if (value.effort) |effort| try writeField(writer, "effort", effort);
            if (value.profile) |profile| try writeField(writer, "profile", profile);
            if (value.report) |report| try writeField(writer, "report", report.name());
        },
        .agent_status => |maybe_agent| {
            if (maybe_agent) |agent| try writeField(writer, "agent", agent);
        },
        .agent_stop, .agent_close => |agent| try writeField(writer, "agent", agent),
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
    /// A one-line diagnostic for stderr, already bounded by `boundedNotice`.
    notice: ?[]const u8 = null,
};

/// The notice as the bridge sends it: terminal-safe, one line, and at most
/// `max_notice_bytes`, cut on a token boundary with "...".
pub fn boundedNotice(arena: Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    return (try text_utils.encodeTerminalSafeInline(arena, raw, max_notice_bytes)).bytes;
}

pub fn writeHeader(writer: *std.Io.Writer, header: Header) std.Io.Writer.Error!void {
    try writer.print("{{\"v\":{d},\"status\":\"{s}\"", .{ mcp_call.protocol_version, @tagName(header.status) });
    if (header.reason) |reason| try writer.print(",\"reason\":\"{s}\"", .{@tagName(reason)});
    if (header.notice) |notice| {
        try writer.writeAll(",\"notice\":");
        try std.json.Stringify.value(notice, .{}, writer);
    }
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
    const notice: ?[]const u8 = if (value.object.get("notice")) |raw| blk: {
        if (raw != .string) return error.MalformedReply;
        break :blk raw.string;
    } else null;
    return .{
        .status = std.meta.stringToEnum(Status, status.string) orelse return error.MalformedReply,
        .reason = reason,
        .bytes = @intCast(bytes.integer),
        .notice = notice,
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

test "a reply header round-trips with and without a notice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeHeader(&out.writer, .{ .status = .ok, .bytes = 5, .notice = "a \"quoted\" note" });
    const with_notice = out.written();
    const parsed = try parseHeader(arena, with_notice[0 .. with_notice.len - 1]);
    try std.testing.expectEqualStrings("a \"quoted\" note", parsed.notice orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(u64, 5), parsed.bytes);

    var plain: std.Io.Writer.Allocating = .init(arena);
    try writeHeader(&plain.writer, .{ .status = .ok, .bytes = 5 });
    const without = plain.written();
    const bare = try parseHeader(arena, without[0 .. without.len - 1]);
    try std.testing.expect(bare.notice == null);
}

test "a reply header refuses a notice that is not a string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.MalformedReply, parseHeader(arena, "{\"v\":1,\"status\":\"ok\",\"bytes\":0,\"notice\":7}"));
}

test "a notice is cut to the bound and encoded as one terminal-safe line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var raw: std.Io.Writer.Allocating = .init(arena);
    try raw.writer.writeAll("\x1b[31m\nnote ");
    try raw.writer.splatByteAll('a', 3000);
    const bounded = try boundedNotice(arena, raw.written());
    try std.testing.expect(bounded.len <= max_notice_bytes);
    try std.testing.expect(std.mem.findScalar(u8, bounded, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, bounded, '\n') == null);
    try std.testing.expect(std.mem.endsWith(u8, bounded, "..."));
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

test "skill and agent lines round-trip with every optional field, and none are lookups" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token: mcp_call.Token = @splat(0x73);
    const ops = [_]Operation{
        .skill_list,
        .{ .skill_open = .{ .name = "zig" } },
        .{ .skill_open = .{ .name = "zig", .resource = "SKILL.md" } },
        .{ .agent_message = .{ .agent = "worker", .message = "check \"quotes\"\nline2" } },
        .{ .agent_message = .{
            .agent = "worker",
            .message = "go",
            .instructions = "be brief",
            .model = "claude-sonnet",
            .effort = "high",
            .profile = "reviewer",
            .report = .every_turn,
        } },
        .agent_wait,
        .{ .agent_status = null },
        .{ .agent_status = "worker" },
        .{ .agent_stop = "worker" },
        .{ .agent_close = "worker" },
    };

    for (ops) |op| {
        try std.testing.expect(op.lookup() == null);
        var out: std.Io.Writer.Allocating = .init(arena);
        try writeRequest(&out.writer, token, op);
        const line = out.written();
        try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
        const parsed = try parseRequest(arena, line[0 .. line.len - 1]);
        try std.testing.expectEqualDeep(op, parsed.operation);
    }
}

test "malformed skill and agent lines are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "{\"v\":1,\"token\":\"\",\"op\":\"skill_open\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"skill_open\",\"name\":\"\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"skill_open\",\"name\":\"zig\",\"resource\":\"\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"skill_open\",\"name\":\"zig\",\"resource\":3}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_message\",\"agent\":\"w\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_message\",\"agent\":\"\",\"message\":\"hi\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_message\",\"agent\":\"w\",\"message\":\"\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_message\",\"agent\":\"w\",\"message\":\"hi\",\"report\":\"bogus\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_message\",\"agent\":\"w\",\"message\":\"hi\",\"model\":\"\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_status\",\"agent\":\"\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_status\",\"agent\":4}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_stop\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_stop\",\"agent\":\"\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_close\"}",
        "{\"v\":1,\"token\":\"\",\"op\":\"agent_close\",\"agent\":\"\"}",
    }) |line| try std.testing.expectError(error.MalformedRequest, parseRequest(arena, line));
}

const max_fuzz_request_bytes = max_request_bytes + 64;

fn fuzzWire(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_fuzz_request_bytes]u8 = undefined;
    const line = buffer[0..smith.slice(&buffer)];
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = parseRequest(arena, line) catch |err| switch (err) {
        error.MalformedRequest, error.OutOfMemory => return,
    };
    if (line.len > max_request_bytes) return error.TestOversizedRequestAccepted;

    const token = parsed.token orelse @as(mcp_call.Token, @splat(0));
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeRequest(&out.writer, token, parsed.operation);
    const rewritten = out.written();
    try std.testing.expect(std.mem.endsWith(u8, rewritten, "}\n"));
    const reparsed = try parseRequest(arena, rewritten[0 .. rewritten.len - 1]);
    if (parsed.version == mcp_call.protocol_version) {
        try std.testing.expectEqual(parsed.version, reparsed.version);
    } else {
        try std.testing.expectEqual(mcp_call.protocol_version, reparsed.version);
    }
    try std.testing.expect(reparsed.token != null);
    try std.testing.expectEqualSlices(u8, &token, &reparsed.token.?);
    try expectSameOperation(parsed.operation, reparsed.operation);
}

fn expectSameOperation(want: Operation, got: Operation) !void {
    try std.testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
    switch (want) {
        .call => |w| {
            try std.testing.expectEqualStrings(w.tool, got.call.tool);
            try std.testing.expectEqualStrings(w.arguments_json, got.call.arguments_json);
        },
        .list => |w| try std.testing.expectEqualStrings(w, got.list),
        .search => |w| try std.testing.expectEqualStrings(w, got.search),
        .help => |w| try std.testing.expectEqualStrings(w, got.help),
        .edit => |w| {
            try std.testing.expectEqualStrings(w.path, got.edit.path);
            try std.testing.expectEqual(w.blocks.len, got.edit.blocks.len);
            for (w.blocks, got.edit.blocks) |wb, gb| {
                try std.testing.expectEqualStrings(wb.search, gb.search);
                try std.testing.expectEqualStrings(wb.replace, gb.replace);
            }
        },
        .write => |w| {
            try std.testing.expectEqualStrings(w.path, got.write.path);
            try std.testing.expectEqualStrings(w.content, got.write.content);
        },
        .skill_list, .agent_wait => {},
        .skill_open => |w| {
            try std.testing.expectEqualStrings(w.name, got.skill_open.name);
            try expectOptionalStrings(w.resource, got.skill_open.resource);
        },
        .agent_message => |w| {
            try std.testing.expectEqualStrings(w.agent, got.agent_message.agent);
            try std.testing.expectEqualStrings(w.message, got.agent_message.message);
            try expectOptionalStrings(w.instructions, got.agent_message.instructions);
            try expectOptionalStrings(w.model, got.agent_message.model);
            try expectOptionalStrings(w.effort, got.agent_message.effort);
            try expectOptionalStrings(w.profile, got.agent_message.profile);
            try std.testing.expectEqual(w.report, got.agent_message.report);
        },
        .agent_status => |w| try expectOptionalStrings(w, got.agent_status),
        .agent_stop => |w| try std.testing.expectEqualStrings(w, got.agent_stop),
        .agent_close => |w| try std.testing.expectEqualStrings(w, got.agent_close),
    }
}

fn expectOptionalStrings(want: ?[]const u8, got: ?[]const u8) !void {
    if (want) |w| {
        const g = got orelse return error.TestExpectedOptionalValue;
        try std.testing.expectEqualStrings(w, g);
    } else {
        try std.testing.expect(got == null);
    }
}

test "tool bridge wire requests parse or are refused, and parsed requests round-trip, on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzWire, .{
        .corpus = &(@import("fuzz_corpus").tool_bridge_wire.*),
    });
}

test "a call request whose arguments nest deeper than the limit is refused, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]usize{ 300, json_depth.max_depth }) |array_levels| {
        const line = try nestedCallLine(arena, array_levels);
        try std.testing.expectError(error.MalformedRequest, parseRequest(arena, line));
    }
}

test "a request line longer than max_request_bytes is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pad = try arena.alloc(u8, max_request_bytes);
    @memset(pad, 'a');
    const line = try arena.print("{{\"v\":1,\"token\":\"\",\"op\":\"list\",\"server\":\"{s}\"}}", .{pad});
    try std.testing.expectEqual(@as(usize, 1_048_618), line.len);
    try std.testing.expectError(error.MalformedRequest, parseRequest(arena, line));
}

test "a call request whose arguments nest at the limit parses and round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `arguments` itself is level 1, plus `json_depth.max_depth - 1` array levels.
    const line = try nestedCallLine(arena, json_depth.max_depth - 1);
    const parsed = try parseRequest(arena, line);
    const token = parsed.token orelse return error.TestExpectedToken;
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeRequest(&out.writer, token, parsed.operation);
    const rewritten = out.written();
    const reparsed = try parseRequest(arena, rewritten[0 .. rewritten.len - 1]);
    try expectSameOperation(parsed.operation, reparsed.operation);
}

test "a request line nested one level past the limit is refused, even outside arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The envelope object is level 1 of the line, so the line takes
    // `json_depth.max_depth` array levels after it, and one more is refused.
    for ([_]usize{ json_depth.max_depth, json_depth.max_depth + 1 }) |array_levels| {
        var out: std.Io.Writer.Allocating = .init(arena);
        const hex = tokenHex(@splat(0xab));
        try out.writer.print("{{\"v\":1,\"token\":\"{s}\",\"op\":\"list\",\"server\":\"s\",\"extra\":", .{&hex});
        try out.writer.splatByteAll('[', array_levels);
        try out.writer.splatByteAll(']', array_levels);
        try out.writer.writeAll("}");
        const line = out.written();
        if (array_levels == json_depth.max_depth) {
            _ = try parseRequest(arena, line);
        } else {
            try std.testing.expectError(error.MalformedRequest, parseRequest(arena, line));
        }
    }
}

test "a request line nested far past the limit is refused, not a crash, once it parses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // About 1 MB of nesting, the longest line max_request_bytes allows.
    const line = try nestedCallLine(arena, 500_000);
    try std.testing.expect(line.len <= max_request_bytes);
    try std.testing.expectError(error.MalformedRequest, parseRequest(arena, line));
}

fn nestedCallLine(arena: Allocator, array_levels: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const hex = tokenHex(@splat(0xab));
    try out.writer.print("{{\"v\":1,\"token\":\"{s}\",\"op\":\"call\",\"tool\":\"t\",\"arguments\":{{\"x\":", .{&hex});
    try out.writer.splatByteAll('[', array_levels);
    try out.writer.splatByteAll(']', array_levels);
    try out.writer.writeAll("}}");
    return out.written();
}

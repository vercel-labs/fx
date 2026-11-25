//! The socket round trip of a bridge client: connect to the session's bridge,
//! send one request line, and read the reply's header and its bytes. `fx mcp
//! call` and `fx tool` both use it, so they share one exit-code table and one
//! way to write a reply's text.
const std = @import("std");
const capability_mod = @import("capability.zig");
const mcp_call = @import("core.zig");
const text_utils = @import("../shared/text_utils.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// What a bridge client command exits with: `fx mcp call` and `fx tool`.
pub const exit = struct {
    pub const ok: u8 = 0;
    /// The call failed, or the connection to fx was lost.
    pub const failed: u8 = 1;
    /// A usage mistake, as for every `fx mcp` verb.
    pub const usage: u8 = 2;
    /// No running fx shell call to reach: outside fx, after the shell call
    /// ended, or another fx version.
    pub const unavailable: u8 = 3;
    /// Too many calls are running; nothing ran.
    pub const busy: u8 = 4;
    /// Permission was not granted; nothing ran.
    pub const denied: u8 = 5;
    /// The tool ran and returned an error.
    pub const tool_error: u8 = 6;
};

pub const Reply = struct {
    header: wire.Header,
    bytes: []const u8,
};

pub const CallError = error{ RequestTooLarge, MalformedReply, UnsupportedReply, ConnectionLost, OutOfMemory };

/// Encodes one request line into `arena` and checks `wire.max_request_bytes`
/// before any socket connection is opened.
pub fn encodeRequest(
    arena: Allocator,
    token: mcp_call.Token,
    operation: wire.Operation,
) error{ RequestTooLarge, OutOfMemory }![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    wire.writeRequest(&out.writer, token, operation) catch return error.OutOfMemory;
    const line = out.written();
    if (line.len > wire.max_request_bytes) return error.RequestTooLarge;
    return line;
}

/// Sends one request to the bridge at `socket_path` and reads its whole reply.
pub fn call(
    arena: Allocator,
    io: std.Io,
    socket_path: []const u8,
    token: mcp_call.Token,
    operation: wire.Operation,
) (CallError || std.Io.net.UnixAddress.ConnectError || std.Io.net.UnixAddress.InitError)!Reply {
    const encoded = try encodeRequest(arena, token, operation);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(encoded) catch return error.ConnectionLost;
    writer.interface.flush() catch return error.ConnectionLost;
    var read_buffer: [wire.max_header_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = (reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.MalformedReply,
        error.ReadFailed => return error.ConnectionLost,
    }) orelse return error.ConnectionLost;
    const header = try wire.parseHeader(arena, line);
    // A reply carries at most the bridge's result limit and a short message.
    if (header.bytes > capability_mod.max_result_bytes + 64 * 1024) return error.MalformedReply;
    const bytes = reader.interface.readAllocAll(arena, @intCast(header.bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EndOfStream, error.ReadFailed => return error.ConnectionLost,
    };
    return .{ .header = header, .bytes = bytes };
}

/// The exit code of a refused request: busy, a request the bridge could not
/// read, or any other refusal, which means nothing can reach fx.
pub fn refusalExit(reason: ?wire.Reason) u8 {
    return if (reason == .busy) exit.busy else if (reason == .malformed or reason == .too_large) exit.usage else exit.unavailable;
}

/// Writes `text` as one line, with every control byte that is not a line break
/// or a tab shown as a visible escape. The text can be an MCP server's own, or a
/// command's, so it must not act on a terminal. A line end is added only when the
/// text lacks one.
pub fn writeSafeLine(arena: Allocator, w: *Writer, text: []const u8) !void {
    var safe: std.ArrayList(u8) = .empty;
    try text_utils.appendTerminalSafeText(arena, &safe, text);
    try w.writeAll(safe.items);
    if (!std.mem.endsWith(u8, safe.items, "\n")) try w.writeByte('\n');
}

test "encodeRequest and call reject an encoded request over max_request_bytes before connecting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const token: mcp_call.Token = @splat(0x22);
    const quotes = try arena.alloc(u8, 700_000);
    @memset(quotes, '"');
    const operation: wire.Operation = .{ .write = .{ .path = "/tmp/quotes.txt", .content = quotes } };

    try std.testing.expectError(error.RequestTooLarge, encodeRequest(arena, token, operation));
    try std.testing.expectError(
        error.RequestTooLarge,
        call(arena, std.testing.io, "/tmp/fx-must-not-connect.sock", token, operation),
    );
}

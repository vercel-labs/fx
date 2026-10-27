//! The stdio MCP server the `claude` executable starts in the `anthropic`
//! provider's Claude Code mode (D166): `proto-fx __claude-tools <file>`.
//! It lists proto-fx's tools from the file the transport wrote and refuses
//! every call. Claude only proposes calls; proto-fx's own loop runs them,
//! with its permissions, after the stream ends. Proto's in-process MCP server
//! throws from its call handler the same way, as defence in depth behind the
//! denied permission prompts.
const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const Allocator = std.mem.Allocator;

pub const argv_marker = "__claude-tools";
const max_tools_bytes = 8 * 1024 * 1024;
const max_line_bytes = 4 * 1024 * 1024;
const default_protocol = "2025-06-18";
pub const refusal = "proto-fx runs its tools in its own agent loop; Claude Code never executes them.";

/// Serves until stdin closes.
pub fn run(alloc: Allocator, tools_path: []const u8) !void {
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().openFile(io, tools_path, .{});
    const tools = blk: {
        defer file.close(io);
        break :blk try io_mod.readFileToEnd(alloc, &file, max_tools_bytes);
    };
    defer alloc.free(tools);
    const buffer = try alloc.alloc(u8, max_line_bytes);
    defer alloc.free(buffer);
    var stdin = std.Io.File.stdin().reader(io, buffer);
    const stdout = std.Io.File.stdout();
    while (true) {
        const line = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            // A line past the limit cannot be answered; skip to the next one.
            error.StreamTooLong => continue,
            else => return err,
        } orelse return;
        const reply = try respond(alloc, line, tools) orelse continue;
        defer alloc.free(reply);
        try stdout.writeStreamingAll(io, reply);
    }
}

/// The JSON-RPC reply to one line, newline terminated, or null for a
/// notification or a line that is not a request. Caller owns it.
pub fn respond(alloc: Allocator, line: []const u8, tools_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const request = parsed.value.object;
    const id = request.get("id") orelse return null;
    if (id != .integer and id != .string) return null;
    const method_value = request.get("method") orelse return null;
    if (method_value != .string) return null;
    const method = method_value.string;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    if (std.mem.eql(u8, method, "initialize")) {
        var version: []const u8 = default_protocol;
        if (request.get("params")) |params| if (params == .object) if (params.object.get("protocolVersion")) |value| if (value == .string) {
            version = value.string;
        };
        try w.writeAll(",\"result\":{\"protocolVersion\":");
        try std.json.Stringify.value(version, .{}, w);
        try w.writeAll(",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"proto_fx\",\"version\":\"1\"}}}\n");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try w.writeAll(",\"result\":{\"tools\":");
        try w.writeAll(tools_json);
        try w.writeAll("}}\n");
    } else if (std.mem.eql(u8, method, "ping")) {
        try w.writeAll(",\"result\":{}}\n");
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try w.writeAll(",\"error\":{\"code\":-32603,\"message\":\"" ++ refusal ++ "\"}}\n");
    } else {
        try w.writeAll(",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n");
    }
    return try out.toOwnedSlice();
}

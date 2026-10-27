//! Turning a configured CDP endpoint into the browser's WebSocket URL
//! (D196): a `ws://` URL is used as is; an `http://host:port` endpoint is
//! asked for `/json/version`.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const websocket = @import("websocket.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidEndpoint, EndpointUnreachable, OutOfMemory };

/// The browser WebSocket URL for `endpoint`. The caller owns it.
pub fn resolve(alloc: Allocator, endpoint: []const u8) Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, endpoint, " \t\r\n"), "/");
    if (std.mem.startsWith(u8, trimmed, "ws://")) return alloc.dupe(u8, trimmed);
    if (!std.mem.startsWith(u8, trimmed, "http://")) return error.InvalidEndpoint;
    const authority = trimmed["http://".len..];
    if (std.mem.findScalar(u8, authority, '/') != null) return error.InvalidEndpoint;
    const colon = std.mem.findScalarLast(u8, authority, ':') orelse return error.InvalidEndpoint;
    const host = authority[0..colon];
    const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidEndpoint;
    const body = fetchVersion(alloc, host, port) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EndpointUnreachable,
    };
    defer alloc.free(body);
    return parseVersion(alloc, body) orelse error.EndpointUnreachable;
}

/// `webSocketDebuggerUrl` from a `/json/version` response body.
pub fn parseVersion(alloc: Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const url = parsed.value.object.get("webSocketDebuggerUrl") orelse return null;
    if (url != .string or !std.mem.startsWith(u8, url.string, "ws://")) return null;
    return alloc.dupe(u8, url.string) catch null;
}

fn fetchVersion(alloc: Allocator, host: []const u8, port: u16) ![]u8 {
    const io = io_mod.getIo();
    const stream = try websocket.connectTcp(host, port);
    defer stream.close(io);
    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.print("GET /json/version HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ host, port });
    try writer.interface.flush();
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(alloc);
    while (response.items.len < 64 * 1024) {
        if (!try websocket.waitReadable(stream.socket.handle, 5_000, null)) return error.Timeout;
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(stream.socket.handle, &buf) catch break;
        if (n == 0) break;
        try response.appendSlice(alloc, buf[0..n]);
    }
    const head_end = std.mem.find(u8, response.items, "\r\n\r\n") orelse return error.BadResponse;
    if (!std.mem.startsWith(u8, response.items, "HTTP/1.1 200")) return error.BadResponse;
    return alloc.dupe(u8, response.items[head_end + 4 ..]);
}

test "browser endpoints accept ws urls and read the debugger url from /json/version" {
    const alloc = std.testing.allocator;
    const ws = try resolve(alloc, " ws://127.0.0.1:9222/devtools/browser/x/ ");
    defer alloc.free(ws);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/browser/x", ws);
    try std.testing.expectError(error.InvalidEndpoint, resolve(alloc, "https://example.com"));
    try std.testing.expectError(error.InvalidEndpoint, resolve(alloc, "http://127.0.0.1"));
    const url = parseVersion(alloc, "{\"Browser\":\"Chrome/140\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9222/devtools/browser/abc\"}").?;
    defer alloc.free(url);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/browser/abc", url);
    try std.testing.expect(parseVersion(alloc, "{}") == null);
}

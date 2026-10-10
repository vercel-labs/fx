//! The loopback redirect for an MCP sign-in (RFC 8252 §7.3): fx listens on
//! 127.0.0.1, the browser comes back to `GET /callback`, and the address it
//! came to goes to MCP-v2's `finishSignIn`. Anything else, such as a request
//! for an icon, gets a 404 and the wait goes on.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A request head longer than this is not a browser coming back.
const max_head_bytes = 16 * 1024;

pub const Listener = struct {
    server: std.Io.net.Server,
    port: u16,

    /// Listens on 127.0.0.1 at `port`, or at a free port when null.
    pub fn open(io: std.Io, port: ?u16) !Listener {
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port orelse 0) catch unreachable;
        var server = try address.listen(io, .{ .reuse_address = port != null });
        return .{ .port = server.socket.address.getPort(), .server = server };
    }

    pub fn close(l: *Listener, io: std.Io) void {
        l.server.deinit(io);
    }

    /// The redirect URI to sign in with, in `buffer`.
    pub fn redirectUri(l: *const Listener, buffer: *[64]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/callback", .{l.port}) catch unreachable;
    }

    /// Waits for the browser's `GET /callback` and returns the full address it
    /// came to, owned by `alloc`. A cancellation point: cancelling the task
    /// ends the wait with error.Canceled.
    pub fn accept(l: *Listener, io: std.Io, alloc: Allocator) ![]u8 {
        while (true) {
            const stream = try l.server.accept(io);
            defer stream.close(io);
            if (try answer(stream, io, alloc, l.port)) |url| return url;
        }
    }
};

/// Answers one connection: the callback address when it was the browser's
/// return, null otherwise.
fn answer(stream: std.Io.net.Stream, io: std.Io, alloc: Allocator, port: u16) !?[]u8 {
    var in: [max_head_bytes]u8 = undefined;
    var reader = stream.reader(io, &in);
    const first = reader.interface.takeDelimiterInclusive('\n') catch return null;
    var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, first, "\r\n"), ' ');
    const method_view = parts.next() orelse return null;
    const target_view = parts.next() orelse return null;
    // Both are copied: the reads below reuse `in`.
    var line: [max_head_bytes]u8 = undefined;
    const method = line[0..method_view.len];
    @memcpy(method, method_view);
    const target = line[method.len..][0..target_view.len];
    @memcpy(target, target_view);
    // The rest of the head is read first, so closing doesn't reset the connection.
    while (true) {
        const header = reader.interface.takeDelimiterInclusive('\n') catch return null;
        if (std.mem.trimEnd(u8, header, "\r\n").len == 0) break;
    }
    const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
    const ours = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/callback");
    const body = if (ours) "fx: back from the sign-in. You can close this tab.\n" else "Not found\n";
    var out: [256]u8 = undefined;
    var writer = stream.writer(io, &out);
    writer.interface.print("HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        if (ours) "200 OK" else "404 Not Found",
        body.len,
        body,
    }) catch {};
    writer.interface.flush() catch {};
    if (!ours) return null;
    return try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}{s}", .{ port, target });
}

const testing = std.testing;

fn get(port: u16, target: []const u8) !void {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    var out: [512]u8 = undefined;
    var writer = stream.writer(testing.io, &out);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", .{target});
    try writer.interface.flush();
    var in: [512]u8 = undefined;
    var reader = stream.reader(testing.io, &in);
    _ = reader.interface.takeDelimiterInclusive('\n') catch {};
}

test "the browser's return is the callback address; other requests get a 404 and the wait goes on" {
    var listener = try Listener.open(testing.io, null);
    defer listener.close(testing.io);
    try testing.expect(listener.port != 0);
    var buffer: [64]u8 = undefined;
    const uri = listener.redirectUri(&buffer);
    try testing.expect(std.mem.startsWith(u8, uri, "http://127.0.0.1:"));
    try testing.expect(std.mem.endsWith(u8, uri, "/callback"));

    const Browser = struct {
        fn run(port: u16) void {
            get(port, "/favicon.ico") catch {};
            get(port, "/callback?code=c1&state=s1") catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Browser.run, .{listener.port});
    defer thread.join();
    const url = try listener.accept(testing.io, testing.allocator);
    defer testing.allocator.free(url);
    const want = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/callback?code=c1&state=s1", .{listener.port});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, url);
}

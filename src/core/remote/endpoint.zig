const std = @import("std");

pub const Endpoint = union(enum) {
    unix: []const u8,
    websocket: struct {
        secure: bool,
        host: []const u8,
        port: u16,
        path: []const u8,
    },
};

pub fn parse(value: []const u8, server: bool) !Endpoint {
    if (std.mem.startsWith(u8, value, "unix://")) {
        const path = value["unix://".len..];
        if (path.len == 0 or path[0] != '/') return error.InvalidEndpoint;
        return .{ .unix = path };
    }
    const secure = std.mem.startsWith(u8, value, "wss://");
    const prefix = if (secure) "wss://" else if (std.mem.startsWith(u8, value, "ws://")) "ws://" else return error.InvalidEndpoint;
    const rest = value[prefix.len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |index| authority[0..index] else authority;
    const port: u16 = if (colon) |index|
        std.fmt.parseUnsigned(u16, authority[index + 1 ..], 10) catch return error.InvalidEndpoint
    else if (secure)
        443
    else
        80;
    if (host.len == 0 or port == 0 or path.len == 0 or path[0] != '/') return error.InvalidEndpoint;
    if ((!secure and !std.mem.eql(u8, host, "127.0.0.1")) or (server and secure))
        return error.NonLoopbackWebSocket;
    return .{ .websocket = .{ .secure = secure, .host = host, .port = port, .path = path } };
}

test "server endpoints require loopback ws while clients accept wss" {
    const unix = try parse("unix:///tmp/fx.sock", true);
    try std.testing.expectEqualStrings("/tmp/fx.sock", unix.unix);
    const ws = try parse("ws://127.0.0.1:7741/fx", true);
    try std.testing.expectEqual(@as(u16, 7741), ws.websocket.port);
    try std.testing.expect(!ws.websocket.secure);
    const wss = try parse("wss://builder.example/fx", false);
    try std.testing.expect(wss.websocket.secure);
    try std.testing.expectEqual(@as(u16, 443), wss.websocket.port);
    try std.testing.expectError(error.NonLoopbackWebSocket, parse("ws://0.0.0.0:7741/fx", true));
    try std.testing.expectError(error.NonLoopbackWebSocket, parse("ws://remote.example:7741/fx", false));
}

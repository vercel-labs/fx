//! HTTPS carries credentials only to the prepared endpoint; redirects never receive authorization.
const std = @import("std");
const wire = @import("wire.zig");
const sse = @import("sse.zig");
const body_buffer_bytes = 8192;
const transfer_buffer_bytes = 16 * 1024;
const content_type = "application/json";
const user_agent = "fx-opencode-go/1";
const session_header = "x-opencode-session";
const ipv6_loopback_address = "::1";
const ipv6_loopback_host = "[::1]";
const default_http_port = 80;
const loopback_hosts = [_][]const u8{ "localhost", "127.0.0.1", ipv6_loopback_address, ipv6_loopback_host };
const managed_headers = [_][]const u8{ "authorization", "proxy-authorization", "host", "content-length", "content-type", "connection", "transfer-encoding", "user-agent" };

/// Job owns request parameters and socket publication throughout this synchronous worker call.
pub fn run(job: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(job.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const params = try wire.field(job.envelope.value, "params");
    const credential = try wire.text(try wire.field(params, "credential"));
    if (credential.len == 0) return error.InvalidCredential;
    for (credential) |byte| if (std.ascii.isControl(byte) or byte == 0x7f) return error.InvalidCredential;
    const header_values = try wire.field(params, "headers");
    if (header_values != .object) return error.InvalidHeaders;
    var session_present = false;
    var headers: std.ArrayList(std.http.Header) = .empty;
    var iter = header_values.object.iterator();
    while (iter.next()) |entry| {
        for (managed_headers) |managed| if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, managed)) return error.InvalidHeaders;
        const value = try wire.text(entry.value_ptr.*);
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, session_header)) {
            if (session_present or value.len == 0) return error.InvalidHeaders;
            session_present = true;
        }
        for (value) |byte| if (std.ascii.isControl(byte) or byte == 0x7f) return error.InvalidHeaders;
        try headers.append(alloc, .{ .name = entry.key_ptr.*, .value = value });
    }
    if (!session_present) return error.InvalidHeaders;
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{credential});
    defer std.crypto.secureZero(u8, authorization);
    var client = std.http.Client{ .allocator = alloc, .io = job.io };
    defer client.deinit();
    const uri = try std.Uri.parse(job.prepared.endpoint);
    var connection_host: ?[]const u8 = null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidEndpoint;
        const host = uri.host orelse return error.InvalidEndpoint;
        const name = try host.toRawMaybeAlloc(alloc);
        // Core admission accepts case-insensitive DNS names and bracketed IPv6 URI hosts.
        var loopback = false;
        for (loopback_hosts) |allowed| if (std.ascii.eqlIgnoreCase(name, allowed)) {
            loopback = true;
            break;
        };
        if (!loopback) return error.InvalidEndpoint;
        if (std.mem.eql(u8, name, ipv6_loopback_host)) connection_host = ipv6_loopback_address;
    }
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidEndpoint;
    if (job.cancel.load(.seq_cst)) return error.Cancelled;
    var request = prepared_request: {
        // DNS resolution needs an unbracketed address, while HTTP authority must retain URI brackets.
        const connection = if (connection_host) |name| try client.connectTcp(.{ .bytes = name }, uri.port orelse default_http_port, .plain) else null;
        errdefer if (connection) |owned| {
            owned.closing = true;
            client.connection_pool.release(owned, job.io);
        };
        break :prepared_request try client.request(.POST, uri, .{ .connection = connection, .headers = .{
            .content_type = .{ .override = content_type },
            .authorization = .{ .override = authorization },
            .accept_encoding = .omit,
            .user_agent = .{ .override = user_agent },
        }, .extra_headers = headers.items, .keep_alive = false, .redirect_behavior = .unhandled });
    };
    defer request.deinit();
    if (request.connection) |connection| job.publish_socket(connection.stream_writer.stream);
    defer job.publish_socket(null);
    if (job.cancel.load(.seq_cst)) return error.Cancelled;
    request.transfer_encoding = .{ .content_length = job.prepared.body.len };
    var send_buffer: [body_buffer_bytes]u8 = undefined;
    var body = try request.sendBodyUnflushed(&send_buffer);
    try body.writer.writeAll(job.prepared.body);
    try body.end();
    if (request.connection) |connection| try connection.flush();
    var response = try request.receiveHead(&.{});
    if (response.head.status != .ok) return error.ProviderFailed;
    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    var context = sse.Context{ .alloc = job.alloc, .output = job.output, .id = job.id, .handle = job.prepared.handle, .cancel = &job.cancel };
    defer context.deinit();
    try context.consume(response.reader(&transfer_buffer));
    if (job.cancel.load(.seq_cst)) return error.Cancelled;
    try context.reply();
}

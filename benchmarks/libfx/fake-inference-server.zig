const std = @import("std");

const Protocol = enum { fx, openai };
const max_request_bytes = 8 * 1024 * 1024;
var next_request_id: std.atomic.Value(u64) = .init(1);

pub fn main(init: std.process.Init) !void {
    const port = try parsePort(init.minimal.args);
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);

    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try stdout.interface.print("{{\"host\":\"127.0.0.1\",\"port\":{d}}}\n", .{listener.socket.address.getPort()});
    try stdout.interface.flush();

    while (true) {
        const stream = try listener.accept(init.io);
        const thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, serveConnection, .{stream}) catch {
            stream.close(init.io);
            continue;
        };
        thread.detach();
    }
}

fn parsePort(raw_args: std.process.Args) !u16 {
    var args = try std.process.Args.Iterator.initAllocator(raw_args, std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |name| {
        if (!std.mem.eql(u8, name, "--port")) return error.InvalidArgument;
        const value = args.next() orelse return error.InvalidArgument;
        if (args.next() != null) return error.InvalidArgument;
        return std.fmt.parseInt(u16, value, 10);
    }
    return 0;
}

fn serveConnection(stream: std.Io.net.Stream) void {
    var io_backend: std.Io.Threaded = .init_single_threaded;
    defer io_backend.deinit();
    serveConnectionFallible(io_backend.io(), stream) catch |err| {
        std.log.err("libfx benchmark server failed: {s}", .{@errorName(err)});
    };
}

fn serveConnectionFallible(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    const no_delay: c_int = 1;
    try std.posix.setsockopt(stream.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&no_delay));
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch return;
        const keep_alive = request.head.keep_alive;
        if (request.head.method != .POST) {
            try request.respond("method not allowed\n", .{ .status = .method_not_allowed, .keep_alive = false });
            return;
        }
        const protocol: Protocol = if (std.mem.eql(u8, request.head.target, "/fx"))
            .fx
        else if (std.mem.eql(u8, request.head.target, "/v1/responses"))
            .openai
        else {
            try request.respond("unknown benchmark endpoint\n", .{ .status = .not_found, .keep_alive = false });
            return;
        };
        if (request.head.transfer_encoding == .chunked or
            (request.head.content_length orelse 0) > max_request_bytes)
        {
            try request.respond("bounded content-length required\n", .{ .status = .payload_too_large, .keep_alive = false });
            return;
        }
        var request_body_buffer: [8 * 1024]u8 = undefined;
        const request_body = try request.readerExpectContinue(&request_body_buffer);
        _ = try request_body.discardRemaining();
        try writeResponse(&request, protocol, keep_alive);
        if (!keep_alive) return;
    }
}

fn writeResponse(request: *std.http.Server.Request, protocol: Protocol, keep_alive: bool) !void {
    const request_id = next_request_id.fetchAdd(1, .monotonic);
    var request_id_buffer: [32]u8 = undefined;
    const request_id_text = try std.fmt.bufPrint(&request_id_buffer, "{d}", .{request_id});
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "text/event-stream" },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "x-fake-request-id", .value = request_id_text },
    };
    var response_buffer: [64 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buffer, .{
        .respond_options = .{ .keep_alive = keep_alive, .extra_headers = &headers },
    });
    try response.writer.flush();
    try request.server.out.flush();
    switch (protocol) {
        .fx => try response.writer.writeAll(
            "data: {\"type\":\"text-delta\",\"id\":\"0\",\"delta\":\"xxxxx\"}\n\n" ++
                "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"},\"usage\":{\"inputTokens\":{\"total\":1},\"outputTokens\":{\"total\":1}}}\n\n" ++
                "data: [DONE]\n\n",
        ),
        .openai => try response.writer.writeAll(
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"fake\",\"status\":\"in_progress\",\"output\":[]}}\n\n" ++
                "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"fake_message\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n\n" ++
                "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"xxxxx\",\"item_id\":\"fake_message\"}\n\n" ++
                "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"fake_message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[]}}\n\n" ++
                "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"fake\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens_details\":{\"reasoning_tokens\":0}}}}\n\n" ++
                "data: [DONE]\n\n",
        ),
    }
    try response.end();
    try request.server.out.flush();
}

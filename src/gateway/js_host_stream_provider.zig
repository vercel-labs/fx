const stream_provider = @import("../core/agent/stream_provider.zig");
const host_stream_provider = @import("host_stream_provider.zig");
const builtin_gateway = @import("../builtins/gateway.zig");

extern "fx" fn fx_http_stream_open(
    method_ptr: [*]const u8,
    method_len: usize,
    url_ptr: [*]const u8,
    url_len: usize,
    headers_ptr: [*]const u8,
    headers_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
) i32;
extern "fx" fn fx_http_stream_status(handle: i32, status_out: *u16) i32;
extern "fx" fn fx_http_stream_next(handle: i32, out_ptr: [*]u8, out_cap: usize) i32;
extern "fx" fn fx_http_stream_close(handle: i32) void;

const provider_context = host_stream_provider.initContext(builtin_gateway.buildAgentRequest, .{ .resolve = builtin_gateway.agentChatUrl }, .{
    .context = null,
    .open_fn = open,
    .status_fn = status,
    .next_fn = next,
    .close_fn = close,
});

pub fn provider() stream_provider.Provider {
    return host_stream_provider.provider(@constCast(&provider_context));
}

pub fn transport() host_stream_provider.Transport {
    return provider_context.transport;
}

fn open(_: ?*anyopaque, method: []const u8, url: []const u8, headers: []const u8, body: []const u8) !i32 {
    const handle = fx_http_stream_open(method.ptr, method.len, url.ptr, url.len, headers.ptr, headers.len, body.ptr, body.len);
    if (handle < 0) return error.HostStreamFailed;
    return handle;
}

fn status(_: ?*anyopaque, handle: i32, status_out: *u16) i32 {
    return fx_http_stream_status(handle, status_out);
}

fn next(_: ?*anyopaque, handle: i32, out: []u8) i32 {
    return fx_http_stream_next(handle, out.ptr, out.len);
}

fn close(_: ?*anyopaque, handle: i32) void {
    fx_http_stream_close(handle);
}

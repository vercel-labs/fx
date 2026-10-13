const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const host_stream = @import("host_stream_provider.zig");
const builtin_gateway = @import("../builtins/gateway.zig");
const Allocator = std.mem.Allocator;

const max_catalog_bytes = 4 * 1024 * 1024;

/// Borrows the host transport for the lifetime of the provider.
pub fn provider(transport: *host_stream.Transport) model_catalog.Provider {
    return .{ .context = transport, .fetch_fn = fetch };
}

fn fetch(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    const transport: *host_stream.Transport = @ptrCast(@alignCast(raw.?));
    const url = try alloc.print("{s}{s}", .{ builtin_gateway.default_model_catalog_base_url, input.endpoint });
    defer alloc.free(url);
    const auth = if (input.access.authorizationCredential()) |credential| try alloc.print("Bearer {s}", .{credential}) else null;
    defer if (auth) |value| alloc.free(value);
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(alloc);
    if (auth) |value| try headers.append(alloc, .{ .name = "authorization", .value = value });
    if (input.access.teamContext()) |team| try headers.append(alloc, .{ .name = "x-vercel-ai-gateway-team", .value = team });
    const body = switch (try get(alloc, transport.*, url, headers.items, input.cancel_flag, max_catalog_bytes)) {
        .body => |body| body,
        .failure => |failure| return .{ .failure = failure },
    };
    defer alloc.free(body);
    const catalog = builtin_gateway.parseModelCatalogForView(alloc, body, input.view) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response } };
    };
    return .{ .catalog = catalog };
}

pub const GetResult = union(enum) {
    /// Owned by the caller.
    body: []u8,
    failure: model_catalog.Failure,
};

/// Sends one GET through the host and reads a 200 response body of at most
/// `max_bytes`. Other statuses map to catalog failures.
pub fn get(
    alloc: Allocator,
    transport: host_stream.Transport,
    url: []const u8,
    headers: []const std.http.Header,
    cancel_flag: ?*std.atomic.Value(bool),
    max_bytes: usize,
) Allocator.Error!GetResult {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    std.json.Stringify.value(headers, .{}, &encoded.writer) catch return error.OutOfMemory;
    if (cancelled(cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
    const handle = transport.open_fn(transport.context, "GET", url, encoded.written(), "") catch return .{ .failure = .{ .category = .transport } };
    if (handle < 0) return .{ .failure = .{ .category = .transport } };
    defer transport.close_fn(transport.context, handle);
    var status: u16 = 0;
    while (true) {
        if (cancelled(cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
        const state = transport.status_fn(transport.context, handle, &status);
        if (state == 1) break;
        if (state < 0) return .{ .failure = .{ .category = if (state == -2) .cancellation else .transport } };
    }
    const http_status = host_stream.httpStatus(status) orelse return .{ .failure = .{ .category = .transport } };
    if (http_status != .ok) return .{ .failure = model_catalog.failureForHttpStatus(http_status) };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        if (cancelled(cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
        const count = transport.next_fn(transport.context, handle, &chunk);
        if (count == -3) continue;
        if (count < 0) return .{ .failure = .{ .category = if (count == -2) .cancellation else .transport } };
        if (count == 0) break;
        const size: usize = @intCast(count);
        if (size > chunk.len or size > max_bytes -| body.items.len) return .{ .failure = .{ .category = .resource_exhausted } };
        try body.appendSlice(alloc, chunk[0..size]);
    }
    return .{ .body = try body.toOwnedSlice(alloc) };
}

fn cancelled(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

test "catalog GET fails cleanly on a status outside the HTTP range" {
    const FakeTransport = struct {
        status_code: u16,
        close_calls: usize = 0,

        fn open(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) anyerror!i32 {
            return 3;
        }
        fn status(raw: ?*anyopaque, _: i32, status_out: *u16) i32 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            status_out.* = self.status_code;
            return 1;
        }
        fn next(_: ?*anyopaque, _: i32, _: []u8) i32 {
            return 0;
        }
        fn close(raw: ?*anyopaque, _: i32) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.close_calls += 1;
        }
    };

    for ([_]u16{ 0, 99, 404, 600, 1024, 65535 }) |code| {
        var fake: FakeTransport = .{ .status_code = code };
        const transport: host_stream.Transport = .{
            .context = &fake,
            .open_fn = FakeTransport.open,
            .status_fn = FakeTransport.status,
            .next_fn = FakeTransport.next,
            .close_fn = FakeTransport.close,
        };
        const result = try get(std.testing.allocator, transport, "https://example.invalid/v1/models", &.{}, null, 1024);
        try std.testing.expect(result == .failure);
        if (code == 404) {
            try std.testing.expectEqual(@as(?std.http.Status, .not_found), result.failure.http_status);
        } else {
            try std.testing.expectEqual(model_catalog.FailureCategory.transport, result.failure.category);
            try std.testing.expectEqual(@as(?std.http.Status, null), result.failure.http_status);
        }
        try std.testing.expectEqual(@as(usize, 1), fake.close_calls);
    }
}

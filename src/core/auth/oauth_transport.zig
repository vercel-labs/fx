const std = @import("std");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const Method = enum {
    get,
    post_form,
    post_json,
};

pub const Request = struct {
    method: Method,
    url: []const u8,
    payload: ?[]const u8 = null,
    /// Optional preformatted Authorization value, borrowed for this request.
    authorization: ?[]const u8 = null,
    /// Optional extra headers borrowed for this request.
    extra_headers: []const std.http.Header = &.{},
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline: ?std.Io.Clock.Timestamp = null,
};

pub const Disposition = enum {
    accepted,
    rejected,
};

pub const Response = struct {
    disposition: Disposition,
    /// Owned bytes allocated with the allocator passed to `Provider.execute`.
    body: []u8,

    pub fn deinit(self: *Response, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = .{
            .disposition = .rejected,
            .body = &.{},
        };
    }

    /// Transfers ownership of `body` to the caller.
    pub fn takeBody(self: *Response) []u8 {
        const body = self.body;
        self.body = &.{};
        return body;
    }
};

pub const ExecuteFn = *const fn (
    ?*anyopaque,
    Allocator,
    Request,
) anyerror!Response;

pub const Provider = struct {
    context: ?*anyopaque = null,
    execute_fn: ExecuteFn,

    pub fn execute(self: Provider, alloc: Allocator, request: Request) !Response {
        return self.execute_fn(self.context, alloc, request);
    }
};

fn unavailable(
    _: ?*anyopaque,
    _: Allocator,
    _: Request,
) !Response {
    return error.OAuthTransportUnavailable;
}

pub const unavailable_provider = Provider{
    .execute_fn = unavailable,
};

test "response transfers owned bytes exactly once" {
    var response = Response{
        .disposition = .accepted,
        .body = try std.testing.allocator.dupe(u8, "secret"),
    };
    const body = response.takeBody();
    defer secret.zeroAndFree(std.testing.allocator, body);

    response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
    try std.testing.expectEqualStrings("secret", body);
}

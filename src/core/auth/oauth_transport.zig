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
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    /// Overrides the transport's response size limit for a request whose
    /// body is expected to be larger than an OAuth response.
    max_response_bytes: ?usize = null,
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

/// Sends every request through `inner` with `cancel_flag` set, so the owner
/// of a background request can stop it. Must outlive the requests it sends.
pub const Cancellable = struct {
    inner: Provider,
    cancel_flag: *std.atomic.Value(bool),

    pub fn provider(self: *Cancellable) Provider {
        return .{ .context = self, .execute_fn = execute };
    }

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: Request) !Response {
        const self: *Cancellable = @ptrCast(@alignCast(raw.?));
        var bounded = request;
        bounded.cancel_flag = self.cancel_flag;
        return self.inner.execute(alloc, bounded);
    }
};

fn unavailable(
    _: ?*anyopaque,
    _: Allocator,
    _: Request,
) !Response {
    return error.OAuthTransportUnavailable;
}

test "cancellable transport adds its cancel flag to every request" {
    const Recorder = struct {
        seen: ?*std.atomic.Value(bool) = null,

        fn execute(raw: ?*anyopaque, _: Allocator, request: Request) !Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.seen = request.cancel_flag;
            return .{ .disposition = .accepted, .body = &.{} };
        }
    };
    var recorder: Recorder = .{};
    var cancel = std.atomic.Value(bool).init(false);
    var cancellable: Cancellable = .{
        .inner = .{ .context = &recorder, .execute_fn = Recorder.execute },
        .cancel_flag = &cancel,
    };
    var response = try cancellable.provider().execute(std.testing.allocator, .{ .method = .get, .url = "https://issuer.test" });
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(&cancel, recorder.seen.?);
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

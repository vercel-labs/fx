const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");

pub fn fromHttpStatus(status: std.http.Status) model_catalog.Failure {
    var failure: model_catalog.Failure = switch (status) {
        .unauthorized, .forbidden => .{ .category = .authentication },
        .too_many_requests => .{ .category = .rate_limited, .retryable = true },
        .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => .{ .category = .unavailable, .retryable = true },
        else => if (@intFromEnum(status) >= 500)
            .{ .category = .unavailable }
        else
            .{ .category = .protocol },
    };
    failure.http_status = @intFromEnum(status);
    return failure;
}

test "Vercel model catalog HTTP failures normalize at the adapter edge" {
    const cases = [_]struct {
        status: std.http.Status,
        category: model_catalog.FailureCategory,
        retryable: bool,
    }{
        .{ .status = .unauthorized, .category = .authentication, .retryable = false },
        .{ .status = .forbidden, .category = .authentication, .retryable = false },
        .{ .status = .too_many_requests, .category = .rate_limited, .retryable = true },
        .{ .status = .service_unavailable, .category = .unavailable, .retryable = true },
        .{ .status = .not_implemented, .category = .unavailable, .retryable = false },
        .{ .status = .bad_request, .category = .protocol, .retryable = false },
    };
    for (cases) |expected| {
        const failure = fromHttpStatus(expected.status);
        try std.testing.expectEqual(expected.category, failure.category);
        try std.testing.expectEqual(@as(?u16, @intFromEnum(expected.status)), failure.http_status);
        try std.testing.expectEqual(expected.retryable, failure.retryable);
    }
}

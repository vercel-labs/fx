const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Result = enum {
    accepted,
    refused,
    unavailable,
};

pub const ValidateFn = *const fn (?*anyopaque, Allocator, []const u8) Result;

pub const Provider = struct {
    /// Vercel adapter validation capability; generic auth sees only normalized outcomes.
    /// When set, context must remain valid until every in-flight validation returns.
    context: ?*anyopaque = null,
    validate_fn: ValidateFn,

    pub fn validate(self: Provider, alloc: Allocator, api_key: []const u8) Result {
        return self.validate_fn(self.context, alloc, api_key);
    }
};

fn validateUnavailable(_: ?*anyopaque, _: Allocator, _: []const u8) Result {
    return .unavailable;
}

pub const unavailable_provider = Provider{
    .validate_fn = validateUnavailable,
};

test "api key validator dispatches through the injected provider" {
    const Fake = struct {
        calls: usize = 0,

        fn validate(raw_ctx: ?*anyopaque, _: Allocator, api_key: []const u8) Result {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            self.calls += 1;
            return if (std.mem.eql(u8, api_key, "accepted-key")) .accepted else .refused;
        }
    };

    var fake: Fake = .{};
    const provider = Provider{
        .context = &fake,
        .validate_fn = Fake.validate,
    };

    try std.testing.expectEqual(Result.accepted, provider.validate(std.testing.allocator, "accepted-key"));
    try std.testing.expectEqual(Result.refused, provider.validate(std.testing.allocator, "other-key"));
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

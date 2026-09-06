const std = @import("std");
const model_contract = @import("model_contract.zig");

const Allocator = std.mem.Allocator;

pub const Status = enum {
    success,
    failure,
};

/// Owned provider output. The caller frees `body` with the allocator passed to
/// `Provider.execute`.
pub const Result = struct {
    status: Status,
    body: []u8,
};

pub const ExecuteError = Allocator.Error || error{Cancelled};

pub const ExecuteFn = *const fn (
    ?*anyopaque,
    Allocator,
    *model_contract.Request,
    []const u8,
) ExecuteError!Result;

/// Host-facing executor for one validated registered subagent request. The
/// caller retains request ownership; the provider may inspect it during the
/// synchronous call but must not retain the pointer.
pub const Provider = struct {
    context: ?*anyopaque = null,
    execute_fn: ExecuteFn,

    pub fn execute(
        self: Provider,
        alloc: Allocator,
        request: *model_contract.Request,
        invocation_id: []const u8,
    ) ExecuteError!Result {
        return self.execute_fn(
            self.context,
            alloc,
            request,
            invocation_id,
        );
    }
};

test "provider forwards the validated managed request and invocation identity" {
    const Fixture = struct {
        calls: usize = 0,
        request: ?*model_contract.Request = null,
        invocation_id: ?[]const u8 = null,

        fn execute(
            raw_context: ?*anyopaque,
            alloc: Allocator,
            request: *model_contract.Request,
            invocation_id: []const u8,
        ) ExecuteError!Result {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            self.calls += 1;
            self.request = request;
            self.invocation_id = invocation_id;
            return .{
                .status = .success,
                .body = try alloc.dupe(u8, "executed"),
            };
        }
    };

    var fixture = Fixture{};
    var request = model_contract.Request{ .run = .{
        .task = @constCast("review this"),
    } };
    const provider = Provider{
        .context = &fixture,
        .execute_fn = Fixture.execute,
    };

    const result = try provider.execute(
        std.testing.allocator,
        &request,
        "call-1",
    );
    defer std.testing.allocator.free(result.body);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqualStrings("executed", result.body);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(fixture.request.? == &request);
    try std.testing.expectEqualStrings("call-1", fixture.invocation_id.?);
}
